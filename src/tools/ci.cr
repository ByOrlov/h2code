require "json"
require "http/client"
require "uri"
require "compress/zip"
require "yaml"

require "./ci/port"
require "./ci/github_api"
require "./ci/github_cli"
require "./ci/github_client"
require "./ci/gitlab_api"
require "./ci/gitlab_cli"
require "./ci/gitlab_client"

module H2code
  module Tools
    # Full CI integration — automatic GitHub Actions / GitLab CI observation
    # after the agent pushes ("ping-pong" architecture).
    #
    # Access layer (hexagonal): `Ci::Port` is the single CI access
    # interface — check a commit's status and fetch its failed run's log —
    # implemented by the `GithubClient` / `GitlabClient` adapters. Each
    # adapter encapsulates its access variants: `GithubApi` (REST) /
    # `GithubCli` (gh) and `GitlabApi` (REST, token optional) /
    # `GitlabCli` (glab api). Which adapter is used is decided by the
    # service from its provider detection (see `LiveCiService#poll_once`).
    #
    # Flow:
    #   1. The Bash tool detects a successful `git push` (sudo-detect style)
    #      and calls `Ci.service.try_observe_push`.
    #   2. The remote the pushed commit actually landed on decides the
    #      provider — `git branch -r --contains <sha>` right after the push
    #      names the remotes that received it (origin is the fallback), so
    #      a repo with two remotes (github.com origin + a GitLab mirror)
    #      is observed where the commit really went. If the repo has
    #      GitHub Actions workflows and a github.com remote, an `Observer`
    #      polls right away and then every 30 s (gives up after 60 min).
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
    #      Manual bindings from `~/.h2code/ci.json` (written by the
    #      `/ci type <provider> [host]` command) take precedence over
    #      the host whitelists: once a host is bound, every repository
    #      on it is detected as that provider.
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

      # Host of a git remote URL (SSH and HTTPS forms, credentials and port
      # stripped), or nil for inputs that parse as neither.
      def self.remote_host(url : String) : String?
        url = url.strip
        ssh = url.match(%r{git@([^:\s/]+):(.+?)(?:\.git)?$})
        https = url.match(%r{(?:https?|ssh)://(?:[^@\s]+@)?([^/:\s]+)(?::\d+)?/(.+?)(?:\.git)?$})
        (ssh || https).try { |m| m[1].downcase.split(':')[0]? }
      end

      # Manual CI provider bindings, persisted as `<h2code home>/ci.json`:
      #
      #   {"hosts": {"gl.example.com": "gitlab"},
      #    "urls":  {"git@gl.example.com:acme/app.git": "gitlab"}}
      #
      # Written by the `/ci type <provider> [host]` command: the urls entry
      # pins the exact repository, the hosts entry makes every repository
      # from that host auto-detect as the provider — one `/ci type gitlab`
      # per GitLab instance covers all of a user's repositories on it, with
      # no `gitlab.endpoint` config needed. Detection consults bindings
      # before the builtin/configured host whitelists. A nil path keeps
      # the bindings in memory only (tests, service fakes).
      class Bindings
        getter path : String?

        @mutex = Mutex.new
        @hosts = {} of String => Provider
        @urls = {} of String => Provider

        def initialize(@path : String? = nil)
          load
        end

        # Provider bound for a remote URL: the exact urls entry (a ".git"
        # suffix is tolerated) or the entry of the URL's host. Nil when
        # unbound.
        def provider_for_url(url : String) : Provider?
          url = url.strip
          base = url.ends_with?(".git") ? url[0...url.size - 4] : url
          @mutex.synchronize do
            @urls[url]? ||
              @urls[base]? ||
              Ci.remote_host(url).try { |host| @hosts[host]? }
          end
        end

        # Provider bound for a host, or nil.
        def provider_for_host(host : String) : Provider?
          @mutex.synchronize { @hosts[host.downcase]? }
        end

        # Hosts bound to GitLab — feeds the remote host whitelist of
        # detection (see `LiveCiService#gitlab_hosts`).
        def gitlab_hosts : Array(String)
          @mutex.synchronize { @hosts.select { |_, p| p.gitlab? }.keys }
        end

        # Record a binding: the host plus every given remote URL on it.
        def set(host : String, urls : Array(String), provider : Provider) : Nil
          @mutex.synchronize do
            @hosts[host.downcase] = provider
            urls.each { |url| @urls[url.strip] = provider }
            save
          end
        end

        private def load : Nil
          path = @path
          return if path.nil? || !File.exists?(path)
          root = JSON.parse(File.read(path))
          @hosts = parse_map(root["hosts"]?)
          @urls = parse_map(root["urls"]?)
        rescue JSON::ParseException | IO::Error | File::NotFoundError
          # Best-effort: a broken ci.json behaves as no bindings at all.
        end

        private def parse_map(value : JSON::Any?) : Hash(String, Provider)
          map = {} of String => Provider
          hash = value.try(&.raw.as?(Hash))
          return map if hash.nil?
          hash.each do |key, v|
            case v.to_s.downcase
            when "gitlab" then map[key.to_s] = Provider::Gitlab
            when "github" then map[key.to_s] = Provider::Github
            end
          end
          map
        end

        private def save : Nil
          path = @path
          return if path.nil?
          json = JSON.build do |b|
            b.object do
              b.field("hosts") { b.object { @hosts.each { |k, p| b.field(k, p.to_s.downcase) } } }
              b.field("urls") { b.object { @urls.each { |k, p| b.field(k, p.to_s.downcase) } } }
            end
          end
          dir = File.dirname(path)
          Dir.mkdir_p(dir) unless Dir.exists?(dir)
          File.write(path, json + "\n")
        rescue IO::Error | File::NotFoundError | ArgumentError
          # Best-effort persistence: a failed write keeps the in-memory
          # bindings working for this session.
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
        # Причина, почему лог упавшего прогона получить не удалось (пуст,
        # когда лог получен). Показывается отдельной ошибкой в TUI и
        # строкой в нотификации — отсутствие лога не должно быть молчаливым.
        property failure_log_error : String = ""
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
      # instead of skipping a real build. GitLab-bound pushes skip this
      # gate entirely (see `observe_push_branch?`) — `.gitlab-ci.yml`
      # `workflow:rules` are not parsed.
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
               when Hash   then on["push"]?
               when Array  then raw.any?(&.to_s.==("push")) ? true : nil
               when String then raw == "push" ? true : nil
               else             nil
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
          h.each do |k, true_val|
            return true_val if k.raw.as?(Bool) == true
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

      # Aggregate GitHub Actions run rows (`gh run list --json` / Actions
      # API) into an observer status — thin wrapper over the universal
      # Port.aggregate with the runs normalized by GithubClient.
      def self.aggregate_runs(runs : Array(JSON::Any)) : {Status, String}
        mapped = GithubClient.map_runs(runs)
        Port.aggregate(mapped, "no runs reported yet", "run(s)")
      end

      # Aggregate GitLab pipeline rows into an observer status — thin
      # wrapper over Port.aggregate (see aggregate_runs).
      def self.aggregate_pipelines(pipelines : Array(JSON::Any)) : {Status, String}
        mapped = GitlabClient.map_pipelines(pipelines, nil, "")
        Port.aggregate(mapped, "no pipelines reported yet", "pipeline(s)")
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

        # True when the CI repo at `cwd` resolves to GitLab — GitHub
        # workflow branch filters do not apply to its pushes. Concrete
        # default keeps test doubles simple; `LiveCiService` overrides.
        def gitlab_repo?(cwd : String) : Bool
          false
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
        # Manual CI provider bindings (ci.json) — `/ci type gitlab|github
        # [host]` writes them; detection consults them before the
        # host whitelists. Memory-only by default; the wiring sites point
        # it at <h2code home>/ci.json.
        property bindings : Bindings = Bindings.new
        # Injectable REST GET for tests; defaults to real GithubApi/GitlabApi.
        property api_get : (String -> ApiResponse)? = nil

        @observers = [] of Observer
        @mutex = Mutex.new
        # Per-cwd repo resolution of `git remote get-url origin`.
        @repo_cache = {} of String => RepoInfo?

        def initialize(@github_token : String = "", @gitlab_token : String = "",
                       @gitlab_endpoint : String = "", @bindings : Bindings = Bindings.new)
        end

        # Token for direct REST polling (nil → gh CLI fallback mode).
        private def api_token : String?
          @github_token.presence
        end

        # GitLab hosts whose remotes are observed: gitlab.com plus the host
        # of the configured self-hosted endpoint. Public for the
        # MergeRequest tool's remote detection.
        def gitlab_hosts : Array(String)
          hosts = ["gitlab.com"] + @bindings.gitlab_hosts
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
        # https://<remote host>. Public for the MergeRequest tool's API
        # calls against self-hosted instances.
        def gitlab_api_base(info : RepoInfo) : String
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
        # A nil `sha` serves the cached entry (the poll loop); a concrete sha
        # forces a fresh, sha-aware detection — after a push the commit may
        # live on a different remote than a cached resolution says.
        private def resolve_repo(cwd : String, sha : String? = nil) : RepoInfo?
          if sha.nil?
            cached = @mutex.synchronize { @repo_cache[cwd]? }
            return cached if cached
            return nil if @mutex.synchronize { @repo_cache.has_key?(cwd) }
          end
          info = detect_repo(cwd, sha)
          @mutex.synchronize { @repo_cache[cwd] = info }
          info
        end

        # Provider detection for the repo at cwd: the candidate remotes are
        # checked in order (see `candidate_remote_urls`) and the first one
        # whose host matches a CI marker wins — GitHub Actions
        # (`.github/workflows` + github.com remote), then GitLab CI
        # (`.gitlab-ci.yml` + a gitlab.com / configured-endpoint remote).
        # Marker directories are checked first so repos that are not
        # CI-eligible resolve to nil without spawning any command. Nil
        # when the repo is not eligible for CI observation.
        private def detect_repo(cwd : String, sha : String? = nil) : RepoInfo?
          gh_marker = Dir.exists?(File.join(cwd, ".github", "workflows"))
          gl_marker = File.exists?(File.join(cwd, ".gitlab-ci.yml"))
          return nil unless gh_marker || gl_marker
          candidate_remote_urls(cwd, sha).each do |url|
            info = bound_repo_info(url)
            return info if info
            info = gh_marker ? Ci.parse_github_remote(url) : nil
            info ||= gl_marker ? Ci.parse_gitlab_remote(url, gitlab_hosts) : nil
            return info if info
          end
          nil
        end

        # RepoInfo from a ci.json binding: the urls entry pins this exact
        # repository, the hosts entry every repository from that host. The
        # host needs no whitelist here — the user's binding says what it
        # is; the generic git-URL parsing extracts host + project path.
        private def bound_repo_info(url : String) : RepoInfo?
          provider = @bindings.provider_for_url(url)
          return nil if provider.nil?
          host = Ci.remote_host(url)
          return nil if host.nil?
          Ci.parse_gitlab_remote(url, [host]).try { |info| RepoInfo.new(provider, host, info.path) }
        end

        # URLs of the remotes to test for CI eligibility, best-candidate
        # order: when `sha` is known (right after a push), the remotes whose
        # tracking refs contain the commit come first — `git branch -r
        # --contains` reports exactly where the commit went (a successful
        # push updates the tracking refs), so a non-origin `git push gitlab
        # master` is detected on the gitlab remote even when origin is
        # github.com and both CI configs sit in the tree. origin follows as
        # the fallback (and for the sha-less resolution). A commit pushed
        # to several CI-eligible remotes is observed on the first one
        # listed — one observer per commit.
        private def candidate_remote_urls(cwd : String, sha : String?) : Array(String)
          names = [] of String
          if sha
            res = run("git branch -r --contains #{sha}", cwd)
            if res.exit_code == 0
              res.output.each_line do |line|
                next if line.includes?("->") # origin/HEAD -> origin/master
                name = line.strip.split('/')[0]?
                # Remote names are word chars / dots / dashes; anything else
                # is noise and must never reach the shell.
                next if name.nil? || name.empty? || !(name =~ /\A[\w.-]+\z/)
                names << name unless names.includes?(name)
              end
            end
          end
          names << "origin" unless names.includes?("origin")
          names.compact_map do |name|
            res = run("git remote get-url #{name}", cwd)
            url = res.output.strip
            res.exit_code == 0 && !url.empty? ? url : nil
          end
        end

        # Port-adapter for the GitHub repo at cwd: REST (GithubApi) when a
        # token is configured and the repo is resolved, otherwise the gh
        # CLI (GithubCli). The api_get hook (tests) rides on the API variant.
        private def github_client(info : RepoInfo?, cwd : String) : GithubClient
          api = info && api_token ? GithubApi.new(api_token, @api_get) : nil
          GithubClient.new(info, api, GithubCli.new(@runner, cwd))
        end

        # Port-adapter for the GitLab repo: GitlabApi (token optional;
        # private projects fall back to glab inside the adapter) with the
        # api_get hook (tests) riding along.
        private def gitlab_client(info : RepoInfo, cwd : String) : GitlabClient
          GitlabClient.new(
            info,
            GitlabApi.new(gitlab_api_base(info), @gitlab_token.presence, @api_get),
            GitlabCli.new(@runner, cwd, info.host),
            -> { glab_ready?(cwd) },
          )
        end

        def try_observe_push(command : String, cwd : String) : Bool
          return false unless Ci.push_command?(command)
          repo_dir = Ci.repo_dir_from_command(command, cwd)
          sha = rev_parse_head(repo_dir)
          return false if sha.nil?
          # Resolve the repo with the sha in hand: right after the push the
          # remote tracking refs already say which remote received the
          # commit, so `git push gitlab master` in a repo whose origin is
          # GitHub is observed on GitLab, not on GitHub.
          info = resolve_repo(repo_dir, sha)
          return false if info.nil?
          return false unless observe_push_branch?(repo_dir, info)
          observe(sha, repo_dir)
        end

        # A plain `git push` publishes the current branch, so before
        # observing, check that branch against the workflows' `on.push`
        # triggers. GitLab-bound pushes skip the gate — `.gitlab-ci.yml`
        # `workflow:rules` are not parsed, so the pipeline counts as
        # covered (and the GitHub workflows in a two-config tree say
        # nothing about a GitLab push). When no workflow covers the sha's
        # branch, CI never runs for it — report that instead of parking a
        # "Waiting for CI" line until MAX_WAIT_S. Refspec pushes
        # (`git push origin HEAD:master`) are not parsed; an undeterminable
        # branch (empty / detached HEAD) falls through to observing, same
        # as before.
        private def observe_push_branch?(repo_dir : String, info : RepoInfo) : Bool
          return true if info.provider.gitlab?
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
          text = "[notification id=\"ci.noci.#{branch}\"]\n" \
                 "No CI build for this branch\n#{body}"
          @delivery.try(&.call(text))
        end

        # Branch of the repo at `cwd`, "" when HEAD is detached or the
        # lookup fails (both treated as "undeterminable — observe").
        def current_branch(cwd : String) : String
          res = run("git rev-parse --abbrev-ref HEAD", cwd)
          res.exit_code == 0 ? res.output.strip : ""
        end

        # True when the resolved CI repo at `cwd` is GitLab-bound. Uses the
        # per-cwd cache (populated by head_sha / try_observe_push), so this
        # spawns no subprocess on the WaitForCI path.
        def gitlab_repo?(cwd : String) : Bool
          resolve_repo(cwd).try(&.provider.gitlab?) || false
        end

        # HEAD sha of the repo at `cwd`, or nil when the repo is not eligible
        # for CI observation (see `detect_repo`; GitHub needs
        # `.github/workflows` + a github.com remote, GitLab needs
        # `.gitlab-ci.yml` + a GitLab remote — resolved sha-aware, so a HEAD
        # published to a non-origin remote is detected there).
        def head_sha(cwd : String) : String?
          sha = rev_parse_head(cwd)
          return nil if sha.nil?
          resolve_repo(cwd, sha).nil? ? nil : sha
        end

        # HEAD sha of the repo at `cwd` — 40 hex chars — or nil when
        # rev-parse fails or returns anything else.
        private def rev_parse_head(cwd : String) : String?
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

        # URLs of all remotes configured for the repo at `cwd` — `/ci type`
        # picks the host to bind from them. Empty when the lookup fails.
        def remote_urls(cwd : String) : Array(String)
          res = run("git config --local --get-regexp '^remote\\..*\\.url$'", cwd)
          return [] of String unless res.exit_code == 0
          res.output.lines.compact_map do |line|
            value = line.strip.split(' ', 2)[1]?
            value.try(&.strip).presence
          end
        end

        # `/ci type`: persist the provider binding (ci.json) and drop the
        # cached repo resolution, so the next detection — a push, /ci,
        # WaitForCI — sees it immediately.
        def bind_provider(cwd : String, host : String, urls : Array(String),
                          provider : Provider) : Nil
          @bindings.set(host, urls, provider)
          @mutex.synchronize { @repo_cache.delete(cwd) }
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

        # The poll loop: check immediately, then every POLL_INTERVAL_S. The
        # first poll runs right away (a manual `/ci` or a WaitForCI wait must
        # not sit idle for a full interval — a commit whose CI already
        # finished settles instantly); a fresh push just reports "no runs
        # yet" and keeps waiting.
        def poll_loop(obs : Observer, cwd : String) : Nil
          while obs.pending?
            poll_once(obs, cwd)
            break unless obs.pending?
            sleep POLL_INTERVAL_S.seconds
            if obs.elapsed_s >= MAX_WAIT_S
              obs.status = Status::Timeout
              obs.detail = "gave up after #{MAX_WAIT_S}s"
              settle(obs)
              return
            end
          end
        end

        # One polling step. Public so tests can drive the state machine with
        # a scripted runner. Which port adapter is used follows the current
        # provider logic: GitLab observers (or a repo that resolves to
        # GitLab — e.g. WaitForCI on a fresh sha) go through GitlabClient
        # (GitlabApi REST, glab fallback inside the adapter); GitHub
        # observers use GithubClient — its REST variant when a token is
        # available (config / env), else the gh CLI. Transient failures
        # (non-zero CLI exit, HTTP 5xx / rate limits, output that is not
        # valid JSON) only count towards `consecutive_failures`; the
        # observer stays Pending until MAX_CONSECUTIVE_FAILURES in a row,
        # so the "Waiting for CI" line does not vanish while the build is
        # still running. Permanent errors (GitLab access denied, no glab)
        # settle as Error right away.
        def poll_once(obs : Observer, cwd : String) : Nil
          return unless obs.pending?
          info = resolve_repo(cwd)
          if obs.provider.gitlab?
            if info.nil? || !info.provider.gitlab?
              record_poll_failure(obs, "repository is no longer GitLab-connected")
            else
              poll_via_client(obs, gitlab_client(info, cwd))
            end
          elsif (gl_info = info) && gl_info.provider.gitlab?
            # GitLab repo observed without a prior push detection:
            # switch the observer to GitLab.
            obs.provider = Ci::Provider::Gitlab
            poll_via_client(obs, gitlab_client(gl_info, cwd))
          elsif info && api_token
            poll_via_client(obs, github_client(info, cwd))
          else
            poll_via_client(obs, github_client(nil, cwd))
          end
        end

        # One check through a CI port adapter: map the universal Check onto
        # the observer — wait-line link from the run's web_url, failure-log
        # excerpt on failure, transient-error accounting via
        # record_poll_failure, immediate settle on permanent errors.
        private def poll_via_client(obs : Observer, client : Port) : Nil
          check = client.runs(obs.sha)
          if check.status.error?
            if check.permanent_error
              obs.status = Status::Error
              obs.detail = check.detail
              settle(obs)
            else
              record_poll_failure(obs, check.detail)
            end
            return
          end
          obs.consecutive_failures = 0
          obs.detail = check.detail
          if run = check.runs.first?
            obs.actions_url = run.web_url unless run.web_url.empty?
          end
          if check.status.terminal?
            if check.status.failure?
              log = client.failure_log(check)
              obs.failure_log = Ci.excerpt(log.text, FAILURE_LOG_MAX_BYTES) unless log.text.empty?
              obs.failure_log_error = log.error
            end
            obs.status = check.status
            settle(obs)
          end
        end

        # True when the glab CLI is installed (probed once per service;
        # injectable in tests via glab_probed= / glab_available=).
        private def glab_ready?(cwd : String) : Bool
          return @glab_available if @glab_probed
          @glab_probed = true
          @glab_available = run("glab --version", cwd).exit_code == 0
          @glab_available
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
                              # the same base as the API. `/commit/<sha>`
                              # (singular) is the commit page; `/commits/`
                              # is an unfiltered listing. Replaced by the
                              # direct pipeline link once a poll sees one
                              # (settle_gitlab_pipelines).
                              "#{gitlab_api_base(info)}/#{info.path}/-/commit/#{obs.sha}"
                            else
                              "https://github.com/#{info.path}/commit/#{obs.sha}/checks"
                            end
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

      # Startup CI-token warning tip for the repo at `cwd`: resolves the
      # provider sha-aware (like the post-push detection — the remote the
      # HEAD commit actually lives on decides, not origin, so a repo whose
      # origin is GitHub but whose HEAD sits on a GitLab remote gets the
      # GitLab tip) and returns the i18n tip text when the matching token
      # is not configured. Nil when the repo is not CI-eligible or the
      # token is already set.
      def self.token_warning_tip(service : LiveCiService, github_token : String,
                                 gitlab_token : String, cwd : String) : String?
        service.head_sha(cwd)
        case service.repo_info(cwd).try(&.provider)
        when Provider::Gitlab
          gitlab_token.empty? ? H2code.t("ui.ci_token_tip_gitlab") : nil
        when Provider::Github
          github_token.empty? ? H2code.t("ui.ci_token_tip") : nil
        else
          nil
        end
      end

      # Notification prompt for a finished observer, as plain readable text
      # the model sees directly — no XML envelope. The bracketed id line on
      # top is the exactly-once delivery marker (the TUI / ACP dedup key).
      # Nil for non-actionable outcomes (success is log-only; pending never
      # reaches here).
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
            unless obs.failure_log_error.empty?
              s << "Could not fetch the CI failure log: #{obs.failure_log_error}\n"
            end
            if gitlab
              s << "The GitLab CI pipeline for this commit failed. Investigate the failures above, fix the code, then commit and push again — a new CI observer will start automatically."
            else
              s << "The GitHub Actions build for this commit failed. Investigate the failures above, fix the code, then commit and push again — a new CI observer will start automatically."
            end
          end
          notification_text(obs, "failure", "CI build failed", body)
        when .error?
          body = "Commit: #{obs.sha}\nThe CI observer could not query #{gitlab ? "GitLab CI" : "GitHub Actions"}: #{obs.detail}\nCheck the build status manually with #{gitlab ? "`glab ci status`" : "`gh run list` / `gh run view`"}."
          notification_text(obs, "error", "CI observer error", body)
        when .timeout?
          body = "Commit: #{obs.sha}\nThe CI observer gave up after #{MAX_WAIT_S}s without a terminal status. Check the build status manually with #{gitlab ? "`glab ci status`" : "`gh run list`"}."
          notification_text(obs, "timeout", "CI status unknown", body)
        end
      end

      # Plain-text notification: the id marker line + title + body. The
      # marker format must stay parseable by `external_notification_id`
      # (TUI TurnController and Acp::Session).
      private def self.notification_text(obs : Observer, type : String,
                                         title : String, body : String) : String
        "[notification id=\"ci.#{obs.sha}.#{type}\"]\n#{title}\n#{body}"
      end
    end
  end
end
