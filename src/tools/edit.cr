module H2code
  module Tools
    # Edit — exact string replacement in a file.
    #
    # Contract ported from `packages/agent-core/src/tools/builtin/file/edit.ts`:
    #
    #   * Parameters: `path`, `old_string`, `new_string`, `replace_all`.
    #     Legacy `filePath` / `oldString` / `newString` / `replaceAll` names
    #     still work so older prompt templates / sessions don't break.
    #   * Default (`replace_all=false`): replace the first occurrence; error
    #     if `old_string` is not found or not unique.
    #   * `replace_all=true`: replace every occurrence; error if none found.
    #   * `old_string == new_string` is rejected with "no changes".
    #   * CRLF line endings: model view folds `\r\n` to `\n`; on write, LF is
    #     turned back into CRLF for pure-CRLF files.
    #   * Path access policy blocks sensitive files (`.env`, SSH keys, ...).
    class Edit < Tool
      @work_dir : String

      # Retargeted by `/fork` / `/merge` at the idle boundary between turns.
      setter work_dir

      def initialize(@work_dir : String = Dir.current)
      end

      def name : String
        Names::EDIT
      end

      def description : String
        "Performs an exact string replacement in a file. old_string must appear exactly once unless replace_all is true. " \
        "Read the file first and match it verbatim (drop any line-number prefix). " \
        "For pure CRLF files, pass LF in old_string/new_string and Edit writes CRLF back."
      end

      def parameters : JSON::Any
        JSON.parse(%({
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Path to the text file to edit. Relative paths resolve against the working directory; a path outside the working directory must be absolute."
            },
            "old_string": {
              "type": "string",
              "description": "Exact content to replace from the Read output view, without the line-number prefix. Use LF for pure CRLF files; use actual \\\\r escapes where Read shows \\\\r."
            },
            "new_string": {
              "type": "string",
              "description": "Replacement text in the same Read output view. LF is written back as CRLF only for pure CRLF files."
            },
            "replace_all": {
              "type": "boolean",
              "description": "Set true only when every occurrence of old_string should be replaced."
            }
          },
          "required": ["path", "old_string", "new_string"]
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        path = read_string(input, "path", "filePath")
        old_str = read_string(input, "old_string", "oldString")
        new_str = read_string(input, "new_string", "newString")
        replace_all = read_bool(input, "replace_all", "replaceAll", default: false)

        return ToolResult.error("No path provided") if path.empty?
        # old_string must be non-empty: the non-replace_all branch walks
        # occurrences and would loop forever on an empty search string.
        return ToolResult.error("No old_string provided") if old_str.empty?

        full_path = begin
          PathAccess.resolve(path, @work_dir, PathAccess::Mode::Write)
        rescue ex : PathAccess::AccessError
          return ToolResult.error(ex.message || "access error")
        end
        return ToolResult.error("File not found: #{path}") unless File.exists?(full_path)
        return ToolResult.error("#{path} is not a file.") unless File.file?(full_path)

        if old_str == new_str
          return ToolResult.error("No changes to make: old_string and new_string are exactly the same.")
        end

        begin
          raw = File.read(full_path)
          model_view = LineEndings.to_model_view(raw)
          content = model_view.text

          if replace_all
            count = count_occurrences(content, old_str)
            if count == 0
              return ToolResult.error(not_found_message(path))
            end

            new_content = content.split(old_str).join(new_str)
            File.write(full_path, LineEndings.materialize(new_content, model_view.line_ending_style))
            build_edit_result("Replaced #{count} occurrences in #{path}", path, old_str, new_str)
          else
            count = count_occurrences(content, old_str)
            case count
            when 0
              ToolResult.error(not_found_message(path))
            when 1
              new_content = replace_once(content, old_str, new_str)
              File.write(full_path, LineEndings.materialize(new_content, model_view.line_ending_style))
              build_edit_result("Edited #{path}", path, old_str, new_str)
            else
              ToolResult.error(
                "old_string is not unique in #{path} (found #{count} occurrences). " \
                "To replace every occurrence, set replace_all=true. " \
                "To replace only one occurrence, include more surrounding context in old_string.")
            end
          end
        rescue ex : IO::Error
          ToolResult.error("Failed to edit file: #{ex.message}")
        end
      end

      private def count_occurrences(content : String, needle : String) : Int32
        count = 0
        pos = 0
        while pos <= content.size
          idx = content.index(needle, pos)
          break unless idx
          count += 1
          pos = idx + needle.size
        end
        count
      end

      private def replace_once(content : String, old_str : String, new_str : String) : String
        idx = content.index(old_str)
        return content unless idx
        content[0, idx] + new_str + content[idx + old_str.size..]
      end

      private def not_found_message(path : String) : String
        "old_string not found in #{path}, the file contents may be out of date. " \
        "Please use the Read Tool to reload the content."
      end

      # Build a successful Edit result and attach a structured `file_io`
      # display so the TUI can render the diff without re-parsing `tool_args`
      # (which is brittle w.r.t. argument key naming).
      private def build_edit_result(message : String, path : String,
                                    old_str : String, new_str : String) : ToolResult
        res = ToolResult.success(message)
        res.display = ToolDisplay.new("file_io", "edit", path, old_str, new_str)
        res
      end

      private def read_string(input : JSON::Any, primary : String, legacy : String) : String
        input[primary]?.try(&.to_s) || input[legacy]?.try(&.to_s) || ""
      end

      private def read_bool(input : JSON::Any, primary : String, legacy : String, default : Bool) : Bool
        input[primary]?.try(&.as_bool?) || input[legacy]?.try(&.as_bool?) || default
      end
    end
  end
end
