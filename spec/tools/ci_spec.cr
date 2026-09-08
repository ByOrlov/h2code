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

    describe "poll_interval" do
      it "grows quadratically then caps" do
        Ci.poll_interval(0).should eq(5)
        Ci.poll_interval(1).should eq(20)
        Ci.poll_interval(2).should eq(45)
        Ci.poll_interval(3).should eq(60)
        Ci.poll_interval(50).should eq(60)
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
        Ci.parse_github_remote("git@github.com:acme/app.git").should eq({"acme", "app"})
        Ci.parse_github_remote("https://github.com/acme/app.git").should eq({"acme", "app"})
        Ci.parse_github_remote("https://user:tok@github.com/acme/app").should eq({"acme", "app"})
      end

      it "rejects non-github remotes" do
        Ci.parse_github_remote("git@gitlab.com:acme/app.git").should be_nil
        Ci.parse_github_remote("https://example.com/acme/app.git").should be_nil
        Ci.parse_github_remote("").should be_nil
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

    describe "render_notification" do
      it "returns nil for success (log-only)" do
        obs = Ci::Observer.new("a" * 40)
        obs.status = Ci::Status::Success
        obs.detail = "1 run(s) passed"
        Ci.render_notification(obs).should be_nil
      end

      it "builds a fix-it notification for failure" do
        obs = Ci::Observer.new("a" * 40)
        obs.status = Ci::Status::Failure
        obs.detail = "spec (failure)"
        obs.failure_log = "expected true, got false"
        xml = Ci.render_notification(obs).not_nil!
        xml.should contain("ci_completion")
        xml.should contain("CI build failed")
        xml.should contain("expected true, got false")
        xml.should contain("commit and push again")
      end
    end
  end

  describe Ci::LiveCiService do
    it "try_observe_push starts an observer for an eligible repo" do
      with_tmpdir do |dir|
        Dir.mkdir_p(File.join(dir, ".github", "workflows"))
        runner = CiFakeRunner.new
        runner.add(0, "git@github.com:acme/app.git") # git remote get-url origin
        runner.add(0, CI_SPEC_SHA)                   # git rev-parse HEAD
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
        runner.add(0, "git@github.com:acme/target.git") # remote in target/
        runner.add(0, CI_SPEC_SHA)                      # HEAD in target/
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
          api_urls.should contain("/repos/acme/app/actions/runs?head_sha=#{CI_SPEC_SHA}&per_page=20")
          # No gh CLI invocation on the API path.
          runner.commands.any?(&.starts_with?("gh ")).should be_false
        end
      end

      it "fetches the failure log zip via the 302 redirect" do
        with_tmpdir do |dir|
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
  end
end
