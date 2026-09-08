require "json"
require "http/client"
require "uri"
require "compress/zip"

module H2code
  module Tools
    # Full CI integration — automatic GitHub Actions observation after the
    # agent pushes ("ping-pong" architecture).
    #
    # Flow:
    #   1. The Bash tool detects a successful `git push` (sudo-detect style)
    #      and calls `Ci.service.try_observe_push`.
    #   2. If the repo has GitHub Actions workflows and a github.com remote,
    #      an `Observer` starts polling on a quadratic backoff (5·n² s,
    #      capped at 60 s, gives up after 30 min). With a GitHub token
    #      configured (config `github.token` / GITHUB_TOKEN / GH_TOKEN)
    #      the observer polls api.github.com directly via `GithubApi` —
    #      no gh CLI, no browser login; without a token it falls back to
    #      the gh CLI (`gh run list` / `gh run view --log-failed`).
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
      # Quadratic backoff base: poll n-th time after 5·n² seconds (5, 20, 45…).
      BASE_INTERVAL_S = 5
      # Cap for a single poll interval.
      MAX_INTERVAL_S = 60
      # Give up observing after this many seconds and report "timeout".
      MAX_WAIT_S = 1800
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
      # redirect target (the run-logs endpoint answers 302 with a signed
      # URL). status_code 0 marks a network-level failure (DNS, TLS, …).
      record ApiResponse, status_code : Int32, body : String, location : String? = nil

      # Direct GitHub REST client — the "own Crystal analog" of `gh run
      # list` / `gh run view --log-failed`. Used whenever a token is
      # available (config `github.token` / GITHUB_TOKEN / GH_TOKEN), so CI
      # observation never touches the gh CLI (and its browser login) at
      # all. Token goes only into the Authorization header; it is never
      # included in observer details or logs.
      class GithubApi
        API_BASE = "https://api.github.com"

        def initialize(@token : String? = nil)
        end

        def get(path : String) : ApiResponse
          url = path.starts_with?("http") ? path : "#{API_BASE}#{path}"
          uri = URI.parse(url)
          HTTP::Client.new(uri) do |client|
            client.connect_timeout = 10.seconds
            client.read_timeout = 15.seconds
            resp = client.get(uri.request_target, self.class.headers(@token))
            ApiResponse.new(resp.status_code, resp.body, resp.headers["Location"]?)
          end
        rescue ex
          ApiResponse.new(0, ex.message.to_s)
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

      # `owner/repo` pair from a github.com git remote URL (SSH and HTTPS
      # forms), or nil for non-GitHub remotes.
      def self.parse_github_remote(url : String) : {String, String}?
        url = url.strip.downcase
        ssh = url.match(%r{git@github\.com:([^/\s]+)/([^/\s]+?)(?:\.git)?$})
        https = url.match(%r{https?://(?:[^@\s]+@)?github\.com/([^/\s]+)/([^/\s]+?)(?:\.git)?$})
        if m = ssh || https
          {m[1], m[2]}
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

      # Quadratic poll cadence: attempt 0 waits 5 s, 1 → 20 s, 2 → 45 s, then
      # capped at MAX_INTERVAL_S.
      def self.poll_interval(attempt : Int32) : Int32
        n = attempt <= 0 ? 1 : attempt + 1
        {BASE_INTERVAL_S * n * n, MAX_INTERVAL_S}.min
      end

      # Aggregate `gh run list --json` rows into an observer status.
      # Pending while any run is in progress or none is registered yet.
      def self.aggregate_runs(runs : Array(JSON::Any)) : {Status, String}
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
        # Injectable REST GET for tests; defaults to a real GithubApi.
        property api_get : (String -> ApiResponse)? = nil

        @observers = [] of Observer
        @mutex = Mutex.new
        # Per-cwd {owner, repo} resolution of `git remote get-url origin`.
        @repo_cache = {} of String => {String, String}?

        def initialize(@github_token : String = "")
        end

        # Token for direct REST polling (nil → gh CLI fallback mode).
        private def api_token : String?
          @github_token.presence
        end

        # Resolved REST-poll target for the repo at cwd, or nil when no
        # token is available (→ gh CLI mode). The remote is resolved once
        # per cwd.
        private record ApiTarget, owner : String, repo : String, token : String

        private def api_target(cwd : String) : ApiTarget?
          token = api_token
          return nil if token.nil?
          owner_repo = @mutex.synchronize { @repo_cache[cwd]? }
          if owner_repo.nil? && !@mutex.synchronize { @repo_cache.has_key?(cwd) }
            remote = run("git remote get-url origin", cwd)
            owner_repo = remote.exit_code == 0 ? Ci.parse_github_remote(remote.output) : nil
            @mutex.synchronize { @repo_cache[cwd] = owner_repo }
          end
          return nil if owner_repo.nil?
          ApiTarget.new(owner_repo[0], owner_repo[1], token)
        end

        private def api_call(path : String) : ApiResponse
          getter = @api_get
          return getter.call(path) if getter
          GithubApi.new(api_token).get(path)
        end

        def try_observe_push(command : String, cwd : String) : Bool
          return false unless Ci.push_command?(command)
          repo_dir = Ci.repo_dir_from_command(command, cwd)
          sha = head_sha(repo_dir)
          return false if sha.nil?
          observe(sha, repo_dir)
        end

        # HEAD sha of the repo at `cwd`, or nil when the repo is not eligible
        # for CI observation: no `.github/workflows` or a non-GitHub remote.
        def head_sha(cwd : String) : String?
          return nil unless Dir.exists?(File.join(cwd, ".github", "workflows"))
          remote = run("git remote get-url origin", cwd)
          return nil if remote.exit_code != 0
          return nil unless remote.output.downcase.includes?("github.com")
          # Remember the parsed owner/repo so observe() can build the
          # commit's Actions URL without a second remote lookup.
          @mutex.synchronize { @repo_cache[cwd] = Ci.parse_github_remote(remote.output) }
          rev = run("git rev-parse HEAD", cwd)
          sha = rev.output.strip
          return nil if rev.exit_code != 0 || sha.size != 40 || sha =~ /[^0-9a-f]/
          sha
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
          attempt = 0
          while obs.pending?
            sleep Ci.poll_interval(attempt).seconds
            attempt += 1
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
        # a scripted runner. With a token available (config / env) the
        # observer polls the GitHub REST API directly; otherwise it falls
        # back to the gh CLI. Transient failures (non-zero gh exit, HTTP 5xx
        # / rate limits, output that is not valid JSON — stderr is merged
        # into stdout on the gh path) only count towards
        # `consecutive_failures`; the observer stays Pending until
        # MAX_CONSECUTIVE_FAILURES in a row, so the "Waiting for CI" line
        # does not vanish while the build is still running.
        def poll_once(obs : Observer, cwd : String) : Nil
          return unless obs.pending?
          if target = api_target(cwd)
            poll_once_via_api(obs, target)
          else
            poll_once_via_gh(obs, cwd)
          end
        end

        # Direct REST polling (token mode): GET /actions/runs?head_sha=…,
        # map onto the same aggregation as the gh path.
        private def poll_once_via_api(obs : Observer, target : ApiTarget) : Nil
          res = api_call("/repos/#{target.owner}/#{target.repo}/actions/runs?head_sha=#{obs.sha}&per_page=20")
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

        # gh CLI polling (fallback mode — needs an interactive gh login).
        private def poll_once_via_gh(obs : Observer, cwd : String) : Nil
          res = run("gh run list -c #{obs.sha} --json databaseId,name,status,conclusion --limit 20", cwd)
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

        # Best-effort link to the commit's checks page on github.com, shown
        # in the active-zone wait line so the build can be opened with a
        # click. Resolved from the per-cwd remote cache (populated by
        # head_sha / api_target); no extra subprocess is spawned here, and
        # the link stays empty when the owner/repo pair is unknown.
        private def set_actions_url(obs : Observer, cwd : String) : Nil
          return unless obs.actions_url.empty?
          owner_repo = @mutex.synchronize { @repo_cache[cwd]? }
          return if owner_repo.nil?
          obs.actions_url = "https://github.com/#{owner_repo[0]}/#{owner_repo[1]}/commit/#{obs.sha}/checks"
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
          res = api_call("/repos/#{target.owner}/#{target.repo}/actions/runs/#{failed_id}/logs")
          if res.status_code == 302 && (loc = res.location)
            res = api_call(loc)
          end
          return "" unless res.status_code == 200
          Ci.extract_zip_text(res.body)
        rescue
          ""
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
            s << "The GitHub Actions build for this commit failed. Investigate the failures above, fix the code, then commit and push again — a new CI observer will start automatically."
          end
          notification_xml(obs, "failure", "warning", "CI build failed", body)
        when .error?
          body = "Commit: #{obs.sha}\nThe CI observer could not query GitHub Actions: #{obs.detail}\nCheck the build status manually with `gh run list` / `gh run view`."
          notification_xml(obs, "error", "warning", "CI observer error", body)
        when .timeout?
          body = "Commit: #{obs.sha}\nThe CI observer gave up after #{MAX_WAIT_S}s without a terminal status. Check the build status manually with `gh run list`."
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
