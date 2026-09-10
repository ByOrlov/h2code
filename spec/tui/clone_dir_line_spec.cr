require "../spec_helper"
require "file_utils"
require "../../src/tui/terminal"
require "../../src/tui/terminal_mock"
require "../../src/tui/app"
require "../../src/worktree"

# Spec-only wrapper exposing the private clone-dir notice renderer.
class CloneDirApp < H2code::TUI::App
  def clone_line(cols = 80) : Array(String)
    render_clone_dir_line(cols)
  end
end

private def git_run(dir : String, *args : String)
  Process.run("git", ["-C", dir] + args.to_a,
    output: IO::Memory.new, error: IO::Memory.new)
end

describe "clone dir notice" do
  it "shows Clone: <folder> under the input when cwd is a fork sandbox" do
    next pending! "git unavailable" unless Process.run("git", ["--version"],
                                             output: IO::Memory.new, error: IO::Memory.new).success?

    repo = File.join(Dir.tempdir, "h2code-clone-line-#{Random::Secure.hex(6)}")
    home = File.join(Dir.tempdir, "h2code-clone-line-home-#{Random::Secure.hex(6)}")
    Dir.mkdir_p(repo)
    Dir.mkdir_p(home)

    git_run(repo, "init", "-b", "main")
    File.write(File.join(repo, "a.txt"), "one\n")
    git_run(repo, "add", "-A")
    git_run(repo, "-c", "user.email=spec@example.com",
      "-c", "user.name=Spec", "commit", "-m", "init")

    begin
      sandbox = H2code::Worktree.create(repo, "line01", home).path.not_nil!
      app = CloneDirApp.new
      app.home = home
      app.work_dir = sandbox
      lines = app.clone_line
      lines.size.should eq(1)
      stripped = lines.first.gsub(/\e\[[0-9;]*m/, "")
      # Long temp paths are truncated to the terminal width; the label and
      # the head of the path must survive.
      stripped.should start_with("Clone: ")
      stripped.should contain(sandbox[0, 30])
      # Bold + theme warning colour: the line must stand out as a
      # "not on the main checkout" signal.
      ansi = H2code::TUI::ANSI
      raw = lines.first
      raw.should contain(ansi.bold)
      raw.should contain(ansi.color(app.@theme.colors.warning, nil))

      # Outside a sandbox (the original repo, a random dir) — no notice.
      app.work_dir = repo
      app.clone_line.should be_empty
      app.work_dir = home
      app.clone_line.should be_empty
    ensure
      FileUtils.rm_r(repo) if File.exists?(repo)
      FileUtils.rm_r(home) if File.exists?(home)
    end
  end
end
