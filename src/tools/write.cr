module H2code
  module Tools
    class Write < Tool
      @work_dir : String

      # `/fork` into a worktree (and `/merge` back) retarget this at the
      # idle boundary between turns.
      setter work_dir

      def initialize(@work_dir : String = Dir.current)
      end

      def name : String
        Names::WRITE
      end

      def description : String
        "Create, append to, or replace a file entirely. Missing parent directories are created automatically. mode defaults to overwrite; append adds content at EOF without adding a newline. Write is NOT ALLOWED for incremental edits — use Edit instead."
      end

      def parameters : JSON::Any
        JSON.parse(%({
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Path to the file to create, append to, or completely overwrite. Relative paths resolve against the working directory; a path outside the working directory must be absolute. Missing parent directories are created automatically."
            },
            "content": {
              "type": "string",
              "description": "Raw full file content to write exactly as provided. This does not use the Read/Edit text view."
            },
            "mode": {
              "type": "string",
              "enum": ["overwrite", "append"],
              "description": "Write mode. Defaults to overwrite. append adds content to the end exactly as provided and does not add a newline."
            }
          },
          "required": ["path", "content"]
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        path = input["path"]?.try(&.to_s) || ""
        content = input["content"]?.try(&.to_s) || ""
        mode = input["mode"]?.try(&.to_s) || "overwrite"

        return ToolResult.error("No path provided") if path.empty?

        full_path = begin
          PathAccess.resolve(path, @work_dir, PathAccess::Mode::Write)
        rescue ex : PathAccess::AccessError
          return ToolResult.error(ex.message || "access error")
        end

        parent_error = ensure_parent_directory(full_path)
        return ToolResult.error(parent_error) if parent_error

        begin
          if mode == "append"
            File.write(full_path, content, mode: "a")
            verb = "Appended"
          else
            File.write(full_path, content)
            verb = "Wrote"
          end
          # Report the number of UTF-8 bytes this call wrote to disk. The
          # string size would only equal the byte count for pure ASCII, so
          # bytesize is used instead.
          bytes_written = content.bytesize
          ToolResult.success("#{verb} #{bytes_written} bytes to #{path}")
        rescue ex : IO::Error | File::Error
          ToolResult.error("Failed to write #{path}: #{ex.message}")
        end
      end

      # Best-effort check that the parent directory is usable, creating it
      # when it is missing. An existing parent that is not a directory is a
      # hard error. Returns an error string when the precondition is
      # violated, or nil otherwise.
      private def ensure_parent_directory(full_path : String) : String?
        parent = File.dirname(full_path)
        return nil if File.directory?(parent)
        if File.exists?(parent)
          return "Parent path is not a directory: #{parent}."
        end
        begin
          Dir.mkdir_p(parent)
          nil
        rescue ex : IO::Error | File::Error
          ex.message || "Failed to create parent directory: #{parent}"
        end
      end
    end
  end
end
