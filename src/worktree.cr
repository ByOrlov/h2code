require "file_utils"
require "./home_port"

module H2code
  # Isolated feature worktrees for `/fork` + `/merge`.
  #
  # `/fork` creates a git worktree plus a fresh branch `h2code-<session-id>`
  # forked from the CURRENT branch (not master) and parked under
  # `~/.h2code/worktree/<encoded-project-path>/<branch>`, so the agent can
  # work on a feature without touching the main checkout:
  #
  #   /home/oleg/project1  ->  ~/.h2code/worktree/home/oleg/project1/h2code-<id>
  #   C:\Users\oleg\p1     ->  ~/.h2code/worktree/c/users/oleg/p1/h2code-<id>
  #
  # `/merge` asks the agent to merge the branch back into the original
  # repository; on success the worktree and the branch are removed
  # automatically. No registry is kept — `git worktree list` state and the
  # deterministic directory layout are the source of truth.
  module Worktree
    BRANCH_PREFIX = "h2code-"

    # A `/merge` in flight: which worktree/branch to fold back and where.
    # Checked by the TUI when the merge turn ends.
    struct PendingMerge
      getter worktree : String
      getter branch : String
      getter main_repo : String

      def initialize(@worktree : String, @branch : String, @main_repo : String)
      end
    end

    # Root directory under which all h2code worktrees live.
    def self.root(home : String = HomePort.home) : String
      File.join(home, ".h2code", "worktree")
    end

    # Branch name for a session id.
    def self.branch_for(session_id : String) : String
      "#{BRANCH_PREFIX}#{session_id}"
    end

    # Encode an absolute project path into directory segments below the
    # worktree root: the leading separator is dropped and a Windows drive
    # letter is lower-cased (`/home/oleg/p1` -> `home/oleg/p1`,
    # `C:\Users\oleg\p1` -> `c/users/oleg/p1`). Segments are joined with `/`
    # on every platform so the layout is identical across OSes.
    def self.encode_project_path(cwd : String) : String
      # Windows drive paths must not go through expand_path on POSIX (it
      # would treat them as relative and prepend the cwd).
      expanded = cwd =~ /^[A-Za-z]:[\/\\]/ ? cwd : File.expand_path(cwd)
      segments = expanded.split(/[\/\\]/).reject(&.empty?)
      unless segments.empty?
        # Drive letter: drop the colon and lower-case (`C:` -> `c`).
        if segments[0].size == 2 && segments[0][1] == ':'
          segments[0] = segments[0][0].downcase.to_s
        end
      end
      segments.join("/")
    end

    # Deterministic worktree directory for a project + session.
    def self.worktree_dir(cwd : String, session_id : String, home : String = HomePort.home) : String
      File.join(root(home), encode_project_path(cwd), branch_for(session_id))
    end

    # ------------------------------------------------------------------
    # git helpers
    # ------------------------------------------------------------------

    private def self.git(dir : String, *args : String) : NamedTuple(out: String, err: String, code: Int32)
      out_io = IO::Memory.new
      err_io = IO::Memory.new
      code = Process.run("git", ["-C", dir] + args.to_a,
        output: out_io, error: err_io).exit_code
      {out: out_io.to_s, err: err_io.to_s, code: code}
    end

    # Is `dir` inside a git work tree at all?
    def self.git_repo?(dir : String) : Bool
      git(dir, "rev-parse", "--is-inside-work-tree")[:code] == 0
    end

    # Current branch name, or nil when HEAD is detached.
    def self.current_branch(dir : String) : String?
      res = git(dir, "rev-parse", "--abbrev-ref", "HEAD")
      return nil unless res[:code] == 0
      branch = res[:out].strip
      branch.empty? || branch == "HEAD" ? nil : branch
    end

    # Is `dir` a linked worktree (git-dir != common-dir)?
    def self.worktree?(dir : String) : Bool
      gd = git(dir, "rev-parse", "--git-dir")
      cd = git(dir, "rev-parse", "--git-common-dir")
      return false unless gd[:code] == 0 && cd[:code] == 0
      File.expand_path(gd[:out].strip, dir) != File.expand_path(cd[:out].strip, dir)
    end

    # The main repository directory that a worktree belongs to (the parent
    # of the shared `.git`), or nil when not resolvable.
    def self.main_repo(dir : String) : String?
      res = git(dir, "rev-parse", "--git-common-dir")
      return nil unless res[:code] == 0
      common = File.expand_path(res[:out].strip, dir)
      # The common dir is `<main>/.git` (or the `.git` file in a bare-ish
      # edge case); its parent is the main checkout.
      parent = File.dirname(common)
      parent == dir ? nil : parent
    end

    # Is `branch` fully merged into HEAD of `repo`?
    def self.branch_merged?(repo : String, branch : String) : Bool
      git(repo, "merge-base", "--is-ancestor", branch, "HEAD")[:code] == 0
    end

    # Does the worktree hold uncommitted or untracked changes?
    def self.dirty?(dir : String) : Bool
      res = git(dir, "status", "--porcelain")
      res[:code] == 0 && !res[:out].strip.empty?
    end

    # ------------------------------------------------------------------
    # create / remove
    # ------------------------------------------------------------------

    struct CreateResult
      getter path : String?
      getter branch : String?
      getter error : String?

      def self.success(path : String, branch : String) : CreateResult
        new(path, branch, nil)
      end

      def self.failure(error : String) : CreateResult
        new(nil, nil, error)
      end

      def initialize(@path : String?, @branch : String?, @error : String?)
      end

      def success? : Bool
        @error.nil?
      end
    end

    # Create a worktree for `session_id` in `cwd`, branching
    # `h2code-<session-id>` from the CURRENT branch's HEAD. The main
    # checkout (including uncommitted changes) is left untouched.
    def self.create(cwd : String, session_id : String, home : String = HomePort.home) : CreateResult
      return CreateResult.failure("not a git repository") unless git_repo?(cwd)
      base = current_branch(cwd)
      return CreateResult.failure("HEAD is detached — no branch to fork from") unless base

      branch = branch_for(session_id)
      dest = worktree_dir(cwd, session_id, home)
      return CreateResult.failure("worktree already exists at #{dest}") if File.exists?(dest)
      Dir.mkdir_p(File.dirname(dest))

      res = git(cwd, "worktree", "add", "-b", branch, dest, base)
      if res[:code] != 0
        FileUtils.rm_r(dest) if File.exists?(dest)
        message = res[:err].strip
        message = "git worktree add failed" if message.empty?
        return CreateResult.failure(message)
      end
      CreateResult.success(dest, branch)
    end

    # Remove a worktree and delete its (fully merged) branch. A dirty
    # worktree is never deleted — the caller is told why.
    def self.remove(main_repo : String, path : String, branch : String | Nil) : String?
      if File.exists?(path) && dirty?(path)
        return "worktree has uncommitted changes: #{path}"
      end
      if File.exists?(path)
        res = git(main_repo, "worktree", "remove", path)
        return res[:err].strip if res[:code] != 0
      end
      if branch
        # `-d` refuses to delete branches that are not fully merged.
        git(main_repo, "branch", "-d", branch)
      end
      nil
    end

    # ------------------------------------------------------------------
    # list / clean / gc
    # ------------------------------------------------------------------

    struct Info
      getter path : String
      getter branch : String
      getter main_repo : String
      getter? merged : Bool
      getter? dirty : Bool
      getter last_used : Time

      def initialize(@path : String, @branch : String, @main_repo : String,
                     @merged : Bool, @dirty : Bool, @last_used : Time)
      end
    end

    # Enumerate h2code worktrees below the root. Directories holding a
    # `.git` file are linked worktrees; anything else is skipped.
    def self.list(home : String = HomePort.home) : Array(Info)
      base = root(home)
      return [] of Info unless Dir.exists?(base)
      infos = [] of Info
      walk_worktrees(base) do |dir|
        next unless repo = main_repo(dir)
        branch = current_branch(dir) || File.basename(dir)
        infos << Info.new(
          path: dir,
          branch: branch,
          main_repo: repo,
          merged: branch_merged?(repo, branch),
          dirty: dirty?(dir),
          last_used: last_used_at(dir),
        )
      end
      infos.sort_by(&.path)
    end

    private def self.walk_worktrees(dir : String, &block : String ->) : Nil
      return if File.symlink?(dir)
      if File.file?(File.join(dir, ".git"))
        block.call(dir)
        return
      end
      begin
        Dir.each_child(dir) do |child|
          child_path = File.join(dir, child)
          next unless File.directory?(child_path)
          walk_worktrees(child_path) do |p|
            block.call(p)
          end
        end
      rescue File::NotFoundError
        # Directory vanished mid-walk (concurrent clean) — skip it.
      end
    end

    private def self.last_used_at(dir : String) : Time
      File.info?(dir).try(&.modification_time) || Time.utc
    end

    struct CleanResult
      getter removed : Array(String)
      getter kept : Array(String)

      def initialize(@removed : Array(String) = [] of String, @kept : Array(String) = [] of String)
      end
    end

    # Remove every fully merged, clean worktree. Unmerged or dirty
    # worktrees are kept and reported.
    def self.clean(home : String = HomePort.home) : CleanResult
      result = CleanResult.new
      list(home).each do |info|
        if info.merged? && !info.dirty?
          error = remove(info.main_repo, info.path, info.branch)
          error ? result.kept << "#{info.path} (#{error})" : result.removed << info.path
        else
          reason = info.dirty? ? "uncommitted changes" : "branch not merged"
          result.kept << "#{info.path} (#{reason})"
        end
      end
      result
    end

    # Age-based GC for startup: remove fully merged, clean worktrees whose
    # directory has not been touched for `max_age_days`. Unmerged work is
    # never collected.
    def self.gc(home : String = HomePort.home, max_age_days : Int32 = 14) : Array(String)
      cutoff = Time.utc - max_age_days.days
      removed = [] of String
      list(home).each do |info|
        collectable = info.merged? && !info.dirty? && info.last_used < cutoff
        removed << info.path if collectable && remove(info.main_repo, info.path, info.branch).nil?
      end
      removed
    end
  end
end
