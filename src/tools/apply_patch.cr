require "json"

module H2code
  module Tools
    # ApplyPatch — multi-file diff editing in the codex "V4A" patch format.
    #
    # A single call can add, update, move, or delete multiple files. The
    # patch is fully parsed and validated against the current file contents
    # before any write happens, so a malformed hunk leaves the tree
    # untouched. Format (ported from codex-rs/apply-patch):
    #
    #   *** Begin Patch
    #   *** Add File: path/new.txt
    #   +line one
    #   +line two
    #   *** Delete File: path/old.txt
    #   *** Update File: path/existing.py
    #   *** Move to: path/renamed.py
    #   @@ class Foo:
    #    context
    #   -removed
    #   +added
    #   *** End of File
    #   *** End Patch
    #
    # Update hunks locate their context exactly (with trailing/leading
    # whitespace tolerance, like codex `seek_sequence`); chunks within a
    # hunk apply in order, each strictly after the previous one.
    class ApplyPatchError < Exception
    end

    module Patch
      BEGIN_MARKER       = "*** Begin Patch"
      END_MARKER         = "*** End Patch"
      ADD_FILE_MARKER    = "*** Add File: "
      DELETE_FILE_MARKER = "*** Delete File: "
      UPDATE_FILE_MARKER = "*** Update File: "
      MOVE_TO_MARKER     = "*** Move to: "
      EOF_MARKER         = "*** End of File"

      # One contiguous replacement inside an Update hunk.
      class Chunk
        property change_context : String?
        property old_lines : Array(String) = [] of String
        property new_lines : Array(String) = [] of String
        property? is_end_of_file : Bool = false

        def initialize(@change_context : String? = nil)
        end
      end

      abstract class Hunk
      end

      class AddFile < Hunk
        getter path : String
        getter contents : String

        def initialize(@path : String, @contents : String)
        end
      end

      class DeleteFile < Hunk
        getter path : String

        def initialize(@path : String)
        end
      end

      class UpdateFile < Hunk
        getter path : String
        getter move_path : String?
        getter chunks : Array(Chunk)

        def initialize(@path : String, @move_path : String?, @chunks : Array(Chunk))
        end
      end

      # Parse the patch text into hunks. Raises ApplyPatchError on any
      # structural problem; does not touch the filesystem.
      def self.parse(text : String) : Array(Hunk)
        lines = text.strip.split('\n').map(&.rstrip('\r'))
        if lines.empty? || lines.first.strip != BEGIN_MARKER
          raise ApplyPatchError.new("The first line of the patch must be '*** Begin Patch'")
        end
        if lines.last.strip != END_MARKER
          raise ApplyPatchError.new("The last line of the patch must be '*** End Patch'")
        end

        hunks = [] of Hunk
        i = 1
        while i < lines.size - 1
          line = lines[i]
          if line.starts_with?(ADD_FILE_MARKER)
            path = line[ADD_FILE_MARKER.size..].strip
            raise ApplyPatchError.new("Add File hunk has an empty path at line #{i + 1}") if path.empty?
            i += 1
            content = [] of String
            while i < lines.size - 1 && lines[i].starts_with?('+')
              content << lines[i][1..]
              i += 1
            end
            if content.empty?
              raise ApplyPatchError.new("Add File hunk for '#{path}' has no content lines (each line must start with '+')")
            end
            hunks << AddFile.new(path, content.join('\n') + "\n")
          elsif line.starts_with?(DELETE_FILE_MARKER)
            path = line[DELETE_FILE_MARKER.size..].strip
            raise ApplyPatchError.new("Delete File hunk has an empty path at line #{i + 1}") if path.empty?
            hunks << DeleteFile.new(path)
            i += 1
          elsif line.starts_with?(UPDATE_FILE_MARKER)
            path = line[UPDATE_FILE_MARKER.size..].strip
            raise ApplyPatchError.new("Update File hunk has an empty path at line #{i + 1}") if path.empty?
            i += 1

            move_path = nil
            if i < lines.size - 1 && lines[i].starts_with?(MOVE_TO_MARKER)
              move_path = lines[i][MOVE_TO_MARKER.size..].strip
              raise ApplyPatchError.new("Move to target is empty at line #{i + 1}") if move_path.empty?
              i += 1
            end

            chunks = [] of Chunk
            current : Chunk? = nil
            while i < lines.size - 1
              l = lines[i]
              if l == EOF_MARKER
                cur = current || raise ApplyPatchError.new("'*** End of File' without change lines at line #{i + 1}")
                cur.is_end_of_file = true
                i += 1
              elsif l.starts_with?("@@")
                ctx = l[2..].strip
                current = Chunk.new(ctx.empty? ? nil : ctx)
                chunks << current
                i += 1
              elsif l.starts_with?('+')
                cur = current || begin
                  c = Chunk.new
                  chunks << c
                  current = c
                end
                cur.new_lines << l[1..]
                i += 1
              elsif l.starts_with?('-')
                cur = current || begin
                  c = Chunk.new
                  chunks << c
                  current = c
                end
                cur.old_lines << l[1..]
                i += 1
              elsif l.starts_with?(' ')
                cur = current || begin
                  c = Chunk.new
                  chunks << c
                  current = c
                end
                cur.old_lines << l[1..]
                cur.new_lines << l[1..]
                i += 1
              elsif l.starts_with?("*** ")
                break # next hunk header
              else
                raise ApplyPatchError.new("Invalid hunk line #{i + 1}: #{l.inspect} (update lines must start with '+', '-', or ' ')")
              end
            end
            if chunks.empty?
              raise ApplyPatchError.new("Update file hunk for path '#{path}' is empty")
            end
            hunks << UpdateFile.new(path, move_path, chunks)
          else
            raise ApplyPatchError.new("Invalid patch line #{i + 1}: #{line.inspect}")
          end
        end
        hunks
      end

      # Find `pattern` inside `lines` at or after `start`. Matches are
      # attempted with decreasing strictness: exact, trailing-whitespace-
      # insensitive, then fully trimmed (codex seek_sequence minus the
      # unicode-punctuation pass). When `eof` is true the search starts at
      # the end of the file so end-of-file hunks land at the tail.
      def self.seek_sequence(lines : Array(String), pattern : Array(String),
                             start : Int32, eof : Bool) : Int32?
        return start if pattern.empty?
        return nil if pattern.size > lines.size

        search_start = eof ? {lines.size - pattern.size, start}.max : start
        last_start = lines.size - pattern.size

        (search_start..last_start).each do |i|
          return i if lines[i, pattern.size] == pattern
        end
        (search_start..last_start).each do |i|
          ok = true
          pattern.each_with_index do |pat, p|
            unless lines[i + p].rstrip == pat.rstrip
              ok = false
              break
            end
          end
          return i if ok
        end
        (search_start..last_start).each do |i|
          ok = true
          pattern.each_with_index do |pat, p|
            unless lines[i + p].strip == pat.strip
              ok = false
              break
            end
          end
          return i if ok
        end
        nil
      end

      # Compute the updated file body (model view, LF) by applying chunks.
      # Raises ApplyPatchError when a context or old-lines block cannot be
      # located.
      def self.compute_updated_text(original : String, path : String,
                                    chunks : Array(Chunk)) : String
        lines = original.split('\n')
        # Drop the trailing empty element produced by the final newline so
        # line indices match standard diff behaviour.
        lines.pop if lines.last == ""

        replacements = [] of Tuple(Int32, Int32, Array(String))
        line_index = 0

        chunks.each do |chunk|
          if ctx = chunk.change_context
            idx = seek_sequence(lines, [ctx], line_index, false)
            raise ApplyPatchError.new("Failed to find context '#{ctx}' in #{path}") unless idx
            line_index = idx + 1
          end

          if chunk.old_lines.empty?
            # Pure insertion: append after the last line.
            replacements << {lines.size, 0, chunk.new_lines}
            next
          end

          pattern = chunk.old_lines
          new_slice = chunk.new_lines
          found = seek_sequence(lines, pattern, line_index, chunk.is_end_of_file?)

          # A trailing empty pattern element stands for the terminating
          # newline of the replaced region; retry without it.
          if found.nil? && pattern.last == ""
            pattern = pattern[0...-1]
            new_slice = new_slice[0...-1] if new_slice.last == ""
            found = seek_sequence(lines, pattern, line_index, chunk.is_end_of_file?)
          end

          unless found
            raise ApplyPatchError.new(
              "Failed to find expected lines in #{path}:\n#{chunk.old_lines.join('\n')}")
          end
          replacements << {found, pattern.size, new_slice}
          line_index = found + pattern.size
        end

        replacements.sort_by!(&.[0])

        new_lines = lines.dup
        # Apply in reverse so earlier replacements don't shift positions.
        replacements.reverse_each do |(start_idx, old_len, segment)|
          new_lines.delete_at(start_idx, old_len) if old_len > 0
          segment.each_with_index do |line, off|
            new_lines.insert(start_idx + off, line)
          end
        end

        new_lines << "" unless new_lines.last == ""
        new_lines.join('\n')
      end

      record ApplySummary, lines : Array(String), updated : Array(Tuple(String, String, String))

      # Planned filesystem operation — everything is validated (pass 1)
      # before anything is written (pass 2).
      private abstract class PlanOp
      end

      private class PlanAdd < PlanOp
        getter full_path : String, contents : String

        def initialize(@full_path, @contents)
        end
      end

      private class PlanUpdate < PlanOp
        getter full_path : String, target_path : String, new_body : String,
          display_path : String, before : String, after : String

        def initialize(@full_path, @target_path, @new_body, @display_path, @before, @after)
        end

        def move? : Bool
          @target_path != @full_path
        end
      end

      private class PlanDelete < PlanOp
        getter full_path : String

        def initialize(@full_path)
        end
      end

      # Validate every hunk against the filesystem and compute all new
      # contents; then write. Raises ApplyPatchError (nothing written) on
      # validation failure, and PathAccess::AccessError for blocked paths.
      def self.apply(hunks : Array(Hunk), work_dir : String) : ApplySummary
        ops = [] of PlanOp
        updated = [] of Tuple(String, String, String)

        hunks.each do |hunk|
          case hunk
          when AddFile
            full_path = PathAccess.resolve(hunk.path, work_dir, PathAccess::Mode::Write)
            if File.exists?(full_path)
              raise ApplyPatchError.new("Add File failed: #{hunk.path} already exists")
            end
            ops << PlanAdd.new(full_path, hunk.contents)
          when DeleteFile
            full_path = PathAccess.resolve(hunk.path, work_dir, PathAccess::Mode::Write)
            unless File.exists?(full_path)
              raise ApplyPatchError.new("Delete File failed: #{hunk.path} not found")
            end
            ops << PlanDelete.new(full_path)
          when UpdateFile
            full_path = PathAccess.resolve(hunk.path, work_dir, PathAccess::Mode::Write)
            unless File.exists?(full_path)
              raise ApplyPatchError.new("Update File failed: #{hunk.path} not found")
            end
            target_path = full_path
            if move_path = hunk.move_path
              target_path = PathAccess.resolve(move_path, work_dir, PathAccess::Mode::Write)
              if File.exists?(target_path)
                raise ApplyPatchError.new("Move failed: #{move_path} already exists")
              end
            end

            raw = File.read(full_path)
            view = LineEndings.to_model_view(raw)
            new_text = compute_updated_text(view.text, hunk.path, hunk.chunks)
            new_body = LineEndings.materialize(new_text, view.line_ending_style)

            display_path = hunk.move_path || hunk.path
            ops << PlanUpdate.new(full_path, target_path, new_body, display_path, raw, new_body)
            updated << {display_path, raw, new_body}
          end
        end

        # Pass 2: execute.
        done = [] of String
        ops.each do |op|
          case op
          when PlanAdd
            Dir.mkdir_p(File.dirname(op.full_path))
            File.write(op.full_path, op.contents)
            done << "A #{display_rel(op.full_path, work_dir)}"
          when PlanUpdate
            File.write(op.full_path, op.new_body)
            if op.move?
              Dir.mkdir_p(File.dirname(op.target_path))
              File.rename(op.full_path, op.target_path)
            end
            done << (op.move? ? "M #{display_rel(op.target_path, work_dir)} (moved from #{display_rel(op.full_path, work_dir)})" : "M #{display_rel(op.full_path, work_dir)}")
          when PlanDelete
            File.delete(op.full_path)
            done << "D #{display_rel(op.full_path, work_dir)}"
          end
        end

        ApplySummary.new(done, updated)
      end

      private def self.display_rel(full_path : String, work_dir : String) : String
        full_path.starts_with?(work_dir) ? full_path[work_dir.size..].lstrip('/') : full_path
      end
    end

    class ApplyPatchTool < Tool
      # Retargeted by `/fork` / `/merge` at the idle boundary between turns.
      setter work_dir

      def initialize(@work_dir : String = Dir.current)
      end

      def name : String
        Names::APPLY_PATCH
      end

      def description : String
        "Apply a multi-file patch in the V4A diff format. A single call can add, update, move, or delete multiple files, and the patch is validated against current file contents before anything is written. " \
        "Prefer this over many Edit calls when changing several files at once. " \
        "Format: '*** Begin Patch'; '*** Add File: <path>' followed by '+' lines; '*** Delete File: <path>'; '*** Update File: <path>' with optional '*** Move to: <new path>', then chunks: '@@ <context line>' optional header, ' '-prefixed context lines, '-' removed lines, '+' added lines, optional '*** End of File' to anchor a chunk at the file tail; '*** End Patch'. " \
        "Read files first and copy context verbatim; chunks within a hunk must appear in file order."
      end

      def parameters : JSON::Any
        JSON.parse(%({
          "type": "object",
          "properties": {
            "input": {
              "type": "string",
              "description": "The complete patch text, starting with '*** Begin Patch' and ending with '*** End Patch'."
            }
          },
          "required": ["input"]
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        patch = input["input"]?.try(&.to_s) || input["patch"]?.try(&.to_s) || ""
        return ToolResult.error("No patch provided: pass the patch text in 'input'.") if patch.strip.empty?

        hunks = Patch.parse(patch)
        if hunks.empty?
          return ToolResult.error("The patch contains no hunks (no Add / Update / Delete File sections).")
        end

        summary = Patch.apply(hunks, @work_dir)

        res = ToolResult.success("Done! Applied the patch:\n#{summary.lines.join('\n')}")
        # Attach a file_io display only for single-file updates so the TUI
        # can render the usual diff card.
        if summary.updated.size == 1
          path, before, after = summary.updated.first
          res.display = ToolDisplay.new("file_io", "edit", path, before, after)
        end
        res
      rescue ex : ApplyPatchError
        ToolResult.error("Patch failed: #{ex.message}")
      rescue ex : PathAccess::AccessError
        ToolResult.error(ex.message || "access error")
      rescue ex : IO::Error
        ToolResult.error("Patch failed while writing: #{ex.message}")
      end
    end
  end
end
