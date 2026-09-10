module H2code
  module TUI
    enum Key
      Unknown
      Enter
      ShiftEnter
      Tab
      ShiftTab
      Backspace
      Delete
      Escape
      CtrlC
      CtrlD
      CtrlL
      CtrlS
      CtrlG
      CtrlB
      CtrlE
      CtrlR
      CtrlV
      Up
      Down
      Left
      Right
      Home
      End
      PageUp
      PageDown
      Char
      Paste
    end

    struct KeyEvent
      property key : Key
      property char : Char?
      property text : String?
      property? ctrl : Bool = false
      property? shift : Bool = false
      property? alt : Bool = false

      def initialize(@key : Key, @char : Char? = nil, @text : String? = nil)
      end

      def self.char(c : Char) : KeyEvent
        new(Key::Char, c)
      end

      def self.paste(text : String) : KeyEvent
        new(Key::Paste, text: text)
      end

      def to_s(io : IO) : Nil
        case @key
        in .char?        then io << @char
        in .enter?       then io << "Enter"
        in .backspace?   then io << "Backspace"
        in .up?          then io << "Up"
        in .down?        then io << "Down"
        in .ctrl_c?      then io << "Ctrl+C"
        in .escape?      then io << "Escape"
        in .tab?         then io << "Tab"
        in .shift_tab?   then io << "Shift+Tab"
        in .ctrl_s?      then io << "Ctrl+S"
        in .ctrl_l?      then io << "Ctrl+L"
        in .ctrl_g?      then io << "Ctrl+G"
        in .ctrl_b?      then io << "Ctrl+B"
        in .ctrl_d?      then io << "Ctrl+D"
        in .delete?      then io << "Delete"
        in .home?        then io << "Home"
        in .end?         then io << "End"
        in .page_up?     then io << "PageUp"
        in .page_down?   then io << "PageDown"
        in .left?        then io << "Left"
        in .right?       then io << "Right"
        in .ctrl_e?      then io << "Ctrl+E"
        in .ctrl_r?      then io << "Ctrl+R"
        in .ctrl_v?      then io << "Ctrl+V"
        in .shift_enter? then io << "Shift+Enter"
        in .paste?       then io << "Paste"
        in .unknown?     then io << "Unknown"
        end
      end
    end

    class Input
      # Time to wait for the rest of an escape/paste sequence to arrive.
      COLLECT_TIMEOUT = 5.milliseconds

      @buffer : Array(UInt8) = [] of UInt8
      @events : Array(KeyEvent) = [] of KeyEvent
      @wait : InputWait = InputWait.default
      @@debug_input_path : String? = nil

      # When H2CODE_DEBUG_INPUT=/path/to/log is set, every raw stdin chunk
      # and every parsed key event is appended there — the tool for
      # diagnosing "my terminal sends Ctrl+V differently" reports.
      def self.debug_input_path : String?
        @@debug_input_path = ENV["H2CODE_DEBUG_INPUT"]? if @@debug_input_path.nil? && ENV["H2CODE_DEBUG_INPUT"]?
        @@debug_input_path
      end

      private def log_debug_input(line : String) : Nil
        path = self.class.debug_input_path || return
        File.open(path, "a") { |f| f.puts line }
      rescue
        # Diagnostics must never break the input loop.
      end

      def read_key : KeyEvent?
        return @events.shift? unless @events.empty?

        collect_bytes
        parse_buffer
        @events.shift?
      end

      # Discard any queued Enter events so a stray/doubled Enter byte (e.g.
      # \r\n, or a double keypress) that was batched with the key that opened
      # a modal dialog cannot immediately close it on the next read_key call.
      def drain_pending_enters : Nil
        @events.reject!(&.key.enter?)
      end

      private def collect_bytes : Nil
        start = Time.monotonic
        loop do
          elapsed = Time.monotonic - start
          remaining = COLLECT_TIMEOUT - elapsed
          break if remaining <= Time::Span.zero

          break unless @wait.stdin_readable?(remaining)

          read_available
        end
      end

      private def read_available : Nil
        loop do
          # On POSIX raw mode a read() with an empty queue returns 0, but on
          # Windows a console read (ReadConsoleW under the hood) blocks until
          # the NEXT key press. Draining until a read returns 0 would freeze
          # the input loop there, so only read chunks while input is actually
          # pending (zero-timeout readiness check) and stop when it runs dry.
          break unless @wait.stdin_readable?(Time::Span.zero)

          buf = uninitialized UInt8[256]
          slice = buf.to_slice
          bytes_read = read_stdin_chunk(slice)
          break if bytes_read <= 0
          @buffer.concat(slice[0, bytes_read].to_a)
          if self.class.debug_input_path
            hex = slice[0, bytes_read].map { |b| b.to_s(16).rjust(2, '0') }.join(' ')
            log_debug_input("raw(#{bytes_read}): #{hex}")
          end
        end
      end

      private def read_stdin_chunk(slice : Bytes) : Int32
        {% if flag?(:win32) %}
          STDIN.read(slice)
        {% else %}
          LibC.read(STDIN.fd, slice.to_unsafe, slice.size).to_i32
        {% end %}
      end

      private def parse_buffer : Nil
        loop do
          key, consumed = parse_one(@buffer)
          break if consumed == 0
          if key && self.class.debug_input_path
            log_debug_input("parsed: #{key} (consumed #{consumed})")
          end
          @events << key if key
          @buffer = @buffer[consumed..]
        end
      end

      def parse_one(bytes : Array(UInt8)) : {KeyEvent?, Int32}
        return {nil, 0} if bytes.empty?

        first = bytes[0]

        case first
        when 13, 10
          {KeyEvent.new(Key::Enter), 1}
        when 9
          {KeyEvent.new(Key::Tab), 1}
        when 127, 8
          {KeyEvent.new(Key::Backspace), 1}
        when 1, 3
          {KeyEvent.new(Key::CtrlC), 1}
        when 4
          {KeyEvent.new(Key::CtrlD), 1}
        when 12
          {KeyEvent.new(Key::CtrlL), 1}
        when 19
          {KeyEvent.new(Key::CtrlS), 1}
        when 7
          {KeyEvent.new(Key::CtrlG), 1}
        when 2
          {KeyEvent.new(Key::CtrlB), 1}
        when 5
          {KeyEvent.new(Key::CtrlE), 1}
        when 18
          {KeyEvent.new(Key::CtrlR), 1}
        when 22
          {KeyEvent.new(Key::CtrlV), 1}
        when 27
          parse_escape(bytes)
        else
          if first >= 32 && first < 127
            {KeyEvent.char(first.chr), 1}
          elsif first >= 128
            parse_utf8(bytes)
          else
            {KeyEvent.new(Key::Unknown), 1}
          end
        end
      end

      private def parse_escape(bytes : Array(UInt8)) : {KeyEvent?, Int32}
        # After collect_bytes has timed out (5 ms), a lone ESC byte with no
        # continuation is a standalone Escape key press, not the start of a
        # multi-byte escape sequence.
        return {KeyEvent.new(Key::Escape), 1} if bytes.size < 2

        b2 = bytes[1]

        case b2
        when 91 # '['
          parse_csi(bytes)
        when 79 # 'O'
          return {nil, 0} if bytes.size < 3

          case bytes[2]
          when 65 then {KeyEvent.new(Key::Up), 3}
          when 66 then {KeyEvent.new(Key::Down), 3}
          when 67 then {KeyEvent.new(Key::Right), 3}
          when 68 then {KeyEvent.new(Key::Left), 3}
          when 72 then {KeyEvent.new(Key::Home), 3}
          when 70 then {KeyEvent.new(Key::End), 3}
          else         {KeyEvent.new(Key::Escape), 3}
          end
        when 10
          ev = KeyEvent.new(Key::Enter)
          ev.alt = true
          {ev, 2}
        when 127, 8
          ev = KeyEvent.new(Key::Backspace)
          ev.alt = true
          {ev, 2}
        else
          if b2 >= 32 && b2 < 127
            ev = KeyEvent.char(b2.chr)
            ev.alt = true
            {ev, 2}
          else
            {KeyEvent.new(Key::Escape), 2}
          end
        end
      end

      private def parse_csi(bytes : Array(UInt8)) : {KeyEvent?, Int32}
        final_idx = -1
        i = 2

        while i < bytes.size
          b = bytes[i]
          if b >= 48 && b <= 63 # 0-9 : ; < = > ?
            i += 1
          elsif b >= 64 && b <= 126 # final byte
            final_idx = i
            break
          else
            return {KeyEvent.new(Key::Escape), i + 1}
          end
        end

        return {nil, 0} if final_idx < 0

        # Bracketed paste start: ESC [ 200 ~
        if bytes[final_idx] == 126 && final_idx == 5 &&
           bytes[2] == 50 && bytes[3] == 48 && bytes[4] == 48
          return parse_paste(bytes)
        end

        f = bytes[final_idx]
        params = bytes[2...final_idx]

        case f
        when 65 then {KeyEvent.new(Key::Up), final_idx + 1}
        when 66 then {KeyEvent.new(Key::Down), final_idx + 1}
        when 67 then {KeyEvent.new(Key::Right), final_idx + 1}
        when 68 then {KeyEvent.new(Key::Left), final_idx + 1}
        when 72 then {KeyEvent.new(Key::Home), final_idx + 1}
        when 70 then {KeyEvent.new(Key::End), final_idx + 1}
        when 90 then {KeyEvent.new(Key::ShiftTab), final_idx + 1} # ESC [ Z
        when 117                                                  # 'u' — kitty CSI-u: ESC [ <codepoint> [; <mods>[:<event>]] u
          # Terminals with the kitty keyboard protocol report Ctrl+V as
          # ESC [ 118 ; 5 u instead of the legacy 0x16 byte. Without this
          # branch the paste hotkey silently dies in those terminals.
          # The mods field may carry an event-type sub-parameter
          # (<mods>:<event>) — releases (:3) must be dropped since the
          # protocol is pushed with the report-event-types flag.
          return {KeyEvent.new(Key::Unknown), final_idx + 1} if params.empty?
          parts = params.join(&.chr).split(';')
          codepoint = parts[0]?.try(&.to_i?)
          return {KeyEvent.new(Key::Unknown), final_idx + 1} if codepoint.nil?
          mods_field = parts[1]? || "1"
          mods, event_type = parse_mods_field(mods_field)
          return {nil, final_idx + 1} if event_type == 3 # key release
          key_event_for_codepoint(codepoint, mods, final_idx)
        when 126
          return {KeyEvent.new(Key::Unknown), final_idx + 1} if params.empty?

          param_str = params.join(&.chr)

          # xterm modifyOtherKeys: ESC [ 27 ; <mods> ; <codepoint> ~ —
          # another Ctrl+<letter> encoding some terminals emit.
          if param_str.starts_with?("27;")
            parts = param_str.split(';')
            if parts.size == 3
              mods = (parts[1].to_i? || 1) - 1
              codepoint = parts[2].to_i?
              return key_event_for_codepoint(codepoint, mods, final_idx) if codepoint
            end
            return {KeyEvent.new(Key::Unknown), final_idx + 1}
          end

          param = param_str.to_i? || 0
          case param
          when 1, 7, 8 then {KeyEvent.new(Key::Home), final_idx + 1}
          when 2       then {KeyEvent.new(Key::Unknown), final_idx + 1} # Insert
          when 3       then {KeyEvent.new(Key::Delete), final_idx + 1}
          when 4       then {KeyEvent.new(Key::End), final_idx + 1}
          when 5       then {KeyEvent.new(Key::PageUp), final_idx + 1}
          when 6       then {KeyEvent.new(Key::PageDown), final_idx + 1}
          else              {KeyEvent.new(Key::Unknown), final_idx + 1}
          end
        else
          {KeyEvent.new(Key::Unknown), final_idx + 1}
        end
      end

      # Parse a kitty mods field: "<mods>" or "<mods>:<event-type>".
      # Modifier value is 1-based (1 = none); event-type 1 = press,
      # 2 = repeat, 3 = release.
      private def parse_mods_field(field : String) : {Int32, Int32}
        sub = field.split(':')
        mods = ((sub[0]?.try(&.to_i?)) || 1) - 1
        event_type = (sub[1]?.try(&.to_i?)) || 1
        {mods, event_type}
      end

      # Build a KeyEvent from a kitty/xterm codepoint+modifier encoding.
      # Modifier bitmask: 1 = shift, 2 = alt, 4 = ctrl. Ctrl+letter maps to
      # the Key enum's Ctrl members (unmapped combos are Unknown, matching
      # the legacy raw-byte path); alt/shift fall back to a flagged char
      # event like the ESC- prefixed legacy path does.
      private def key_event_for_codepoint(codepoint : Int32, mods : Int32,
                                          final_idx : Int32) : {KeyEvent?, Int32}
        ctrl = mods & 4 > 0
        alt = mods & 2 > 0
        shift = mods & 1 > 0

        # Control keys arrive as CSI-u under the disambiguate flag
        # (e.g. Esc as ESC [ 27 u).
        unless ctrl || alt
          key = case codepoint
                when  27 then Key::Escape
                when  13 then shift ? Key::ShiftEnter : Key::Enter
                when   9 then shift ? Key::ShiftTab : Key::Tab
                when 127 then Key::Backspace
                else          nil
                end
          return {KeyEvent.new(key), final_idx + 1} if key
        end

        if ctrl && !alt
          char = (32..0x10FFFF).includes?(codepoint) ? codepoint.chr : nil
          if char && char.letter?
            key = case char.downcase
                  when 'c' then Key::CtrlC
                  when 'd' then Key::CtrlD
                  when 'l' then Key::CtrlL
                  when 's' then Key::CtrlS
                  when 'g' then Key::CtrlG
                  when 'b' then Key::CtrlB
                  when 'e' then Key::CtrlE
                  when 'r' then Key::CtrlR
                  when 'v' then Key::CtrlV
                  else          return {KeyEvent.new(Key::Unknown), final_idx + 1}
                  end
            return {KeyEvent.new(key), final_idx + 1}
          end
          return {KeyEvent.new(Key::Unknown), final_idx + 1}
        end

        char = (32..0x10FFFF).includes?(codepoint) ? codepoint.chr : nil
        return {KeyEvent.new(Key::Unknown), final_idx + 1} if char.nil?
        event = KeyEvent.char(char)
        event.alt = true if alt
        event.shift = true if shift
        {event, final_idx + 1}
      end

      private def parse_paste(bytes : Array(UInt8)) : {KeyEvent?, Int32}
        end_marker = [27_u8, 91_u8, 50_u8, 48_u8, 49_u8, 126_u8] # \e[201~
        content_start = 6

        (content_start..bytes.size - end_marker.size).each do |i|
          match = true
          end_marker.each_with_index do |b, j|
            if bytes[i + j] != b
              match = false
              break
            end
          end

          if match
            content = bytes[content_start...i]
            text = begin
              String.new(Bytes.new(content.to_unsafe, content.size))
            rescue
              content.map(&.chr).join
            end
            return {KeyEvent.paste(text), i + end_marker.size}
          end
        end

        # End marker not yet received — keep bytes in buffer.
        {nil, 0}
      end

      private def parse_utf8(bytes : Array(UInt8)) : {KeyEvent?, Int32}
        first = bytes[0]

        num_bytes = case first
                    when 0b110_00000..0b110_11111 then 2
                    when 0b1110_0000..0b1110_1111 then 3
                    when 0b11110_000..0b11110_111 then 4
                    else                               return {KeyEvent.new(Key::Unknown), 1}
                    end

        return {nil, 0} if bytes.size < num_bytes

        slice = bytes[0, num_bytes]
        text = begin
          String.new(Bytes.new(slice.to_unsafe, slice.size))
        rescue
          nil
        end

        if text
          text.each_char do |c|
            return {KeyEvent.char(c), num_bytes}
          end
        end

        {KeyEvent.new(Key::Unknown), num_bytes}
      end
    end
  end
end
