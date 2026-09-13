require "../spec_helper"

CI_SPEC_SHA = "b" * 40

module H2code::Tools
  # Scripted runner: canned results consumed FIFO, one per invocation.
  class CiFakeRunner
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

  def self.fake_ci_service(runner : CiFakeRunner)
    svc = Ci::LiveCiService.new
    svc.autostart = false
    svc.runner = ->runner.call(String, String)
    svc
  end

  describe Ci do
    describe "push_command?" do
      it "detects plain git push" do
        Ci.push_command?("git push").should be_true
        Ci.push_command?("git  push origin main").should be_true
      end

      it "detects push with flags and -C" do
        Ci.push_command?("git -C /repo push").should be_true
        Ci.push_command?("git --force push origin").should be_true
      end

      it "detects push inside compound commands" do
        Ci.push_command?("crystal spec && git push").should be_true
        Ci.push_command?("crystal spec; git push || true").should be_true
      end

      it "rejects non-push git commands" do
        Ci.push_command?("git commit -m foo").should be_false
        Ci.push_command?("git status").should be_false
        Ci.push_command?("git log --grep push").should be_false
      end

      it "rejects non-git commands" do
        Ci.push_command?("crystal spec").should be_false
        Ci.push_command?("echo done").should be_false
      end
    end

    describe "repo_dir_from_command" do
      it "returns the default when no -C is present" do
        Ci.repo_dir_from_command("git push", "/default").should eq("/default")
        Ci.repo_dir_from_command("git push origin main", "/default").should eq("/default")
      end

      it "resolves -C dir" do
        Ci.repo_dir_from_command("git -C /other/repo push", "/default").should eq("/other/repo")
        Ci.repo_dir_from_command("git -C ../rel push", "/default").should eq("/rel")
      end

      it "resolves -C in compound commands" do
        Ci.repo_dir_from_command("rake test && git -C /srv/app push", "/default").should eq("/srv/app")
      end

      it "ignores -C in non-git segments" do
        Ci.repo_dir_from_command("echo -C /nope; git push", "/default").should eq("/default")
      end
    end

    describe "push_covers_branch?" do
      it "covers every branch when a push trigger has no filters" do
        with_tmpdir do |dir|
          wf = File.join(dir, ".github", "workflows")
          Dir.mkdir_p(wf)
          File.write(File.join(wf, "a.yml"), "on: [push]")
          File.write(File.join(wf, "b.yml"), "on:\n  push:")
          Ci.push_covers_branch?(dir, "anything").should be_true
        end
      end

      it "matches branches filters with fnmatch globs" do
        with_tmpdir do |dir|
          wf = File.join(dir, ".github", "workflows")
          Dir.mkdir_p(wf)
          File.write(File.join(wf, "ci.yml"), <<-YML)
            on:
              push:
                branches: [master, develop, "release/**"]
          YML
          Ci.push_covers_branch?(dir, "master").should be_true
          Ci.push_covers_branch?(dir, "release/1.2.3").should be_true
          Ci.push_covers_branch?(dir, "feature/x").should be_false
        end
      end

      it "honors branches-ignore without a branches list" do
        with_tmpdir do |dir|
          wf = File.join(dir, ".github", "workflows")
          Dir.mkdir_p(wf)
          File.write(File.join(wf, "ci.yml"), <<-YML)
            on:
              push:
                branches-ignore: [docs/*]
          YML
          Ci.push_covers_branch?(dir, "master").should be_true
          Ci.push_covers_branch?(dir, "docs/readme").should be_false
        end
      end

      it "is not covered when only other events trigger" do
        with_tmpdir do |dir|
          wf = File.join(dir, ".github", "workflows")
          Dir.mkdir_p(wf)
          File.write(File.join(wf, "ci.yml"), "on:\n  pull_request:\n    branches: [master]")
          Ci.push_covers_branch?(dir, "master").should be_false
        end
      end

      it "treats undecidable input as covered" do
        with_tmpdir do |dir|
          wf = File.join(dir, ".github", "workflows")
          Dir.mkdir_p(wf)
          # Unparsable YAML, empty workflows dir, detached HEAD, no dir.
          File.write(File.join(wf, "bad.yml"), "on: [push\n")
          Ci.push_covers_branch?(dir, "master").should be_true
          File.delete(File.join(wf, "bad.yml"))
          Ci.push_covers_branch?(dir, "master").should be_true
          Ci.push_covers_branch?(dir, "").should be_true
          Ci.push_covers_branch?(dir, "HEAD").should be_true
          Ci.push_covers_branch?(File.join(dir, "missing"), "master").should be_true
        end
      end

      it "covers any branch when several workflows combine" do
        with_tmpdir do |dir|
          wf = File.join(dir, ".github", "workflows")
          Dir.mkdir_p(wf)
          File.write(File.join(wf, "a.yml"), "on:\n  push:\n    branches: [master]")
          File.write(File.join(wf, "b.yml"), "on: [push, pull_request]")
          Ci.push_covers_branch?(dir, "feature/x").should be_true
        end
      end
    end

    describe "poll cadence" do
      it "is a fixed 30 s interval" do
        Ci::POLL_INTERVAL_S.should eq(30)
      end
    end

    describe "aggregate_runs" do
      it "is pending when no runs are registered yet" do
        status, detail = Ci.aggregate_runs([] of JSON::Any)
        status.pending?.should be_true
        detail.should contain("no runs")
      end

      it "is pending while any run is in progress" do
        runs = [
          {"name" => "build", "status" => "completed", "conclusion" => "success"},
          {"name" => "test", "status" => "in_progress", "conclusion" => nil},
        ].map { |h| JSON.parse(h.to_json) }
        status, _ = Ci.aggregate_runs(runs)
        status.pending?.should be_true
      end

      it "is success when all completed runs passed" do
        runs = [
          {"name" => "build", "status" => "completed", "conclusion" => "success"},
          {"name" => "lint", "status" => "completed", "conclusion" => "skipped"},
        ].map { |h| JSON.parse(h.to_json) }
        status, detail = Ci.aggregate_runs(runs)
        status.success?.should be_true
        detail.should contain("2 run(s) passed")
      end

      it "is failure when any completed run failed" do
        runs = [
          {"name" => "build", "status" => "completed", "conclusion" => "success"},
          {"name" => "spec", "status" => "completed", "conclusion" => "failure"},
        ].map { |h| JSON.parse(h.to_json) }
        status, detail = Ci.aggregate_runs(runs)
        status.failure?.should be_true
        detail.should contain("spec (failure)")
      end

      it "ignores Dependabot dynamic bookkeeping runs" do
        # Dependabot's dependabot-updates runs attach to the default branch
        # head; counted as passes they fabricate a green verdict for commits
        # whose real CI never ran or failed.
        runs = [
          {"name" => "github_actions in /. - Update #1", "status" => "completed",
           "conclusion" => "success", "event" => "dynamic"},
          {"name" => "bundler in /. - Update #2", "status" => "completed",
           "conclusion" => "success", "event" => "dynamic"},
        ].map { |h| JSON.parse(h.to_json) }
        status, detail = Ci.aggregate_runs(runs)
        status.pending?.should be_true
        detail.should contain("no runs")
      end

      it "reports failure from the real run among dynamic runs" do
        runs = [
          {"name" => "github_actions in /. - Update #1", "status" => "completed",
           "conclusion" => "success", "event" => "dynamic"},
          {"name" => "CI", "status" => "completed", "conclusion" => "failure",
           "event" => "push"},
        ].map { |h| JSON.parse(h.to_json) }
        status, detail = Ci.aggregate_runs(runs)
        status.failure?.should be_true
        detail.should contain("CI (failure)")
      end
    end

    describe "aggregate_pipelines" do
      it "is pending when no pipelines are registered yet" do
        status, detail = Ci.aggregate_pipelines([] of JSON::Any)
        status.pending?.should be_true
        detail.should contain("no pipelines")
      end

      it "is pending while any pipeline is in progress" do
        pipelines = [
          {"id" => 1, "status" => "success"},
          {"id" => 2, "status" => "running"},
        ].map { |h| JSON.parse(h.to_json) }
        status, _ = Ci.aggregate_pipelines(pipelines)
        status.pending?.should be_true
      end

      it "is success when all pipelines passed or were skipped" do
        pipelines = [
          {"id" => 1, "status" => "success"},
          {"id" => 2, "status" => "skipped"},
        ].map { |h| JSON.parse(h.to_json) }
        status, detail = Ci.aggregate_pipelines(pipelines)
        status.success?.should be_true
        detail.should contain("2 pipeline(s) passed")
      end

      it "is failure for failed / canceled / manual pipelines" do
        pipelines = [
          {"id" => 1, "status" => "success"},
          {"id" => 2, "status" => "failed"},
          {"id" => 3, "status" => "canceled"},
        ].map { |h| JSON.parse(h.to_json) }
        status, detail = Ci.aggregate_pipelines(pipelines)
        status.failure?.should be_true
        detail.should contain("#2 (failed)")
        detail.should contain("#3 (canceled)")
      end
    end

    describe "excerpt" do
      it "keeps short strings intact" do
        Ci.excerpt("abc", 10).should eq("abc")
      end

      it "keeps the tail of long strings" do
        Ci.excerpt("0123456789", 4).should eq("...6789")
      end
    end

    describe "parse_github_remote" do
      it "parses SSH and HTTPS github.com remotes" do
        Ci.parse_github_remote("git@github.com:acme/app.git").should eq(Ci::RepoInfo.new(Ci::Provider::Github, "github.com", "acme/app"))
        Ci.parse_github_remote("https://github.com/acme/app.git").should eq(Ci::RepoInfo.new(Ci::Provider::Github, "github.com", "acme/app"))
        Ci.parse_github_remote("https://user:tok@github.com/acme/app").should eq(Ci::RepoInfo.new(Ci::Provider::Github, "github.com", "acme/app"))
      end

      it "rejects non-github remotes" do
        Ci.parse_github_remote("git@gitlab.com:acme/app.git").should be_nil
        Ci.parse_github_remote("https://example.com/acme/app.git").should be_nil
        Ci.parse_github_remote("").should be_nil
      end
    end

    describe "parse_gitlab_remote" do
      it "parses SSH and HTTPS gitlab.com remotes with subgroups" do
        Ci.parse_gitlab_remote("git@gitlab.com:acme/app.git").should eq(Ci::RepoInfo.new(Ci::Provider::Gitlab, "gitlab.com", "acme/app"))
        Ci.parse_gitlab_remote("https://gitlab.com/acme/app.git").should eq(Ci::RepoInfo.new(Ci::Provider::Gitlab, "gitlab.com", "acme/app"))
        Ci.parse_gitlab_remote("https://gitlab.com/grp/sub/team/proj").should eq(Ci::RepoInfo.new(Ci::Provider::Gitlab, "gitlab.com", "grp/sub/team/proj"))
        Ci.parse_gitlab_remote("ssh://git@gitlab.com/acme/app.git").should eq(Ci::RepoInfo.new(Ci::Provider::Gitlab, "gitlab.com", "acme/app"))
      end

      it "accepts configured self-hosted hosts only" do
        hosts = ["gitlab.com", "gitlab.corp.io"]
        Ci.parse_gitlab_remote("git@gitlab.corp.io:acme/app.git", hosts).should eq(Ci::RepoInfo.new(Ci::Provider::Gitlab, "gitlab.corp.io", "acme/app"))
        Ci.parse_gitlab_remote("https://gitlab.corp.io/acme/app.git", hosts).should_not be_nil
        # Without the extra host configured the remote is not GitLab.
        Ci.parse_gitlab_remote("git@gitlab.corp.io:acme/app.git").should be_nil
        Ci.parse_gitlab_remote("git@github.com:acme/app.git").should be_nil
      end

      it "keeps the path case-sensitive and rejects namespace-less paths" do
        Ci.parse_gitlab_remote("https://gitlab.com/Org/App").not_nil!.path.should eq("Org/App")
        Ci.parse_gitlab_remote("git@gitlab.com:app.git").should be_nil
        Ci.parse_gitlab_remote("").should be_nil
      end

      it "strips ports and credentials from the host" do
        Ci.parse_gitlab_remote("http://root:glpat-x@localhost:8080/root/hello_ci.git", ["gitlab.com", "localhost"])
          .should eq(Ci::RepoInfo.new(Ci::Provider::Gitlab, "localhost", "root/hello_ci"))
        Ci.parse_gitlab_remote("https://gitlab.corp.io:8443/grp/proj.git", ["gitlab.corp.io"])
          .not_nil!.host.should eq("gitlab.corp.io")
      end

      it "URL-encodes the project ref for API calls" do
        info = Ci.parse_gitlab_remote("https://gitlab.com/grp/sub/proj").not_nil!
        info.gitlab_project_ref.should eq("grp%2Fsub%2Fproj")
        Ci.encode_path_segment("a b+c").should eq("a%20b%2Bc")
      end
    end

    describe "extract_zip_text" do
      it "concatenates the text entries of a run-logs zip" do
        zip = IO::Memory.new
        Compress::Zip::Writer.open(zip) do |writer|
          writer.add("job/1_setup.txt", IO::Memory.new("setup ok\n"))
          writer.add("job/2_build.txt", IO::Memory.new("expected true, got false\n"))
        end
        text = Ci.extract_zip_text(zip.to_s)
        text.should contain("setup ok")
        text.should contain("expected true, got false")
      end

      it "returns an empty string for non-zip input" do
        Ci.extract_zip_text("not a zip").should eq("")
      end
    end

    describe Ci::GithubApi do
      it "extracts the redirect target from the Location header" do
        resp = HTTP::Client::Response.new(301, "",
          HTTP::Headers{"Location" => "https://api.github.com/repositories/1/actions/runs"})
        Ci::GithubApi.redirect_target(resp).should eq("https://api.github.com/repositories/1/actions/runs")
      end

      it "falls back to the url field of a moved-repository notice" do
        body = %({"message":"Moved Permanently","url":"https://api.github.com/repositories/1304806254/actions/runs","documentation_url":"https://docs.github.com/rest"})
        resp = HTTP::Client::Response.new(301, body)
        Ci::GithubApi.redirect_target(resp).should eq("https://api.github.com/repositories/1304806254/actions/runs")
      end

      it "returns nil for non-redirect responses" do
        resp = HTTP::Client::Response.new(200, %({"workflow_runs":[]}))
        Ci::GithubApi.redirect_target(resp).should be_nil
      end
    end

    describe "render_notification" do
      it "returns nil for success (log-only)" do
        obs = Ci::Observer.new("a" * 40)
        obs.status = Ci::Status::Success
        obs.detail = "1 run(s) passed"
        Ci.render_notification(obs).should be_nil
      end

      it "builds a plain-text fix-it notification for failure" do
        obs = Ci::Observer.new("a" * 40)
        obs.status = Ci::Status::Failure
        obs.detail = "spec (failure)"
        obs.failure_log = "expected true, got false"
        text = Ci.render_notification(obs).not_nil!
        # The plain-text delivery marker (exactly-once dedup key).
        text.should contain(%([notification id="ci.#{"a" * 40}.failure"]))
        text.should contain("CI build failed")
        text.should contain("expected true, got false")
        text.should contain("commit and push again")
        # No raw XML envelope reaches the model.
        text.should_not contain("<notification")
      end

      it "mentions GitLab CI and glab for GitLab observers" do
        obs = Ci::Observer.new("a" * 40)
        obs.provider = Ci::Provider::Gitlab
        obs.status = Ci::Status::Failure
        obs.detail = "pipeline #7 (failed)"
        Ci.render_notification(obs).not_nil!.should contain("GitLab CI pipeline")

        err = Ci::Observer.new("b" * 40)
        err.provider = Ci::Provider::Gitlab
        err.status = Ci::Status::Error
        err.detail = "GitLab API HTTP 404"
        Ci.render_notification(err).not_nil!.should contain("glab ci status")
      end
    end
  end

  describe Ci::LiveCiService do
    it "try_observe_push starts an observer for an eligible repo" do
      with_tmpdir do |dir|
        Dir.mkdir_p(File.join(dir, ".github", "workflows"))
        runner = CiFakeRunner.new
        runner.add(0, CI_SPEC_SHA)                   # git rev-parse HEAD
        runner.add(0, "")                            # git branch -r --contains
        runner.add(0, "git@github.com:acme/app.git") # git remote get-url origin
        svc = Tools.fake_ci_service(runner)

        svc.try_observe_push("git push", dir).should be_true
        obs = svc.observer_for(CI_SPEC_SHA).should_not be_nil
        obs.not_nil!.pending?.should be_true
        svc.pending?.should be_true

        # The wait line gets a clickable link to the commit's checks page.
        obs.not_nil!.actions_url.should eq("https://github.com/acme/app/commit/#{CI_SPEC_SHA}/checks")
      end
    end

    it "try_observe_push observes the repo targeted by git -C, not the cwd" do
      with_tmpdir do |dir|
        # The session cwd has workflows but no github remote; the real repo
        # at target/ is eligible. Detection must resolve HEAD in target/.
        Dir.mkdir_p(File.join(dir, "target", ".github", "workflows"))
        runner = CiFakeRunner.new
        runner.add(0, CI_SPEC_SHA)                      # HEAD in target/
        runner.add(0, "")                               # git branch -r --contains
        runner.add(0, "git@github.com:acme/target.git") # remote in target/
        svc = Tools.fake_ci_service(runner)

        svc.try_observe_push("git -C #{dir}/target push", dir).should be_true
        obs = svc.observer_for(CI_SPEC_SHA).should_not be_nil
        obs.not_nil!.pending?.should be_true

        # The fake runner consumed both responses for target/, not for dir.
        svc.try_observe_push("git push", dir).should be_false
      end
    end

    it "try_observe_push ignores repos without workflows" do
      with_tmpdir do |dir|
        runner = CiFakeRunner.new
        runner.add(0, CI_SPEC_SHA)
        svc = Tools.fake_ci_service(runner)

        svc.try_observe_push("git push", dir).should be_false
        svc.pending?.should be_false
      end
    end

    it "try_observe_push ignores non-github remotes" do
      with_tmpdir do |dir|
        Dir.mkdir_p(File.join(dir, ".github", "workflows"))
        runner = CiFakeRunner.new
        runner.add(0, CI_SPEC_SHA)
        runner.add(0, "")
        runner.add(0, "git@gitlab.com:acme/app.git")
        svc = Tools.fake_ci_service(runner)

        svc.try_observe_push("git push", dir).should be_false
      end
    end

    it "try_observe_push ignores non-push commands" do
      with_tmpdir do |dir|
        Dir.mkdir_p(File.join(dir, ".github", "workflows"))
        runner = CiFakeRunner.new
        runner.add(0, "git@github.com:acme/app.git")
        runner.add(0, CI_SPEC_SHA)
        svc = Tools.fake_ci_service(runner)

        svc.try_observe_push("git commit -m wip", dir).should be_false
      end
    end

    it "try_observe_push skips branches no workflow triggers on" do
      with_tmpdir do |dir|
        wf = File.join(dir, ".github", "workflows")
        Dir.mkdir_p(wf)
        File.write(File.join(wf, "ci.yml"), <<-YML)
          name: CI
          on:
            push:
              branches: [master, develop]
        YML
        delivered = [] of String
        runner = CiFakeRunner.new
        runner.add(0, CI_SPEC_SHA)                   # git rev-parse HEAD
        runner.add(0, "")                            # git branch -r --contains
        runner.add(0, "git@github.com:acme/app.git") # git remote get-url origin
        runner.add(0, "feature/x")                   # git rev-parse --abbrev-ref HEAD
        svc = Tools.fake_ci_service(runner)
        svc.delivery = ->(xml : String) { delivered << xml; nil }

        svc.try_observe_push("git push", dir).should be_false
        svc.observer_for(CI_SPEC_SHA).should be_nil
        svc.pending?.should be_false
        delivered.join.should contain("No CI build for this branch")
        delivered.join.should contain("feature/x")
      end
    end

    it "try_observe_push observes a branch covered by a workflow filter" do
      with_tmpdir do |dir|
        wf = File.join(dir, ".github", "workflows")
        Dir.mkdir_p(wf)
        File.write(File.join(wf, "ci.yml"), <<-YML)
          name: CI
          on:
            push:
              branches: [master, develop]
        YML
        runner = CiFakeRunner.new
        runner.add(0, CI_SPEC_SHA)
        runner.add(0, "")
        runner.add(0, "git@github.com:acme/app.git")
        runner.add(0, "develop")
        svc = Tools.fake_ci_service(runner)

        svc.try_observe_push("git push", dir).should be_true
        svc.observer_for(CI_SPEC_SHA).should_not be_nil
      end
    end

    it "poll_once settles as success and skips delivery" do
      with_tmpdir do |dir|
        delivered = [] of String
        updates = [] of Ci::Observer
        runner = CiFakeRunner.new
        runner.add(0, %[[{"name":"build","status":"completed","conclusion":"success"}]])
        svc = Tools.fake_ci_service(runner)
        svc.delivery = ->(text : String) { delivered << text; nil }
        svc.on_update = ->(obs : Ci::Observer) { updates << obs; nil }

        svc.observe(CI_SPEC_SHA, dir)
        obs = svc.observer_for(CI_SPEC_SHA).not_nil!
        svc.poll_once(obs, dir)

        obs.status.success?.should be_true
        svc.pending?.should be_false
        delivered.empty?.should be_true
        updates.size.should eq(2) # one on observe, one on terminal state
      end
    end

    it "observe settles from the first immediate poll instead of waiting POLL_INTERVAL_S" do
      with_tmpdir do |dir|
        runner = CiFakeRunner.new
        runner.add(0, %[ [{"name":"build","status":"completed","conclusion":"success"}] ])
        svc = Ci::LiveCiService.new
        svc.runner = ->runner.call(String, String)

        svc.observe(CI_SPEC_SHA, dir).should be_true

        # The spawned poll fiber must run its first check right away: the
        # observer reaches a terminal state in well under POLL_INTERVAL_S.
        deadline = Time.instant + 2.seconds
        while svc.observer_for(CI_SPEC_SHA).try(&.pending?) && Time.instant < deadline
          sleep 10.milliseconds
        end
        svc.observer_for(CI_SPEC_SHA).not_nil!.status.success?.should be_true
      end
    end

    it "poll_once captures the failure log and delivers a notification" do
      with_tmpdir do |dir|
        delivered = [] of String
        runner = CiFakeRunner.new
        runner.add(0, %[[]]) # first poll: no runs yet
        runner.add(0, %[ [{"databaseId":42,"name":"spec","status":"completed","conclusion":"failure"}] ])
        runner.add(0, "Error: expected true\n") # gh run view --log-failed
        svc = Tools.fake_ci_service(runner)
        svc.observe(CI_SPEC_SHA, dir)
        obs = svc.observer_for(CI_SPEC_SHA).not_nil!
        svc.poll_once(obs, dir)
        obs.pending?.should be_true # no runs yet → stays pending

        svc.delivery = ->(text : String) { delivered << text; nil }
        svc.poll_once(obs, dir)

        obs.status.failure?.should be_true
        obs.failure_log.should contain("expected true")
        delivered.size.should eq(1)
        delivered.first.should contain("CI build failed")
      end
    end

    it "poll_once tolerates transient gh failures without dropping the wait" do
      with_tmpdir do |dir|
        runner = CiFakeRunner.new
        runner.add(1, "gh: command not found")
        svc = Tools.fake_ci_service(runner)
        svc.observe(CI_SPEC_SHA, dir)
        obs = svc.observer_for(CI_SPEC_SHA).not_nil!
        svc.poll_once(obs, dir)

        # A single failure must NOT terminate the observer — the active-zone
        # wait line stays until a real terminal status (or the error
        # threshold / overall timeout is reached).
        obs.pending?.should be_true
        obs.detail.should contain("retrying after")

        # It recovers on the next successful poll.
        runner.add(0, %[[{"name":"build","status":"in_progress","conclusion":null}]])
        svc.poll_once(obs, dir)
        obs.pending?.should be_true
        obs.consecutive_failures.should eq(0)
      end
    end

    it "poll_once marks the observer as error after repeated gh failures" do
      with_tmpdir do |dir|
        runner = CiFakeRunner.new
        svc = Tools.fake_ci_service(runner)
        svc.observe(CI_SPEC_SHA, dir)
        obs = svc.observer_for(CI_SPEC_SHA).not_nil!
        Ci::MAX_CONSECUTIVE_FAILURES.times do
          runner.add(1, "gh: command not found")
          svc.poll_once(obs, dir)
        end

        obs.status.error?.should be_true
        obs.detail.should contain("gh failed")
      end
    end

    it "poll_once tolerates non-JSON gh output (merged stderr noise)" do
      with_tmpdir do |dir|
        runner = CiFakeRunner.new
        runner.add(0, "warning: update available\n[]")
        svc = Tools.fake_ci_service(runner)
        svc.observe(CI_SPEC_SHA, dir)
        obs = svc.observer_for(CI_SPEC_SHA).not_nil!
        svc.poll_once(obs, dir)

        obs.pending?.should be_true
      end
    end

    it "suppressed delivery when the observer is claimed" do
      with_tmpdir do |dir|
        delivered = [] of String
        runner = CiFakeRunner.new
        runner.add(0, %[[{"name":"build","status":"completed","conclusion":"failure"}]])
        svc = Tools.fake_ci_service(runner)
        svc.delivery = ->(text : String) { delivered << text; nil }
        svc.observe(CI_SPEC_SHA, dir)
        obs = svc.observer_for(CI_SPEC_SHA).not_nil!
        obs.claimed = true
        svc.poll_once(obs, dir)

        obs.status.failure?.should be_true
        delivered.empty?.should be_true
      end
    end

    it "does not duplicate observers for the same sha" do
      with_tmpdir do |dir|
        runner = CiFakeRunner.new
        svc = Tools.fake_ci_service(runner)
        svc.observe(CI_SPEC_SHA, dir).should be_true
        svc.observe(CI_SPEC_SHA, dir).should be_true
        svc.observer_for(CI_SPEC_SHA).should_not be_nil
        svc.pending_observer.should_not be_nil
      end
    end

    it "keeps one observer per pushed commit, oldest first" do
      with_tmpdir do |dir|
        runner = CiFakeRunner.new
        svc = Tools.fake_ci_service(runner)
        svc.observe("a" * 40, dir)
        svc.observe("b" * 40, dir)

        pending = svc.pending_observers
        pending.size.should eq(2)
        pending.map(&.sha).should eq(["a" * 40, "b" * 40])

        # Settling one commit leaves the other's wait line alive.
        runner.add(0, %[[{"name":"build","status":"completed","conclusion":"success"}]])
        obs_a = svc.observer_for("a" * 40).not_nil!
        svc.poll_once(obs_a, dir)
        svc.pending?.should be_true
        svc.pending_observers.map(&.sha).should eq(["b" * 40])
      end
    end
  end

  describe Ci::LiveCiService do
    describe "direct REST mode (token present)" do
      it "polls api.github.com and settles without touching gh" do
        with_tmpdir do |dir|
          Dir.mkdir_p(File.join(dir, ".github", "workflows"))
          runner = CiFakeRunner.new
          runner.add(0, "git@github.com:acme/app.git") # git remote get-url origin
          api_urls = [] of String
          svc = Tools.fake_ci_service(runner)
          svc.github_token = "ghp_test"
          svc.api_get = ->(path : String) do
            api_urls << path
            Ci::ApiResponse.new(200, %({"workflow_runs":[{"name":"build","status":"completed","conclusion":"success"}]}))
          end

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.status.success?.should be_true
          api_urls.should contain("/repos/acme/app/actions/runs?head_sha=#{CI_SPEC_SHA}&per_page=100")
          # No gh CLI invocation on the API path.
          runner.commands.any?(&.starts_with?("gh ")).should be_false
        end
      end

      it "fetches the failure log zip via the 302 redirect" do
        with_tmpdir do |dir|
          Dir.mkdir_p(File.join(dir, ".github", "workflows"))
          runner = CiFakeRunner.new
          runner.add(0, "https://github.com/acme/app.git")
          zip = IO::Memory.new
          Compress::Zip::Writer.open(zip) do |writer|
            writer.add("job/2_spec.txt", IO::Memory.new("expected true, got false\n"))
          end
          svc = Tools.fake_ci_service(runner)
          svc.github_token = "ghp_test"
          svc.api_get = ->(path : String) do
            if path.includes?("/logs")
              Ci::ApiResponse.new(302, "", "https://objects.githubusercontent.com/signed")
            elsif path.starts_with?("https://")
              Ci::ApiResponse.new(200, zip.to_s)
            else
              Ci::ApiResponse.new(200, %({"workflow_runs":[{"id":42,"name":"spec","status":"completed","conclusion":"failure"}]}))
            end
          end

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.status.failure?.should be_true
          obs.failure_log.should contain("expected true, got false")
        end
      end

      it "treats API 5xx / rate limits as transient failures" do
        with_tmpdir do |dir|
          Dir.mkdir_p(File.join(dir, ".github", "workflows"))
          runner = CiFakeRunner.new
          runner.add(0, "git@github.com:acme/app.git")
          svc = Tools.fake_ci_service(runner)
          svc.github_token = "ghp_test"
          svc.api_get = ->(_path : String) { Ci::ApiResponse.new(403, "API rate limit exceeded") }

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.pending?.should be_true
          obs.detail.should contain("HTTP 403")
        end
      end
    end

    describe "GitLab integration" do
      it "observes a .gitlab-ci.yml repo with a gitlab remote" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "test:\n  script: echo hi\n")
          runner = CiFakeRunner.new
          runner.add(0, CI_SPEC_SHA)                   # git rev-parse HEAD
          runner.add(0, "")                            # git branch -r --contains
          runner.add(0, "git@gitlab.com:acme/app.git") # git remote get-url origin
          svc = Tools.fake_ci_service(runner)

          svc.try_observe_push("git push", dir).should be_true
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          obs.pending?.should be_true
          obs.provider.gitlab?.should be_true
          obs.actions_url.should eq("https://gitlab.com/acme/app/-/commit/#{CI_SPEC_SHA}")
        end
      end

      it "observes self-hosted GitLab remotes matching gitlab.endpoint" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, CI_SPEC_SHA)
          runner.add(0, "")
          runner.add(0, "git@gitlab.corp.io:acme/app.git")
          svc = Tools.fake_ci_service(runner)
          svc.gitlab_endpoint = "https://gitlab.corp.io"

          svc.try_observe_push("git push", dir).should be_true
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          obs.provider.gitlab?.should be_true
          # The wait-line link uses the configured endpoint base.
          obs.actions_url.should eq("https://gitlab.corp.io/acme/app/-/commit/#{CI_SPEC_SHA}")
        end
      end

      it "ignores .gitlab-ci.yml repos with non-GitLab remotes" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, CI_SPEC_SHA)
          runner.add(0, "")
          runner.add(0, "git@github.com:acme/app.git")
          svc = Tools.fake_ci_service(runner)

          svc.try_observe_push("git push", dir).should be_false
        end
      end

      it "observes the remote the pushed commit landed on (two configs, non-origin push)" do
        with_tmpdir do |dir|
          # Both CI configs in the tree; origin is GitHub, but the push went
          # to the self-hosted GitLab remote only — the observer must follow
          # the commit, not the origin URL.
          Dir.mkdir_p(File.join(dir, ".github", "workflows"))
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, CI_SPEC_SHA)                   # git rev-parse HEAD
          runner.add(0, "  gitlab/master\n")           # git branch -r --contains
          runner.add(0, "git@gl.corp.io:h2/app.git")   # git remote get-url gitlab
          runner.add(0, "git@github.com:acme/app.git") # git remote get-url origin (unused)
          svc = Tools.fake_ci_service(runner)
          svc.gitlab_endpoint = "https://gl.corp.io"

          svc.try_observe_push("git push gitlab master", dir).should be_true
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          obs.pending?.should be_true
          obs.provider.gitlab?.should be_true
          obs.actions_url.should eq("https://gl.corp.io/h2/app/-/commit/#{CI_SPEC_SHA}")
          # The gitlab remote is resolved before origin.
          runner.commands.index!("git remote get-url gitlab")
            .should be < runner.commands.index!("git remote get-url origin")
        end
      end

      it "observes a GitLab-bound push even when the GitHub workflow filters exclude the branch" do
        with_tmpdir do |dir|
          # Two configs again: the GitHub workflow only triggers on master,
          # but the push went to the GitLab remote — .gitlab-ci.yml has no
          # parsed branch filter, so the pipeline counts as covered.
          Dir.mkdir_p(File.join(dir, ".github", "workflows"))
          File.write(File.join(dir, ".github", "workflows", "ci.yml"),
            "on:\n  push:\n    branches: [master]\n")
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, CI_SPEC_SHA)                       # git rev-parse HEAD
          runner.add(0, "  gitlab/feature/x\n")            # git branch -r --contains
          runner.add(0, "https://gitlab.com/acme/app.git") # git remote get-url gitlab
          svc = Tools.fake_ci_service(runner)

          svc.try_observe_push("git push gitlab feature/x", dir).should be_true
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          obs.pending?.should be_true
          obs.provider.gitlab?.should be_true
        end
      end

      it "re-resolves the remote per pushed commit" do
        with_tmpdir do |dir|
          Dir.mkdir_p(File.join(dir, ".github", "workflows"))
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "a" * 40)                      # rev-parse (push 1)
          runner.add(0, "  gitlab/master\n")           # branch -r --contains (push 1)
          runner.add(0, "git@gitlab.com:acme/app.git") # get-url gitlab (push 1)
          runner.add(0, "")                            # get-url origin (push 1, unused)
          runner.add(0, CI_SPEC_SHA)                   # rev-parse (push 2)
          runner.add(0, "  origin/master\n")           # branch -r --contains (push 2)
          runner.add(0, "git@github.com:acme/app.git") # get-url origin (push 2)
          svc = Tools.fake_ci_service(runner)

          svc.try_observe_push("git push gitlab master", dir).should be_true
          svc.try_observe_push("git push origin master", dir).should be_true
          svc.observer_for("a" * 40).not_nil!.provider.gitlab?.should be_true
          svc.observer_for(CI_SPEC_SHA).not_nil!.provider.github?.should be_true
        end
      end

      it "polls the GitLab pipelines API and settles as success (tokenless public project)" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "https://gitlab.com/acme/app.git")
          api_urls = [] of String
          svc = Tools.fake_ci_service(runner)
          svc.api_get = ->(path : String) do
            api_urls << path
            Ci::ApiResponse.new(200, %([{"id":7,"project_id":11,"status":"success"}]))
          end

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.status.success?.should be_true
          api_urls.should contain("/projects/acme%2Fapp/pipelines?sha=#{CI_SPEC_SHA}&per_page=20")
          # GitLab never touches the gh CLI.
          runner.commands.any?(&.starts_with?("gh ")).should be_false
        end
      end

      it "ignores pipelines of other commits (client-side sha match)" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "https://gitlab.com/acme/app.git")
          # The server-side ?sha= filter is not trusted: the payload holds
          # another commit's failed pipeline only — the observer must keep
          # waiting instead of settling with a foreign verdict.
          svc = Tools.fake_ci_service(runner)
          svc.api_get = ->(_path : String) do
            Ci::ApiResponse.new(200, %([{"id":9,"project_id":11,"sha":"#{"a" * 40}","status":"failed"}]))
          end

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.pending?.should be_true
          obs.detail.should contain("no pipelines")
        end
      end

      it "settles from the pipeline whose sha matches the commit" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "https://gitlab.com/acme/app.git")
          svc = Tools.fake_ci_service(runner)
          svc.api_get = ->(_path : String) do
            Ci::ApiResponse.new(200, %([
              {"id":9,"project_id":11,"sha":"#{"a" * 40}","status":"failed"},
              {"id":8,"project_id":11,"sha":"#{CI_SPEC_SHA}","status":"success"}
            ]))
          end

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          # Only the matching row counts: the foreign failed pipeline must
          # not turn the verdict into a failure.
          obs.status.success?.should be_true
          obs.detail.should contain("1 pipeline(s) passed")
          obs.detail.should_not contain("#9")
        end
      end

      it "repoints the wait-line link to the commit's pipeline once it exists" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "https://gitlab.com/acme/app.git")
          svc = Tools.fake_ci_service(runner)
          svc.api_get = ->(_path : String) do
            Ci::ApiResponse.new(200, %([
              {"id":8,"project_id":11,"sha":"#{CI_SPEC_SHA}","status":"running",
               "web_url":"https://gitlab.com/acme/app/-/pipelines/8"}
            ]))
          end

          # Resolve the repo first (populates the per-cwd cache, same as a
          # push does), so observe can link the wait line before the first
          # poll.
          svc.repo_info(dir).not_nil!.provider.gitlab?.should be_true
          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          obs.actions_url.should eq("https://gitlab.com/acme/app/-/commit/#{CI_SPEC_SHA}")
          svc.poll_once(obs, dir)

          obs.pending?.should be_true
          obs.actions_url.should eq("https://gitlab.com/acme/app/-/pipelines/8")
        end
      end

      it "constructs the pipeline link when the row has no web_url" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "https://gitlab.com/acme/app.git")
          svc = Tools.fake_ci_service(runner)
          svc.api_get = ->(_path : String) do
            Ci::ApiResponse.new(200, %([{"id":7,"project_id":11,"sha":"#{CI_SPEC_SHA}","status":"running"}]))
          end

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.pending?.should be_true
          obs.actions_url.should eq("https://gitlab.com/acme/app/-/pipelines/7")
        end
      end

      it "captures the failed job trace on failure" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "git@gitlab.com:acme/app.git")
          svc = Tools.fake_ci_service(runner)
          api_urls = [] of String
          svc.api_get = ->(path : String) do
            api_urls << path
            if path.includes?("/jobs?")
              Ci::ApiResponse.new(200, %([{"id":501,"status":"failed","allow_failure":false},{"id":502,"status":"failed","allow_failure":true}]))
            elsif path.includes?("/trace")
              Ci::ApiResponse.new(200, "expected true, got false\n")
            else
              Ci::ApiResponse.new(200, %([{"id":7,"project_id":11,"status":"failed"}]))
            end
          end

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.status.failure?.should be_true
          obs.detail.should contain("#7 (failed)")
          obs.failure_log.should contain("expected true, got false")
          # allow_failure jobs do not count as the pipeline's failure log.
          api_urls.last.should contain("/jobs/501/trace")
        end
      end

      it "records why the failure log could not be fetched (fine-grained PAT)" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "git@gitlab.com:acme/app.git")
          svc = Tools.fake_ci_service(runner)
          # glab not installed → no CLI fallback for the denied trace.
          svc.glab_probed = true
          svc.glab_available = false
          svc.api_get = ->(path : String) do
            if path.includes?("/jobs?")
              Ci::ApiResponse.new(200, %([{"id":501,"status":"failed","allow_failure":false}]))
            elsif path.includes?("/trace")
              Ci::ApiResponse.new(403, %({"error":"insufficient_granular_scope","error_description":"Access denied: requires a fine-grained personal access token with the following project permissions: [Job: Read]."}))
            else
              Ci::ApiResponse.new(200, %([{"id":7,"project_id":11,"status":"failed"}]))
            end
          end

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.status.failure?.should be_true
          obs.failure_log.empty?.should be_true
          obs.failure_log_error.should contain("HTTP 403")
          obs.failure_log_error.should contain("Job: Read")
          Ci.render_notification(obs).not_nil!.should contain("Could not fetch the CI failure log")
        end
      end

      it "errors immediately on 401 when no token and no glab exist (no endless wait)" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "git@gitlab.com:acme/app.git")
          svc = Tools.fake_ci_service(runner)
          # glab not installed → no CLI fallback.
          svc.glab_probed = true
          svc.glab_available = false
          svc.api_get = ->(_path : String) { Ci::ApiResponse.new(401, "401 Unauthorized") }

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.status.error?.should be_true
          obs.detail.should contain("no GitLab token is configured")
          obs.detail.should contain("glab auth login")
          runner.commands.any?(&.starts_with?("glab")).should be_false
        end
      end

      it "errors immediately on 404 from a private project without a token" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "git@gl.corp.io:h2/app.git")
          svc = Tools.fake_ci_service(runner)
          svc.gitlab_endpoint = "https://gl.corp.io"
          svc.glab_probed = true
          svc.glab_available = false
          # GitLab hides private projects behind 404 for anonymous queries.
          svc.api_get = ->(_path : String) { Ci::ApiResponse.new(404, %({"message":"404 Project Not Found"})) }

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.status.error?.should be_true
          obs.detail.should contain("404")
          obs.detail.should contain("gitlab.token")
          # The wait line is gone on the first poll, not after the
          # failure threshold / MAX_WAIT_S.
          svc.pending?.should be_false
        end
      end

      it "errors immediately when the configured GitLab token is rejected" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "git@gitlab.com:acme/app.git")
          svc = Tools.fake_ci_service(runner)
          svc.gitlab_token = "glpat-bad"
          svc.glab_probed = true
          svc.glab_available = false
          svc.api_get = ->(_path : String) { Ci::ApiResponse.new(403, "403 Forbidden") }

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.status.error?.should be_true
          obs.detail.should contain("token was rejected")
        end
      end

      it "falls back to glab api when anonymous REST access is denied" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "git@gitlab.com:acme/app.git")                    # remote
          runner.add(0, %([{"id":7,"project_id":11,"status":"success"}])) # glab api
          svc = Tools.fake_ci_service(runner)
          svc.glab_probed = true
          svc.glab_available = true
          # Private projects answer 404 to anonymous queries on GitLab.
          svc.api_get = ->(_path : String) { Ci::ApiResponse.new(404, "404 Not Found") }

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.status.success?.should be_true
          glab_calls = runner.commands.select(&.starts_with?("glab api"))
          glab_calls.size.should eq(1)
          glab_calls.first.should contain("--hostname gitlab.com")
          glab_calls.first.should contain("-X GET")
          glab_calls.first.should contain("projects/acme%2Fapp/pipelines?sha=#{CI_SPEC_SHA}")
        end
      end

      it "captures the failed job trace via glab" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "git@gitlab.com:acme/app.git")                   # remote
          runner.add(0, %([{"id":7,"project_id":11,"status":"failed"}])) # pipelines
          runner.add(0, %([{"id":501,"status":"failed","allow_failure":false},
                           {"id":502,"status":"failed","allow_failure":true}])) # jobs
          runner.add(0, "expected true, got false\n")                           # trace
          svc = Tools.fake_ci_service(runner)
          svc.glab_probed = true
          svc.glab_available = true
          svc.api_get = ->(_path : String) { Ci::ApiResponse.new(401, "401 Unauthorized") }

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.status.failure?.should be_true
          obs.failure_log.should contain("expected true, got false")
          # pipelines + jobs + trace, all through glab api.
          runner.commands.count(&.starts_with?("glab api")).should eq(3)
        end
      end

      it "treats glab failures like transient poll failures" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "git@gitlab.com:acme/app.git")
          runner.add(1, "glab: not logged in")
          svc = Tools.fake_ci_service(runner)
          svc.glab_probed = true
          svc.glab_available = true
          svc.api_get = ->(_path : String) { Ci::ApiResponse.new(401, "401 Unauthorized") }

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.pending?.should be_true
          obs.detail.should contain("glab failed")
        end
      end

      it "probes glab once and caches the availability" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, "git@gitlab.com:acme/app.git")                    # remote
          runner.add(0, "glab version 1.50.0")                            # glab --version
          runner.add(0, %([{"id":7,"project_id":11,"status":"success"}])) # glab api (poll 1)
          runner.add(0, %([{"id":7,"project_id":11,"status":"success"}])) # glab api (poll 2)
          svc = Tools.fake_ci_service(runner)
          svc.api_get = ->(_path : String) { Ci::ApiResponse.new(404, "404 Not Found") }

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)
          obs.status.success?.should be_true

          svc.observe("c" * 40, dir)
          obs2 = svc.observer_for("c" * 40).not_nil!
          svc.poll_once(obs2, dir)

          runner.commands.count(&.==("glab --version")).should eq(1)
          runner.commands.count(&.starts_with?("glab api")).should eq(2)
        end
      end
    end

    describe "gh CLI fallback (no token)" do
      it "uses gh run list when no token is configured" do
        with_tmpdir do |dir|
          runner = CiFakeRunner.new
          runner.add(0, %[[{"name":"build","status":"completed","conclusion":"success"}]]) # gh run list
          api_called = false
          svc = Tools.fake_ci_service(runner)
          svc.github_token = ""
          svc.api_get = ->(_path : String) do
            api_called = true
            Ci::ApiResponse.new(200, "{}")
          end

          svc.observe(CI_SPEC_SHA, dir)
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          svc.poll_once(obs, dir)

          obs.status.success?.should be_true
          api_called.should be_false
        end
      end
    end

    describe "ci.json provider bindings" do
      it "detects a bound self-hosted GitLab host without gitlab.endpoint" do
        with_tmpdir do |dir|
          Dir.mkdir_p(File.join(dir, ".github", "workflows"))
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, CI_SPEC_SHA)                   # git rev-parse HEAD
          runner.add(0, "  gitlab/master\n")           # git branch -r --contains
          runner.add(0, "git@gl.corp.io:h2/app.git")   # git remote get-url gitlab
          runner.add(0, "git@github.com:acme/app.git") # git remote get-url origin
          svc = Tools.fake_ci_service(runner)
          svc.bindings.set("gl.corp.io",
            ["git@gl.corp.io:h2/app.git"], Ci::Provider::Gitlab)

          svc.try_observe_push("git push gitlab master", dir).should be_true
          obs = svc.observer_for(CI_SPEC_SHA).not_nil!
          obs.provider.gitlab?.should be_true
          obs.actions_url.should eq("https://gl.corp.io/h2/app/-/commit/#{CI_SPEC_SHA}")
        end
      end

      it "propagates a host binding to other repositories on the host" do
        with_tmpdir do |dir|
          File.write(File.join(dir, ".gitlab-ci.yml"), "")
          runner = CiFakeRunner.new
          runner.add(0, CI_SPEC_SHA)                     # git rev-parse HEAD
          runner.add(0, "")                              # branch -r --contains: origin fallback
          runner.add(0, "https://gl.corp.io/other/proj") # git remote get-url origin
          svc = Tools.fake_ci_service(runner)
          # Bound via a different repository's URL; only the host matches.
          svc.bindings.set("gl.corp.io", ["git@gl.corp.io:h2/app.git"], Ci::Provider::Gitlab)

          svc.try_observe_push("git push", dir).should be_true
          svc.observer_for(CI_SPEC_SHA).not_nil!.provider.gitlab?.should be_true
        end
      end
    end
  end

  describe Ci::Bindings do
    it "binds a host and propagates to every URL on it" do
      with_tmpdir do |_dir|
        b = Ci::Bindings.new
        b.set("gl.corp.io", ["git@gl.corp.io:h2/app.git"], Ci::Provider::Gitlab)
        b.provider_for_url("git@gl.corp.io:h2/app.git").try(&.gitlab?).should be_true
        # Another repository on the same host — detected via the hosts entry.
        b.provider_for_url("https://gl.corp.io/other/proj.git").try(&.gitlab?).should be_true
        b.provider_for_host("GL.CORP.IO").try(&.gitlab?).should be_true
        b.gitlab_hosts.should contain("gl.corp.io")
        b.provider_for_url("git@github.com:acme/app.git").should be_nil
      end
    end

    it "persists to ci.json and reloads" do
      with_tmpdir do |dir|
        path = File.join(dir, "ci.json")
        Ci::Bindings.new(path).set("gl.corp.io",
          ["git@gl.corp.io:h2/app.git"], Ci::Provider::Gitlab)
        File.exists?(path).should be_true
        reloaded = Ci::Bindings.new(path)
        reloaded.provider_for_url("git@gl.corp.io:h2/app.git").try(&.gitlab?).should be_true
        reloaded.provider_for_host("gl.corp.io").try(&.gitlab?).should be_true
      end
    end

    it "treats a broken file as no bindings" do
      with_tmpdir do |dir|
        path = File.join(dir, "ci.json")
        File.write(path, "{not json")
        Ci::Bindings.new(path).provider_for_host("gl.corp.io").should be_nil
      end
    end
  end

  describe ".token_warning_tip" do
    it "shows the GitLab token tip for a GitLab repo without a token" do
      with_tmpdir do |dir|
        File.write(File.join(dir, ".gitlab-ci.yml"), "")
        runner = CiFakeRunner.new
        runner.add(0, CI_SPEC_SHA)                       # rev-parse HEAD
        runner.add(0, "")                                # branch -r --contains
        runner.add(0, "https://gitlab.com/acme/app.git") # get-url origin
        svc = Tools.fake_ci_service(runner)

        Ci.token_warning_tip(svc, "", "", dir)
          .should eq(H2code.t("ui.ci_token_tip_gitlab"))
      end
    end

    it "shows no GitLab tip once the token is configured" do
      with_tmpdir do |dir|
        File.write(File.join(dir, ".gitlab-ci.yml"), "")
        runner = CiFakeRunner.new
        runner.add(0, CI_SPEC_SHA)
        runner.add(0, "")
        runner.add(0, "https://gitlab.com/acme/app.git")
        svc = Tools.fake_ci_service(runner)

        Ci.token_warning_tip(svc, "", "glpat-x", dir).should be_nil
      end
    end

    it "follows the commit, not origin: HEAD on the gitlab remote → GitLab tip" do
      with_tmpdir do |dir|
        # Both CI configs; origin is GitHub, the HEAD commit sits on the
        # gitlab remote only — the GitLab tip must win over the GitHub one.
        Dir.mkdir_p(File.join(dir, ".github", "workflows"))
        File.write(File.join(dir, ".gitlab-ci.yml"), "")
        runner = CiFakeRunner.new
        runner.add(0, CI_SPEC_SHA)                   # rev-parse HEAD
        runner.add(0, "  gitlab/master\n")           # branch -r --contains
        runner.add(0, "git@gl.corp.io:h2/app.git")   # get-url gitlab
        runner.add(0, "git@github.com:acme/app.git") # get-url origin
        svc = Tools.fake_ci_service(runner)
        svc.bindings.set("gl.corp.io", ["git@gl.corp.io:h2/app.git"], Ci::Provider::Gitlab)

        Ci.token_warning_tip(svc, "", "", dir)
          .should eq(H2code.t("ui.ci_token_tip_gitlab"))
      end
    end

    it "shows the GitHub tip for a GitHub repo without a token" do
      with_tmpdir do |dir|
        Dir.mkdir_p(File.join(dir, ".github", "workflows"))
        runner = CiFakeRunner.new
        runner.add(0, CI_SPEC_SHA)
        runner.add(0, "")
        runner.add(0, "git@github.com:acme/app.git")
        svc = Tools.fake_ci_service(runner)

        Ci.token_warning_tip(svc, "", "", dir)
          .should eq(H2code.t("ui.ci_token_tip"))
        Ci.token_warning_tip(svc, "ghp_x", "", dir).should be_nil
      end
    end

    it "shows nothing for a CI-ineligible repo" do
      with_tmpdir do |dir|
        runner = CiFakeRunner.new
        runner.add(0, CI_SPEC_SHA)
        svc = Tools.fake_ci_service(runner)

        Ci.token_warning_tip(svc, "", "", dir).should be_nil
      end
    end
  end
end
