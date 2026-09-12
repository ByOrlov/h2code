require "../spec_helper"
require "file_utils"
require "../../src/tui/app"

# Private handlers are reachable from a subclass — this spec-only wrapper
# drives /ci the same way the slash dispatcher does.
class CiCommandApp < H2code::TUI::App
  def run_cmd_ci(args : String)
    cmd_ci(args)
  end
end

# Eligible GitHub repo in `dir` (workflows dir + github.com remote) with one
# commit; returns its full HEAD sha.
def init_ci_repo(dir : String) : String
  FileUtils.mkdir_p(File.join(dir, ".github", "workflows"))
  H2code::Tools::Ci.run_shell("git init -q", dir)
  H2code::Tools::Ci.run_shell(
    "git -c user.email=spec@example.com -c user.name=spec commit -q --allow-empty -m init", dir)
  H2code::Tools::Ci.run_shell("git remote add origin https://github.com/example/repo.git", dir)
  H2code::Tools::Ci.run_shell("git rev-parse HEAD", dir).output.strip
end

describe "/ci command" do
  it "errors when no CI service is wired" do
    old = H2code::Tools::Ci.service
    H2code::Tools::Ci.service = nil
    begin
      app = CiCommandApp.new
      app.run_cmd_ci("abc1234")
      app.@messages.last.role.should eq("error")
      app.@messages.last.content.should contain("not available")
    ensure
      H2code::Tools::Ci.service = old
    end
  end

  it "errors when the repository is not eligible for CI observation" do
    old = H2code::Tools::Ci.service
    with_tmpdir do |dir|
      svc = H2code::Tools::Ci::LiveCiService.new
      svc.autostart = false
      H2code::Tools::Ci.service = svc
      begin
        app = CiCommandApp.new
        app.work_dir = dir
        app.run_cmd_ci("")
        app.@messages.last.role.should eq("error")
        app.@messages.last.content.should contain("not eligible")
        svc.pending?.should be_false
      ensure
        H2code::Tools::Ci.service = old
      end
    end
  end

  it "observes HEAD when no commit is given" do
    old = H2code::Tools::Ci.service
    with_tmpdir do |dir|
      head = init_ci_repo(dir)
      svc = H2code::Tools::Ci::LiveCiService.new
      svc.autostart = false
      H2code::Tools::Ci.service = svc
      begin
        app = CiCommandApp.new
        app.work_dir = dir
        app.run_cmd_ci("")
        app.@messages.last.role.should eq("system")
        app.@messages.last.content.should contain(head[0, 7])
        svc.observer_for(head).should_not be_nil
      ensure
        H2code::Tools::Ci.service = old
      end
    end
  end

  it "resolves a short sha argument to the full commit" do
    old = H2code::Tools::Ci.service
    with_tmpdir do |dir|
      head = init_ci_repo(dir)
      svc = H2code::Tools::Ci::LiveCiService.new
      svc.autostart = false
      H2code::Tools::Ci.service = svc
      begin
        app = CiCommandApp.new
        app.work_dir = dir
        app.run_cmd_ci(head[0, 7])
        app.@messages.last.role.should eq("system")
        app.@messages.last.content.should contain("Watching CI")
        svc.observer_for(head).should_not be_nil
      ensure
        H2code::Tools::Ci.service = old
      end
    end
  end

  it "resolves a branch name argument" do
    old = H2code::Tools::Ci.service
    with_tmpdir do |dir|
      head = init_ci_repo(dir)
      branch = H2code::Tools::Ci.run_shell(
        "git rev-parse --abbrev-ref HEAD", dir).output.strip
      svc = H2code::Tools::Ci::LiveCiService.new
      svc.autostart = false
      H2code::Tools::Ci.service = svc
      begin
        app = CiCommandApp.new
        app.work_dir = dir
        app.run_cmd_ci(branch)
        app.@messages.last.role.should eq("system")
        svc.observer_for(head).should_not be_nil
      ensure
        H2code::Tools::Ci.service = old
      end
    end
  end

  it "repeated /ci for the same commit does not duplicate observers" do
    old = H2code::Tools::Ci.service
    with_tmpdir do |dir|
      head = init_ci_repo(dir)
      svc = H2code::Tools::Ci::LiveCiService.new
      svc.autostart = false
      H2code::Tools::Ci.service = svc
      begin
        app = CiCommandApp.new
        app.work_dir = dir
        20.times { app.run_cmd_ci("") }
        # One pending observer for the HEAD sha, not twenty: observe()
        # reuses the existing pending observer for the same sha.
        svc.pending_observers.size.should eq(1)
        svc.observer_for(head).should_not be_nil
      ensure
        H2code::Tools::Ci.service = old
      end
    end
  end

  it "errors on a revision that does not resolve" do
    old = H2code::Tools::Ci.service
    with_tmpdir do |dir|
      init_ci_repo(dir)
      svc = H2code::Tools::Ci::LiveCiService.new
      svc.autostart = false
      H2code::Tools::Ci.service = svc
      begin
        app = CiCommandApp.new
        app.work_dir = dir
        app.run_cmd_ci("no-such-thing")
        app.@messages.last.role.should eq("error")
        app.@messages.last.content.should contain("no-such-thing")
        svc.pending?.should be_false
      ensure
        H2code::Tools::Ci.service = old
      end
    end
  end

  it "/ci type gitlab binds the non-github host and detection follows" do
    old = H2code::Tools::Ci.service
    with_tmpdir do |dir|
      head = init_ci_repo(dir)
      H2code::Tools::Ci.run_shell("git remote add gitlab https://gl.corp.io/h2/app.git", dir)
      File.write(File.join(dir, ".gitlab-ci.yml"), "")
      bindings_path = File.join(dir, "ci.json")
      svc = H2code::Tools::Ci::LiveCiService.new
      svc.autostart = false
      svc.bindings = H2code::Tools::Ci::Bindings.new(bindings_path)
      H2code::Tools::Ci.service = svc
      begin
        app = CiCommandApp.new
        app.work_dir = dir
        app.run_cmd_ci("type gitlab")
        app.@messages.last.role.should eq("system")
        app.@messages.last.content.should contain("gl.corp.io")
        File.exists?(bindings_path).should be_true

        # The binding drives detection: a push recorded on the gitlab
        # remote is observed as GitLab, not GitHub — no endpoint config.
        H2code::Tools::Ci.run_shell("git update-ref refs/remotes/gitlab/master #{head}", dir)
        svc.try_observe_push("git push gitlab master", dir).should be_true
        svc.observer_for(head).not_nil!.provider.gitlab?.should be_true
      ensure
        H2code::Tools::Ci.service = old
      end
    end
  end

  it "/ci check is an explicit alias of /ci (observes HEAD)" do
    old = H2code::Tools::Ci.service
    with_tmpdir do |dir|
      head = init_ci_repo(dir)
      svc = H2code::Tools::Ci::LiveCiService.new
      svc.autostart = false
      H2code::Tools::Ci.service = svc
      begin
        app = CiCommandApp.new
        app.work_dir = dir
        app.run_cmd_ci("check")
        app.@messages.last.role.should eq("system")
        app.@messages.last.content.should contain("Watching CI")
        svc.observer_for(head).should_not be_nil

        # check also accepts an explicit commit, like /ci <commit>.
        app.run_cmd_ci("check #{head[0, 7]}")
        svc.pending_observers.size.should eq(1)
      ensure
        H2code::Tools::Ci.service = old
      end
    end
  end

  it "/ci type lists the effective binding per remote" do
    old = H2code::Tools::Ci.service
    with_tmpdir do |dir|
      init_ci_repo(dir)
      H2code::Tools::Ci.run_shell("git remote add gitlab https://gl.corp.io/h2/app.git", dir)
      svc = H2code::Tools::Ci::LiveCiService.new
      svc.autostart = false
      H2code::Tools::Ci.service = svc
      begin
        app = CiCommandApp.new
        app.work_dir = dir
        app.run_cmd_ci("type")
        app.@messages.last.role.should eq("system")
        content = app.@messages.last.content
        content.should contain("github.com")
        content.should contain("gl.corp.io")
        content.should contain("auto")
        # The allowed types are spelled out.
        content.should contain("'gitlab'")
        content.should contain("'github'")
      ensure
        H2code::Tools::Ci.service = old
      end
    end
  end

  it "/ci type gitlab asks for the host when several remotes qualify" do
    old = H2code::Tools::Ci.service
    with_tmpdir do |dir|
      init_ci_repo(dir)
      H2code::Tools::Ci.run_shell("git remote add one https://gl1.corp.io/h2/app.git", dir)
      H2code::Tools::Ci.run_shell("git remote add two https://gl2.corp.io/h2/app.git", dir)
      svc = H2code::Tools::Ci::LiveCiService.new
      svc.autostart = false
      H2code::Tools::Ci.service = svc
      begin
        app = CiCommandApp.new
        app.work_dir = dir
        app.run_cmd_ci("type gitlab")
        app.@messages.last.role.should eq("error")
        app.@messages.last.content.should contain("gl1.corp.io")
        app.@messages.last.content.should contain("gl2.corp.io")
        svc.bindings.provider_for_host("gl1.corp.io").should be_nil

        # The explicit host binds only that one.
        app.run_cmd_ci("type gitlab gl2.corp.io")
        app.@messages.last.role.should eq("system")
        svc.bindings.provider_for_host("gl2.corp.io").try(&.gitlab?).should be_true
        svc.bindings.provider_for_url("https://gl2.corp.io/h2/app.git").try(&.gitlab?).should be_true
        svc.bindings.provider_for_host("gl1.corp.io").should be_nil
      ensure
        H2code::Tools::Ci.service = old
      end
    end
  end

  describe "#on_ci_update" do
    it "keeps the checks-page link on the settled line when CI goes green" do
      H2code::I18n.init("en")
      app = CiCommandApp.new
      obs = H2code::Tools::Ci::Observer.new("1234567890abcdef")
      obs.status = H2code::Tools::Ci::Status::Success
      obs.detail = "1 run(s) passed"
      obs.actions_url = "https://github.com/example/repo/actions/runs/1"

      app.on_ci_update(obs)

      msg = app.@messages.last
      msg.role.should eq("ci_success")
      msg.content.should contain("CI build passed for 1234567")
      msg.content.should contain("link: https://github.com/example/repo/actions/runs/1")
    end

    it "omits the link when the owner/repo pair was never known" do
      H2code::I18n.init("en")
      app = CiCommandApp.new
      obs = H2code::Tools::Ci::Observer.new("1234567890abcdef")
      obs.status = H2code::Tools::Ci::Status::Success
      obs.detail = "1 run(s) passed"

      app.on_ci_update(obs)

      msg = app.@messages.last
      msg.content.should contain("CI build passed for 1234567")
      msg.content.should_not contain("link:")
    end
  end
end
