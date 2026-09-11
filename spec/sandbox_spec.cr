require "./spec_helper"

{% if flag?(:win32) %}
  SB_GIT_AVAILABLE = false
{% else %}
  SB_GIT_AVAILABLE = Process.run("git", ["--version"],
    output: IO::Memory.new, error: IO::Memory.new).success?
{% end %}

# Creates a temp git repo (branch "main", one commit) plus a `/fork`
# sandbox clone of it under a temp worktree home. ENV["HOME"] is pointed
# at the temp home for the block's duration so the Sandbox module (which
# resolves the worktree root through HomePort) sees the same layout the
# real app would. Skips when git is unavailable.
private def with_sandbox(&)
  unless SB_GIT_AVAILABLE
    pending! "git unavailable"
    return
  end
  repo = File.join(Dir.tempdir, "h2code-sb-repo-#{Random::Secure.hex(6)}")
  home = File.join(Dir.tempdir, "h2code-sb-home-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(repo)
  Dir.mkdir_p(home)
  sb_git(repo, "init", "-b", "main")
  sb_git(repo, "config", "user.email", "spec@example.com")
  sb_git(repo, "config", "user.name", "Spec")
  File.write(File.join(repo, "a.txt"), "one\n")
  sb_git(repo, "add", "-A")
  sb_git(repo, "commit", "-m", "init")
  sandbox = H2code::Worktree.create(repo, "sbsess", home).path.not_nil!
  old_home = ENV["HOME"]?
  ENV["HOME"] = home
  H2code::Sandbox.reset
  begin
    yield repo, home, sandbox
  ensure
    ENV["HOME"] = old_home if old_home
    H2code::Sandbox.reset
    FileUtils.rm_r(repo) if File.exists?(repo)
    FileUtils.rm_r(home) if File.exists?(home)
  end
end

private def sb_git(dir : String, *args : String) : String
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  code = Process.run("git", ["-C", dir] + args.to_a,
    output: out_io, error: err_io).exit_code
  raise "git #{args.first} failed: #{err_io}" unless code == 0
  out_io.to_s.strip
end

module H2code
  describe Sandbox do
    describe "command_references?" do
      it "matches exact paths, subpaths and quoted forms" do
        Sandbox.command_references?("cat /home/oleg/p1/f.txt", "/home/oleg/p1").should be_true
        Sandbox.command_references?("cat /home/oleg/p1", "/home/oleg/p1").should be_true
        Sandbox.command_references?(%(cd "/home/oleg/p1" && ls), "/home/oleg/p1").should be_true
        Sandbox.command_references?("git -C /home/oleg/p1 status", "/home/oleg/p1").should be_true
      end

      it "does not match sibling paths sharing the prefix" do
        Sandbox.command_references?("ls /home/oleg/p1x", "/home/oleg/p1").should be_false
        Sandbox.command_references?("ls /home/oleg/p1-two", "/home/oleg/p1").should be_false
        Sandbox.command_references?("ls /home/oleg", "/home/oleg/p1").should be_false
      end

      it "ignores occurrences inside the sandbox's own path" do
        # The encoded project path mirrors the original repo's segments,
        # so the sandbox path literally contains the repo path inside it.
        sandbox = "/home/oleg/.h2code/worktree/home/oleg/p1/h2code-s1"
        Sandbox.command_references?("git -C #{sandbox} status",
          "/home/oleg/p1", sandbox: sandbox).should be_false
        # ...but a genuine reference next to it still matches.
        Sandbox.command_references?("git -C #{sandbox} fetch /home/oleg/p1",
          "/home/oleg/p1", sandbox: sandbox).should be_true
      end
    end

    describe "main_repo_for" do
      it "resolves the sandbox origin, nil outside sandboxes" do
        with_sandbox do |repo, home, sandbox|
          Sandbox.main_repo_for(sandbox, home).should eq(File.expand_path(repo))
          Sandbox.main_repo_for(repo, home).should be_nil
          Sandbox.main_repo_for(Dir.tempdir, home).should be_nil
        end
      end
    end

    describe "file tools" do
      it "blocks Write into the original repository" do
        with_sandbox do |repo, _home, sandbox|
          target = File.join(repo, "escaped.txt")
          tool = Tools::Write.new(sandbox)
          result = tool.execute(JSON.parse(%({"path": #{target.inspect}, "content": "x"})))
          result.is_error?.should be_true
          result.content.should contain("fork sandbox")
          File.exists?(target).should be_false
        end
      end

      it "blocks Edit and ApplyPatch through PathAccess" do
        with_sandbox do |repo, _home, sandbox|
          target = File.join(repo, "a.txt")
          expect_raises(Tools::PathAccess::AccessError, "fork sandbox") do
            Tools::PathAccess.resolve(target, sandbox, Tools::PathAccess::Mode::Write)
          end

          edit = Tools::Edit.new(sandbox)
          result = edit.execute(JSON.parse(%({"path": #{target.inspect}, "old_string": "one", "new_string": "two"})))
          result.is_error?.should be_true
          File.read(target).should eq("one\n")

          patch = Tools::ApplyPatchTool.new(sandbox)
          result = patch.execute(JSON.parse(%({"input": "*** Begin Patch\\n*** Update File: #{target}\\n@@\\n-one\\n+two\\n*** End Patch"})))
          result.is_error?.should be_true
          File.read(target).should eq("one\n")
        end
      end

      it "allows writes inside the sandbox and reads of the original repo" do
        with_sandbox do |repo, _home, sandbox|
          inside = File.join(sandbox, "new.txt")
          Tools::Write.new(sandbox)
            .execute(JSON.parse(%({"path": #{inside.inspect}, "content": "x"})))
            .is_error?.should be_false
          File.exists?(inside).should be_true

          Tools::PathAccess.resolve(File.join(repo, "a.txt"), sandbox,
            Tools::PathAccess::Mode::Read).should eq(File.join(repo, "a.txt"))
        end
      end

      it "blocks symlink tunnels into the original repository" do
        with_sandbox do |repo, _home, sandbox|
          link = File.join(sandbox, "tunnel")
          File.symlink(repo, link)
          expect_raises(Tools::PathAccess::AccessError, "fork sandbox") do
            Tools::PathAccess.resolve(File.join(link, "via-link.txt"),
              sandbox, Tools::PathAccess::Mode::Write)
          end
        end
      end

      it "lifts the block during a merge turn" do
        with_sandbox do |repo, _home, sandbox|
          Sandbox.merge_active = true
          begin
            Tools::PathAccess.resolve(File.join(repo, "merged.txt"),
              sandbox, Tools::PathAccess::Mode::Write)
              .should eq(File.join(repo, "merged.txt"))
          ensure
            Sandbox.merge_active = false
          end
        end
      end
    end

    describe "Bash" do
      it "blocks commands referencing the original repository" do
        with_sandbox do |repo, _home, sandbox|
          target = File.join(repo, "frombash.txt")
          bash = Tools::Bash.new(sandbox)
          result = bash.execute(JSON.parse(%({"command": "echo x > #{target}"})))
          result.is_error?.should be_true
          result.content.should contain("fork sandbox")
          File.exists?(target).should be_false
        end
      end

      it "blocks cwd inside the original repository" do
        with_sandbox do |repo, _home, sandbox|
          bash = Tools::Bash.new(sandbox)
          result = bash.execute(JSON.parse(%({"command": "pwd", "cwd": #{repo.inspect}})))
          result.is_error?.should be_true
          result.content.should contain("cwd")
        end
      end

      it "allows commands inside the sandbox (including its own path)" do
        with_sandbox do |_repo, _home, sandbox|
          bash = Tools::Bash.new(sandbox)
          result = bash.execute(JSON.parse(%({"command": "git -C #{sandbox} rev-parse --is-inside-work-tree"})))
          result.is_error?.should be_false
          result.content.strip.should eq("true")
        end
      end

      it "lifts the block during a merge turn" do
        with_sandbox do |repo, _home, sandbox|
          Sandbox.merge_active = true
          begin
            bash = Tools::Bash.new(sandbox)
            result = bash.execute(JSON.parse(%({"command": "pwd", "cwd": #{repo.inspect}})))
            result.is_error?.should be_false
            File.expand_path(result.content.strip).should eq(File.expand_path(repo))
          ensure
            Sandbox.merge_active = false
          end
        end
      end
    end

    describe "InteractiveShell" do
      it "blocks starting a session in the original repository" do
        with_sandbox do |repo, _home, sandbox|
          Tools::InteractiveShell.service = Tools::InteractiveShellService.new
          begin
            tool = Tools::InteractiveShellTool.new(sandbox)
            result = tool.execute(JSON.parse(%({"action": "start", "command": "cat", "cwd": #{repo.inspect}})))
            result.is_error?.should be_true
            result.content.should contain("fork sandbox")
          ensure
            Tools::InteractiveShell.service = nil
          end
        end
      end
    end

    describe "sibling sandboxes and session store" do
      it "blocks writes into another session's sandbox" do
        with_sandbox do |repo, home, sandbox|
          sibling = H2code::Worktree.create(repo, "sbsib", home).path.not_nil!
          tool = Tools::Write.new(sandbox)
          target = File.join(sibling, "intrude.txt")
          result = tool.execute(JSON.parse(%({"path": #{target.inspect}, "content": "x"})))
          result.is_error?.should be_true
          result.content.should contain("is inside one")
          File.exists?(target).should be_false

          bash = Tools::Bash.new(sandbox)
          result = bash.execute(JSON.parse(%({"command": "echo x > #{File.join(sibling, "b.txt")}"})))
          result.is_error?.should be_true
          result.content.should contain("Sandboxes under")
        end
      end

      it "blocks writes into the session store from any session" do
        with_sandbox do |_repo, home, sandbox|
          # From a fork sandbox...
          target = File.join(home, ".h2code", "sessions", "other", "wire.log")
          expect_raises(Tools::PathAccess::AccessError, "session") do
            Tools::PathAccess.resolve(target, sandbox, Tools::PathAccess::Mode::Write)
          end
          # ...and from a plain (non-fork) directory.
          plain = File.join(home, "plain")
          Dir.mkdir_p(plain)
          expect_raises(Tools::PathAccess::AccessError, "session") do
            Tools::PathAccess.resolve(target, plain, Tools::PathAccess::Mode::Write)
          end
          # Reads stay allowed.
          Tools::PathAccess.resolve(target, plain,
            Tools::PathAccess::Mode::Read).should eq(target)
        end
      end

      it "blocks Bash and InteractiveShell aimed at the session store" do
        with_sandbox do |_repo, home, sandbox|
          sroot = File.join(home, ".h2code", "sessions")
          bash = Tools::Bash.new(sandbox)
          result = bash.execute(JSON.parse(%({"command": "ls #{sroot}"})))
          result.is_error?.should be_true
          result.content.should contain("session data")
          result = bash.execute(JSON.parse(%({"command": "pwd", "cwd": #{sroot.inspect}})))
          result.is_error?.should be_true

          Tools::InteractiveShell.service = Tools::InteractiveShellService.new
          begin
            tool = Tools::InteractiveShellTool.new(sandbox)
            result = tool.execute(JSON.parse(%({"action": "start", "command": "cat", "cwd": #{sroot.inspect}})))
            result.is_error?.should be_true
          ensure
            Tools::InteractiveShell.service = nil
          end
        end
      end

      it "still holds during a merge turn" do
        with_sandbox do |repo, home, sandbox|
          Sandbox.merge_active = true
          begin
            # The main-repo block is lifted for the merge turn...
            Tools::PathAccess.resolve(File.join(repo, "merged.txt"),
              sandbox, Tools::PathAccess::Mode::Write)
              .should eq(File.join(repo, "merged.txt"))
            # ...but siblings and the session store stay blocked.
            expect_raises(Tools::PathAccess::AccessError, "session") do
              Tools::PathAccess.resolve(File.join(home, ".h2code", "sessions", "x", "y"),
                sandbox, Tools::PathAccess::Mode::Write)
            end
          ensure
            Sandbox.merge_active = false
          end
        end
      end
    end

    describe "NO_SANDBOX" do
      it "lifts every confinement while set, restores them after unset" do
        with_sandbox do |repo, home, sandbox|
          ENV["NO_SANDBOX"] = "1"
          begin
            Sandbox.disabled?.should be_true
            # Session store, sibling sandbox and fork original repo all
            # become writable...
            Tools::PathAccess.resolve(File.join(home, ".h2code", "sessions", "x", "y"),
              sandbox, Tools::PathAccess::Mode::Write)
              .should eq(File.join(home, ".h2code", "sessions", "x", "y"))
            Tools::PathAccess.resolve(File.join(repo, "escaped.txt"),
              sandbox, Tools::PathAccess::Mode::Write)
              .should eq(File.join(repo, "escaped.txt"))
            # ...and shell commands aimed at them pass the guard too.
            Sandbox.shell_block_reason("ls #{File.join(home, ".h2code", "sessions")}",
              nil, sandbox, home).should be_nil
          ensure
            ENV.delete("NO_SANDBOX")
          end

          Sandbox.disabled?.should be_false
          expect_raises(Tools::PathAccess::AccessError, "session") do
            Tools::PathAccess.resolve(File.join(home, ".h2code", "sessions", "x", "y"),
              sandbox, Tools::PathAccess::Mode::Write)
          end
        end
      end
    end

    it "does not confine sessions outside a fork sandbox" do
      with_sandbox do |_repo, home, _sandbox|
        # A normal directory pair: absolute-path writes outside the
        # workspace remain allowed (pre-existing PathAccess policy).
        other = File.join(home, "plain-dir")
        Dir.mkdir_p(other)
        target = File.join(other, "ok.txt")
        Tools::PathAccess.resolve(target, home, Tools::PathAccess::Mode::Write)
          .should eq(target)
      end
    end
  end
end
