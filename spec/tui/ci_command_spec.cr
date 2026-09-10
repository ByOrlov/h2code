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
end
