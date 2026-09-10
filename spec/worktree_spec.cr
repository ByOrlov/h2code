require "./spec_helper"

{% if flag?(:win32) %}
  WT_GIT_AVAILABLE = false
{% else %}
  WT_GIT_AVAILABLE = Process.run("git", ["--version"],
    output: IO::Memory.new, error: IO::Memory.new).success?
{% end %}

# Creates a temp git repo (branch "main", one commit) plus a temp
# worktree home, yields them, and cleans both up. Skips the test when
# git is unavailable.
private def with_git_repo(&)
  unless WT_GIT_AVAILABLE
    pending! "git unavailable"
    return
  end
  repo = File.join(Dir.tempdir, "h2code-wt-spec-#{Random::Secure.hex(6)}")
  home = File.join(Dir.tempdir, "h2code-wt-home-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(repo)
  Dir.mkdir_p(home)
  wt_git(repo, "init", "-b", "main")
  wt_git(repo, "config", "user.email", "spec@example.com")
  wt_git(repo, "config", "user.name", "Spec")
  File.write(File.join(repo, "a.txt"), "one\n")
  wt_git(repo, "add", "-A")
  wt_git(repo, "commit", "-m", "init")
  begin
    yield repo, home
  ensure
    wt_git(repo, "worktree", "prune") if Dir.exists?(repo)
    FileUtils.rm_r(repo) if File.exists?(repo)
    FileUtils.rm_r(home) if File.exists?(home)
  end
end

private def wt_git(dir : String, *args : String) : String
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  code = Process.run("git", ["-C", dir] + args.to_a,
    output: out_io, error: err_io).exit_code
  raise "git #{args.first} failed: #{err_io}" unless code == 0
  out_io.to_s.strip
end

# Success-only variant for assertions about failing commands.
private def wt_git_ok?(dir : String, *args : String) : Bool
  Process.run("git", ["-C", dir] + args.to_a,
    output: IO::Memory.new, error: IO::Memory.new).success?
end

module H2code
  describe Worktree do
    describe "encode_project_path" do
      it "encodes a POSIX absolute path without the leading separator" do
        {% if !flag?(:win32) %}
          Worktree.encode_project_path("/home/oleg/project1").should eq("home/oleg/project1")
        {% end %}
      end

      it "encodes a Windows drive path with a lower-cased drive letter" do
        Worktree.encode_project_path("C:\\Users\\oleg\\p1").should eq("c/Users/oleg/p1")
      end

      it "normalizes relative segments" do
        Worktree.encode_project_path("/home/oleg/../oleg/p1").should eq("home/oleg/p1")
      end
    end

    describe "branch_for" do
      it "prefixes the session id" do
        Worktree.branch_for("abc123").should eq("h2code-abc123")
      end
    end

    describe "create" do
      it "creates a standalone clone branched from the current branch" do
        with_git_repo do |repo, home|
          result = Worktree.create(repo, "sess01", home)
          result.success?.should be_true
          result.path.should_not be_nil
          dest = result.path.not_nil!
          result.branch.not_nil!.should eq("h2code-sess01")

          # A standalone clone, not a linked worktree: own .git directory.
          File.directory?(File.join(dest, ".git")).should be_true
          Worktree.worktree?(dest).should be_false
          Worktree.worktree?(repo).should be_false

          File.exists?(File.join(dest, "a.txt")).should be_true
          Worktree.current_branch(dest).should eq("h2code-sess01")
          # Cut from the current branch's tip (main), not master:
          wt_git(dest, "rev-parse", "h2code-sess01").should eq(
            wt_git(repo, "rev-parse", "main"))
          # The session branch exists ONLY inside the clone — the original
          # repository's refs are untouched.
          wt_git_ok?(repo, "rev-parse", "--verify", "h2code-sess01").should be_false
          # The clone's origin points back at the source repo.
          Worktree.main_repo(dest).should eq(File.expand_path(repo))
        end
      end

      it "isolates destructive git commands from the original repo" do
        with_git_repo do |repo, home|
          dest = Worktree.create(repo, "sess08", home).path.not_nil!
          # The classic poisoning vector: deleting a shared branch from a
          # linked worktree killed it repo-wide. In the clone it only drops
          # the clone's own local copy — main survives in the source repo.
          wt_git(dest, "branch", "-D", "main").should contain("Deleted branch main")
          wt_git_ok?(repo, "rev-parse", "--verify", "main").should be_true
          wt_git_ok?(dest, "rev-parse", "--verify", "origin/main").should be_true
        end
      end

      it "pushes the session branch from the sandbox to the original repo" do
        with_git_repo do |repo, home|
          dest = Worktree.create(repo, "sess09", home).path.not_nil!
          # Push stays enabled out of the box; fetch still works for /merge.
          wt_git_ok?(dest, "push", "origin", "h2code-sess09").should be_true
          wt_git_ok?(repo, "rev-parse", "--verify", "h2code-sess09").should be_true
          wt_git_ok?(dest, "fetch", "origin").should be_true
        end
      end

      it "refuses to fork a detached HEAD" do
        with_git_repo do |repo, home|
          wt_git(repo, "checkout", "--detach")
          result = Worktree.create(repo, "sess02", home)
          result.success?.should be_false
          result.error.to_s.should contain("detached")
        end
      end

      it "fails outside a git repository" do
        home = File.join(Dir.tempdir, "h2code-wt-home-#{Random::Secure.hex(6)}")
        Dir.mkdir_p(home)
        begin
          result = Worktree.create(home, "sess05", home)
          result.success?.should be_false
          result.error.to_s.should contain("git")
        ensure
          FileUtils.rm_r(home)
        end
      end
    end

    describe "fork_sandbox?" do
      it "accepts sandboxes under the root, rejects other repos" do
        with_git_repo do |repo, home|
          dest = Worktree.create(repo, "sess10", home).path.not_nil!
          Worktree.fork_sandbox?(dest, home).should be_true
          Worktree.fork_sandbox?(repo, home).should be_false
        end
      end
    end

    describe "merged state and clean" do
      it "reports dirty/merged state and clean removes merged sandboxes" do
        with_git_repo do |repo, home|
          result = Worktree.create(repo, "sess03", home)
          dest = result.path.not_nil!

          # Uncommitted work in the sandbox: dirty. (The dirty check is
          # what protects uncommitted files from removal.)
          File.write(File.join(dest, "b.txt"), "two\n")
          Worktree.dirty?(dest).should be_true

          # Commit on the sandbox branch, then fold it back exactly like
          # the /merge prompt does: fetch into the original repo + merge.
          wt_git(dest, "config", "user.email", "spec@example.com")
          wt_git(dest, "config", "user.name", "Spec")
          wt_git(dest, "add", "-A")
          wt_git(dest, "commit", "-m", "feature")
          Worktree.dirty?(dest).should be_false
          wt_git(repo, "fetch", dest, "+h2code-sess03:h2code-sess03")
          wt_git(repo, "merge", "h2code-sess03", "--no-edit")
          Worktree.branch_merged?(repo, "h2code-sess03").should be_true

          # list reflects the state.
          infos = Worktree.list(home)
          infos.size.should eq(1)
          infos[0].branch.should eq("h2code-sess03")
          infos[0].merged?.should be_true
          infos[0].dirty?.should be_false
          infos[0].main_repo.should eq(File.expand_path(repo))

          # clean removes the merged sandbox and its (fetched) branch.
          clean = Worktree.clean(home)
          clean.removed.should contain(dest)
          File.exists?(dest).should be_false
          wt_git(repo, "branch", "--list", "h2code-sess03").should be_empty
        end
      end

      it "keeps unmerged sandboxes in clean" do
        with_git_repo do |repo, home|
          result = Worktree.create(repo, "sess04", home)
          dest = result.path.not_nil!
          wt_git(dest, "config", "user.email", "spec@example.com")
          wt_git(dest, "config", "user.name", "Spec")
          File.write(File.join(dest, "a.txt"), "changed\n")
          wt_git(dest, "add", "-A")
          wt_git(dest, "commit", "-m", "wip")

          clean = Worktree.clean(home)
          clean.removed.should be_empty
          clean.kept.size.should eq(1)
          File.exists?(dest).should be_true
        end
      end

      it "gc removes only aged, merged sandboxes" do
        with_git_repo do |repo, home|
          # Aged but unmerged: kept by gc.
          unmerged = Worktree.create(repo, "sess06", home).path.not_nil!
          wt_git(unmerged, "config", "user.email", "spec@example.com")
          wt_git(unmerged, "config", "user.name", "Spec")
          File.write(File.join(unmerged, "a.txt"), "wip\n")
          wt_git(unmerged, "add", "-A")
          wt_git(unmerged, "commit", "-m", "wip")
          past = Time.utc - 30.days
          File.utime(past, past, unmerged)

          # Freshly merged: gc skips it (still within the age window).
          fresh = Worktree.create(repo, "sess07", home).path.not_nil!
          wt_git(repo, "fetch", fresh, "+h2code-sess07:h2code-sess07")
          wt_git(repo, "merge", "h2code-sess07", "--no-edit")

          removed = Worktree.gc(home, max_age_days: 14)
          removed.should be_empty
          File.exists?(unmerged).should be_true
          File.exists?(fresh).should be_true

          # Age the merged one past the cutoff: gc removes it.
          File.utime(past, past, fresh)
          removed = Worktree.gc(home, max_age_days: 14)
          removed.should contain(fresh)
          File.exists?(fresh).should be_false
          File.exists?(unmerged).should be_true
        end
      end
    end

    describe "legacy linked worktrees" do
      it "are still listed and cleaned up" do
        with_git_repo do |repo, home|
          legacy = File.join(Worktree.root(home), "legacy")
          FileUtils.mkdir_p(File.dirname(legacy))
          wt_git(repo, "worktree", "add", "-b", "legacy-branch", legacy)

          infos = Worktree.list(home)
          paths = infos.map(&.path)
          paths.should contain(legacy)

          # The legacy branch sits at main's tip: merged + clean.
          error = Worktree.remove(repo, legacy, "legacy-branch")
          error.should be_nil
          File.exists?(legacy).should be_false
          wt_git(repo, "branch", "--list", "legacy-branch").should be_empty
        end
      end
    end
  end
end
