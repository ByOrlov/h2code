require "json"
require "http/client"
require "uri"
require "./tool"
require "./ci"
require "../session/store"

module H2code
  module Tools
    # Create a merge request (GitLab) or pull request (GitHub) for the
    # current branch via the REST API and persist its web URL in the
    # session state (`state.json` → `merge_request_url`), where the TUI
    # picks it up and pins it as a one-line link under the input box.
    #
    # One merge request per session: the tool refuses when the session
    # already has one (further changes belong in the existing MR — push
    # to the same branch). The link survives `/merge` by design: an MR
    # outlives the sandbox it was opened from.
    #
    # The branch must already be pushed to origin — this tool never
    # pushes by itself (pushes go through the Bash tool so the existing
    # permission flow applies).
    class MergeRequest < Tool
      DESCRIPTION = <<-DESC
        Create a merge request (GitLab) or pull request (GitHub) for the current branch and return its web URL.

        The URL is saved in the session state and pinned as a link under the input box for the rest of the session (it survives /merge).

        When to use:
        - In a /fork sandbox (or any branch) after committing AND pushing the branch to origin.
        - When the user asks to open an MR/PR for the current work.

        Guidelines:
        - Push the branch first (`git push`); this tool never pushes on its own and errors when the branch is not on origin yet.
        - Exactly one merge request per session: the tool refuses when the session already has one. Push further changes to the same branch instead.
        - The target branch is the repository's default branch.
        - Requires a matching API token (config github.token / GITHUB_TOKEN for GitHub, config gitlab.token / GITLAB_TOKEN for GitLab).

        Parameters: `title` (required) and an optional markdown `description`.
      DESC

      # Session store of the active session — read for the
      # one-MR-per-session guard, written when an MR is created, and the
      # `session.merge_request` wire event is appended. Assigned at wiring
      # time (TUI/headless in h2code.run, ACP in Acp::Server). The TUI's
      # session switches adopt in place, so the reference stays valid
      # across /new, /resume and /fork.
      class_property store : H2code::Session::Store? = nil

      # Fired with the new MR web URL so the TUI can surface the link
      # under the input box immediately (runs on the tool's fiber).
      class_property on_created : (String -> Nil)? = nil

      # Retargeted by `/fork` / `/merge` at the idle boundary between turns.
      setter work_dir

      # Git runner, swapped out in tests (same injection as
      # Ci::LiveCiService#runner).
      property runner : (String, String) -> Ci::CommandResult = ->H2code::Tools::Ci.run_shell(String, String)

      # REST layer for tests: (method, full_url, json_body?) → response.
      # Defaults to real HTTP against api.github.com / the GitLab host.
      property api : (String, String, String?) -> Ci::ApiResponse = ->H2code::Tools::MergeRequest.default_http(String, String, String?)

      def initialize(@work_dir : String = Dir.current)
      end

      def name : String
        Names::MERGE_REQUEST
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%({
          "type": "object",
          "properties": {
            "title": {
              "type": "string",
              "description": "Merge request title."
            },
            "description": {
              "type": "string",
              "description": "Optional merge request description (markdown)."
            }
          },
          "required": ["title"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        sess = MergeRequest.store
        return ToolResult.error("Session state is not available — the MergeRequest tool needs an active session.") if sess.nil?

        if existing = sess.read_state.try(&.merge_request_url.presence)
          return ToolResult.error(
            "This session already has a merge request:\n#{existing}\n\n" \
            "One merge request per session — push further changes to the same branch, " \
            "or fork a fresh session for a new MR.",
          )
        end

        title = input["title"]?.try(&.to_s.strip)
        return ToolResult.error("title is required.") if title.nil? || title.empty?
        description = input["description"]?.try(&.to_s.presence) || ""

        info = detect_repo
        return ToolResult.error(
          "Not a GitHub or GitLab repository: `git remote get-url origin` in #{@work_dir} " \
          "did not resolve to a known host.",
        ) if info.nil?

        branch = current_branch
        return ToolResult.error("HEAD is detached — check out a branch first.") if branch.nil?

        ls = run("git ls-remote origin #{branch}")
        if ls.exit_code != 0
          return ToolResult.error("Could not check origin for branch #{branch}:\n#{ls.output.strip}")
        end
        if ls.output.strip.empty?
          return ToolResult.error(
            "Branch #{branch} is not on origin yet — `git push` first, then create the merge request.",
          )
        end

        url, error = case info.provider
                     when .github?
                       create_github_pr(info, branch, title, description)
                     else
                       create_gitlab_mr(info, branch, title, description)
                     end
        return ToolResult.error(error) if error
        # A nil error implies the creator produced a URL (its failure path
        # always pairs a nil URL with a message).
        return ToolResult.error("The API response carried no merge request URL.") if url.nil?

        meta = sess.read_state || H2code::Session::StateMeta.new(File.basename(sess.session_dir))
        meta.merge_request_url = url
        sess.write_state(meta)
        sess.append_simple("session.merge_request", "url", url)
        MergeRequest.on_created.try(&.call(url))
        ToolResult.success(
          "Merge request created: #{url}\n" \
          "The link is pinned under the input box for this session (and survives /merge).",
        )
      end

      # ---- git / repo detection ------------------------------------------

      private def run(command : String) : Ci::CommandResult
        @runner.call(command, @work_dir)
      end

      # Current branch, nil for detached HEAD / lookup failure.
      private def current_branch : String?
        res = run("git rev-parse --abbrev-ref HEAD")
        return nil unless res.exit_code == 0
        branch = res.output.strip
        branch.empty? || branch == "HEAD" ? nil : branch
      end

      # RepoInfo from the origin remote URL. Unlike CI observation there
      # is no CI-marker requirement — an MR can be opened from any repo
      # hosted on a known provider.
      private def detect_repo : Ci::RepoInfo?
        remote = run("git remote get-url origin")
        return nil unless remote.exit_code == 0
        url = remote.output.strip
        return nil if url.empty?
        hosts = Ci.service.as?(Ci::LiveCiService).try(&.gitlab_hosts) || ["gitlab.com"]
        Ci.parse_github_remote(url) || Ci.parse_gitlab_remote(url, hosts)
      end

      # ---- provider APIs ---------------------------------------------------

      # GitHub token from the wired CI service (config github.token /
      # GITHUB_TOKEN / GH_TOKEN, applied at wiring time).
      private def github_token : String?
        Ci.service.as?(Ci::LiveCiService).try(&.github_token.presence)
      end

      private def gitlab_token : String?
        Ci.service.as?(Ci::LiveCiService).try(&.gitlab_token.presence)
      end

      private def create_github_pr(info : Ci::RepoInfo, branch : String,
                                   title : String, description : String) : {String?, String?}
        token = github_token
        return {nil, "Creating a GitHub pull request requires a GitHub token (config github.token / GITHUB_TOKEN env)."} if token.nil?

        resp = @api.call("GET", "https://api.github.com/repos/#{info.path}", nil)
        default_branch = json_field(resp, "default_branch")
        return {nil, api_error("GitHub", resp)} if default_branch.nil?

        body = {"head" => branch, "base" => default_branch,
                "title" => title, "body" => description}.to_json
        resp = @api.call("POST", "https://api.github.com/repos/#{info.path}/pulls", body)
        url = resp.status_code == 201 ? json_field(resp, "html_url") : nil
        return {url, nil} if url
        {nil, api_error("GitHub", resp)}
      end

      private def create_gitlab_mr(info : Ci::RepoInfo, branch : String,
                                   title : String, description : String) : {String?, String?}
        token = gitlab_token
        return {nil, "Creating a GitLab merge request requires a GitLab token (config gitlab.token / GITLAB_TOKEN env)."} if token.nil?

        base = Ci.service.as?(Ci::LiveCiService).try(&.gitlab_api_base(info)) || "https://#{info.host}"
        project = "#{base}/api/v4/projects/#{info.gitlab_project_ref}"

        resp = @api.call("GET", project, nil)
        default_branch = json_field(resp, "default_branch")
        return {nil, api_error("GitLab", resp)} if default_branch.nil?

        body = {"source_branch" => branch, "target_branch" => default_branch,
                "title" => title, "description" => description}.to_json
        resp = @api.call("POST", "#{project}/merge_requests", body)
        url = resp.status_code == 201 ? json_field(resp, "web_url") : nil
        return {url, nil} if url
        {nil, api_error("GitLab", resp)}
      end

      # Parsed top-level JSON string field of an API response, nil when
      # the body is not JSON or the field is missing.
      private def json_field(resp : Ci::ApiResponse, key : String) : String?
        return nil unless resp.status_code == 200 || resp.status_code == 201
        JSON.parse(resp.body)[key]?.try(&.to_s.presence)
      rescue JSON::ParseException
        nil
      end

      # Human-shaped API failure: status, body excerpt, and a hint for
      # auth failures (token missing a scope) and duplicate-MR conflicts.
      private def api_error(provider : String, resp : Ci::ApiResponse) : String
        hint = case resp.status_code
               when 401, 403
                 " — check that the #{provider} token is valid and has API write access"
               when 409, 422
                 " — an MR for this branch may already exist, or a branch/project field was rejected"
               else
                 ""
               end
        excerpt = resp.body.strip[0, 400]
        "#{provider} API HTTP #{resp.status_code}#{hint}:\n#{excerpt}"
      end

      # ---- default REST layer ----------------------------------------------

      # Real HTTP for the injectable `api` proc: routes by URL host to
      # the GitHub or GitLab header set (reusing the Ci API clients'
      # header builders so tokens travel the same way as CI polling).
      def self.default_http(method : String, url : String, body : String?) : Ci::ApiResponse
        uri = URI.parse(url)
        svc = Ci.service.as?(Ci::LiveCiService)
        headers = if uri.host == "api.github.com"
                    Ci::GithubApi.headers(svc.try(&.github_token.presence))
                  else
                    Ci::GitlabApi.headers(svc.try(&.gitlab_token.presence))
                  end
        headers["Content-Type"] = "application/json"
        resp = HTTP::Client.new(uri) do |client|
          client.connect_timeout = 10.seconds
          client.read_timeout = 15.seconds
          if body
            client.post(uri.request_target, headers, body)
          else
            client.get(uri.request_target, headers)
          end
        end
        Ci::ApiResponse.new(resp.status_code, resp.body, resp.headers["Location"]?)
      rescue ex
        Ci::ApiResponse.new(0, ex.message.to_s)
      end
    end
  end
end
