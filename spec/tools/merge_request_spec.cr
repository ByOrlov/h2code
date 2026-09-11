require "../spec_helper"
require "../../src/tools/merge_request"

module H2code::Tools
  # Saves/restores the class-level wiring every test mutates.
  module MergeRequestSpecHelpers
    def self.with_store(store : Session::Store?, &)
      old_store = MergeRequest.store
      old_created = MergeRequest.on_created
      MergeRequest.store = store
      begin
        yield
      ensure
        MergeRequest.store = old_store
        MergeRequest.on_created = old_created
      end
    end

    def self.with_ci_service(svc : Ci::CiService?, &)
      old = Ci.service
      Ci.service = svc
      begin
        yield
      ensure
        Ci.service = old
      end
    end
  end

  describe MergeRequest do
    it "errors when no session store is wired" do
      MergeRequestSpecHelpers.with_store(nil) do
        tool = MergeRequest.new
        result = tool.execute(JSON.parse(%({"title": "Add feature"})))
        result.is_error?.should be_true
        result.content.should contain("not available")
      end
    end

    it "refuses a second merge request in the same session" do
      with_tmpdir do |dir|
        store = Session::Store.new(File.join(dir, "session"))
        meta = Session::StateMeta.new("s1")
        meta.merge_request_url = "https://gitlab.com/acme/app/-/merge_requests/1"
        store.write_state(meta)

        MergeRequestSpecHelpers.with_store(store) do
          tool = MergeRequest.new(dir)
          result = tool.execute(JSON.parse(%({"title": "Another one"})))
          result.is_error?.should be_true
          result.content.should contain("already has a merge request")
          result.content.should contain("merge_requests/1")
        end
      end
    end

    it "requires a title" do
      with_tmpdir do |dir|
        store = Session::Store.new(File.join(dir, "session"))
        MergeRequestSpecHelpers.with_store(store) do
          tool = MergeRequest.new(dir)
          result = tool.execute(JSON.parse(%({})))
          result.is_error?.should be_true
          result.content.should contain("title is required")
        end
      end
    end

    it "requires the branch to be pushed to origin first" do
      with_tmpdir do |dir|
        store = Session::Store.new(File.join(dir, "session"))
        responses = {
          "git remote get-url origin"       => "git@gitlab.com:acme/app.git",
          "git rev-parse --abbrev-ref HEAD" => "feature/x",
          "git ls-remote origin feature/x"  => "",
        }
        MergeRequestSpecHelpers.with_store(store) do
          tool = MergeRequest.new(dir)
          tool.runner = ->(cmd : String, _cwd : String) { Ci::CommandResult.new(0, responses[cmd]? || "") }

          result = tool.execute(JSON.parse(%({"title": "Add feature"})))
          result.is_error?.should be_true
          result.content.should contain("git push")
        end
      end
    end

    it "requires a GitLab token" do
      with_tmpdir do |dir|
        store = Session::Store.new(File.join(dir, "session"))
        responses = {
          "git remote get-url origin"       => "git@gitlab.com:acme/app.git",
          "git rev-parse --abbrev-ref HEAD" => "feature/x",
          "git ls-remote origin feature/x"  => "abc\trefs/heads/feature/x",
        }
        MergeRequestSpecHelpers.with_store(store) do
          MergeRequestSpecHelpers.with_ci_service(Ci::LiveCiService.new) do
            tool = MergeRequest.new(dir)
            tool.runner = ->(cmd : String, _cwd : String) { Ci::CommandResult.new(0, responses[cmd]? || "") }

            result = tool.execute(JSON.parse(%({"title": "Add feature"})))
            result.is_error?.should be_true
            result.content.should contain("gitlab.token")
          end
        end
      end
    end

    it "creates a GitLab MR, persists the URL and fires on_created" do
      with_tmpdir do |dir|
        store = Session::Store.new(File.join(dir, "session"))
        store.write_state(Session::StateMeta.new("s1").tap { |m| m.cwd = dir })
        responses = {
          "git remote get-url origin"       => "git@gitlab.com:acme/app.git",
          "git rev-parse --abbrev-ref HEAD" => "feature/x",
          "git ls-remote origin feature/x"  => "abc\trefs/heads/feature/x",
        }
        mr_url = "https://gitlab.com/acme/app/-/merge_requests/7"
        api = ->(method : String, url : String, body : String?) do
          case {method, url}
          when {"GET", "https://gitlab.com/api/v4/projects/acme%2Fapp"}
            Ci::ApiResponse.new(200, %({"default_branch": "master"}))
          when {"POST", "https://gitlab.com/api/v4/projects/acme%2Fapp/merge_requests"}
            payload = body.not_nil!
            payload.should contain("feature/x")
            payload.should contain("Add feature")
            Ci::ApiResponse.new(201, %({"web_url": "#{mr_url}"}))
          else
            Ci::ApiResponse.new(404, "unexpected #{method} #{url}")
          end
        end
        created = [] of String

        MergeRequestSpecHelpers.with_store(store) do
          MergeRequest.on_created = ->(url : String) { created << url; nil }
          MergeRequestSpecHelpers.with_ci_service(Ci::LiveCiService.new(gitlab_token: "tok")) do
            tool = MergeRequest.new(dir)
            tool.runner = ->(cmd : String, _cwd : String) { Ci::CommandResult.new(0, responses[cmd]? || "") }
            tool.api = api

            result = tool.execute(JSON.parse(%({"title": "Add feature", "description": "Details"})))
            result.is_error?.should be_false
            result.content.should contain(mr_url)

            # Persisted in state.json under merge_request_url.
            store.read_state.not_nil!.merge_request_url.should eq(mr_url)
            store.read_state.not_nil!.id.should eq("s1")
            # The wire log records the link event.
            File.read(store.wire_path).should contain("session.merge_request")
            File.read(store.wire_path).should contain(mr_url)
            # The TUI bottom-panel callback fired.
            created.should eq([mr_url])
          end
        end
      end
    end

    it "creates a GitHub PR against the default branch" do
      with_tmpdir do |dir|
        store = Session::Store.new(File.join(dir, "session"))
        responses = {
          "git remote get-url origin"       => "git@github.com:acme/app.git",
          "git rev-parse --abbrev-ref HEAD" => "feature/y",
          "git ls-remote origin feature/y"  => "abc\trefs/heads/feature/y",
        }
        pr_url = "https://github.com/acme/app/pull/9"
        api = ->(method : String, url : String, body : String?) do
          case {method, url}
          when {"GET", "https://api.github.com/repos/acme/app"}
            Ci::ApiResponse.new(200, %({"default_branch": "main"}))
          when {"POST", "https://api.github.com/repos/acme/app/pulls"}
            payload = body.not_nil!
            payload.should contain(%("base":"main"))
            payload.should contain(%("head":"feature/y"))
            Ci::ApiResponse.new(201, %({"html_url": "#{pr_url}"}))
          else
            Ci::ApiResponse.new(404, "unexpected #{method} #{url}")
          end
        end

        MergeRequestSpecHelpers.with_store(store) do
          MergeRequestSpecHelpers.with_ci_service(Ci::LiveCiService.new(github_token: "tok")) do
            tool = MergeRequest.new(dir)
            tool.runner = ->(cmd : String, _cwd : String) { Ci::CommandResult.new(0, responses[cmd]? || "") }
            tool.api = api

            result = tool.execute(JSON.parse(%({"title": "Add feature"})))
            result.is_error?.should be_false
            result.content.should contain(pr_url)
            store.read_state.not_nil!.merge_request_url.should eq(pr_url)
          end
        end
      end
    end
  end
end
