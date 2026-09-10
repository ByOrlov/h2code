require "file_utils"
require "./home_port"

module H2code
  # Isolated feature sandboxes for `/fork` + `/merge`.
  #
  # `/fork` creates a STANDALONE CLONE (`git clone --no-hardlinks`) plus a
  # fresh branch `h2code-<session-id>` forked from the CURRENT branch (not
  # master) and parked under `~/.h2code/worktree/<encoded-project-path>/<branch>`:
  #
  #   /home/oleg/project1  ->  ~/.h2code/worktree/home/oleg/project1/h2code-<id>
  #   C:\Users\oleg\p1     ->  ~/.h2code/worktree/c/users/oleg/p1/h2code-<id>
  #
  # A standalone clone (unlike a linked worktree) owns its object database,
  # refs, reflog and config outright, so destructive commands run inside the
  # sandbox (`git branch -D`, `git update-ref`, `git gc --prune=now`, ...)
  # cannot poison the original repository or its other branches. The local
  # source repository is reachable through the `h2code-main` remote, so
  # `/merge` can find it and `git push` of the session branch to it works
  # from the sandbox. `origin` is inherited from the source repo (e.g.
  # git@github.com:owner/repo.git), so CI observation (which keys off
  # `git remote get-url origin`) and pushes to the shared remote work in
  # the sandbox exactly like in the original checkout. Sources without a
  # remote of their own keep the legacy layout: `origin` is the local
  # source path, and `main_repo` falls back to it.
  #
  # `/merge` asks the agent to fetch the branch from the sandbox into the
  # original repository and merge it; on success the sandbox and the branch
  # are removed automatically. No registry is kept — the deterministic
  # directory layout is the source of truth. Legacy linked worktrees (`.git`
  # file) created by older versions are still listed, merged and cleaned up.
  module Worktree
    BRANCH_PREFIX = "h2code-"

    # Remote that keeps pointing at the local source repository in fork
    # sandboxes, so `/merge`, list/clean/gc and the sandbox write guard
    # always resolve a local checkout (never a network URL) — see
    # `main_repo`. `origin` itself carries the source repo's own remote
    # URL (GitHub/GitLab) for CI observation and pushes.
    LOCAL_ORIGIN = "h2code-main"

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

    # Is `dir` one of our fork sandboxes — a git repository (standalone
    # clone or legacy linked worktree) parked under the worktree root?
    # Gate for `/merge`.
    def self.fork_sandbox?(dir : String, home : String = HomePort.home) : Bool
      expanded = File.expand_path(dir)
      return false unless expanded.starts_with?(File.expand_path(root(home)) + File::SEPARATOR)
      git_repo?(expanded)
    end

    # The main repository a fork sandbox belongs to: the local source remote
    # (`h2code-main`, set at clone time when the source repo has its own
    # origin), falling back to `origin` for legacy sandboxes whose origin
    # still is the local source path. Never the network URL — callers run
    # git against a local checkout (merge checks, branch deletion, the
    # sandbox write guard). For a legacy linked worktree it is the parent
    # of the shared `.git`. Returns nil when not resolvable.
    def self.main_repo(dir : String) : String?
      if File.directory?(File.join(dir, ".git"))
        {LOCAL_ORIGIN, "origin"}.each do |remote|
          res = git(dir, "remote", "get-url", remote)
          next unless res[:code] == 0
          url = res[:out].strip
          return url unless url.empty?
        end
        nil
      end
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

    # Create a sandbox for `session_id` in `cwd`: a standalone clone of the
    # current repository with a fresh branch `h2code-<session-id>` cut from
    # the CURRENT branch's HEAD. The main checkout (including uncommitted
    # changes and every other branch) is left untouched — the clone shares
    # no refs, objects, reflog or config with it.
    def self.create(cwd : String, session_id : String, home : String = HomePort.home) : CreateResult
      return CreateResult.failure("not a git repository") unless git_repo?(cwd)
      base = current_branch(cwd)
      return CreateResult.failure("HEAD is detached — no branch to fork from") unless base

      branch = branch_for(session_id)
      dest = worktree_dir(cwd, session_id, home)
      return CreateResult.failure("worktree already exists at #{dest}") if File.exists?(dest)
      Dir.mkdir_p(File.dirname(dest))

      # --no-hardlinks: full object copy, not a single shared inode with the
      # original `.git` — the structural poisoning boundary. When the source
      # repo has its own origin, the local source remote is renamed to
      # `h2code-main` at clone time and `origin` is re-pointed at the
      # source's remote URL below — CI observation and pushes to the shared
      # remote work in the sandbox like in the original checkout.
      source_origin = origin_url(cwd)
      if source_origin
        res = git(cwd, "clone", "--no-hardlinks", "--origin", LOCAL_ORIGIN, cwd, dest)
      else
        res = git(cwd, "clone", "--no-hardlinks", cwd, dest)
      end
      if res[:code] != 0
        FileUtils.rm_r(dest) if File.exists?(dest)
        message = res[:err].strip
        message = "git clone failed" if message.empty?
        return CreateResult.failure(message)
      end
      if url = source_origin
        res = git(dest, "remote", "add", "origin", url)
        if res[:code] != 0
          FileUtils.rm_r(dest)
          message = res[:err].strip
          message = "git remote add origin failed" if message.empty?
          return CreateResult.failure(message)
        end
      end
      # The clone checked out the source's current branch at its HEAD; fork
      # the session branch off that tip (exists only inside the clone).
      res = git(dest, "checkout", "-b", branch)
      if res[:code] != 0
        FileUtils.rm_r(dest)
        message = res[:err].strip
        message = "git checkout -b failed" if message.empty?
        return CreateResult.failure(message)
      end
      # The local source remote (fetch and push) points at the source repo,
      # so a `git push` of the session branch to it works out of the box;
      # `origin` carries the source's own remote URL for CI observation and
      # pushes to the shared remote.
      CreateResult.success(dest, branch)
    end

    # Fetch URL of the source repo's own origin remote, or nil when it has
    # none (a pure-local repository).
    private def self.origin_url(dir : String) : String?
      res = git(dir, "remote", "get-url", "origin")
      return nil unless res[:code] == 0
      url = res[:out].strip
      url.empty? ? nil : url
    end

    # Remove a fork sandbox and delete its (fully merged) branch from the
    # main repository. A dirty sandbox is never deleted — the caller is told
    # why. Standalone clones are plain directories (rm -r); legacy linked
    # worktrees still go through `git worktree remove`.
    def self.remove(main_repo : String, path : String, branch : String | Nil) : String?
      if File.exists?(path) && dirty?(path)
        return "worktree has uncommitted changes: #{path}"
      end
      if File.exists?(path)
        if File.directory?(File.join(path, ".git"))
          # Standalone sandbox clone: nothing shared to deregister.
          FileUtils.rm_r(path)
        else
          res = git(main_repo, "worktree", "remove", path)
          return res[:err].strip if res[:code] != 0
        end
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

    # Enumerate h2code fork sandboxes below the root. Directories holding a
    # `.git` entry are ours — a `.git` directory marks a standalone clone, a
    # `.git` file marks a legacy linked worktree; anything else is skipped.
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
      dot_git = File.join(dir, ".git")
      if File.file?(dot_git) || File.directory?(dot_git)
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
