require "./sensitive"
require "./run_rg"

module H2code
  module Tools
    class Grep < Tool
      DEFAULT_TIMEOUT_S  = 20
      SIGTERM_GRACE_S    =  5
      MAX_OUTPUT_BYTES   = 10 * 1024 * 1024
      DEFAULT_HEAD_LIMIT = 250
      RG_MAX_COLUMNS     = 500

      @work_dir : String

      # Retargeted by `/fork` / `/merge` at the idle boundary between turns.
      setter work_dir

      def initialize(@work_dir : String = Dir.current)
      end

      def name : String
        Names::GREP
      end

      def description : String
        "Search file contents using regular expressions (powered by ripgrep). " \
        "Use Grep when the task is to find unknown content or unknown file locations. " \
        "Do not use shell grep or rg directly; this tool applies output limits and " \
        "sensitive-file filtering. Hidden files (dotfiles) are searched by default. " \
        "Sensitive files (such as .env) are always skipped for safety."
      end

      def parameters : JSON::Any
        JSON.parse(%({
          "type": "object",
          "properties": {
            "pattern": {
              "type": "string",
              "description": "Regular expression to search for."
            },
            "path": {
              "type": "string",
              "description": "File or directory to search. Accepts an absolute path or a path relative to the current working directory. Omit to search the current working directory."
            },
            "glob": {
              "type": "string",
              "description": "Optional glob filter for which files to search, e.g. *.ts. Matched against each file's full absolute path."
            },
            "type": {
              "type": "string",
              "description": "Optional ripgrep file type filter, such as ts or py."
            },
            "output_mode": {
              "type": "string",
              "enum": ["content", "files_with_matches", "count_matches"],
              "description": "Shape of the result. content shows matching lines; files_with_matches shows only file paths; count_matches shows per-file match counts. Defaults to files_with_matches."
            },
            "-i": {
              "type": "boolean",
              "description": "Perform a case-insensitive search. Defaults to false."
            },
            "-n": {
              "type": "boolean",
              "description": "Prefix each matching line with its line number. Applies only when output_mode is content. Defaults to true."
            },
            "-A": {
              "type": "integer",
              "description": "Number of lines to show after each match. Applies only when output_mode is content."
            },
            "-B": {
              "type": "integer",
              "description": "Number of lines to show before each match. Applies only when output_mode is content."
            },
            "-C": {
              "type": "integer",
              "description": "Number of lines to show before and after each match. Takes precedence over -A and -B."
            },
            "head_limit": {
              "type": "integer",
              "description": "Limit output to the first N lines/entries after offset. Defaults to 250. Pass 0 for unlimited."
            },
            "offset": {
              "type": "integer",
              "description": "Number of leading lines/entries to skip before applying head_limit. Defaults to 0."
            },
            "multiline": {
              "type": "boolean",
              "description": "Enable multiline matching, where the pattern can span line boundaries. Defaults to false."
            },
            "include_ignored": {
              "type": "boolean",
              "description": "Also search files excluded by ignore files such as .gitignore. Sensitive files and VCS metadata remain filtered out. Defaults to false."
            }
          },
          "required": ["pattern"]
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        pattern = input["pattern"]?.try(&.to_s) || ""
        return ToolResult.error("No pattern provided") if pattern.empty?

        mode = parse_mode(input["output_mode"]?.try(&.to_s))
        search_path = resolve_search_path(input["path"]?.try(&.to_s))

        cmd = build_rg_args(input, pattern, mode, search_path)

        run_result = run_rg(cmd)

        stdout_text = run_result.stdout
        if run_result.stdout_truncated? || run_result.timed_out?
          stdout_text = omit_incomplete_trailing(stdout_text, mode)
        end
        if run_result.timed_out? && stdout_text.strip.empty?
          return ToolResult.error(
            "Grep timed out after #{DEFAULT_TIMEOUT_S}s. Try a more specific path or pattern.",
          )
        end

        # rg exit codes: 0 = matches, 1 = no matches, 2 = error.
        if run_result.exit_code != 0 && run_result.exit_code != 1 && !run_result.timed_out?
          return ToolResult.error(format_rg_error(run_result))
        end

        raw_lines = parse_rg_output(stdout_text, mode)

        filtered_sensitive = [] of String
        kept = filter_sensitive(raw_lines, mode, filtered_sensitive)

        ordered = ((mode == "files_with_matches" || mode == "count_matches") && !run_result.timed_out?) ? sort_by_mtime(kept) : kept

        offset_val = (input["offset"]?.try(&.as_i?) || 0).to_i32
        head_limit = (input["head_limit"]?.try(&.as_i?) || DEFAULT_HEAD_LIMIT).to_i32
        after_offset = offset_val > 0 ? ordered[offset_val..] || [] of ParsedLine : ordered
        limit_active = head_limit > 0
        limited = limit_active ? slice_at(after_offset, head_limit) : after_offset
        pagination_truncated = limit_active && after_offset.size > head_limit

        header_lines = [] of String
        messages = [] of String

        unless filtered_sensitive.empty?
          displayed = filtered_sensitive.map { |p| relativize(p) }
          messages << "Filtered #{filtered_sensitive.size} sensitive file(s): #{displayed.join(", ")}"
        end

        if mode == "count_matches" && !ordered.empty?
          header_lines << format_count_summary(ordered, !filtered_sensitive.empty?)
        end

        if pagination_truncated
          total = after_offset.size + offset_val
          next_offset = offset_val + head_limit
          notice = "Results truncated to #{head_limit} lines (total: #{total}). Use offset=#{next_offset} to see more."
          mode == "count_matches" ? header_lines << notice : messages << notice
        end

        if run_result.stdout_truncated?
          messages << "[stdout truncated at #{MAX_OUTPUT_BYTES} bytes; incomplete trailing line omitted]"
        end

        if run_result.timed_out?
          messages << "Grep timed out after #{DEFAULT_TIMEOUT_S}s; partial results returned"
        end

        content_includes_ln = mode == "content" && input["-n"]?.try(&.as_bool?) != false
        displayed = limited.map { |line| format_display_line(line, mode, content_includes_ln) }
        content_body = displayed.join('\n')

        visible_body =
          if ordered.empty? && !filtered_sensitive.empty?
            "No non-sensitive matches found"
          elsif content_body.empty?
            filtered_sensitive.empty? ? "No matches found" : "No non-sensitive matches found"
          else
            content_body
          end

        parts = [] of String
        parts.concat(header_lines)
        parts << visible_body unless visible_body.empty?
        parts.concat(messages)
        combined = parts.reject(&.empty?).join('\n')

        ToolResult.success(combined)
      rescue ex : File::NotFoundError
        ToolResult.error("ripgrep (rg) is not available. Install it: brew install ripgrep, apt-get install ripgrep, or see https://github.com/BurntSushi/ripgrep#installation")
      rescue ex
        ToolResult.error("Grep failed: #{ex.message}")
      end

      # ------------------------------------------------------------------
      # Helpers
      # ------------------------------------------------------------------

      private def parse_mode(raw : String?) : String
        case raw
        when "content", "files_with_matches", "count_matches"
          raw.as(String)
        else
          "files_with_matches"
        end
      end

      private def resolve_search_path(raw : String?) : String
        path = raw || @work_dir
        path.starts_with?('/') ? path : File.join(@work_dir, path)
      end

      private def build_rg_args(input : JSON::Any, pattern : String, mode : String, search_path : String) : Array(String)
        cmd = ["rg", "--hidden"]

        if mode != "content"
          cmd << "--max-columns"
          cmd << RG_MAX_COLUMNS.to_s
        end

        cmd << "--null"

        Sensitive::VCS_DIRECTORIES_TO_EXCLUDE.each do |dir|
          cmd << "--glob"
          cmd << "!#{dir}"
        end

        case mode
        when "files_with_matches"
          cmd << "-l"
        when "count_matches"
          cmd << "--count-matches"
          cmd << "--with-filename"
        end

        if input["-i"]?.try(&.as_bool?)
          cmd << "-i"
        end

        if mode == "content"
          cmd << "--with-filename"
          if input["-n"]?.try(&.as_bool?) != false
            cmd << "-n"
          else
            cmd << "--field-context-separator"
            cmd << ":"
          end
          if c = input["-C"]?.try(&.as_i?)
            cmd << "-C"; cmd << c.to_s
          else
            if a = input["-A"]?.try(&.as_i?)
              cmd << "-A"; cmd << a.to_s
            end
            if b = input["-B"]?.try(&.as_i?)
              cmd << "-B"; cmd << b.to_s
            end
          end
        end

        if g = input["glob"]?.try(&.to_s)
          cmd << "--glob"; cmd << g
        end
        if t = input["type"]?.try(&.to_s)
          cmd << "--type"; cmd << t
        end
        if input["multiline"]?.try(&.as_bool?)
          cmd << "-U"; cmd << "--multiline-dotall"
        end
        if input["include_ignored"]?.try(&.as_bool?)
          cmd << "--no-ignore"
        end

        Sensitive.globs_to_exclude.each do |glob|
          cmd << "--glob"
          cmd << "!#{glob}"
        end

        cmd << "--"
        cmd << pattern
        cmd << search_path
        cmd
      end

      # Run rg with timeout and capped stdout/stderr. The binary comes from
      # RunRg.rg_binary (PATH + Homebrew/cargo fallbacks) so a minimal PATH —
      # common on macOS when spawned from a GUI/launchd parent — still works;
      # cmd[0] is only the argv placeholder from build_rg_args.
      private def run_rg(cmd : Array(String)) : RgRunResult
        process = Process.new(
          RunRg.rg_binary, cmd[1..],
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe,
        )

        stdout_ch = Channel({String, Bool}).new
        stderr_ch = Channel({String, Bool}).new

        spawn do
          buf = IO::Memory.new
          truncated = copy_with_cap(process.output, buf, MAX_OUTPUT_BYTES)
          stdout_ch.send({buf.to_s, truncated})
        end

        spawn do
          buf = IO::Memory.new
          truncated = copy_with_cap(process.error, buf, MAX_OUTPUT_BYTES)
          stderr_ch.send({buf.to_s, truncated})
        end

        status_ch = Channel(Process::Status).new
        spawn { status_ch.send(process.wait) }

        deadline = Time.monotonic + DEFAULT_TIMEOUT_S.seconds
        timed_out = false
        aborted = false
        status : Process::Status? = nil

        loop do
          select
          when s = status_ch.receive
            status = s
            break
          when timeout(100.milliseconds)
            if abort_check.call
              aborted = true
              break
            end
            if Time.monotonic >= deadline
              timed_out = true
              break
            end
          end
        end

        if timed_out || aborted
          begin
            PROCESS_PORT.terminate(process)
          rescue
          end
          select
          when s = status_ch.receive
            status = s
          when timeout(SIGTERM_GRACE_S.seconds)
            PROCESS_PORT.force_kill(process)
            status = status_ch.receive
          end
        end

        status = status || raise "process status should not be nil"

        out_pair = stdout_ch.receive
        err_pair = stderr_ch.receive

        exit_code = status.normal_exit? ? status.exit_code : -1

        RgRunResult.new(
          exit_code,
          out_pair[0],
          err_pair[0],
          out_pair[1],
          err_pair[1],
          timed_out,
        )
      end

      private def copy_with_cap(src : IO, dst : IO, max_bytes : Int32) : Bool
        total = 0
        slice = Bytes.new(8192)
        loop do
          read = src.read(slice)
          break if read == 0
          if total + read > max_bytes
            remaining = max_bytes - total
            dst.write(slice[0, remaining]) if remaining > 0
            # Drain the rest without storing to avoid blocking rg.
            loop do
              r = src.read(slice)
              break if r == 0
            end
            return true
          else
            dst.write(slice[0, read])
            total += read
          end
        end
        false
      rescue IO::Error
        # Stream closed prematurely (e.g. process killed during timeout).
        true
      end

      private def format_rg_error(result : RgRunResult) : String
        stderr = result.stderr.strip
        if stderr.empty?
          return "Failed to grep: ripgrep exited with code #{result.exit_code}"
        end
        lines = stderr.lines.map(&.strip).reject(&.empty?)
        summary = lines.reverse.find { |l| l.downcase.starts_with?("error:") } || lines.last? || "ripgrep error"
        msg = ["Failed to grep: #{summary}", "", "ripgrep stderr:", stderr] of String
        if result.stderr_truncated?
          msg << "[stderr truncated at #{MAX_OUTPUT_BYTES} bytes]"
        end
        msg.join('\n')
      end

      # Drop the trailing partial record left by buffer truncation / timeout.
      private def omit_incomplete_trailing(text : String, mode : String) : String
        return "" if text.empty?
        unless text.includes?('\0')
          last_nl = text.rindex('\n')
          return last_nl ? text[0...last_nl] : ""
        end
        if mode == "files_with_matches"
          last_nul = text.rindex('\0')
          return last_nul ? text[0..last_nul] : ""
        end
        last_nl = text.rindex('\n')
        last_nl ? text[0..last_nl] : ""
      end

      # ------------------------------------------------------------------
      # Output parsing
      # ------------------------------------------------------------------

      private def parse_rg_output(text : String, mode : String) : Array(ParsedLine)
        return [] of ParsedLine if text.empty?

        unless text.includes?('\0')
          return split_rg_lines(text).map do |line|
            mode == "content" && line == "--" ? ParsedLine.separator : ParsedLine.legacy(line)
          end
        end

        if mode == "files_with_matches"
          return text.split('\0')
            .map { |p| strip_cr(p) }
            .reject(&.empty?)
            .map { |p| ParsedLine.record(p, "") }
        end

        # content / count_matches: each line is path\0payload
        records = [] of ParsedLine
        text.each_line(chomp: true) do |line|
          if mode == "content" && line == "--"
            records << ParsedLine.separator
            next
          end
          nul_idx = line.index('\0')
          if nul_idx
            records << ParsedLine.record(line[0...nul_idx], line[(nul_idx + 1)..])
          else
            records << ParsedLine.legacy(line) unless line.empty?
          end
        end
        records
      end

      private def split_rg_lines(text : String) : Array(String)
        return [] of String if text.empty?
        lines = text.split('\n')
        while !lines.empty? && lines.last.empty?
          lines.pop
        end
        lines.map { |l| strip_cr(l) }
      end

      private def strip_cr(s : String) : String
        s.ends_with?('\r') ? s[0...-1] : s
      end

      # ------------------------------------------------------------------
      # Sensitive filtering
      # ------------------------------------------------------------------

      private def filter_sensitive(lines : Array(ParsedLine), mode : String, filtered : Array(String)) : Array(ParsedLine)
        kept = [] of ParsedLine
        lines.each do |line|
          if line.kind.separator?
            kept << line
            next
          end
          fp = parsed_file_path(line, mode)
          if fp && Sensitive.sensitive?(fp)
            filtered << fp
          else
            kept << line
          end
        end
        mode == "content" ? normalize_separators(kept) : kept
      end

      private def normalize_separators(lines : Array(ParsedLine)) : Array(ParsedLine)
        normalized = [] of ParsedLine
        lines.each do |line|
          next if line.kind.separator? && (normalized.empty? || normalized.last.kind.separator?)
          normalized << line
        end
        while !normalized.empty? && normalized.last.kind.separator?
          normalized.pop
        end
        normalized
      end

      private def parsed_file_path(line : ParsedLine, mode : String) : String?
        case line.kind
        when .record?
          line.file_path
        when .separator?
          nil
        else
          text = line.text
          case mode
          when "files_with_matches"
            text
          when "count_matches"
            idx = text.rindex(':')
            idx && idx > 0 ? text[0...idx] : text
          else
            extract_content_path(text)
          end
        end
      end

      private def extract_content_path(line : String) : String?
        if m = line.match(/^(.*?)([:-])\d+[:-]/)
          return m[1]?
        end
        idx = line.index(':')
        idx && idx > 0 ? line[0...idx] : nil
      end

      # ------------------------------------------------------------------
      # Sorting / pagination helpers
      # ------------------------------------------------------------------

      private def sort_by_mtime(lines : Array(ParsedLine)) : Array(ParsedLine)
        entries = lines.map_with_index do |line, idx|
          fp = parsed_file_path(line, "files_with_matches") || ""
          mtime = 0_i64
          unless fp.empty?
            mtime = begin
              File.info(fp).modification_time.to_unix
            rescue
              0_i64
            end
          end
          {line, mtime, idx}
        end
        entries.sort! { |a, b| (b[1] <=> a[1]) || (a[2] <=> b[2]) }
        entries.map(&.[0])
      end

      private def slice_at(arr : Array(ParsedLine), n : Int32) : Array(ParsedLine)
        arr.size > n ? arr[0...n] : arr
      end

      # ------------------------------------------------------------------
      # Display formatting
      # ------------------------------------------------------------------

      private def format_display_line(line : ParsedLine, mode : String, content_includes_ln : Bool) : String
        return "--" if line.kind.separator?

        if line.kind.record?
          display_path = relativize(line.file_path)
          case mode
          when "files_with_matches"
            return display_path
          when "count_matches"
            return "#{display_path}:#{line.payload}"
          else
            sep = content_includes_ln ? content_payload_sep(line.payload) : ":"
            return "#{display_path}#{sep}#{line.payload}"
          end
        end

        # Legacy
        text = line.text
        case mode
        when "files_with_matches"
          relativize(text)
        when "count_matches"
          if idx = text.rindex(':')
            idx > 0 ? relativize(text[0...idx]) + text[idx..] : text
          else
            text
          end
        else
          if fp = extract_content_path(text)
            relativize(fp) + text[fp.size..]
          else
            text
          end
        end
      end

      private def content_payload_sep(payload : String) : String
        if m = payload.match(/^\d+([:-])/)
          m[1]? || ":"
        else
          ":"
        end
      end

      private def format_count_summary(lines : Array(ParsedLine), redacted_sensitive : Bool) : String
        total_matches = 0
        total_files = 0
        lines.each do |line|
          raw =
            case line.kind
            when .record?
              line.payload
            when .legacy?
              count_payload_from_legacy(line.text)
            else
              nil
            end
          next if raw.nil?
          count = raw.to_i? || -1
          next if count < 0
          total_matches += count
          total_files += 1
        end
        occ_word = total_matches == 1 ? "occurrence" : "occurrences"
        file_word = total_files == 1 ? "file" : "files"
        scope = redacted_sensitive ? "total non-sensitive" : "total"
        "Found #{total_matches} #{scope} #{occ_word} across #{total_files} #{file_word}."
      end

      private def count_payload_from_legacy(line : String) : String?
        idx = line.rindex(':')
        idx && idx > 0 ? line[(idx + 1)..] : nil
      end

      private def relativize(path : String) : String
        abs = File.expand_path(path, @work_dir)
        work = File.expand_path(@work_dir)
        return "." if abs == work
        prefix = work.ends_with?('/') ? work : work + "/"
        return abs[prefix.size..] if abs.starts_with?(prefix)
        abs
      end

      # ------------------------------------------------------------------
      # Internal types
      # ------------------------------------------------------------------

      enum GrepLineKind
        Record
        Separator
        Legacy
      end

      struct ParsedLine
        getter kind : GrepLineKind
        getter file_path : String
        getter payload : String
        getter text : String

        def initialize(@kind : GrepLineKind, @file_path : String = "", @payload : String = "", @text : String = "")
        end

        def self.record(file_path : String, payload : String) : ParsedLine
          new(GrepLineKind::Record, file_path, payload)
        end

        def self.separator : ParsedLine
          new(GrepLineKind::Separator)
        end

        def self.legacy(text : String) : ParsedLine
          new(GrepLineKind::Legacy, text: text)
        end
      end

      struct RgRunResult
        getter exit_code : Int32
        getter stdout : String
        getter stderr : String
        getter? stdout_truncated : Bool
        getter? stderr_truncated : Bool
        getter? timed_out : Bool

        def initialize(@exit_code : Int32, @stdout : String, @stderr : String,
                       @stdout_truncated : Bool, @stderr_truncated : Bool, @timed_out : Bool)
        end
      end
    end
  end
end
