module H2code
  module Tools
    # Glob — file pattern matching via ripgrep.
    #
    # Ported from `packages/agent-core/src/tools/builtin/file/glob.ts`.
    # Finds files matching a glob pattern, returned sorted by modification
    # time (most recent first). Implemented by shelling out to
    # `rg --files` — sharing the ripgrep binary, subprocess plumbing, and
    # gitignore / sensitive-file handling with Grep.
    #
    # Output convention: content shown to the LLM is relativized to the
    # search base only when the base is inside the workspace. External
    # roots stay absolute so downstream Read/Edit target the same file.
    class Glob < Tool
      MAX_MATCHES = 100

      @work_dir : String

      # Retargeted by `/fork` / `/merge` at the idle boundary between turns.
      setter work_dir

      def initialize(@work_dir : String = Dir.current)
      end

      def name : String
        Names::GLOB
      end

      def description : String
        "Find files by glob pattern, sorted by modification time (most recent first). " \
        "Powered by ripgrep. Respects `.gitignore`, `.ignore`, and `.rgignore` by default — " \
        "set `include_ignored` to also match ignored files (e.g. build outputs, node_modules). " \
        "Sensitive files (such as `.env`) are always filtered out. Results are files only — directories are never listed. " \
        "Good patterns: `*.ts` (recursive by extension), `src/*.ts` (one level), `src/**/*.ts` (recursive walk with anchor), " \
        "`*.{ts,tsx}` (brace expansion). " \
        "`limit` caps the number of results (default #{MAX_MATCHES}); `offset` skips the first N results for pagination."
      end

      def parameters : JSON::Any
        JSON.parse(%({
          "type": "object",
          "properties": {
            "pattern": {
              "type": "string",
              "description": "Glob pattern to match files"
            },
            "path": {
              "type": "string",
              "description": "Directory to search. Accepts an absolute path, or a path relative to the current working directory. Defaults to the current working directory."
            },
            "include_ignored": {
              "type": "boolean",
              "description": "Also match files excluded by ignore files such as `.gitignore`, `.ignore`, and `.rgignore` (e.g. node_modules or build outputs). Sensitive files (such as `.env`) remain filtered out for safety. VCS metadata directories (`.git` and similar) are always skipped, even when this is true. Defaults to false."
            },
            "include_dirs": {
              "type": "boolean",
              "description": "Deprecated and ignored. Results are always files-only — directories are never listed."
            },
            "limit": {
              "type": "integer",
              "description": "Caps the number of results. Defaults to #{MAX_MATCHES}."
            },
            "offset": {
              "type": "integer",
              "description": "Skips the first N results before applying limit — use for pagination. Defaults to 0."
            }
          },
          "required": ["pattern"]
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        pattern = input["pattern"]?.try(&.to_s) || ""
        return ToolResult.error("No pattern provided") if pattern.empty?

        base = input["path"]?.try(&.to_s) || @work_dir
        include_ignored = input["include_ignored"]?.try(&.as_bool?) || false

        # PathAccess::Search allows absolute paths outside the workspace
        # (e.g. grep `/etc` or another checkout), but rejects relative
        # paths that escape via `..`. Sensitive check is off here because
        # the *search root* itself is not sensitive; per-file sensitive
        # filtering runs later on rg's output.
        begin
          search_root = PathAccess.resolve(base, @work_dir, PathAccess::Mode::Search,
            check_sensitive: false)
        rescue ex : PathAccess::AccessError
          return ToolResult.error(ex.message || "access error")
        end
        return ToolResult.error("#{base} does not exist") unless File.exists?(search_root)
        return ToolResult.error("#{base} is not a directory") unless File.directory?(search_root)

        run_result = run_rg(build_rg_args(include_ignored), search_root)

        # rg exit codes: 0 = matches, 1 = no matches, 2+ = error. Timeout
        # kills usually surface as a signal exit code; keep any partial paths.
        # If rg returned complete paths before failing on a traversal error
        # (unreadable subdirectory), keep those paths and surface a warning.
        traversal_warning : String? = nil
        if run_result.exit_code != 0 && run_result.exit_code != 1 && !run_result.timed_out
          raw_before_error = split_complete_paths(run_result.stdout_text, truncated_output: true)
          if raw_before_error.empty?
            return ToolResult.error(format_glob_error(search_root, run_result.stderr_text))
          end
          traversal_warning = format_glob_warning(run_result.stderr_text)
        end

        # rg reports paths relative to its cwd (the search root),
        # e.g. `./src/a.ts`; resolve them back to absolute paths so the
        # pattern match, sensitive-file check, workspace relativization,
        # and display all keep working on absolute paths.
        raw_paths = split_complete_paths(
          run_result.stdout_text,
          truncated_output: run_result.buffer_truncated || run_result.timed_out,
        ).map { |p| File.expand_path(p, search_root) }

        # Apply the user's pattern post-hoc (see build_rg_args for why we
        # don't pass it as a positive --glob to rg). Sensitive files are
        # filtered in the same pass so the per-file filtered count is
        # accurate.
        kept = [] of String
        filtered_sensitive = 0
        raw_paths.each do |p|
          rel = relative_to_search_root(p, search_root)
          unless match_pattern?(pattern, rel)
            next
          end
          if Sensitive.sensitive?(p)
            filtered_sensitive += 1
          else
            kept << p
          end
        end

        # Pagination: `offset` skips the first N matches, `limit` caps the
        # page size (mirrors the Grep head_limit/offset semantics).
        offset_val = (input["offset"]?.try(&.as_i?) || 0).to_i32
        offset_val = 0 if offset_val < 0
        limit = (input["limit"]?.try(&.as_i?) || MAX_MATCHES).to_i32
        limit = MAX_MATCHES if limit < 0
        total = kept.size
        after_offset = offset_val > 0 ? kept[offset_val..]? || [] of String : kept
        limit_active = limit > 0
        limited = limit_active ? after_offset.first(limit) : after_offset
        truncated = limit_active && after_offset.size > limit

        if kept.empty? && !run_result.timed_out
          if filtered_sensitive > 0
            return ToolResult.success(
              "No non-sensitive matches found (#{filtered_sensitive} sensitive file(s) filtered)."
            )
          end
          return ToolResult.success("No matches found")
        end

        if limited.empty? && total > 0 && !run_result.timed_out
          return ToolResult.success("No more matches (offset #{offset_val} >= #{total} total).")
        end

        # Relativize to the search base only when the base is inside the
        # workspace. External roots stay absolute to keep follow-up Read
        # /Edit calls on the same file.
        should_relativize = PathAccess.within_directory?(search_root, @work_dir)
        display_lines = limited.map do |p|
          should_relativize ? relativize_if_under(p, search_root) : p
        end

        lines = [] of String
        if run_result.timed_out
          lines << "Glob timed out after #{RunRg::DEFAULT_TIMEOUT_S}s; partial results returned."
        end
        if run_result.buffer_truncated
          lines << "[stdout truncated at #{RunRg::MAX_OUTPUT_BYTES} bytes; results may be incomplete — use a more specific pattern]"
        end
        if warning = traversal_warning
          lines << warning
        end
        if truncated
          next_offset = offset_val + limit
          lines << "[Truncated at #{limit} matches — use a more specific pattern, or offset=#{next_offset} to page]"
          lines << "Only the first #{limit} matches are returned."
        end
        lines.concat(display_lines)
        if filtered_sensitive > 0
          lines << "Filtered #{filtered_sensitive} sensitive file(s)."
        end
        if !truncated && limit_active && limited.size == limit
          lines << "Found #{limited.size} matches"
        end
        ToolResult.success(lines.join('\n'))
      rescue ex : RunRg::RgUnavailableError
        ToolResult.error(
          "ripgrep (rg) is not available. Install it: brew install ripgrep, " \
          "apt-get install ripgrep, or see " \
          "https://github.com/BurntSushi/ripgrep#installation")
      end

      # ------------------------------------------------------------------
      # Helpers
      # ------------------------------------------------------------------

      # Build the `rg` argv (without the binary name — `RunRg.run` prepends
      # `rg`). The user's positive `pattern` is intentionally NOT passed to
      # rg as a `--glob`: a positive `--glob` overrides `.gitignore`
      # (documented rg semantics — "This always overrides any other ignore
      # logic"). To respect `.gitignore` by default and still apply the
      # user's pattern, we let rg return all non-ignored files and then
      # filter by the pattern in Crystal (`match_pattern?`).
      #
      # `--no-require-git` makes `.gitignore` / `.ignore` / `.rgignore`
      # honored even when the search root is not inside a real git checkout
      # (matches user expectation outside of git repos).
      private def build_rg_args(include_ignored : Bool) : Array(String)
        cmd = ["--files", "--hidden", "--sortr=modified", "--no-require-git"]
        Sensitive::VCS_DIRECTORIES_TO_EXCLUDE.each do |dir|
          cmd << "--glob"
          cmd << "!#{dir}"
        end
        cmd << "--no-ignore" if include_ignored
        cmd << "."
        cmd
      end

      # Match `pattern` against `rel_path` (both relative to the search root).
      # Implements the standard glob semantics that `File.match?` gets wrong:
      #   * `**/` matches zero or more intermediate directories
      #         (so `src/**/*.ts` matches both `src/a.ts` and `src/sub/b.ts`)
      #   * `*`   matches any run of non-`/` characters
      #   * `?`   matches a single non-`/` character
      #   * `{a,b}` brace expansion → alternation
      private def match_pattern?(pattern : String, rel_path : String) : Bool
        rel = rel_path.starts_with?("./") ? rel_path[2..] : rel_path
        return true if rel == pattern
        regex = glob_to_regex(pattern)
        !!(regex =~ rel)
      end

      # Convert a glob pattern to an anchored Regex.
      private def glob_to_regex(pattern : String) : Regex
        s = String::Builder.new
        s << '^'
        emit_glob_fragment(s, pattern)
        s << '$'
        Regex.new(s.to_s)
      end

      # Translate a glob fragment into regex text appended to `s` (no
      # anchors). Recursed into for each `{a,b}` alternation part so that
      # wildcards inside braces (`{.github/**,deploy*,*.sh}`) are
      # translated rather than emitted as raw (invalid) regex.
      private def emit_glob_fragment(s : String::Builder, fragment : String) : Nil
        i = 0
        size = fragment.size
        while i < size
          if i + 2 < size && fragment[i, 3] == "**/"
            # `**/` matches zero or more directory segments
            s << "(?:[^/]+/)*"
            i += 3
          elsif i + 1 < size && fragment[i, 2] == "**"
            s << ".*"
            i += 2
          elsif fragment[i] == '*'
            s << "[^/]*"
            i += 1
          elsif fragment[i] == '?'
            s << "[^/]"
            i += 1
          elsif fragment[i] == '{'
            end_idx = fragment.index('}', i + 1)
            if end_idx
              contents = fragment[(i + 1)...end_idx]
              s << "(?:"
              # alternation: a,b,c → a|b|c
              first = true
              contents.split(',').each do |part|
                s << '|' unless first
                first = false
                emit_glob_fragment(s, part)
              end
              s << ")"
              i = end_idx + 1
            else
              s << "\\{"
              i += 1
            end
          elsif fragment[i] == '['
            # Character class: [abc] / [a-z], [!...] negation.
            end_idx = fragment.index(']', i + 1)
            if end_idx && end_idx > i + 1
              contents = fragment[(i + 1)...end_idx]
              negated = contents.starts_with?('!')
              contents = contents[1..] if negated
              s << (negated ? "[^" : "[")
              first = true
              contents.each_char do |ch|
                # Escape a leading `^` (would negate in regex) and
                # backslashes; `-` stays literal so ranges keep working.
                s << '\\' if ch == '\\' || (ch == '^' && first)
                s << ch
                first = false
              end
              s << "]"
              i = end_idx + 1
            else
              s << "\\["
              i += 1
            end
          elsif regex_meta?(fragment[i])
            s << '\\'
            s << fragment[i]
            i += 1
          else
            s << fragment[i]
            i += 1
          end
        end
      end

      private def regex_meta?(c : Char) : Bool
        "\\^$.|+()?[]{}".includes?(c)
      end

      # Compute `abs_path` relative to `search_root` (inverse of
      # `File.expand_path(p, search_root)`).
      private def relative_to_search_root(abs_path : String, search_root : String) : String
        prefix = search_root.ends_with?(File::SEPARATOR) ? search_root : "#{search_root}#{File::SEPARATOR}"
        abs_path.starts_with?(prefix) ? abs_path[prefix.size..] : abs_path
      end

      private def run_rg(args : Array(String), search_root : String) : RunRg::Result
        RunRg.run(args, chdir: search_root, aborted?: abort_check)
      end

      private def split_complete_paths(stdout_text : String, *, truncated_output : Bool) : Array(String)
        text = stdout_text
        if truncated_output && !text.ends_with?('\n')
          last_newline = text.rindex('\n')
          text = last_newline ? text[0..last_newline] : ""
        end
        text.split('\n').reject(&.empty?)
      end

      private def format_glob_error(search_root : String, stderr : String) : String
        trimmed = stderr.strip
        return "#{search_root} does not exist" if /no such file or directory/i.matches?(trimmed)
        trimmed.empty? ? "Glob failed" : "Glob failed: #{trimmed}"
      end

      private def format_glob_warning(stderr : String) : String
        trimmed = stderr.strip
        trimmed.empty? ? "Glob completed with warnings; some directories could not be read." : "Glob completed with warnings; some directories could not be read: #{trimmed}"
      end

      private def relativize_if_under(candidate : String, base : String) : String
        return "." if candidate == base
        prefix = base.ends_with?(File::SEPARATOR) ? base : "#{base}#{File::SEPARATOR}"
        candidate.starts_with?(prefix) ? candidate[prefix.size..] : candidate
      end
    end
  end
end
