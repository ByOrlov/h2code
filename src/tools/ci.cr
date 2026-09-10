require "json"
require "http/client"
require "uri"
require "compress/zip"
require "yaml"

module H2code
  module Tools
    # Full CI integration — automatic GitHub Actions / GitLab CI observation
    # after the agent pushes ("ping-pong" architecture).
    #
    # Flow:
    #   1. The Bash tool detects a successful `git push` (sudo-detect style)
    #      and calls `Ci.service.try_observe_push`.
    #   2. If the repo has GitHub Actions workflows and a github.com remote,
    #      an `Observer` starts polling every 30 s (gives up after 60 min).
    #      With a GitHub token
    #      configured (config `github.token` / GITHUB_TOKEN / GH_TOKEN)
    #      the observer polls api.github.com directly via `GithubApi` —
    #      no gh CLI, no browser login; without a token it falls back to
    #      the gh CLI (`gh run list` / `gh run view --log-failed`).
    #      GitLab repos (`.gitlab-ci.yml` + a gitlab.com remote, or a
    #      self-hosted one matching config `gitlab.endpoint` / GITLAB_HOST)
    #      are polled via the GitLab REST API (`GitlabApi`): the token
    #      (config `gitlab.token` / GITLAB_TOKEN / GITLAB_PRIVATE_TOKEN)
    #      is optional — public projects answer anonymous queries; private
    #      ones (401/403/404) are retried through the `glab` CLI
    #      (`glab api`, when installed) so its login covers them too.
    #   3. While pending, the TUI shows one animated "Waiting for CI for
    #      commit <sha>" line per watched commit in the active zone (with a
    #      `link:` to the commit's Actions checks page) and guards the
    #      Ctrl+D exit flow.
    #   4. On a terminal state: the TUI logs the outcome, a `ci.status` event
    #      is appended to the session wire log, and — unless a WaitForCI call
    #      claimed the observer — failures/errors/timeouts are delivered to
    #      the agent as a notification prompt so it can fix the build.
    #      Success is log-only (no turn is spawned).
    #
    # See features.md ("Full CI Integration") for the full description.
    module Ci
      # Fixed poll cadence: poll GitHub Actions every 30 s, no backoff.
      POLL_INTERVAL_S = 30
      # Give up observing after this many seconds and report "timeout".
      MAX_WAIT_S = 3600
      # Consecutive failed `gh` polls tolerated before the observer gives up
      # with an "error" terminal state. A single network blip / rate limit /
      # stderr noise in the gh output must NOT drop the wait line while the
      # build is still running.
      MAX_CONSECUTIVE_FAILURES = 5
      # Excerpt limits for gh output surfaced to the agent / user.
      DETAIL_EXCERPT_BYTES  =  300
      FAILURE_LOG_MAX_BYTES = 4000

      # Conclusions that mark a completed run as failed.
      BAD_CONCLUSIONS = {"failure", "cancelled", "timed_out", "action_required", "startup_failure"}

      # GitLab pipeline statuses that mark the pipeline as failed. `manual`
      # is a blocked pipeline waiting for a human (the analog of GitHub's
      # action_required). `skipped` counts as passed, like GitHub's skipped.
      GITLAB_BAD_STATUSES  = {"failed", "canceled", "manual"}
      GITLAB_GOOD_STATUSES = {"success", "skipped"}

      # CI provider of a watched repository.
      enum Provider
        Github
        Gitlab
      end

      enum Status
        Pending
        Success
        Failure
        Error
        Timeout

        def terminal? : Bool
          self != Pending
        end
      end

      # One GitHub REST API response: HTTP status code, body and the
      # redirect target, if the response still carries one (get follows
      # 3xx redirects transparently). status_code 0 marks a network-level
      # failure (DNS, TLS, too many redirects).
      record ApiResponse, status_code : Int32, body : String, location : String? = nil

      # Resolved CI repository of a working dir: provider, host ("github.com",
      # "gitlab.com", "gitlab.example.com") and project path ("owner/repo" /
      # "group/project"; GitLab paths may nest subgroups).
      record RepoInfo, provider : Provider, host : String, path : String do
        # URL-encoded project reference for GitLab API calls
        # ("group%2Fproject" — GitLab v4 expects the path double-safe for `/`).
        def gitlab_project_ref : String
          path.split('/').map { |seg| Ci.encode_path_segment(seg) }.join("%2F")
        end
      end

      # Direct GitHub REST client — the "own Crystal analog" of `gh run
      # list` / `gh run view --log-failed`. Used whenever a token is
      # available (config `github.token` / GITHUB_TOKEN / GH_TOKEN), so CI
      # observation never touches the gh CLI (and its browser login) at
      # all. Token goes only into the Authorization header; it is never
      # included in observer details or logs.
      class GithubApi
        API_BASE = "https://api.github.com"
        # Redirect hops followed per request — renamed repositories answer
        # 301 with the canonical `repositories/{id}` path, run logs answer
        # 302 with a signed URL.
        MAX_REDIRECTS = 3

        def initialize(@token : String? = nil)
        end

        def get(path : String) : ApiResponse
          url = path.starts_with?("http") ? path : "#{API_BASE}#{path}"
          MAX_REDIRECTS.times do
            uri = URI.parse(url)
            resp = HTTP::Client.new(uri) do |client|
              client.connect_timeout = 10.seconds
              client.read_timeout = 15.seconds
              client.get(uri.request_target, self.class.headers(@token))
            end
            target = self.class.redirect_target(resp)
            if target
              url = target.starts_with?("http") ? target : "#{uri.scheme}://#{uri.host}#{target}"
              next
            end
            return ApiResponse.new(resp.status_code, resp.body, resp.headers["Location"]?)
          end
          ApiResponse.new(0, "too many redirects: #{url}")
        rescue ex
          ApiResponse.new(0, ex.message.to_s)
        end

        # Redirect target of a 3xx GitHub API response: the Location
        # header, or the `url` field of the JSON body (GitHub's
        # moved-repository notices carry the canonical URL in the body).
        # Nil for non-redirect responses without a usable target.
        def self.redirect_target(resp : HTTP::Client::Response) : String?
          return nil unless resp.status.redirection?
          location = resp.headers["Location"]?
          return location if location && !location.empty?
          resp.body.match(/"url":\s*"(https?:[^"]+)"/).try(&.[1].gsub("\\/", "/"))
        end

        def self.headers(token : String?) : HTTP::Headers
          headers = HTTP::Headers{
            "Accept"               => "application/vnd.github+json",
            "X-GitHub-Api-Version" => "2022-11-28",
            "User-Agent"           => "h2code",
          }
          headers["Authorization"] = "Bearer #{token}" if token && !token.empty?
          headers
        end
      end

      # Direct GitLab v4 REST client. The base URL comes from the remote host
      # (gitlab.com or a self-hosted endpoint). The token is optional —
      # public projects answer anonymous pipeline queries; private ones need
      # a personal access token (config `gitlab.token` / GITLAB_TOKEN /
      # GITLAB_PRIVATE_TOKEN) sent via the Private-Token header, which never
      # reaches observer details or logs.
      class GitlabApi
        def initialize(@base_url : String = "https://gitlab.com", @token : String? = nil)
        end

        def get(path : String) : ApiResponse
          uri = URI.parse("#{@base_url}/api/v4#{path}")
          resp = HTTP::Client.new(uri) do |client|
            client.connect_timeout = 10.seconds
            client.read_timeout = 15.seconds
            client.get(uri.request_target, self.class.headers(@token))
          end
          ApiResponse.new(resp.status_code, resp.body, resp.headers["Location"]?)
        rescue ex
          ApiResponse.new(0, ex.message.to_s)
        end

        def self.headers(token : String?) : HTTP::Headers
          headers = HTTP::Headers{
            "Accept"     => "application/json",
            "User-Agent" => "h2code",
          }
          headers["Private-Token"] = token if token && !token.empty?
          headers
        end
      end

      # RepoInfo for a github.com git remote URL (SSH and HTTPS forms), or nil
      # for non-GitHub remotes. Path is the lowercased `owner/repo` (GitHub
      # paths are case-insensitive).
      def self.parse_github_remote(url : String) : RepoInfo?
        url = url.strip.downcase
        ssh = url.match(%r{git@github\.com:([^/\s]+/[^/\s]+?)(?:\.git)?$})
        https = url.match(%r{https?://(?:[^@\s]+@)?github\.com/([^/\s]+/[^/\s]+?)(?:\.git)?$})
        if m = ssh || https
          RepoInfo.new(Provider::Github, "github.com", m[1])
        end
      end

      # RepoInfo for a GitLab git remote URL (SSH and HTTPS forms, nested
      # subgroup paths allowed), or nil when the remote host is not one of
      # `hosts` (gitlab.com plus the self-hosted endpoint hosts from config).
      # The path stays case-sensitive — GitLab paths are.
      def self.parse_gitlab_remote(url : String, hosts : Array(String) = ["gitlab.com"]) : RepoInfo?
        url = url.strip
        ssh = url.match(%r{git@([^:\s/]+):(.+?)(?:\.git)?$})
        https = url.match(%r{(?:https?|ssh)://(?:[^@\s]+@)?([^/:\s]+)(?::\d+)?/(.+?)(?:\.git)?$})
        if m = ssh || https
          # Ports are not part of the host for host matching (the endpoint
          # host from config never carries one); URLs like
          # http://user:token@host:8080/group/proj.git are expected.
          host = m[1].downcase.split(':')[0]?
          # A project path is at least `namespace/name`.
          return RepoInfo.new(Provider::Gitlab, host, m[2]) if host && hosts.includes?(host) && m[2].includes?('/')
        end
      end

      # Percent-encode one URL path segment (unreserved chars kept as-is).
      def self.encode_path_segment(segment : String) : String
        String.build do |buf|
          segment.each_byte do |b|
            if (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) ||
               {0x2D, 0x2E, 0x5F, 0x7E}.includes?(b)
              buf.write_byte(b)
            else
              buf << '%' << b.to_s(16).upcase.rjust(2, '0')
            end
          end
        end
      end

      # Concatenate the text entries of a GitHub run-logs zip archive. The
      # zip bytes arrive as a String body (unvalidated UTF-8) — to_slice
      # recovers the exact original bytes for the zip reader.
      def self.extract_zip_text(zip_body : String) : String
        String.build do |s|
          Compress::Zip::Reader.open(IO::Memory.new(zip_body.to_slice)) do |reader|
            reader.each_entry do |entry|
              next if entry.dir?
              s << entry.io.gets_to_end
              s << '\n'
            end
          end
        end
      rescue
        ""
      end

      # One watched commit. Mutated only by the service (poll fiber or tests);
      # read by the TUI renderer and the WaitForCI tool.
      class Observer
        getter sha : String
        getter started_at : Time = Time.utc
        property status : Status = Status::Pending
        property provider : Provider = Provider::Github
        property detail : String = ""
        property failure_log : String = ""
        # Set by WaitForCI: the tool result replaces the automatic completion
        # notification, so delivery is suppressed for this observer.
        property? claimed : Bool = false
        # Guards against spawning a second poll fiber for the same observer.
        property? polling : Bool = false
        # Clickable link to the commit's checks page on github.com, shown in
        # the active-zone wait line. Empty when the owner/repo pair is not
        # (yet) known — set by the service from the per-cwd remote cache.
        property actions_url : String = ""
        # Failed `gh` polls in a row (reset on any successful poll). While
        # below MAX_CONSECUTIVE_FAILURES the observer stays Pending so the
        # active-zone wait line never disappears on a transient blip.
        property consecutive_failures : Int32 = 0

        @started_mono : Time::Span

        def initialize(@sha : String)
          @started_mono = Time.monotonic
        end

        def short_sha : String
          sha[0, Math.min(7, sha.size)]
        end

        def elapsed_s : Int32
          (Time.monotonic - @started_mono).total_seconds.to_i.clamp(0..Int32::MAX)
        end

        def pending? : Bool
          status.pending?
        end

        def terminal? : Bool
          status.terminal?
        end
      end

      @@service : CiService?

      def self.service=(s : CiService?)
        @@service = s
      end

      def self.service : CiService?
        @@service
      end

      # Exit code + combined output of a shell invocation in a working dir.
      record CommandResult, exit_code : Int32, output : String

      # Default runner: real subprocess, combined stdout+stderr. Swapped out
      # in tests via `LiveCiService#runner=`.
      def self.run_shell(command : String, cwd : String) : CommandResult
        output = IO::Memory.new
        status = Process.run(command, shell: true, chdir: cwd,
          output: output, error: output)
        CommandResult.new(status.exit_code, output.to_s)
      rescue ex : File::NotFoundError | IO::Error | ArgumentError
        CommandResult.new(127, ex.message.to_s)
      rescue ex
        CommandResult.new(1, ex.message.to_s)
      end

      # True when any `;`/`|`/`&`-separated segment is a git invocation whose
      # subcommand is `push` (handles `git -C dir push`, flag prefixes).
      def self.push_command?(command : String) : Bool
        value_flags = {"-C", "--git-dir", "--work-tree", "--namespace"}
        command.split(/[;|&]+/).each do |segment|
          tokens = segment.strip.split(/\s+/)
          next unless tokens.first? == "git" && tokens.size > 1
          i = 1
          while i < tokens.size
            token = tokens[i]
            if token == "push"
              return true
            elsif token.starts_with?('-')
              # A value flag consumes the next token too (`git -C dir push`).
              i += value_flags.includes?(token) ? 2 : 1
            else
              break
            end
          end
        end
        false
      end

      # Repo directory targeted by a git command: resolves `git -C <dir>`
      # when present (relative to `default`), so a push into another
      # repository observes the right HEAD instead of the session cwd.
      def self.repo_dir_from_command(command : String, default : String) : String
        command.split(/[;|&]+/).each do |segment|
          tokens = segment.strip.split(/\s+/)
          next unless tokens.first? == "git"
          i = 1
          while i < tokens.size
            token = tokens[i]
            if token == "-C" && (dir = tokens[i + 1]?)
              return File.expand_path(dir, default) unless dir.empty?
            end
            break unless token.starts_with?('-')
            i += 1
          end
        end
        default
      end

      # Does any workflow in `.github/workflows` run on a push of `branch`?
      # Gates the post-push observer: a push to a ref no workflow's
      # `on.push` trigger covers never produces a CI status, so observing
      # it would just park a "Waiting for CI" line until MAX_WAIT_S.
      # Mirrors GitHub's matching closely enough for that gate: a `push`
      # trigger with no branch filter covers every branch, `branches` /
      # `branches-ignore` hold fnmatch-style globs (`*`, `**`, `?`,
      # `[...]`) matched with `File.match?`. Undecidable input (empty or
      # detached branch, no workflow files, YAML the parser rejects)
      # counts as covered, so observation degrades to the old behavior
      # instead of skipping a real build. GitLab repos have no workflows
      # dir and stay covered — `.gitlab-ci.yml` `workflow:rules` are not
      # parsed.
      def self.push_covers_branch?(repo_dir : String, branch : String) : Bool
        return true if branch.empty? || branch == "HEAD"
        paths = Dir.glob(File.join(repo_dir, ".github", "workflows", "*.{yml,yaml}"))
        return true if paths.empty?
        paths.each do |path|
          doc = begin
            YAML.parse(File.read(path))
          rescue YAML::ParseException | IO::Error | File::NotFoundError
            # Undecidable → covered, so observation degrades to the old
            # behavior instead of skipping a possible build.
            return true
          end
          filters = push_trigger(doc)
          next if filters.nil? # no push event in this workflow
          branches, ignore = filters
          covered = if branches
                      branches.any? { |p| File.match?(p, branch) }
                    elsif ignore
                      !ignore.any? { |p| File.match?(p, branch) }
                    else
                      true # push with no branch filter — every branch covered
                    end
          return true if covered
        end
        false
      end

      # `on.push` trigger of a workflow doc: nil when the workflow has no
      # push event, otherwise its branch filters (nil component = absent).
      private def self.push_trigger(doc : YAML::Any) : {Array(String)?, Array(String)?}?
        on = on_value(doc)
        return nil if on.nil?
        push = case raw = on.raw
               when Hash     then on["push"]?
               when Array    then raw.any?(&.to_s.==("push")) ? true : nil
               when String   then raw == "push" ? true : nil
               else               nil
               end
        return nil if push.nil?
        return {nil, nil} if push.is_a?(Bool) # bare push trigger — no filters
        # `push:` with a null value wraps nil; YAML::Any#[]? only indexes
        # Array/Hash and raises otherwise.
        return {nil, nil} unless push.raw.is_a?(Hash)
        {string_array(push["branches"]?), string_array(push["branches-ignore"]?)}
      end

      # The value of the `on:` key. YAML 1.1 parsers (and Crystal's) resolve
      # the bare `on:` scalar to boolean true, so besides the string lookups
      # the raw mapping keys are scanned for a boolean true.
      private def self.on_value(doc : YAML::Any) : YAML::Any?
        if v = doc["on"]? || doc["true"]?
          return v
        end
        if h = doc.raw.as?(Hash)
          h.each do |k, v|
            return v if k.raw.as?(Bool) == true
          end
        end
        nil
      end

      private def self.string_array(value : YAML::Any?) : Array(String)?
        return nil if value.nil?
        case raw = value.raw
        when Array  then raw.map(&.to_s)
        when String then [raw]
        else             nil
        end
      end

      # Aggregate `gh run list --json` / Actions API run rows into an observer
      # status. Pending while any run is in progress or none is registered
      # yet. `event: dynamic` rows (Dependabot's dependabot-updates
      # bookkeeping runs, which attach to the default branch head month after
      # month) are not builds of the commit and are ignored — counted in,
      # they drown out the commit's real runs and fabricate a pass verdict.
      def self.aggregate_runs(runs : Array(JSON::Any)) : {Status, String}
        runs = runs.reject { |run| run["event"]?.try(&.to_s) == "dynamic" }
        return {Status::Pending, "no runs reported yet"} if runs.empty?
        in_progress = [] of String
        failed = [] of String
        passed = 0
        runs.each do |run|
          name = run["name"]?.try(&.to_s) || "run"
          status = run["status"]?.try(&.to_s) || ""
          conclusion = run["conclusion"]?.try(&.to_s) || ""
          if status != "completed"
            in_progress << name
          elsif BAD_CONCLUSIONS.includes?(conclusion)
            failed << "#{name} (#{conclusion})"
          else
            passed += 1
          end
        end
        unless in_progress.empty?
          return {Status::Pending, "in progress: #{in_progress.join(", ")}"}
        end
        if failed.empty?
          {Status::Success, "#{passed} run(s) passed"}
        else
          {Status::Failure, failed.join(", ")}
        end
      end

      # Aggregate GitLab pipeline rows into an observer status. Pending while
      # any pipeline is in progress or none is registered yet.
      def self.aggregate_pipelines(pipelines : Array(JSON::Any)) : {Status, String}
        return {Status::Pending, "no pipelines reported yet"} if pipelines.empty?
        in_progress = [] of String
        failed = [] of String
        passed = 0
        pipelines.each do |pipeline|
          name = "pipeline ##{pipeline["id"]?.try(&.to_s) || "?"}"
          status = pipeline["status"]?.try(&.to_s) || ""
          if GITLAB_BAD_STATUSES.includes?(status)
            failed << "#{name} (#{status})"
          elsif GITLAB_GOOD_STATUSES.includes?(status)
            passed += 1
          else
            in_progress << name
          end
        end
        unless in_progress.empty?
          return {Status::Pending, "in progress: #{in_progress.join(", ")}"}
        end
        if failed.empty?
          {Status::Success, "#{passed} pipeline(s) passed"}
        else
          {Status::Failure, failed.join(", ")}
        end
      end

      # Keep at most `bytes` of a string; on cut keep the tail (errors and
      # failure summaries live at the end of gh output).
      def self.excerpt(text : String, bytes : Int32) : String
        return text if text.bytesize <= bytes
        "...#{text.byte_slice(text.bytesize - bytes, bytes)}"
      end

      abstract class CiService
        abstract def try_observe_push(command : String, cwd : String) : Bool
        abstract def observe(sha : String, cwd : String) : Bool
        abstract def observer_for(sha : String) : Observer?
        abstract def pending_observer : Observer?
        abstract def pending_observers : Array(Observer)
        abstract def pending? : Bool
        abstract def head_sha(cwd : String) : String?

        # Branch of the repo at `cwd` ("" when undeterminable). Combined
        # with `Ci.push_covers_branch?` to skip observing pushes no
        # workflow triggers on. Concrete default keeps test doubles
        # simple; `LiveCiService` overrides.
        def current_branch(cwd : String) : String
          ""
        end
      end

      class LiveCiService < CiService
        property delivery : (String -> Nil)? = nil
        property store : Session::Store? = nil
        property on_update : (Observer -> Nil)? = nil
        # Swappable command runner (tests inject a fake here).
        property runner : (String, String) -> CommandResult = ->H2code::Tools::Ci.run_shell(String, String)
        # When false, `observe` registers the observer without spawning the
        # poll fiber — tests drive `poll_once` manually.
        property? autostart : Bool = true
        # Explicit GitHub API token (config `github.token`, with
        # GITHUB_TOKEN / GH_TOKEN env overrides applied by Config.load and
        # passed in at the wiring site). With a token present the observers
        # poll api.github.com directly (no gh CLI); without one they fall
        # back to the gh CLI path.
        property github_token : String = ""
        # GitLab API token (config `gitlab.token`, env GITLAB_TOKEN /
        # GITLAB_PRIVATE_TOKEN). Optional — public projects are polled
        # anonymously; private ones need it.
        property gitlab_token : String = ""
        # Self-hosted GitLab base URL (config `gitlab.endpoint`, env
        # GITLAB_HOST), e.g. "https://gitlab.example.com". Remotes on that
        # host are treated as GitLab; gitlab.com always is.
        property gitlab_endpoint : String = ""
        # glab CLI availability, probed once on first use (glab_ready?).
        # Injectable in tests to skip the probe subprocess.
        property? glab_available : Bool = false
        property? glab_probed : Bool = false
        # Injectable REST GET for tests; defaults to real GithubApi/GitlabApi.
        property api_get : (String -> ApiResponse)? = nil

        @observers = [] of Observer
        @mutex = Mutex.new
        # Per-cwd repo resolution of `git remote get-url origin`.
        @repo_cache = {} of String => RepoInfo?

        def initialize(@github_token : String = "", @gitlab_token : String = "",
                       @gitlab_endpoint : String = "")
        end

        # Token for direct REST polling (nil → gh CLI fallback mode).
        private def api_token : String?
          @github_token.presence
        end

        # Resolved REST-poll target for the GitHub repo at cwd, or nil when
        # no token is available or the repo is not GitHub (→ gh CLI fallback
        # on GitHub, dedicated GitLab path on GitLab). The remote is resolved
        # once per cwd.
        private record ApiTarget, repo : RepoInfo, token : String

        private def api_target(cwd : String) : ApiTarget?
          token = api_token
          return nil if token.nil?
          info = resolve_repo(cwd)
          return nil if info.nil? || !info.provider.github?
          ApiTarget.new(info, token)
        end

        # GitLab hosts whose remotes are observed: gitlab.com plus the host
        # of the configured self-hosted endpoint.
        private def gitlab_hosts : Array(String)
          hosts = ["gitlab.com"]
          if ep = @gitlab_endpoint.presence
            begin
              host = URI.parse(ep.starts_with?("http") ? ep : "https://#{ep}").host
              hosts << host.downcase if host && !host.empty?
            rescue
            end
          end
          hosts
        end

        # API base URL for the GitLab host of `info`: the configured
        # endpoint when its host matches (keeps scheme / port), otherwise
        # https://<remote host>.
        private def gitlab_api_base(info : RepoInfo) : String
          if ep = @gitlab_endpoint.presence
            begin
              uri = URI.parse(ep.starts_with?("http") ? ep : "https://#{ep}")
              return uri.to_s if uri.host.try(&.downcase) == info.host
            rescue
            end
          end
          "https://#{info.host}"
        end

        # Resolve (and cache per-cwd) the CI repo info for the repo at `cwd`.
        private def resolve_repo(cwd : String) : RepoInfo?
          cached = @mutex.synchronize { @repo_cache[cwd]? }
          return cached if cached
          return nil if @mutex.synchronize { @repo_cache.has_key?(cwd) }
          info = detect_repo(cwd)
          @mutex.synchronize { @repo_cache[cwd] = info }
          info
        end

        # Provider detection for the repo at cwd: GitHub Actions
        # (`.github/workflows` + github.com remote) takes precedence, then
        # GitLab CI (`.gitlab-ci.yml` + a gitlab.com / configured-endpoint
        # remote). Marker directories are checked first so repos that are
        # not CI-eligible resolve to nil without spawning any command. Nil
        # when the repo is not eligible for CI observation.
        private def detect_repo(cwd : String) : RepoInfo?
          gh_marker = Dir.exists?(File.join(cwd, ".github", "workflows"))
          gl_marker = File.exists?(File.join(cwd, ".gitlab-ci.yml"))
          return nil unless gh_marker || gl_marker
          remote = run("git remote get-url origin", cwd)
          return nil if remote.exit_code != 0
          url = remote.output.strip
          info = gh_marker ? Ci.parse_github_remote(url) : nil
          info ||= gl_marker ? Ci.parse_gitlab_remote(url, gitlab_hosts) : nil
          info
        end

        private def api_call(path : String) : ApiResponse
          getter = @api_get
          return getter.call(path) if getter
          GithubApi.new(api_token).get(path)
        end

        # REST GET against the GitLab host of `info` (test-injectable via
        # the same api_get hook; tests distinguish providers by path shape).
        private def api_call_gitlab(info : RepoInfo, path : String) : ApiResponse
          getter = @api_get
          return getter.call(path) if getter
          GitlabApi.new(gitlab_api_base(info), @gitlab_token.presence).get(path)
        end

        def try_observe_push(command : String, cwd : String) : Bool
          return false unless Ci.push_command?(command)
          repo_dir = Ci.repo_dir_from_command(command, cwd)
          sha = head_sha(repo_dir)
          return false if sha.nil?
          return false unless observe_push_branch?(repo_dir)
          observe(sha, repo_dir)
        end

        # A plain `git push` publishes the current branch, so before
        # observing, check that branch against the workflows' `on.push`
        # triggers. When no workflow covers it, CI never runs for the
        # sha — report that instead of parking a "Waiting for CI" line
        # until MAX_WAIT_S. Refspec pushes (`git push origin HEAD:master`)
        # are not parsed; an undeterminable branch (empty / detached HEAD)
        # falls through to observing, same as before.
        private def observe_push_branch?(repo_dir : String) : Bool
          branch = current_branch(repo_dir)
          return true if Ci.push_covers_branch?(repo_dir, branch)
          notify_uncovered_branch(branch)
          false
        end

        # One-shot "nothing to observe" notification, shaped like the
        # observer completion notifications so the delivery path is reused.
        private def notify_uncovered_branch(branch : String) : Nil
          body = "Branch: #{branch}\n" \
                 "No CI workflow triggers on pushes to this branch, so no CI build will run for it. " \
                 "Nothing is being observed. Check the `on: push` branch filters in .github/workflows " \
                 "if you expected a build."
          data = {
            "id"          => JSON::Any.new("ci.noci.#{branch}"),
            "category"    => JSON::Any.new("ci_completion"),
            "type"        => JSON::Any.new("skipped"),
            "source_kind" => JSON::Any.new("ci"),
            "source_id"   => JSON::Any.new(branch),
            "title"       => JSON::Any.new("No CI build for this branch"),
            "severity"    => JSON::Any.new("info"),
            "body"        => JSON::Any.new(body),
          } of String => JSON::Any
          @delivery.try(&.call(Tools.render_notification_xml(data)))
        end

        # Branch of the repo at `cwd`, "" when HEAD is detached or the
        # lookup fails (both treated as "undeterminable — observe").
        def current_branch(cwd : String) : String
          res = run("git rev-parse --abbrev-ref HEAD", cwd)
          res.exit_code == 0 ? res.output.strip : ""
        end

        # HEAD sha of the repo at `cwd`, or nil when the repo is not eligible
        # for CI observation (see `detect_repo`: GitHub needs
        # `.github/workflows` + a github.com remote, GitLab needs
        # `.gitlab-ci.yml` + a GitLab remote).
        def head_sha(cwd : String) : String?
          return nil if resolve_repo(cwd).nil?
          rev = run("git rev-parse HEAD", cwd)
          sha = rev.output.strip
          return nil if rev.exit_code != 0 || sha.size != 40 || sha =~ /[^0-9a-f]/
          sha
        end

        # Resolved CI repo info for the repo at `cwd` (provider detection,
        # same eligibility as head_sha) — used by the startup token tip.
        def repo_info(cwd : String) : RepoInfo?
          resolve_repo(cwd)
        end

        def observe(sha : String, cwd : String) : Bool
          obs = @mutex.synchronize do
            existing = @observers.find { |o| o.sha == sha }
            if existing && !existing.terminal?
              next existing
            end
            @observers.reject! { |o| o.sha == sha }
            fresh = Observer.new(sha)
            @observers << fresh
            fresh
          end
          if info = @mutex.synchronize { @repo_cache[cwd]? }
            obs.provider = info.provider
          end
          set_actions_url(obs, cwd)
          @on_update.try(&.call(obs))
          if obs.pending? && !obs.polling?
            obs.polling = true
            spawn { poll_loop(obs, cwd) } if autostart?
          end
          obs.pending?
        end

        def observer_for(sha : String) : Observer?
          @mutex.synchronize { @observers.find { |o| o.sha == sha } }
        end

        def pending_observer : Observer?
          @mutex.synchronize { @observers.reverse_each.find(&.pending?) }
        end

        # All pending observers, oldest push first. Every pushed commit gets
        # its own observer, and the active zone renders one wait line per
        # entry. Returns a copy safe to iterate outside the mutex.
        def pending_observers : Array(Observer)
          @mutex.synchronize { @observers.select(&.pending?) }
        end

        def pending? : Bool
          @mutex.synchronize { @observers.any?(&.pending?) }
        end

        def poll_loop(obs : Observer, cwd : String) : Nil
          while obs.pending?
            sleep POLL_INTERVAL_S.seconds
            if obs.elapsed_s >= MAX_WAIT_S
              obs.status = Status::Timeout
              obs.detail = "gave up after #{MAX_WAIT_S}s"
              settle(obs)
              return
            end
            poll_once(obs, cwd)
          end
        end

        # One polling step. Public so tests can drive the state machine with
        # a scripted runner. GitLab observers poll the GitLab REST API
        # directly (token optional; denied access falls back to the glab
        # CLI). GitHub observers use the REST API when
        # a token is available (config / env); otherwise they fall back to
        # the gh CLI. Transient failures (non-zero gh exit, HTTP 5xx
        # / rate limits, output that is not valid JSON — stderr is merged
        # into stdout on the gh path) only count towards
        # `consecutive_failures`; the observer stays Pending until
        # MAX_CONSECUTIVE_FAILURES in a row, so the "Waiting for CI" line
        # does not vanish while the build is still running.
        def poll_once(obs : Observer, cwd : String) : Nil
          return unless obs.pending?
          if obs.provider.gitlab?
            poll_once_via_gitlab(obs, cwd)
          elsif target = api_target(cwd)
            poll_once_via_api(obs, target)
          elsif resolve_repo(cwd).try(&.provider.gitlab?)
            # GitLab repo observed without a prior push detection (e.g.
            # WaitForCI on a fresh sha): switch the observer to GitLab.
            obs.provider = Ci::Provider::Gitlab
            poll_once_via_gitlab(obs, cwd)
          else
            poll_once_via_gh(obs, cwd)
          end
        end

        # Direct REST polling (token mode): GET /actions/runs?head_sha=…,
        # map onto the same aggregation as the gh path.
        private def poll_once_via_api(obs : Observer, target : ApiTarget) : Nil
          # per_page=100: runs come back newest-first, and bookkeeping runs
          # (Dependabot updates) must not crowd the commit's real runs off
          # the first page before aggregation filters them out.
          res = api_call("/repos/#{target.repo.path}/actions/runs?head_sha=#{obs.sha}&per_page=100")
          unless res.status_code == 200
            record_poll_failure(obs, "GitHub API HTTP #{res.status_code}: #{Ci.excerpt(res.body, DETAIL_EXCERPT_BYTES)}")
            return
          end
          begin
            runs = JSON.parse(res.body)["workflow_runs"].as_a
          rescue JSON::ParseException | KeyError | TypeCastError
            record_poll_failure(obs, "unexpected GitHub API output: #{Ci.excerpt(res.body, DETAIL_EXCERPT_BYTES)}")
            return
          end
          obs.consecutive_failures = 0
          status, detail = Ci.aggregate_runs(runs)
          obs.detail = detail
          if status.terminal?
            obs.failure_log = Ci.excerpt(api_fetch_failure_log(target, runs), FAILURE_LOG_MAX_BYTES) if status.failure?
            obs.status = status
            settle(obs)
          end
        end

        # GitLab REST polling: GET /projects/<ref>/pipelines?sha=… — the
        # token is optional (public projects answer anonymously). Private
        # projects deny that access (GitLab answers 404 to avoid leaking
        # existence); when that happens and the glab CLI is installed, the
        # poll is retried through `glab api` — its login covers private
        # projects without a token in h2code's config.
        private def poll_once_via_gitlab(obs : Observer, cwd : String) : Nil
          info = resolve_repo(cwd)
          if info.nil? || !info.provider.gitlab?
            record_poll_failure(obs, "repository is no longer GitLab-connected")
            return
          end
          res = api_call_gitlab(info, gitlab_pipelines_path(info, obs))
          if {401, 403, 404}.includes?(res.status_code) && glab_ready?(cwd)
            poll_once_via_glab(obs, info, cwd)
          else
            handle_gitlab_poll_response(obs, info, cwd, res)
          end
        end

        private def gitlab_pipelines_path(info : RepoInfo, obs : Observer) : String
          "/projects/#{info.gitlab_project_ref}/pipelines?sha=#{obs.sha}&per_page=20"
        end

        private def handle_gitlab_poll_response(obs : Observer, info : RepoInfo,
                                                cwd : String, res : ApiResponse) : Nil
          case res.status_code
          when 200
            begin
              pipelines = JSON.parse(res.body).as_a
            rescue JSON::ParseException | TypeCastError
              record_poll_failure(obs, "unexpected GitLab API output: #{Ci.excerpt(res.body, DETAIL_EXCERPT_BYTES)}")
              return
            end
            settle_gitlab_pipelines(obs, info, cwd, pipelines, via_glab: false)
          when 401, 403
            record_poll_failure(obs, "GitLab API HTTP #{res.status_code}: set a GitLab token (config gitlab.token / GITLAB_TOKEN env) or log in with `glab auth login` to observe private projects")
          when 404
            record_poll_failure(obs, "GitLab API HTTP 404: project not found — check the remote URL and token access")
          else
            record_poll_failure(obs, "GitLab API HTTP #{res.status_code}: #{Ci.excerpt(res.body, DETAIL_EXCERPT_BYTES)}")
          end
        end

        # Shared terminal handling for both GitLab backends: aggregate the
        # pipelines, capture the failure-log excerpt on failure, settle.
        private def settle_gitlab_pipelines(obs : Observer, info : RepoInfo, cwd : String,
                                            pipelines : Array(JSON::Any), via_glab : Bool) : Nil
          obs.consecutive_failures = 0
          status, detail = Ci.aggregate_pipelines(pipelines)
          obs.detail = detail
          if status.terminal?
            if status.failure?
              log = via_glab ? glab_fetch_failure_log(info, pipelines, cwd) : gitlab_fetch_failure_log(info, pipelines)
              obs.failure_log = Ci.excerpt(log, FAILURE_LOG_MAX_BYTES)
            end
            obs.status = status
            settle(obs)
          end
        end

        # glab CLI polling: `glab api` is an authenticated passthrough to
        # the same v4 endpoints (its login covers private projects). The
        # explicit `-X GET` matters: with --hostname alone glab flips its
        # default method to POST.
        private def poll_once_via_glab(obs : Observer, info : RepoInfo, cwd : String) : Nil
          res = run(glab_api_command(info, gitlab_pipelines_path(info, obs)), cwd)
          unless res.exit_code == 0
            record_poll_failure(obs, "glab failed (exit #{res.exit_code}): #{Ci.excerpt(res.output, DETAIL_EXCERPT_BYTES)}")
            return
          end
          begin
            pipelines = JSON.parse(res.output).as_a
          rescue JSON::ParseException | TypeCastError
            record_poll_failure(obs, "unexpected glab output: #{Ci.excerpt(res.output, DETAIL_EXCERPT_BYTES)}")
            return
          end
          settle_gitlab_pipelines(obs, info, cwd, pipelines, via_glab: true)
        end

        # Shell invocation of `glab api` for one v4 endpoint path. The path
        # is single-quoted (it carries ?/&/%); its bytes come from the
        # percent-encoded project ref and hex/numeric ids, never a quote.
        private def glab_api_command(info : RepoInfo, path : String) : String
          "glab api --hostname #{info.host} -X GET '#{path.lchop('/')}'"
        end

        # True when the glab CLI is installed (probed once per service;
        # injectable in tests via glab_probed= / glab_available=).
        private def glab_ready?(cwd : String) : Bool
          return @glab_available if @glab_probed
          @glab_probed = true
          @glab_available = run("glab --version", cwd).exit_code == 0
          @glab_available
        end

        # gh CLI polling (fallback mode — needs an interactive gh login).
        private def poll_once_via_gh(obs : Observer, cwd : String) : Nil
          # event is requested so aggregation can drop Dependabot's dynamic
          # bookkeeping runs; --limit 100 keeps real runs from being crowded
          # off the newest-first listing.
          res = run("gh run list -c #{obs.sha} --json databaseId,name,status,conclusion,event --limit 100", cwd)
          unless res.exit_code == 0
            record_poll_failure(obs, "gh failed (exit #{res.exit_code}): #{Ci.excerpt(res.output, DETAIL_EXCERPT_BYTES)}")
            return
          end
          begin
            runs = JSON.parse(res.output).as_a
          rescue JSON::ParseException
            record_poll_failure(obs, "unexpected gh output: #{Ci.excerpt(res.output, DETAIL_EXCERPT_BYTES)}")
            return
          end
          obs.consecutive_failures = 0
          status, detail = Ci.aggregate_runs(runs)
          obs.detail = detail
          if status.terminal?
            obs.failure_log = fetch_failure_log(runs, cwd) if status.failure?
            obs.status = status
            settle(obs)
          end
        end

        # Count a failed poll. Terminal Error only after MAX_CONSECUTIVE_FAILURES
        # consecutive failures; before that the observer keeps waiting and the
        # failure is surfaced via `detail` for the next outcome message.
        private def record_poll_failure(obs : Observer, reason : String) : Nil
          obs.consecutive_failures += 1
          if obs.consecutive_failures >= MAX_CONSECUTIVE_FAILURES
            obs.status = Status::Error
            obs.detail = reason
            settle(obs)
          else
            obs.detail = "retrying after: #{reason}"
          end
        end

        private def run(command : String, cwd : String) : CommandResult
          runner.call(command, cwd)
        end

        # Best-effort link to the commit's checks page, shown in the
        # active-zone wait line so the build can be opened with a click.
        # Resolved from the per-cwd remote cache (populated by
        # head_sha / resolve_repo); no extra subprocess is spawned here, and
        # the link stays empty when the repo info is unknown.
        private def set_actions_url(obs : Observer, cwd : String) : Nil
          return unless obs.actions_url.empty?
          info = @mutex.synchronize { @repo_cache[cwd]? }
          return if info.nil?
          obs.actions_url = case info.provider
                            when .gitlab?
                              # gitlab_api_base carries the configured
                              # endpoint's scheme/port; the web UI lives on
                              # the same base as the API.
                              "#{gitlab_api_base(info)}/#{info.path}/-/commits/#{obs.sha}"
                            else
                              "https://github.com/#{info.path}/commit/#{obs.sha}/checks"
                            end
        end

        # Excerpt of the failed-step log for the first failed run.
        private def fetch_failure_log(runs : Array(JSON::Any), cwd : String) : String
          failed_id = nil
          runs.each do |run|
            conclusion = run["conclusion"]?.try(&.to_s) || ""
            next unless run["status"]?.try(&.to_s) == "completed"
            next unless Ci::BAD_CONCLUSIONS.includes?(conclusion)
            failed_id = run["databaseId"]?.try(&.to_s)
            break
          end
          return "" if failed_id.nil?
          res = run("gh run view #{failed_id} --log-failed", cwd)
          return "" unless res.exit_code == 0
          Ci.excerpt(res.output, FAILURE_LOG_MAX_BYTES)
        end

        # Same as fetch_failure_log but over the REST API: the run-logs
        # endpoint answers 302 with a signed URL, whose body is a zip of
        # plain-text step logs. Best-effort — any failure yields "".
        private def api_fetch_failure_log(target : ApiTarget, runs : Array(JSON::Any)) : String
          failed_run = runs.find do |run|
            run["status"]?.try(&.to_s) == "completed" &&
              Ci::BAD_CONCLUSIONS.includes?(run["conclusion"]?.try(&.to_s) || "")
          end
          failed_id = failed_run.try { |r| r["id"]?.try(&.to_s) }
          return "" if failed_id.nil?
          res = api_call("/repos/#{target.repo.path}/actions/runs/#{failed_id}/logs")
          if res.status_code == 302 && (loc = res.location)
            res = api_call(loc)
          end
          return "" unless res.status_code == 200
          Ci.extract_zip_text(res.body)
        rescue
          ""
        end

        # GitLab failure log: the first failed pipeline → its jobs → the
        # first hard-failed job (allow_failure jobs do not fail the
        # pipeline) → the job's trace (plain text). Best-effort — any
        # failure yields "".
        private def gitlab_fetch_failure_log(info : RepoInfo, pipelines : Array(JSON::Any)) : String
          ids = gitlab_failed_pipeline_ids(pipelines)
          return "" if ids.nil?
          project_id, pipeline_id = ids
          res = api_call_gitlab(info, "/projects/#{project_id}/pipelines/#{pipeline_id}/jobs?per_page=50")
          return "" unless res.status_code == 200
          begin
            jobs = JSON.parse(res.body).as_a
          rescue JSON::ParseException | TypeCastError
            return ""
          end
          job_id = gitlab_failed_job_id(jobs)
          return "" if job_id.nil?
          res = api_call_gitlab(info, "/projects/#{project_id}/jobs/#{job_id}/trace")
          res.status_code == 200 ? res.body : ""
        rescue
          ""
        end

        # Same as gitlab_fetch_failure_log but through `glab api`.
        private def glab_fetch_failure_log(info : RepoInfo, pipelines : Array(JSON::Any), cwd : String) : String
          ids = gitlab_failed_pipeline_ids(pipelines)
          return "" if ids.nil?
          project_id, pipeline_id = ids
          res = run(glab_api_command(info, "/projects/#{project_id}/pipelines/#{pipeline_id}/jobs?per_page=50"), cwd)
          return "" unless res.exit_code == 0
          begin
            jobs = JSON.parse(res.output).as_a
          rescue JSON::ParseException | TypeCastError
            return ""
          end
          job_id = gitlab_failed_job_id(jobs)
          return "" if job_id.nil?
          res = run(glab_api_command(info, "/projects/#{project_id}/jobs/#{job_id}/trace"), cwd)
          res.exit_code == 0 ? res.output : ""
        rescue
          ""
        end

        # {project_id, pipeline_id} of the first failed pipeline, if any.
        private def gitlab_failed_pipeline_ids(pipelines : Array(JSON::Any)) : {String, String}?
          failed = pipelines.find do |pipeline|
            Ci::GITLAB_BAD_STATUSES.includes?(pipeline["status"]?.try(&.to_s) || "")
          end
          project_id = failed.try { |p| p["project_id"]?.try(&.to_s) }
          pipeline_id = failed.try { |p| p["id"]?.try(&.to_s) }
          {project_id, pipeline_id} if project_id && pipeline_id
        end

        # Id of the first hard-failed job (allow_failure jobs do not fail
        # the pipeline).
        private def gitlab_failed_job_id(jobs : Array(JSON::Any)) : String?
          job = jobs.find do |j|
            j["status"]?.try(&.to_s) == "failed" && j["allow_failure"]?.try(&.as_bool?) != true
          end
          job.try { |j| j["id"]?.try(&.to_s) }
        end

        private def settle(obs : Observer) : Nil
          @on_update.try(&.call(obs))
          @store.try(&.append("ci.status", {
            "sha"    => JSON::Any.new(obs.sha),
            "status" => JSON::Any.new(obs.status.to_s.downcase),
            "detail" => JSON::Any.new(obs.detail),
          } of String => JSON::Any))
          return if obs.claimed?
          xml = Ci.render_notification(obs)
          @delivery.try(&.call(xml)) unless xml.nil?
        end
      end

      # Notification prompt for a finished observer. Nil for non-actionable
      # outcomes (success is log-only; pending never reaches here).
      def self.render_notification(obs : Observer) : String?
        gitlab = obs.provider.gitlab?
        case obs.status
        when .pending?, .success?
          nil
        when .failure?
          body = String.build do |s|
            s << "Commit: #{obs.sha}\n"
            s << "Failed runs: #{obs.detail}\n"
            unless obs.failure_log.empty?
              s << "Failure log (excerpt):\n#{obs.failure_log}\n"
            end
            if gitlab
              s << "The GitLab CI pipeline for this commit failed. Investigate the failures above, fix the code, then commit and push again — a new CI observer will start automatically."
            else
              s << "The GitHub Actions build for this commit failed. Investigate the failures above, fix the code, then commit and push again — a new CI observer will start automatically."
            end
          end
          notification_xml(obs, "failure", "warning", "CI build failed", body)
        when .error?
          body = "Commit: #{obs.sha}\nThe CI observer could not query #{gitlab ? "GitLab CI" : "GitHub Actions"}: #{obs.detail}\nCheck the build status manually with #{gitlab ? "`glab ci status`" : "`gh run list` / `gh run view`"}."
          notification_xml(obs, "error", "warning", "CI observer error", body)
        when .timeout?
          body = "Commit: #{obs.sha}\nThe CI observer gave up after #{MAX_WAIT_S}s without a terminal status. Check the build status manually with #{gitlab ? "`glab ci status`" : "`gh run list`"}."
          notification_xml(obs, "timeout", "warning", "CI status unknown", body)
        end
      end

      private def self.notification_xml(obs : Observer, type : String, severity : String,
                                        title : String, body : String) : String
        data = {
          "id"          => JSON::Any.new("ci.#{obs.sha}.#{type}"),
          "category"    => JSON::Any.new("ci_completion"),
          "type"        => JSON::Any.new(type),
          "source_kind" => JSON::Any.new("ci"),
          "source_id"   => JSON::Any.new(obs.sha),
          "title"       => JSON::Any.new(title),
          "severity"    => JSON::Any.new(severity),
          "body"        => JSON::Any.new(body),
        } of String => JSON::Any
        Tools.render_notification_xml(data)
      end
    end
  end
end
