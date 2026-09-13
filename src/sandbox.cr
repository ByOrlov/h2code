module H2code
  # Tool-level write confinement for `/fork` sandbox sessions.
  #
  # A fork session runs inside a standalone clone parked under
  # `~/.h2code/worktree/...`; the whole point of the sandbox is that
  # NOTHING in the original repository changes until `/merge`. Before
  # this guard the file tools happily accepted absolute paths into the
  # original repo (PathAccess allows absolute writes outside the
  # workspace), and Bash could `cd` / `git -C` into it — so a model
  # falling back on habit edited the real checkout from inside the
  # sandbox.
  #
  # The guard resolves the sandbox's origin remote (the original
  # repository) once per work dir (cached) and blocks, for every
  # write-shaped tool call:
  #
  #   * file tools (Write / Edit / ApplyPatch via PathAccess Mode::Write):
  #     any target inside the original repo — lexically, plus a realpath
  #     pass so a symlink planted in the sandbox cannot redirect the
  #     write;
  #   * Bash / InteractiveShell: a `cwd` inside the original repo and any
  #     command text that references its absolute path (best-effort
  #     lexical match on path boundaries — arbitrary shell can still
  #     smuggle a path through variables or `..` chains, so this is
  #     defence in depth, not a security boundary).
  #
  # Reads and searches of the original repo stay allowed (diffing,
  # `git log`, grepping the checkout are legitimate). The single
  # exception is the `/merge` turn: it is an explicit user command whose
  # purpose is to write into the original repo, so the TUI raises
  # `merge_active` for that one turn and lowers it at turn end.
  #
  # Two sibling guards apply to EVERY session, fork or not, and are never
  # lifted (not even during `/merge`):
  #
  #   * the h2code session store (`~/.h2code/sessions/**`) is private
  #     session data — other sessions' dirs are never writable by tools.
  #     The session's OWN dir is writable (plan-mode plan files live under
  #     `<session>/agents/**/plans/*.md` and are written with the regular
  #     Write/Edit tools); tool plumbing like background-task logs bypasses
  #     the tool gate and keeps working;
  #   * other sessions' sandboxes under `~/.h2code/worktree/**` are
  #     off-limits — only the session's own work tree is writable.
  #
  # The single seam that lifts ALL of the above (fork guard included) is
  # the NO_SANDBOX env var — set only by the rake mock tasks (they never
  # wire a real session dir into the guard); real sessions never set it.
  module Sandbox
    @@mutex = Mutex.new
    @@main_repo_cache = {} of String => String?
    @@merge_active = false

    # True only during a `/merge` turn — the one sanctioned moment a
    # fork session may write into the original repository. Set by the
    # TUI command controller; cleared on every turn end.
    class_property? merge_active

    # Whether ALL write/shell confinement is disabled via the NO_SANDBOX
    # env var (rake mock tasks only — see the module docs).
    def self.disabled? : Bool
      ENV.has_key?("NO_SANDBOX")
    end

    # This session's own directory under `~/.h2code/sessions/**` — the one
    # carve-out from the session-store write block (plan files are written
    # there with the regular Write/Edit tools). Set by the runtime wiring
    # when the session store is created/resumed; nil exempts nothing.
    class_property session_dir : String? = nil

    # Test seam: drop the main-repo cache and lower the merge flag.
    def self.reset : Nil
      @@mutex.synchronize { @@main_repo_cache.clear }
      @@merge_active = false
      @@session_dir = nil
    end

    # The original repository a fork-sandbox `cwd` belongs to (normalized
    # local path), or nil when `cwd` is not a fork sandbox. Cached per
    # (home, cwd): resolving runs `git` subprocesses, and whether a path
    # is a sandbox never flips for a given cwd string. A sandbox that is
    # removed and re-created resolves to the same origin.
    def self.main_repo_for(cwd : String, home : String = HomePort.home) : String?
      expanded = File.expand_path(cwd)
      key = "#{home}\0#{expanded}"
      if @@mutex.synchronize { @@main_repo_cache.has_key?(key) }
        return @@mutex.synchronize { @@main_repo_cache[key] }
      end
      resolved = if Worktree.fork_sandbox?(expanded, home)
                   Worktree.main_repo(expanded).try { |url| normalize_repo_path(url) }
                 end
      @@mutex.synchronize { @@main_repo_cache[key] = resolved }
      resolved
    end

    # Path-level write guard for the file tools. Returns a block reason
    # when `canonical` (already resolved against `cwd`) must not be
    # written from this session, nil when the write is allowed.
    def self.write_block_reason(canonical : String, cwd : String,
                                home : String = HomePort.home) : String?
      return nil if disabled?
      base = File.expand_path(cwd)

      # Session store: private data of OTHER sessions. The session's own
      # dir is the one sanctioned write target inside the store (plan
      # files); everything else under the store root stays blocked.
      sroot = sessions_root(home)
      if within?(canonical, sroot)
        own = session_dir
        return nil if own && within?(canonical, File.expand_path(own))
        return session_store_message(canonical, sroot)
      end

      # Sibling sandboxes: under the worktree root but outside this
      # session's own work tree.
      wroot = worktree_root(home)
      if within?(canonical, wroot) && !within?(canonical, base)
        return sibling_message(wroot, "the target path (#{canonical}) is inside one")
      end

      # The original repository of a fork sandbox.
      return nil if merge_active?
      main = main_repo_for(cwd, home)
      return nil unless main
      if within?(canonical, main) || symlinked_into?(canonical, main)
        return block_message(main, base,
          "the target path (#{canonical}) resolves into it")
      end
      nil
    end

    # Guard for shell-shaped tools (Bash, InteractiveShell). Returns a
    # block reason when the command or its `cwd` would operate inside the
    # original repository of a fork sandbox, the session store, or
    # another session's sandbox; nil when allowed.
    def self.shell_block_reason(command : String, cwd : String?, work_dir : String,
                                home : String = HomePort.home) : String?
      return nil if disabled?
      base = File.expand_path(work_dir)
      sroot = sessions_root(home)
      wroot = worktree_root(home)

      expanded_cwd = (cwd && !cwd.strip.empty?) ? File.expand_path(cwd.strip, base) : nil

      if expanded_cwd && within?(expanded_cwd, sroot)
        return session_store_message(expanded_cwd, sroot, "cwd (#{cwd}) is inside it")
      end
      if expanded_cwd && within?(expanded_cwd, wroot) && !within?(expanded_cwd, base)
        return sibling_message(wroot, "cwd (#{cwd}) is inside one")
      end
      if command_references?(command, sroot)
        return session_store_message(sroot, sroot, "the command references it (#{sroot})")
      end
      if command_references?(command, wroot, sandbox: base)
        return sibling_message(wroot, "the command references one (under #{wroot})")
      end

      return nil if merge_active?
      main = main_repo_for(work_dir, home)
      return nil unless main
      detail = if expanded_cwd && within?(expanded_cwd, main)
                 "cwd (#{cwd}) is inside it"
               elsif command_references?(command, main, sandbox: base)
                 "the command references it (#{main})"
               else
                 nil
               end
      detail ? block_message(main, base, detail) : nil
    end

    # ------------------------------------------------------------------
    # command-text scan
    # ------------------------------------------------------------------

    # Does `command` reference the directory `dir` by absolute path?
    # Occurrences must sit on path boundaries (`/repo-x` must not match
    # `/repo`); each match is widened to its whole path token and
    # canonicalized, and tokens that land inside `sandbox` (the session's
    # own work tree — whose encoded layout mirrors the original repo's
    # path segments) are ignored.
    def self.command_references?(command : String, dir : String, *, sandbox : String? = nil) : Bool
      idx = 0
      while pos = command.index(dir, idx)
        after = pos + dir.size
        idx = after
        next unless boundary_at?(command, after)
        token = path_token_around(command, pos, after)
        next if token.empty?
        canonical = File.expand_path(token)
        next if sandbox && within?(canonical, sandbox)
        return true if within?(canonical, dir)
      end
      false
    end

    # A match is on a boundary when the character right after it cannot
    # extend a path component (end of string, separator, quote, space…).
    private def self.boundary_at?(command : String, after : Int32) : Bool
      ch = command[after]?
      ch.nil? || !component_char?(ch)
    end

    private def self.component_char?(ch : Char) : Bool
      ch.alphanumeric? || {'_', '-', '.'}.includes?(ch)
    end

    # Characters that may appear to the left of the matched path inside
    # the same shell word (`~/x`, `$VAR/x` keeps the `$VAR` out of the
    # token only for `$` — both stops are conservative over-flags).
    private LEFT_STOP = {' ', '\t', '\n', '\r', '"', '\'', '`', '=', '$', ';', '|', '&', '(', '<', '>', ')', ','}

    # Characters that terminate a path token on the right. `:` stops on
    # refspecs (`/repo:branch`); quotes and shell metacharacters end the
    # word.
    private RIGHT_STOP = {' ', '\t', '\n', '\r', '"', '\'', '`', ';', '|', '&', '<', '>', '(', ')', ',', ':'}

    # Widen a match at `start...finish` to the full path token around it.
    private def self.path_token_around(command : String, start : Int32, finish : Int32) : String
      left = start
      while left > 0 && !LEFT_STOP.includes?(command[left - 1])
        left -= 1
      end
      right = finish
      while right < command.size && !RIGHT_STOP.includes?(command[right])
        right += 1
      end
      command[left, right - left]
    end

    # ------------------------------------------------------------------
    # symlink / realpath containment
    # ------------------------------------------------------------------

    # Could writing `canonical` land inside `forbidden` even though the
    # lexical path stays outside it? Walks down symlinks and up to the
    # deepest existing ancestor, realpaths it, and checks containment —
    # so a symlink planted inside the sandbox pointing at the original
    # repo cannot tunnel a write through.
    private def self.symlinked_into?(canonical : String, forbidden : String) : Bool
      p = canonical
      16.times do
        if File.symlink?(p)
          target = File.readlink(p) rescue return false
          p = File.expand_path(target, File.dirname(p))
          return true if within?(p, forbidden)
        elsif File.exists?(p)
          break
        else
          parent = File.dirname(p)
          return false if parent == p
          p = parent
        end
      end
      real = File.realpath(p) rescue return false
      within?(real, forbidden)
    end

    # ------------------------------------------------------------------
    # helpers
    # ------------------------------------------------------------------

    # The h2code session store root (`~/.h2code/sessions`).
    private def self.sessions_root(home : String) : String
      File.join(File.expand_path(home), ".h2code", "sessions")
    end

    # The fork-sandbox root (`~/.h2code/worktree`).
    private def self.worktree_root(home : String) : String
      File.expand_path(Worktree.root(home))
    end

    private def self.session_store_message(target : String, root : String, detail : String = "the target path (#{target}) is inside it") : String
      "Blocked: #{detail}. #{root} is private session data (every session's, this " \
      "one included) and is never writable by tools — read it with Read/Grep instead."
    end

    private def self.sibling_message(root : String, detail : String) : String
      "Blocked: #{detail}. Sandboxes under #{root} belong to their own sessions; " \
      "only this session's work tree is writable. Fold shared work back through " \
      "the original repository."
    end

    private def self.block_message(main : String, sandbox : String, detail : String) : String
      "Blocked by the fork sandbox: #{detail}. This session runs in an isolated sandbox " \
      "clone (#{sandbox}) while the original repository (#{main}) is read-only from a " \
      "fork session. Do the work inside the sandbox and use /merge to fold it back."
    end

    # Component-boundary containment — same semantics as
    # Tools::PathAccess.within_directory?, kept local so this module has
    # no load-order dependencies.
    private def self.within?(candidate : String, base : String) : Bool
      {% if flag?(:win32) %}
        within?(candidate.downcase.tr("/", "\\"), base.downcase.tr("/", "\\"), '\\')
      {% else %}
        within?(candidate, base, File::SEPARATOR)
      {% end %}
    end

    # Comparison core; `separator` is the host's canonical separator.
    private def self.within?(candidate : String, base : String, separator : Char) : Bool
      return true if candidate == base
      prefix = base.ends_with?(separator) ? base : base + separator
      candidate.starts_with?(prefix)
    end

    # Pure-string Windows absoluteness test (mirrors the PathAccess one).
    private def self.windows_absolute_path?(path : String) : Bool
      return true if path.starts_with?('/') || path.starts_with?('\\')
      path.size >= 3 && path[0].ascii_letter? && path[1] == ':' &&
        (path[2] == '/' || path[2] == '\\')
    end

    # Normalize a git remote URL into a local absolute path, or nil for
    # non-local remotes (ssh://, https://, git@host:…) that cannot be
    # path-guarded.
    private def self.normalize_repo_path(url : String) : String?
      path = url.strip
      path = path.sub(/^file:\/\//, "")
      local = path.starts_with?('/') || path.starts_with?("\\\\") ||
              windows_absolute_path?(path)
      return nil unless local
      File.expand_path(path)
    end
  end
end
