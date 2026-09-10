require "json"
require "./tool"
require "./ci"

module H2code
  module Tools
    # Wait for the CI status (GitHub Actions or GitLab CI) of a commit and
    # return the outcome.
    #
    # When the agent pushes to a repository with CI workflows (GitHub
    # Actions, or GitLab CI via `.gitlab-ci.yml`), a
    # CI observer starts automatically and the completion notification wakes
    # the agent on its own. Use this tool when the turn should block until CI
    # finishes instead — e.g. right after `git push`, before declaring work
    # done.
    #
    # Guidelines:
    # - Call this after pushing commits that affect the build.
    # - Omit `sha` to wait on the currently observed commit (HEAD at push).
    # - On a failed result, fix the code, commit and push again.
    #
    # Limits: waits up to `timeout_s` (default 600, max 3600). On timeout the
    # tool returns an error but the background observer keeps running.
    class WaitForCI < Tool
      DEFAULT_TIMEOUT_S =  600
      MAX_TIMEOUT_S     = 3600
      POLL_INTERVAL     = 500.milliseconds

      DESCRIPTION = <<-DESC
        Wait for the CI status (GitHub Actions or GitLab CI) of a commit and return the outcome.

        After `git push` to a repository with CI workflows (GitHub Actions, or GitLab CI via `.gitlab-ci.yml`), a CI observer starts automatically and reports the result as a notification. This tool instead blocks the current turn until CI finishes, returning the outcome directly: passed, or failed with an excerpt of the failure log.

        When to use:
        - Right after pushing changes that affect the build, before declaring the task done.
        - When you want the CI verdict inside the same turn instead of waiting for the background notification.

        Guidelines:
        - Omit `sha` to wait on the currently observed commit (the one just pushed).
        - On a failed result: investigate the failure log excerpt, fix the code, commit and push again.
        - Do not loop on this tool with short timeouts; pick a reasonable `timeout_s` once.

        Limits: waits up to timeout_s seconds (default 600, max 3600). On timeout the background observer keeps running and will still notify.
      DESC

      # Retargeted by `/fork` / `/merge` at the idle boundary between turns.
      setter work_dir

      def initialize(@work_dir : String = Dir.current)
      end

      def name : String
        Names::WAIT_FOR_CI
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%({
          "type": "object",
          "properties": {
            "timeout_s": {
              "type": "integer",
              "default": #{DEFAULT_TIMEOUT_S},
              "description": "Maximum seconds to wait for a terminal CI status. Default #{DEFAULT_TIMEOUT_S}, max #{MAX_TIMEOUT_S}."
            },
            "sha": {
              "type": "string",
              "description": "Optional commit SHA to wait on. Defaults to the currently observed commit (HEAD at push time); starts a new observer when none is running."
            }
          },
          "required": [],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        svc = Ci.service
        return ToolResult.error("CI observer is not available in this session.") if svc.nil?

        timeout = input["timeout_s"]?.try(&.as_i?) || DEFAULT_TIMEOUT_S
        timeout = timeout.clamp(1..MAX_TIMEOUT_S)
        sha = input["sha"]?.try(&.to_s.presence)

        obs = if s = sha
                existing = svc.observer_for(s)
                if existing.nil? && svc.observe(s, @work_dir)
                  existing = svc.observer_for(s)
                end
                existing
              else
                existing = svc.pending_observer
                if existing.nil? && (head = svc.head_sha(@work_dir)) && svc.observe(head, @work_dir)
                  existing = svc.observer_for(head)
                end
                existing
              end
        return ToolResult.error(
          "No CI observer running#{sha ? " for #{sha}" : ""} and the repository is not eligible " \
          "(a GitHub remote with .github/workflows, or a GitLab remote with .gitlab-ci.yml, is required). " \
          "Push first, or check manually with `gh run list` / `glab ci status`.",
        ) if obs.nil?

        # The tool result replaces the automatic completion notification.
        obs.claimed = true

        deadline = Time.monotonic + timeout.seconds
        while obs.pending?
          if abort_check.call
            obs.claimed = false
            return ToolResult.error("[interrupted by user]")
          end
          break if Time.monotonic >= deadline
          sleep POLL_INTERVAL
        end

        if obs.pending?
          obs.claimed = false
          return ToolResult.error(
            "Timed out after #{timeout}s waiting for CI; the background observer keeps running and will notify on completion.",
          )
        end

        case obs.status
        when .success?
          ToolResult.success("CI passed for #{obs.short_sha} (#{obs.detail}).")
        when .failure?
          content = String.build do |buf|
            buf << "CI FAILED for #{obs.short_sha}.\n"
            buf << "Failed runs: #{obs.detail}\n"
            unless obs.failure_log.empty?
              buf << "Failure log (excerpt):\n#{obs.failure_log}\n"
            end
            buf << "Fix the failures, then commit and push again."
          end
          ToolResult.error(content)
        when .error?
          ToolResult.error("CI observer error for #{obs.short_sha}: #{obs.detail}")
        when .timeout?
          ToolResult.error("CI observer gave up for #{obs.short_sha}: #{obs.detail}")
        else
          ToolResult.error("Unexpected CI observer state: #{obs.status}")
        end
      end
    end
  end
end
