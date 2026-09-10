# Fork-sandbox write confinement gate used by Mode::Write resolution below.
module H2code
  module Tools
    # Path resolution + sensitive-file detection for the builtin tools.
    #
    # Goals (mirrors the JS layer in `tools/policies/path-access.ts` and
    # `tools/policies/sensitive.ts`):
    #
    #   * Resolve a user-supplied path (relative to `work_dir`, or absolute)
    #     without following symlinks. `..` segments are folded lexically so
    #     a path that escapes the workspace is detectable before any I/O.
    #   * Block credential / secret filenames (`.env`, `id_rsa`, cloud
    #     credential stores, and rename-shielded variants) so a compromised
    #     prompt cannot exfiltrate them. Public-key and `.env.example`
    #     exemptions are honored.
    #   * Allow absolute paths *outside* the workspace for read / search /
    #     write — the agent may need to read `/etc/hosts` or grep another
    #     checkout. Relative `..` escapes stay rejected.
    #
    # Sensitive-file detection delegates to the `Sensitive` module so the
    # pattern list has a single source of truth shared with Glob/Grep.
    module PathAccess
      enum Mode
        Read
        Write
        Search
      end

      # Raised when a path escapes the workspace, targets a sensitive
      # file, or is otherwise invalid. Mirrors `PathSecurityError` in
      # the TS agent-core; the codes stay comparable across implementations.
      class AccessError < Exception
        getter code : String
        getter raw_path : String
        getter canonical_path : String

        def initialize(@code : String, @raw_path : String, @canonical_path : String, message : String)
          super(message)
        end
      end

      # Delegates to `Sensitive.sensitive?` so callers can use either name.
      def self.sensitive?(path : String) : Bool
        Sensitive.sensitive?(path)
      end

      # Lexical canonicalization: resolve relative → absolute against `cwd`,
      # expand `~`, and fold `.` / `..` segments without touching the
      # filesystem (so it works for paths that do not exist yet, e.g. Write
      # targets).
      #
      # Raises `AccessError` (`PATH_INVALID`) for empty input.
      def self.canonicalize(path : String, cwd : String) : String
        if path.empty?
          raise AccessError.new("PATH_INVALID", path, path, "Path cannot be empty")
        end

        expanded = expand_user(path)
        File.expand_path(expanded, cwd)
      end

      # True iff `candidate` is absolute for the host filesystem:
      # POSIX — rooted at `/`; Windows — drive-absolute (`C:\f` or
      # `C:/f`), UNC (`\\server\share\f`), or rooted at the current
      # drive (`\f`, `/f`). Note `File::SEPARATOR` is `'/'` on *all*
      # platforms in Crystal, so it alone cannot detect Windows forms.
      def self.absolute_path?(path : String) : Bool
        {% if flag?(:win32) %}
          windows_absolute_path?(path)
        {% else %}
          path.starts_with?(File::SEPARATOR)
        {% end %}
      end

      # Pure-string Windows absoluteness test, compiled on every host so
      # the Windows logic stays unit-testable from POSIX. `C:foo`
      # (drive-relative, no separator after the colon) deliberately
      # stays non-absolute.
      def self.windows_absolute_path?(path : String) : Bool
        return true if path.starts_with?('/') || path.starts_with?('\\')
        path.size >= 3 && path[0].ascii_letter? && path[1] == ':' &&
          (path[2] == '/' || path[2] == '\\')
      end

      # Windows paths compare case-insensitively and treat `/` and `\`
      # as equivalent separators. Canonical forms may mix them — e.g.
      # `cwd` reported with forward slashes vs a `File.expand_path`
      # result normalized to backslashes — so both sides are folded to
      # a canonical form before any string comparison.
      def self.windows_comparison_form(path : String) : String
        path.downcase.tr("/", "\\")
      end

      # True iff `candidate` is `base` itself or a descendant of it,
      # compared on path-component boundaries. Shared-prefix escapes
      # (a path like `/workspace-evil` against base `/workspace`) are
      # blocked by requiring a separator (or exact equality) after the
      # base prefix. Both arguments must already be canonical.
      def self.within_directory?(candidate : String, base : String) : Bool
        {% if flag?(:win32) %}
          within_directory?(
            windows_comparison_form(candidate),
            windows_comparison_form(base),
            '\\',
          )
        {% else %}
          within_directory?(candidate, base, File::SEPARATOR)
        {% end %}
      end

      # Comparison core shared by both platforms; `separator` is the
      # host's canonical separator (`'\\'` on Windows, `'/'` on POSIX).
      # Public (3-arg overload) so the Windows comparison path is
      # unit-testable on POSIX hosts.
      def self.within_directory?(candidate : String, base : String, separator : Char) : Bool
        return true if candidate == base
        prefix = base.ends_with?(separator) ? base : base + separator
        candidate.starts_with?(prefix)
      end

      # Main entry point. Returns the canonical absolute path when the
      # check passes, raises `AccessError` otherwise.
      #
      # `mode` controls the wording of the "outside workspace" message
      # (and parallels the JS `PathAccessOperation`). `check_sensitive`
      # toggles the sensitive-file block (default true — disable only
      # for tools that must traverse all files, e.g. Glob with
      # `include_ignored`).
      def self.resolve(path : String, cwd : String, mode : Mode = Mode::Write, *, check_sensitive : Bool = true) : String
        raw_is_absolute = absolute_path?(path)
        canonical = canonicalize(path, cwd)

        if check_sensitive && mode != Mode::Search && Sensitive.sensitive?(canonical)
          raise AccessError.new(
            "PATH_SENSITIVE",
            path, canonical,
            %("#{path}" matches a sensitive-file pattern (env / credential / SSH key). Access is blocked to protect secrets.),
          )
        end

        # Fork-sandbox confinement: a /fork session must never write into
        # the original repository its sandbox was cloned from — not even
        # via an absolute path outside the workspace.
        if mode == Mode::Write
          if reason = Sandbox.write_block_reason(canonical, cwd)
            raise AccessError.new("PATH_SANDBOX_WRITE", path, canonical, reason)
          end
        end

        outside = !within_directory?(canonical, canonicalize(cwd, cwd))
        if outside && !raw_is_absolute
          raise AccessError.new(
            "PATH_OUTSIDE_WORKSPACE",
            path, canonical,
            %("#{path}" is not an absolute path. You must provide an absolute path to #{mode_verb(mode)} outside the working directory.),
          )
        end

        canonical
      end

      private def self.expand_user(path : String) : String
        home = HomePort.home

        return home if path == "~"
        tilde_sep = {% if flag?(:win32) %} path.starts_with?("~\\") {% else %} false {% end %}
        return File.join(home, path[2..]) if path.starts_with?("~/") || tilde_sep

        path
      end

      private def self.mode_verb(mode : Mode) : String
        case mode
        when Mode::Write  then "write or edit a file"
        when Mode::Search then "search"
        else                   "read a file"
        end
      end
    end
  end
end

# Loaded after PathAccess is defined (same pattern as home_port.cr): the
# Mode::Write gate above calls into the Sandbox confinement module.
require "../sandbox"
