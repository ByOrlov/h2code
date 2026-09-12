require "../spec_helper"

# Modular specs for the CI access layer: Ci::Port (universal interface),
# the GithubClient / GitlabClient adapters, and their access variants
# GithubApi / GithubCli / GitlabApi / GitlabCli. No network, no service:
# HTTP responses are injected through the GithubApi/GitlabApi http_get
# hook, CLI execution through a scripted runner. Response bodies mirror
# the real API payload shapes (GitHub Actions runs, `gh run list --json`,
# GitLab pipelines/jobs/trace).

PORT_SPEC_SHA = "c" * 40

module H2code::Tools
  # Scripted HTTP getter: records requested paths, answers FIFO.
  class PortHttpFake
    getter paths = [] of String
    @responses = [] of Ci::ApiResponse

    def add(status_code : Int32, body : String, location : String? = nil) : Nil
      @responses << Ci::ApiResponse.new(status_code, body, location)
    end

    def call(path : String) : Ci::ApiResponse
      paths << path
      @responses.shift? || Ci::ApiResponse.new(404, "no canned response")
    end
  end

  # Scripted command runner: canned results FIFO, records commands.
  class PortRunnerFake
    @responses = [] of Ci::CommandResult
    getter commands = [] of String

    def add(exit_code : Int32, output : String) : Nil
      @responses << Ci::CommandResult.new(exit_code, output)
    end

    def call(command : String, cwd : String) : Ci::CommandResult
      commands << command
      @responses.shift? || Ci::CommandResult.new(0, "")
    end
  end

  def self.port_github_repo : Ci::RepoInfo
    Ci::RepoInfo.new(Ci::Provider::Github, "github.com", "acme/app")
  end

  # GithubCli with a no-op runner (unused on the API path; satisfies the
  # adapter's constructor).
  def self.port_idle_gh_cli : Ci::GithubCli
    idle = PortRunnerFake.new
    Ci::GithubCli.new(->idle.call(String, String), "/tmp")
  end

  def self.port_gitlab_repo : Ci::RepoInfo
    Ci::RepoInfo.new(Ci::Provider::Gitlab, "gitlab.com", "acme/app")
  end

  # GitlabClient against a scripted HTTP getter; glab reports available or
  # not. Returns the client and its scripted runner.
  def self.port_gitlab_client(http : PortHttpFake, glab : Bool = false)
    runner = PortRunnerFake.new
    client = Ci::GitlabClient.new(
      port_gitlab_repo,
      Ci::GitlabApi.new("https://gitlab.com", nil, ->http.call(String)),
      Ci::GitlabCli.new(->runner.call(String, String), "/repo", "gitlab.com"),
      -> { glab })
    {client, runner}
  end

  describe Ci::Port do
    describe "aggregate" do
      it "is pending with the provider's empty-detail wording when no runs exist" do
        status, detail = Ci::Port.aggregate([] of Ci::Port::Run, "no runs reported yet", "run(s)")
        status.pending?.should be_true
        detail.should eq("no runs reported yet")
      end

      it "is pending while any run is in progress" do
        runs = [
          Ci::Port::Run.new(id: "1", name: "build", state: Ci::Port::RunState::Passed),
          Ci::Port::Run.new(id: "2", name: "spec", state: Ci::Port::RunState::InProgress),
        ]
        status, detail = Ci::Port.aggregate(runs, "none", "run(s)")
        status.pending?.should be_true
        detail.should eq("in progress: spec")
      end

      it "is success counting passed runs with the provider noun" do
        runs = [
          Ci::Port::Run.new(id: "1", name: "build", state: Ci::Port::RunState::Passed),
          Ci::Port::Run.new(id: "2", name: "lint", state: Ci::Port::RunState::Passed),
        ]
        status, detail = Ci::Port.aggregate(runs, "none", "pipeline(s)")
        status.success?.should be_true
        detail.should eq("2 pipeline(s) passed")
      end

      it "is failure listing failed runs with their provider reason" do
        runs = [
          Ci::Port::Run.new(id: "1", name: "build", state: Ci::Port::RunState::Passed),
          Ci::Port::Run.new(id: "2", name: "spec", state: Ci::Port::RunState::Failed,
            failure_reason: "failure"),
          Ci::Port::Run.new(id: "3", name: "deploy", state: Ci::Port::RunState::Failed),
        ]
        status, detail = Ci::Port.aggregate(runs, "none", "run(s)")
        status.failure?.should be_true
        detail.should eq("spec (failure), deploy")
      end
    end
  end

  describe Ci::GithubApi do
    it "sends the token as a Bearer header and nothing without one" do
      Ci::GithubApi.headers("ghp_test")["Authorization"].should eq("Bearer ghp_test")
      Ci::GithubApi.headers("").has_key?("Authorization").should be_false
      Ci::GithubApi.headers(nil).has_key?("Authorization").should be_false
    end

    it "routes gets through the injected http hook (test seam)" do
      http = PortHttpFake.new
      http.add(200, %({"workflow_runs":[]}))
      api = Ci::GithubApi.new("ghp_test", ->http.call(String))
      api.get("/repos/acme/app/actions/runs").status_code.should eq(200)
      http.paths.should eq(["/repos/acme/app/actions/runs"])
    end
  end

  describe Ci::GitlabApi do
    it "sends the token as a Private-Token header and reports token?" do
      Ci::GitlabApi.headers("glpat-x")["Private-Token"].should eq("glpat-x")
      Ci::GitlabApi.headers(nil).has_key?("Private-Token").should be_false
      Ci::GitlabApi.new("https://gitlab.com", "glpat-x").token?.should be_true
      Ci::GitlabApi.new("https://gitlab.com", nil).token?.should be_false
      Ci::GitlabApi.new("https://gitlab.com", "").token?.should be_false
    end

    it "exposes its base URL (constructed pipeline links hang off it)" do
      Ci::GitlabApi.new("https://gl.corp.io").base_url.should eq("https://gl.corp.io")
    end
  end

  describe Ci::GithubClient do
    describe "via GithubApi (token)" do
      it "checks the commit's runs against the Actions API and maps a real payload" do
        http = PortHttpFake.new
        http.add(200, %({
          "total_count": 1,
          "workflow_runs": [
            {"id": 987654321, "name": "CI", "head_sha": "#{PORT_SPEC_SHA}",
             "event": "push", "status": "completed", "conclusion": "success",
             "html_url": "https://github.com/acme/app/actions/runs/987654321"}
          ]
        }))
        client = Ci::GithubClient.new(port_github_repo,
          Ci::GithubApi.new("ghp_test", ->http.call(String)),
          Tools.port_idle_gh_cli)

        check = client.runs(PORT_SPEC_SHA)

        http.paths.should eq(["/repos/acme/app/actions/runs?head_sha=#{PORT_SPEC_SHA}&per_page=100"])
        check.status.success?.should be_true
        check.detail.should eq("1 run(s) passed")
        check.runs.first.name.should eq("CI")
      end

      it "is pending while a run is in progress and failure lists the conclusion" do
        http = PortHttpFake.new
        http.add(200, %({"workflow_runs":[
          {"id": 1, "name": "build", "status": "in_progress", "conclusion": null},
          {"id": 2, "name": "spec", "status": "completed", "conclusion": "failure"}
        ]}))
        client = Ci::GithubClient.new(port_github_repo,
          Ci::GithubApi.new("ghp_test", ->http.call(String)),
          Tools.port_idle_gh_cli)

        check = client.runs(PORT_SPEC_SHA)
        check.status.pending?.should be_true
        check.detail.should contain("in progress: build")
      end

      it "drops Dependabot dynamic bookkeeping runs from the verdict" do
        http = PortHttpFake.new
        http.add(200, %({"workflow_runs":[
          {"id": 1, "name": "github_actions in /. - Update #1",
           "status": "completed", "conclusion": "success", "event": "dynamic"}
        ]}))
        client = Ci::GithubClient.new(port_github_repo,
          Ci::GithubApi.new("ghp_test", ->http.call(String)),
          Tools.port_idle_gh_cli)

        client.runs(PORT_SPEC_SHA).detail.should eq("no runs reported yet")
      end

      it "fetches the failed run's log following the 302 to the signed zip" do
        zip = IO::Memory.new
        Compress::Zip::Writer.open(zip) do |writer|
          writer.add("job/1_setup.txt", IO::Memory.new("setup ok\n"))
          writer.add("job/2_spec.txt", IO::Memory.new("expected true, got false\n"))
        end
        http = PortHttpFake.new
        http.add(200, %({"workflow_runs":[
          {"id": 42, "name": "spec", "status": "completed", "conclusion": "failure"}
        ]}))
        http.add(302, "", "https://objects.githubusercontent.com/signed")
        http.add(200, zip.to_s)
        client = Ci::GithubClient.new(port_github_repo,
          Ci::GithubApi.new("ghp_test", ->http.call(String)),
          Tools.port_idle_gh_cli)

        check = client.runs(PORT_SPEC_SHA)
        log = client.failure_log(check)

        log.error.should be_empty
        http.paths.should eq([
          "/repos/acme/app/actions/runs?head_sha=#{PORT_SPEC_SHA}&per_page=100",
          "/repos/acme/app/actions/runs/42/logs",
          "https://objects.githubusercontent.com/signed",
        ])
        log.text.should contain("setup ok")
        log.text.should contain("expected true, got false")
      end

      it "treats API errors as transient (rate limits, 5xx)" do
        http = PortHttpFake.new
        http.add(403, "API rate limit exceeded")
        client = Ci::GithubClient.new(port_github_repo,
          Ci::GithubApi.new("ghp_test", ->http.call(String)),
          Tools.port_idle_gh_cli)

        check = client.runs(PORT_SPEC_SHA)
        check.status.error?.should be_true
        check.permanent_error.should be_false
        check.detail.should contain("HTTP 403")
      end
    end

    describe "via GithubCli (gh, no token)" do
      it "checks the commit's runs with gh run list and maps the rows" do
        runner = PortRunnerFake.new
        runner.add(0, %([{"databaseId":42,"name":"spec","status":"completed","conclusion":"failure","event":"push"}]))
        client = Ci::GithubClient.new(nil, nil, Ci::GithubCli.new(->runner.call(String, String), "/repo"))

        check = client.runs(PORT_SPEC_SHA)

        runner.commands.should eq(["gh run list -c #{PORT_SPEC_SHA} --json databaseId,name,status,conclusion,event --limit 100"])
        check.status.failure?.should be_true
        check.detail.should eq("spec (failure)")
        check.runs.first.id.should eq("42")
      end

      it "fetches the failed run's log with gh run view --log-failed" do
        runner = PortRunnerFake.new
        runner.add(0, %([{"databaseId":42,"name":"spec","status":"completed","conclusion":"failure","event":"push"}]))
        runner.add(0, "Error: expected true\n")
        client = Ci::GithubClient.new(nil, nil, Ci::GithubCli.new(->runner.call(String, String), "/repo"))

        log = client.failure_log(client.runs(PORT_SPEC_SHA))
        runner.commands.last.should eq("gh run view 42 --log-failed")
        log.error.should be_empty
        log.text.should contain("expected true")
      end

      it "treats gh failures and non-JSON output as transient errors" do
        runner = PortRunnerFake.new
        runner.add(1, "gh: command not found")
        client = Ci::GithubClient.new(nil, nil, Ci::GithubCli.new(->runner.call(String, String), "/repo"))

        check = client.runs(PORT_SPEC_SHA)
        check.status.error?.should be_true
        check.permanent_error.should be_false
        check.detail.should contain("gh failed (exit 1)")

        runner.add(0, "warning: update available\nnot json")
        check = client.runs(PORT_SPEC_SHA)
        check.status.error?.should be_true
        check.detail.should contain("unexpected gh output")
      end
    end
  end

  describe Ci::GitlabClient do
    describe "via GitlabApi (REST, token optional)" do
      it "checks the commit's pipelines and maps a real payload" do
        http = PortHttpFake.new
        http.add(200, %([
          {"id": 123, "project_id": 456, "sha": "#{PORT_SPEC_SHA}", "ref": "master",
           "status": "running", "source": "push",
           "web_url": "https://gitlab.com/acme/app/-/pipelines/123"}
        ]))
        client, runner = port_gitlab_client(http)

        check = client.runs(PORT_SPEC_SHA)

        http.paths.should eq(["/projects/acme%2Fapp/pipelines?sha=#{PORT_SPEC_SHA}&per_page=20"])
        check.status.pending?.should be_true
        check.detail.should eq("in progress: pipeline #123")
        check.runs.first.web_url.should eq("https://gitlab.com/acme/app/-/pipelines/123")
        runner.commands.should be_empty # REST works — no glab invocation
      end

      it "settles success / failure from the pipeline statuses" do
        http = PortHttpFake.new
        http.add(200, %([
          {"id": 121, "project_id": 456, "sha": "#{PORT_SPEC_SHA}", "status": "success"},
          {"id": 122, "project_id": 456, "sha": "#{PORT_SPEC_SHA}", "status": "skipped"}
        ]))
        client, _ = port_gitlab_client(http)
        check = client.runs(PORT_SPEC_SHA)
        check.status.success?.should be_true
        check.detail.should eq("2 pipeline(s) passed")

        http.add(200, %([
          {"id": 123, "project_id": 456, "sha": "#{PORT_SPEC_SHA}", "status": "failed"}
        ]))
        check = client.runs(PORT_SPEC_SHA)
        check.status.failure?.should be_true
        check.detail.should eq("pipeline #123 (failed)")
      end

      it "ignores foreign-commit pipelines (server-side sha filter untrusted)" do
        http = PortHttpFake.new
        http.add(200, %([
          {"id": 999, "project_id": 456, "sha": "#{"a" * 40}", "status": "failed"},
          {"id": 123, "project_id": 456, "sha": "#{PORT_SPEC_SHA}", "status": "success"}
        ]))
        client, _ = port_gitlab_client(http)

        check = client.runs(PORT_SPEC_SHA)
        check.status.success?.should be_true
        check.runs.map(&.id).should eq(["123"])
      end

      it "constructs the pipeline link when the row has no web_url" do
        http = PortHttpFake.new
        http.add(200, %([{"id": 123, "project_id": 456, "sha": "#{PORT_SPEC_SHA}", "status": "running"}]))
        client, _ = port_gitlab_client(http)

        client.runs(PORT_SPEC_SHA).runs.first.web_url
          .should eq("https://gitlab.com/acme/app/-/pipelines/123")
      end

      it "fetches the failed job trace, skipping allow_failure jobs" do
        http = PortHttpFake.new
        http.add(200, %([{"id": 123, "project_id": 456, "sha": "#{PORT_SPEC_SHA}", "status": "failed"}]))
        http.add(200, %([
          {"id": 501, "status": "failed", "name": "rspec", "allow_failure": false},
          {"id": 502, "status": "failed", "name": "flake", "allow_failure": true}
        ]))
        http.add(200, "Running with gitlab-runner 16.9\nexpected true, got false\n")
        client, _ = port_gitlab_client(http)

        log = client.failure_log(client.runs(PORT_SPEC_SHA))
        log.error.should be_empty
        http.paths.should eq([
          "/projects/acme%2Fapp/pipelines?sha=#{PORT_SPEC_SHA}&per_page=20",
          "/projects/456/pipelines/123/jobs?per_page=50",
          "/projects/456/jobs/501/trace",
        ])
        log.text.should contain("expected true, got false")
      end

      it "reports WHY the trace is unreadable (fine-grained token without Job: Read)" do
        http = PortHttpFake.new
        http.add(200, %([{"id": 123, "project_id": 456, "sha": "#{PORT_SPEC_SHA}", "status": "failed"}]))
        http.add(200, %([{"id": 501, "status": "failed", "allow_failure": false}]))
        # Real-world GitLab answer for a fine-grained PAT lacking the
        # 'Job: Read' permission on the trace endpoint.
        http.add(403, %({"error":"insufficient_granular_scope","error_description":"Access denied: This operation requires a fine-grained personal access token with the following project permissions: [Job: Read]."}))
        client, _ = port_gitlab_client(http)

        log = client.failure_log(client.runs(PORT_SPEC_SHA))

        log.text.should be_empty
        log.error.should contain("HTTP 403")
        log.error.should contain("insufficient_granular_scope")
        log.error.should contain("Job: Read")
      end

      it "reports anonymous access denial as a permanent error with the token hint" do
        http = PortHttpFake.new
        http.add(404, %({"message":"404 Project Not Found"}))
        client, _ = port_gitlab_client(http)

        check = client.runs(PORT_SPEC_SHA)
        check.status.error?.should be_true
        check.permanent_error.should be_true
        check.detail.should contain("GitLab API HTTP 404")
        check.detail.should contain("no GitLab token is configured")
        check.detail.should contain("glab auth login")
      end

      it "reports a rejected configured token as a permanent error" do
        http = PortHttpFake.new
        http.add(403, "403 Forbidden")
        runner = PortRunnerFake.new
        client = Ci::GitlabClient.new(
          port_gitlab_repo,
          Ci::GitlabApi.new("https://gitlab.com", "glpat-bad", ->http.call(String)),
          Ci::GitlabCli.new(->runner.call(String, String), "/repo", "gitlab.com"),
          -> { false })

        check = client.runs(PORT_SPEC_SHA)
        check.permanent_error.should be_true
        check.detail.should contain("token was rejected")
      end

      it "treats server errors as transient" do
        http = PortHttpFake.new
        http.add(500, "500 Internal Server Error")
        client, _ = port_gitlab_client(http)

        check = client.runs(PORT_SPEC_SHA)
        check.status.error?.should be_true
        check.permanent_error.should be_false
        check.detail.should contain("GitLab API HTTP 500")
      end
    end

    describe "via GitlabCli (glab fallback when REST access is denied)" do
      it "retries the pipelines query through glab api" do
        http = PortHttpFake.new
        http.add(404, "404 Not Found")
        runner = PortRunnerFake.new
        runner.add(0, %([{"id": 123, "project_id": 456, "sha": "#{PORT_SPEC_SHA}", "status": "success"}]))
        client = Ci::GitlabClient.new(
          port_gitlab_repo,
          Ci::GitlabApi.new("https://gitlab.com", nil, ->http.call(String)),
          Ci::GitlabCli.new(->runner.call(String, String), "/repo", "gitlab.com"),
          -> { true })

        check = client.runs(PORT_SPEC_SHA)

        check.status.success?.should be_true
        runner.commands.should eq([
          "glab api --hostname gitlab.com -X GET 'projects/acme%2Fapp/pipelines?sha=#{PORT_SPEC_SHA}&per_page=20'",
        ])
      end

      it "fetches the failure log through glab when REST denies access" do
        http = PortHttpFake.new
        http.add(401, "401 Unauthorized") # pipelines
        runner = PortRunnerFake.new
        runner.add(0, %([{"id": 123, "project_id": 456, "sha": "#{PORT_SPEC_SHA}", "status": "failed"}]))
        http.add(401, "401 Unauthorized") # jobs (REST attempt)
        runner.add(0, %([{"id": 501, "status": "failed", "allow_failure": false}]))
        http.add(401, "401 Unauthorized") # trace (REST attempt)
        runner.add(0, "expected true, got false\n")
        client = Ci::GitlabClient.new(
          port_gitlab_repo,
          Ci::GitlabApi.new("https://gitlab.com", nil, ->http.call(String)),
          Ci::GitlabCli.new(->runner.call(String, String), "/repo", "gitlab.com"),
          -> { true })

        log = client.failure_log(client.runs(PORT_SPEC_SHA))

        log.error.should be_empty
        log.text.should contain("expected true, got false")
        runner.commands.count(&.starts_with?("glab api")).should eq(3)
        runner.commands.last.should eq("glab api --hostname gitlab.com -X GET 'projects/456/jobs/501/trace'")
      end

      it "treats glab failures as transient errors" do
        http = PortHttpFake.new
        http.add(401, "401 Unauthorized")
        runner = PortRunnerFake.new
        runner.add(1, "glab: not logged in")
        client = Ci::GitlabClient.new(
          port_gitlab_repo,
          Ci::GitlabApi.new("https://gitlab.com", nil, ->http.call(String)),
          Ci::GitlabCli.new(->runner.call(String, String), "/repo", "gitlab.com"),
          -> { true })

        check = client.runs(PORT_SPEC_SHA)
        check.status.error?.should be_true
        check.permanent_error.should be_false
        check.detail.should contain("glab failed (exit 1)")
      end
    end
  end
end
