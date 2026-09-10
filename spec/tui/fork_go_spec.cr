require "../spec_helper"
require "file_utils"
require "../../src/tui/app"
require "../../src/worktree"

# Spec-only wrapper exposing the private /fork handler.
class ForkGoApp < H2code::TUI::App
  def run_fork(args : String) : Nil
    cmd_fork(args)
  end

  def last_message : H2code::TUI::Message
    @messages.last
  end
end

private def git_run(dir : String, *args : String)
  Process.run("git", ["-C", dir] + args.to_a,
    output: IO::Memory.new, error: IO::Memory.new)
end

describe "/fork go" do
  it "switches to an existing sandbox by id, branch or list index" do
    next pending! "git unavailable" unless Process.run("git", ["--version"],
                                             output: IO::Memory.new, error: IO::Memory.new).success?

    repo = File.join(Dir.tempdir, "h2code-fork-go-#{Random::Secure.hex(6)}")
    home = File.join(Dir.tempdir, "h2code-fork-go-home-#{Random::Secure.hex(6)}")
    Dir.mkdir_p(repo)
    Dir.mkdir_p(home)

    git_run(repo, "init", "-b", "main")
    File.write(File.join(repo, "a.txt"), "one\n")
    git_run(repo, "add", "-A")
    git_run(repo, "-c", "user.email=spec@example.com",
      "-c", "user.name=Spec", "commit", "-m", "init")

    begin
      result = H2code::Worktree.create(repo, "go01", home)
      result.success?.should be_true
      sandbox = result.path.not_nil!

      app = ForkGoApp.new
      app.home = home
      received = nil
      app.on_fork_go = ->(path : String) { received = path; nil }

      # By bare session id.
      app.run_fork("go go01")
      received.should eq(sandbox)
      app.last_message.role.should eq("system")
      app.last_message.content.should contain("h2code-go01")

      # By full branch name.
      received = nil
      app.run_fork("go h2code-go01")
      received.should eq(sandbox)

      # By 1-based list index.
      received = nil
      app.run_fork("go 1")
      received.should eq(sandbox)

      # Unknown id: error, callback not invoked.
      received = nil
      app.run_fork("go nosuch")
      received.should be_nil
      app.last_message.role.should eq("error")

      # Missing id: usage error.
      app.run_fork("go")
      app.last_message.role.should eq("error")

      # Out-of-range index: error.
      app.run_fork("go 9")
      app.last_message.role.should eq("error")
    ensure
      FileUtils.rm_r(repo) if File.exists?(repo)
      FileUtils.rm_r(home) if File.exists?(home)
    end
  end
end
