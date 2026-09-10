module H2code
  module Tools
    class Read < Tool
      MAX_LINES       = 1000
      MAX_LINE_LENGTH = 2000
      MAX_BYTES       = 100 * 1024

      @work_dir : String

      # Retargeted by `/fork` / `/merge` at the idle boundary between turns.
      setter work_dir

      def initialize(@work_dir : String = Dir.current)
      end

      def name : String
        Names::READ
      end

      def description : String
        <<-DESC
        Read a text file from the local filesystem.

        - Relative paths resolve against the working directory; a path outside the working directory must be absolute.
        - Returns up to #{MAX_LINES} lines or #{MAX_BYTES // 1024} KB per call, whichever comes first; lines longer than #{MAX_LINE_LENGTH} chars are truncated.
        - Page larger files with `line_offset` (1-based start line) and `n_lines`. Omit `n_lines` to read up to the #{MAX_LINES}-line cap.
        - Negative `line_offset` reads from the end of the file (-100 reads the last 100 lines); the absolute value cannot exceed #{MAX_LINES}.
        - Sensitive files (`.env`, credential stores, SSH private keys) are refused to protect secrets; `.env.example` and public keys are exempt.
        - Only UTF-8 text files can be read. Non-UTF-8 encodings, binary files, and files containing NUL bytes are refused.
        - Output format: `<line-number>\\t<content>` per line.
        - Pure CRLF files are displayed with LF line endings. Mixed or lone carriage-return line endings are shown as `\\r`.
        DESC
      end

      def parameters : JSON::Any
        JSON.parse(%({
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Path to a text file. Relative paths resolve against the working directory; a path outside the working directory must be absolute. Directories are not supported; use `ls` via Bash for a known directory, or Glob for pattern search."
            },
            "line_offset": {
              "type": "integer",
              "description": "The line number to start reading from (1-based). Omit to start at line 1. Negative values read from the end of the file; the absolute value cannot exceed #{MAX_LINES}."
            },
            "n_lines": {
              "type": "integer",
              "description": "The number of lines to read; the tool also applies its internal cap of #{MAX_LINES} lines."
            }
          },
          "required": ["path"]
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        path = path_arg(input)
        return ToolResult.error("No path provided") if path.empty?

        full_path = begin
          PathAccess.resolve(path, @work_dir, PathAccess::Mode::Read)
        rescue ex : PathAccess::AccessError
          return ToolResult.error(ex.message || "access error")
        end

        return ToolResult.error(%("#{path}" does not exist.)) unless File.exists?(full_path)
        return ToolResult.error(%("#{path}" is not a file.)) unless File.file?(full_path)

        raw = begin
          read_strict_utf8(full_path)
        rescue ex : ArgumentError
          return ToolResult.error(not_readable_message(path))
        rescue ex : IO::Error
          return ToolResult.error("Failed to read file: #{ex.message}")
        end

        return ToolResult.error(not_readable_message(path)) if raw.includes?('\u0000')

        line_offset = line_offset_arg(input)
        requested = n_lines_arg(input)
        effective = {requested, MAX_LINES}.min

        model_view = LineEndings.to_model_view(raw)
        body = model_view.text
        style = model_view.line_ending_style

        all_lines = logical_lines(body)
        total = all_lines.size

        selected, start_line, max_lines_reached =
          if line_offset < 0
            tail_count = {-line_offset, MAX_LINES}.min
            tc = {tail_count, total}.min
            taken_start = total - tc
            taken = all_lines[taken_start...]
            sel = taken.first({effective, taken.size}.min)
            {sel, total > 0 ? taken_start + 1 : 0, false}
          else
            start_idx = {line_offset - 1, 0}.max
            available = total > start_idx ? total - start_idx : 0
            take = {effective, available}.min
            # `Array#[](start, count)` raises IndexError when start > size,
            # so guard the slice for line_offset values past EOF.
            sel = available > 0 ? all_lines[start_idx, take] : [] of String
            ml = effective >= MAX_LINES && start_idx + MAX_LINES <= total
            {sel, sel.empty? ? 0 : start_idx + 1, ml}
          end

        rendered_lines = [] of String
        truncated_lines = [] of Int32
        bytes = 0
        max_bytes_reached = false

        selected.each_with_index do |raw_line, idx|
          line_no = start_line + idx
          content = style.mixed? ? LineEndings.make_cr_visible(raw_line) : raw_line
          if content.size > MAX_LINE_LENGTH
            content = truncate_line(content, MAX_LINE_LENGTH)
            truncated_lines << line_no
          end
          rendered = "#{line_no}\t#{content}"
          line_bytes = rendered.bytesize + (rendered_lines.empty? ? 0 : 1)
          if !rendered_lines.empty? && bytes + line_bytes > MAX_BYTES
            max_bytes_reached = true
            break
          end
          rendered_lines << rendered
          bytes += line_bytes
          if bytes >= MAX_BYTES
            max_bytes_reached = true
            break
          end
        end

        status = status_message(
          start_line: start_line,
          total_lines: total,
          rendered_count: rendered_lines.size,
          requested: requested,
          max_lines_reached: max_lines_reached,
          max_bytes_reached: max_bytes_reached,
          truncated_lines: truncated_lines,
          style: style,
        )

        ToolResult.success(build_output(rendered_lines, status))
      end

      private def path_arg(input : JSON::Any) : String
        (input["path"]? || input["filePath"]?).try(&.to_s) || ""
      end

      private def line_offset_arg(input : JSON::Any) : Int32
        v = (input["line_offset"]? || input["offset"]?).try(&.as_i?) || 1
        return 1 if v == 0
        return {v, -MAX_LINES}.max if v < 0
        v
      end

      private def n_lines_arg(input : JSON::Any) : Int32
        v = (input["n_lines"]? || input["limit"]?).try(&.as_i?) || MAX_LINES
        v <= 0 ? MAX_LINES : v
      end

      # Split the model-view body into logical lines. A trailing newline
      # in the body yields a trailing empty element that should not count
      # as a line; an empty body yields zero lines.
      private def logical_lines(body : String) : Array(String)
        return [] of String if body.empty?
        lines = body.split('\n')
        lines.pop if body.ends_with?('\n') && lines.last == ""
        lines
      end

      private def truncate_line(line : String, max : Int32) : String
        return line if line.size <= max
        marker = "..."
        target = {max, marker.size}.max
        line[0, target - marker.size] + marker
      end

      private def build_output(lines : Array(String), status : String) : String
        io = IO::Memory.new
        unless lines.empty?
          lines.join(io, '\n')
          io << '\n'
        end
        io << "<system>" << status << "</system>"
        io.to_s
      end

      private def status_message(
        *,
        start_line : Int32,
        total_lines : Int32,
        rendered_count : Int32,
        requested : Int32,
        max_lines_reached : Bool,
        max_bytes_reached : Bool,
        truncated_lines : Array(Int32),
        style : LineEndingStyle,
      ) : String
        parts = [] of String
        if rendered_count > 0
          word = rendered_count == 1 ? "line" : "lines"
          parts << "#{rendered_count} #{word} read from file starting from line #{start_line}."
        else
          parts << "No lines read from file."
        end

        parts << "Total lines in file: #{total_lines}."
        if max_lines_reached
          parts << "Max #{MAX_LINES} lines reached."
        elsif max_bytes_reached
          parts << "Max #{MAX_BYTES} bytes reached."
        elsif rendered_count < requested
          parts << "End of file reached."
        end
        unless truncated_lines.empty?
          parts << "Lines [#{truncated_lines.join(", ")}] were truncated."
        end
        if style.mixed?
          parts << "Mixed or lone carriage-return line endings are shown as \\r. Use exact \\r\\n or \\r escapes in Edit.old_string for those lines."
        end
        parts.join(' ')
      end

      # Read the file as strict UTF-8. `String.new(bytes, "UTF-8")` raises
      # `ArgumentError` on invalid byte sequences (unlike `File.read`, which
      # silently replaces them with U+FFFD), so this is the strict path.
      private def read_strict_utf8(path : String) : String
        raw_bytes = File.open(path) do |f|
          io = IO::Memory.new
          IO.copy(f, io)
          io.to_slice
        end
        String.new(raw_bytes, "UTF-8")
      end

      private def not_readable_message(path : String) : String
        %("#{path}" is not readable as UTF-8 text. ) +
          "If it is an image or video, use ReadMediaFile. " +
          "For other binary formats, use Bash or an MCP tool if available."
      end
    end
  end
end
