module H2code
  module TUI
    class Editor < Component
      PASTE_MARKER_RE = /\[paste #\d+(?: \+\d+ lines| \d+ chars)?\]/

      @lines : Array(String) = [""]
      @cursor_row : Int32 = 0
      @cursor_col : Int32 = 0
      @history : Array(String) = [] of String
      @history_index : Int32 = -1
      @draft : String = ""
      @placeholder : String = ""
      # Paste-marker expansion: when a large paste is collapsed into a
      # `[paste #N ...]` marker, the original text is stored here keyed by id.
      @pastes : Hash(Int32, String) = {} of Int32 => String
      @paste_counter : Int32 = 0

      property? multiline : Bool = true
      property placeholder : String
      property fg_color : Int32 = 252
      property accent_color : Int32 = 75

      # Visual cursor position within the rendered editor box — set by the
      # rendering layer (App#render_editor_box) during layout, read by the
      # cursor-positioning layer. Row is 0-based within the editor's content
      # rows (excluding the top border); col is the visible column offset
      # from the content start on that row.
      property cursor_visual_row : Int32 = 0
      property cursor_visual_col : Int32 = 0

      def initialize(@placeholder : String = "")
      end

      def text : String
        @lines.join('\n')
      end

      def clear : Nil
        @lines = [""]
        @cursor_row = 0
        @cursor_col = 0
        @pastes.clear
      end

      def set(text : String) : Nil
        @lines = text.split('\n')
        @lines = [""] if @lines.empty?
        @cursor_row = @lines.size - 1
        @cursor_col = @lines.last.size
        @pastes.clear
      end

      def empty? : Bool
        @lines.size == 1 && @lines[0].empty?
      end

      # Whitespace-only content (spaces, tabs, newlines): no visible text.
      def blank? : Bool
        @lines.all?(&.blank?)
      end

      def profiled_bytes : Int64
        @history.sum(&.profiled_bytes)
      end

      def profiled_count : Int32
        @history.size
      end

      def insert_text(text : String) : Nil
        return if text.empty?

        # Insert at current cursor position, preserving newlines.
        prefix = @lines[@cursor_row][0...@cursor_col] || ""
        suffix = @lines[@cursor_row][@cursor_col..] || ""
        pasted_lines = text.split('\n')
        pasted_lines[0] = prefix + pasted_lines[0]
        pasted_lines[-1] = pasted_lines[-1] + suffix

        @lines[@cursor_row] = pasted_lines[0]
        if pasted_lines.size > 1
          pasted_lines[1..].reverse_each do |line|
            @lines.insert(@cursor_row + 1, line)
          end
        end

        @cursor_row += pasted_lines.size - 1
        @cursor_col = pasted_lines.last.size - suffix.size
        clamp_cursor_col
      end

      # Insert a paste block as an atomic `[paste #N ...]` marker and store
      # the original text for later expansion (on submit or Ctrl+E).
      def insert_paste_marker(text : String, lines : Int32) : Nil
        @paste_counter += 1
        id = @paste_counter
        @pastes[id] = text
        marker = "[paste ##{id} +#{lines} lines]"
        insert_text(marker)
      end

      # True when there is at least one unexpanded paste marker in the buffer.
      def pasted? : Bool
        !@pastes.empty?
      end

      # Expand every paste marker in `str` back to its stored text.
      def expand_paste_markers(str : String) : String
        result = str
        @pastes.each do |id, content|
          re = /\[paste ##{id}(?: \+\d+ lines| \d+ chars)?\]/
          result = result.gsub(re, content)
        end
        result
      end

      # Expand markers and clear paste tracking.
      def expanded_text : String
        expand_paste_markers(text)
      end

      # Expand all paste markers in place (Ctrl+E). Returns true if any marker
      # was expanded.
      def expand_markers : Bool
        return false if @pastes.empty?
        expanded = expand_paste_markers(text)
        set(expanded)
        true
      end

      # Detect whether `text` contains *any* valid (tracked) paste marker.
      def contains_paste_marker?(str : String = text) : Bool
        return false if @pastes.empty?
        str.scan(PASTE_MARKER_RE) do |m|
          id = parse_paste_id(m[0])
          return true if id && @pastes.has_key?(id)
        end
        false
      end

      # Extract the numeric id from a marker string like "[paste #3 +5 lines]".
      private def parse_paste_id(marker : String) : Int32?
        if m = marker.match(/#(\d+)/)
          m[1].to_i?
        end
      end

      # After an edit, drop paste ids whose markers no longer appear in the
      # buffer so expansion and `pasted?` stay accurate.
      private def prune_dead_pastes : Nil
        return if @pastes.empty?
        body = text
        @pastes.reject! do |id, _|
          re = /\[paste ##{id}(?: \+\d+ lines| \d+ chars)?\]/
          !body.matches?(re)
        end
      end

      # Scan the current line for a *tracked* paste marker whose span overlaps
      # or ends at `col`. Returns {start, end} (end exclusive) or nil.
      # Used by backspace/cursor_left to find the marker just before the cursor.
      private def marker_range_at_or_before(col : Int32) : {Int32, Int32}?
        return nil if @pastes.empty?
        line = @lines[@cursor_row]? || ""
        line.scan(PASTE_MARKER_RE) do |m|
          start_col = m.begin || next
          end_col = m.end || next
          next if start_col >= col # marker starts at/after col — not "before"
          id = parse_paste_id(m[0])
          next unless id && @pastes.has_key?(id)
          # The marker must contain col or end at col.
          if start_col < col && end_col >= col
            return {start_col, end_col}
          end
        end
        nil
      end

      # Scan the current line for a tracked paste marker that starts exactly
      # at `col`. Returns {start, end} (end exclusive) or nil.
      private def marker_range_starting_at(col : Int32) : {Int32, Int32}?
        return nil if @pastes.empty?
        line = @lines[@cursor_row]? || ""
        line.scan(PASTE_MARKER_RE) do |m|
          start_col = m.begin || next
          next unless start_col == col
          id = parse_paste_id(m[0])
          next unless id && @pastes.has_key?(id)
          end_col = m.end || next
          return {start_col, end_col}
        end
        nil
      end

      # Delete the marker covering `range` on the current line and move the
      # cursor to the marker's start.
      private def delete_marker(range : {Int32, Int32}) : Nil
        line = @lines[@cursor_row]
        @lines[@cursor_row] = line[0...range[0]] + line[range[1]..]
        @cursor_col = range[0]
        prune_dead_pastes
      end

      def handle_input(key : KeyEvent) : Bool
        case key.key
        when .char?
          if c = key.char
            insert_char(c)
            true
          else
            false
          end
        when .enter?
          if key.shift?
            insert_newline
            true
          else
            false
          end
        when .backspace?
          if key.alt?
            delete_word_back
          else
            backspace
          end
          true
        when .delete?
          delete_forward
          true
        when .left?
          cursor_left
          true
        when .right?
          cursor_right
          true
        when .up?
          if @multiline && @cursor_row > 0
            @cursor_row -= 1
            clamp_cursor_col
          elsif !@history.empty?
            navigate_history(-1)
          end
          true
        when .down?
          if @multiline && @cursor_row < @lines.size - 1
            @cursor_row += 1
            clamp_cursor_col
          elsif @history_index >= 0
            navigate_history(1)
          end
          true
        when .home?
          @cursor_col = 0
          true
        when .end?
          @cursor_col = @lines[@cursor_row].size
          true
        else
          false
        end
      end

      def submit! : String
        full_text = expanded_text
        stripped = full_text.strip
        unless stripped.empty?
          @history << stripped
        end
        @history_index = -1
        clear
        stripped
      end

      def render(io : IO) : Nil
        if empty? && !@placeholder.empty?
          io << ANSI.color(240, nil)
          io << @placeholder
          io << ANSI.clear_line
          io << ANSI.reset
          return
        end

        @lines.each_with_index do |line, i|
          if i == @cursor_row
            before = line[0...@cursor_col] || ""
            after = line[@cursor_col..] || ""
            io << ANSI.color(@fg_color, nil)
            io << before
            if after.empty?
              io << " "
              io << ANSI.color(@accent_color, nil)
              io << ANSI.dim
            else
              io << ANSI.color(@accent_color, nil)
              io << after[0]? || " "
              io << after[1..] if after.size > 1
            end
            io << ANSI.reset
          else
            io << ANSI.color(@fg_color, nil)
            io << line
            io << ANSI.clear_line
            io << ANSI.reset
          end
          io << "\n" if i < @lines.size - 1
        end
      end

      def measure(width : Int32, height : Int32) : Int32
        @width = width
        h = {@lines.size, 1}.max
        @height = h
        h
      end

      def cursor_position : {Int32, Int32}
        {@cursor_row, @cursor_col}
      end

      # Character immediately before the cursor on the current line, or nil at
      # the line start. The double-Space voice trigger uses this to prove the
      # first press's space is still the last thing typed (see
      # InputController#handle_space_tap).
      def char_before_cursor : Char?
        return nil if @cursor_col <= 0
        line = @lines[@cursor_row]? || ""
        line[@cursor_col - 1]?
      end

      private def insert_char(c : Char) : Nil
        line = @lines[@cursor_row]
        @lines[@cursor_row] = line.insert(@cursor_col, c)
        @cursor_col += 1
      end

      private def insert_newline : Nil
        line = @lines[@cursor_row]
        before = line[0...@cursor_col] || ""
        after = line[@cursor_col..] || ""
        @lines[@cursor_row] = before
        @lines.insert(@cursor_row + 1, after)
        @cursor_row += 1
        @cursor_col = 0
      end

      private def backspace : Nil
        # If the character(s) immediately before the cursor form a tracked
        # paste marker, delete the whole marker atomically.
        if range = marker_range_at_or_before(@cursor_col)
          delete_marker(range)
          return
        end

        if @cursor_col > 0
          line = @lines[@cursor_row]
          @lines[@cursor_row] = line[0...@cursor_col - 1] + line[@cursor_col..]
          @cursor_col -= 1
        elsif @cursor_row > 0
          prev_line = @lines[@cursor_row - 1]
          @cursor_col = prev_line.size
          @lines[@cursor_row - 1] = prev_line + @lines[@cursor_row]
          @lines.delete_at(@cursor_row)
          @cursor_row -= 1
        end
        prune_dead_pastes
      end

      private def delete_word_back : Nil
        line = @lines[@cursor_row]
        col = @cursor_col

        if col == 0
          if @cursor_row > 0
            prev_line = @lines[@cursor_row - 1]
            @cursor_col = prev_line.size
            @lines[@cursor_row - 1] = prev_line + line
            @lines.delete_at(@cursor_row)
            @cursor_row -= 1
          end
          return
        end

        i = col - 1
        while i > 0 && line[i].ascii_whitespace?
          i -= 1
        end
        word_start = i
        while word_start > 0 && !line[word_start - 1].ascii_whitespace?
          word_start -= 1
        end

        @lines[@cursor_row] = line[0...word_start] + line[col..]
        @cursor_col = word_start
      end

      private def delete_forward : Nil
        # If a tracked paste marker starts exactly at the cursor, delete it
        # atomically (forward delete jumps over the whole marker).
        if range = marker_range_at_or_before(@cursor_col + 1)
          if range[0] == @cursor_col
            delete_marker(range)
            return
          end
        end

        line = @lines[@cursor_row]
        if @cursor_col < line.size
          @lines[@cursor_row] = line[0...@cursor_col] + line[@cursor_col + 1..]
        elsif @cursor_row < @lines.size - 1
          @lines[@cursor_row] = line + @lines[@cursor_row + 1]
          @lines.delete_at(@cursor_row + 1)
        end
        prune_dead_pastes
      end

      private def cursor_left : Nil
        # Jump over a paste marker atomically when the cursor is at its end.
        if range = marker_range_at_or_before(@cursor_col)
          if range[1] == @cursor_col
            @cursor_col = range[0]
            return
          end
        end
        if @cursor_col > 0
          @cursor_col -= 1
        elsif @cursor_row > 0
          @cursor_row -= 1
          @cursor_col = @lines[@cursor_row].size
        end
      end

      private def cursor_right : Nil
        # Jump over a paste marker atomically when the cursor is at its start.
        if range = marker_range_starting_at(@cursor_col)
          @cursor_col = range[1]
          return
        end
        if @cursor_col < @lines[@cursor_row].size
          @cursor_col += 1
        elsif @cursor_row < @lines.size - 1
          @cursor_row += 1
          @cursor_col = 0
        end
      end

      private def clamp_cursor_col : Nil
        max_col = @lines[@cursor_row].size
        @cursor_col = {@cursor_col, max_col}.min
      end

      private def navigate_history(direction : Int32) : Nil
        if @history_index == -1
          @draft = text
          @history_index = @history.size
        end

        new_index = @history_index + direction
        return if new_index < -1 || new_index >= @history.size

        @history_index = new_index
        content = if new_index == -1
                    @draft
                  else
                    @history[new_index]
                  end

        @lines = content.split('\n')
        @lines = [""] if @lines.empty?
        @cursor_row = @lines.size - 1
        @cursor_col = @lines.last.size
      end
    end
  end
end
