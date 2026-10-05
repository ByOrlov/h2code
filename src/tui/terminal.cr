{% if flag?(:unix) %}
  lib LibCExtra
    # c_cc indices differ between Linux and macOS/BSD.
    {% if flag?(:darwin) %}
      VMIN  = 16
      VTIME = 17

      TIOCGWINSZ = 0x40087468_u64
    {% else %}
      # Linux values
      VMIN  = 6
      VTIME = 5

      TIOCGWINSZ = 0x5413_u64
    {% end %}

    struct Winsize
      ws_row : UInt16
      ws_col : UInt16
      ws_xpixel : UInt16
      ws_ypixel : UInt16
    end

    fun ioctl(fd : Int32, request : UInt64, ...) : Int32
    fun isatty(fd : Int32) : Int32
  end
{% end %}

{% if flag?(:win32) %}
  @[Link("kernel32")]
  lib LibCConsole
    STD_INPUT_HANDLE  = 0xFFFFFFF6_u32 # (DWORD)-10
    STD_OUTPUT_HANDLE = 0xFFFFFFF5_u32 # (DWORD)-11

    ENABLE_PROCESSED_INPUT             = 0x0001_u32
    ENABLE_LINE_INPUT                  = 0x0002_u32
    ENABLE_ECHO_INPUT                  = 0x0004_u32
    ENABLE_VIRTUAL_TERMINAL_INPUT      = 0x0200_u32
    ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004_u32

    struct Coord
      x : Int16
      y : Int16
    end

    struct SmallRect
      left : Int16
      top : Int16
      right : Int16
      bottom : Int16
    end

    struct ConsoleScreenBufferInfo
      size : Coord
      cursor_position : Coord
      attributes : UInt16
      window : SmallRect
      maximum_window_size : Coord
    end

    fun getStdHandle = "GetStdHandle"(handle_id : UInt32) : Void*
    fun getConsoleMode = "GetConsoleMode"(handle : Void*, mode : UInt32*) : Int32
    fun setConsoleMode = "SetConsoleMode"(handle : Void*, mode : UInt32) : Int32
    fun getConsoleScreenBufferInfo = "GetConsoleScreenBufferInfo"(handle : Void*, info : ConsoleScreenBufferInfo*) : Int32
  end
{% end %}

module H2code
  module TUI
    class Terminal
      {% if flag?(:unix) %}
        @original_termios : LibC::Termios?
      {% end %}

      {% if flag?(:win32) %}
        @stdin_handle : Void*? = nil
        @stdout_handle : Void*? = nil
        @original_in_mode : UInt32 = 0
        @original_out_mode : UInt32 = 0
      {% end %}

      @raw : Bool = false

      def self.current : Terminal
        @@current ||= new
      end

      def initialize
        @cols, @rows = size
      end

      getter cols : Int32
      getter rows : Int32

      # Used by tests to control terminal dimensions without a real tty.
      def set_size(@cols : Int32, @rows : Int32) : Nil
      end

      def raw! : Nil
        return if @raw

        {% if flag?(:unix) %}
          fd = STDIN.fd

          orig = uninitialized LibC::Termios
          LibC.tcgetattr(fd, pointerof(orig))
          @original_termios = orig

          raw_termios = orig
          raw_termios.c_lflag &= ~(LibC::ICANON | LibC::ECHO | LibC::ISIG | LibC::IEXTEN)
          raw_termios.c_iflag &= ~(LibC::IXON | LibC::ICRNL)
          raw_termios.c_oflag &= ~LibC::OPOST
          raw_termios.c_cc[LibCExtra::VMIN] = 0
          raw_termios.c_cc[LibCExtra::VTIME] = 0

          LibC.tcsetattr(fd, LibC::TCSAFLUSH, pointerof(raw_termios))
        {% else %}
          in_h = LibCConsole.getStdHandle(LibCConsole::STD_INPUT_HANDLE)
          out_h = LibCConsole.getStdHandle(LibCConsole::STD_OUTPUT_HANDLE)
          @stdin_handle = in_h
          @stdout_handle = out_h

          if in_h && !in_h.null?
            old_in = uninitialized UInt32
            if LibCConsole.getConsoleMode(in_h, pointerof(old_in)) != 0
              @original_in_mode = old_in
              new_in = LibCConsole::ENABLE_VIRTUAL_TERMINAL_INPUT
              LibCConsole.setConsoleMode(in_h, new_in)
            end
          end

          if out_h && !out_h.null?
            old_out = uninitialized UInt32
            if LibCConsole.getConsoleMode(out_h, pointerof(old_out)) != 0
              @original_out_mode = old_out
              new_out = old_out | LibCConsole::ENABLE_VIRTUAL_TERMINAL_PROCESSING
              LibCConsole.setConsoleMode(out_h, new_out)
            end
          end
        {% end %}

        @raw = true

        print ANSI.hide_cursor
        print "\e[?2004h" # Enable bracketed paste mode
        # Push the kitty keyboard protocol (flags 7: disambiguate escape
        # codes + report event types + report alternate keys). Terminals
        # that support it — Alacritty, kitty, Ghostty, WezTerm — then
        # deliver keys like Ctrl+V to the application instead of applying
        # their own default bindings (Alacritty's Ctrl+V is terminal
        # paste: with an image-only clipboard that sends NOTHING to the
        # app, which is exactly the "Ctrl+V does nothing" failure mode).
        # Unsupported terminals ignore the sequence. Popped in restore!.
        print "\e[>7u"
      end

      def restore! : Nil
        return unless @raw

        print "\e[<u"     # Pop the kitty keyboard protocol stack
        print "\e[?2004l" # Disable bracketed paste mode
        print ANSI.show_cursor
        print "\r\n"

        {% if flag?(:unix) %}
          fd = STDIN.fd
          if orig = @original_termios
            restored = orig
            LibC.tcsetattr(fd, LibC::TCSANOW, pointerof(restored))
          end
        {% else %}
          if h = @stdin_handle
            LibCConsole.setConsoleMode(h, @original_in_mode)
          end
          if h = @stdout_handle
            LibCConsole.setConsoleMode(h, @original_out_mode)
          end
        {% end %}

        @raw = false
      end

      def refresh_size : Nil
        @cols, @rows = size
      end

      # How long to wait for DSR replies from a terminal that ignores
      # the width probe before falling back to the static tables.
      PROBE_TIMEOUT = 200.milliseconds

      # Ask the terminal itself how wide glyphs render. For each
      # candidate codepoint: carriage-return to column 1, print the
      # glyph, then request the cursor position (DSR/CPR, `ESC[6n`).
      # The reply `ESC[<row>;<col>R` reports where the cursor landed, so
      # `col - 1` is the glyph's real advance width — ground truth that
      # overrides the static Unicode tables when terminals disagree
      # (e.g. ⏳ rendered 2 cells while the table says 1).
      #
      # All probes are sent as one batch, so this costs a single round
      # trip (~a few ms on a live terminal). Runs once at startup,
      # before the input loop and the first render; the glyphs flash on
      # the current line for a moment and are erased afterwards. A
      # terminal that never answers (pipe, PTY without emulation) keeps
      # the static tables after PROBE_TIMEOUT.
      #
      # Returns the measured widths (nil when nothing was answered) and
      # any non-reply bytes that arrived meanwhile (user keystrokes the
      # caller should re-inject into the input queue).
      def probe_codepoint_widths(candidates : Array(UInt32)) : {Hash(UInt32, Int32)?, Array(UInt8)}
        {% if flag?(:unix) %}
          return {nil, [] of UInt8} unless @raw && tty?

          STDOUT.write(String.build do |io|
            candidates.each { |cp| io << "\r" << cp.chr << "\e[6n" }
          end)
          STDOUT.flush

          data = String::Builder.new
          slice = Bytes.new(4096)
          deadline = Time.monotonic + PROBE_TIMEOUT
          loop do
            n = LibC.read(STDIN.fd, slice.to_unsafe, slice.size)
            data.write(slice[0, n]) if n > 0
            cols, _ = Terminal.extract_dsr_replies(data.to_s)
            break if cols.size >= candidates.size
            break if Time.monotonic >= deadline
            sleep 2.milliseconds
          end

          print "\r#{ANSI.clear_line}"
          STDOUT.flush

          cols, leftovers = Terminal.extract_dsr_replies(data.to_s)
          widths = {} of UInt32 => Int32
          cols.each_with_index do |col, idx|
            cp = candidates[idx]?
            next unless cp
            w = col - 1
            # A glyph is 1 or 2 cells; anything else is a garbled reply.
            widths[cp] = w if w == 1 || w == 2
          end
          {widths.empty? ? nil : widths, leftovers}
        {% else %}
          # Windows console: no reliable DSR round trip — keep tables.
          {nil, [] of UInt8}
        {% end %}
      end

      # Split `data` into DSR cursor-position replies
      # (`ESC [ <row> ; <col> R`) and the remaining bytes — user
      # keystrokes that arrived during the probe. Returns the 1-based
      # columns in reply order plus the leftovers in arrival order.
      # Key encodings never end in `R` (kitty CSI-u ends in `u`, arrows
      # in `A`..`H`/`~`), so replies cannot be spoofed by keystrokes.
      def self.extract_dsr_replies(data : String) : {Array(Int32), Array(UInt8)}
        cols = [] of Int32
        leftovers = [] of UInt8
        bytes = data.bytes
        i = 0
        n = bytes.size
        while i < n
          if bytes[i] == 0x1b_u8 && i + 1 < n && bytes[i + 1] == 0x5B_u8 # ESC [
            j = i + 2
            row_start = j
            while j < n && bytes[j] >= 0x30_u8 && bytes[j] <= 0x39_u8
              j += 1
            end
            if j > row_start && j < n && bytes[j] == 0x3B_u8 # ';'
              j += 1
              col_start = j
              while j < n && bytes[j] >= 0x30_u8 && bytes[j] <= 0x39_u8
                j += 1
              end
              if j > col_start && j < n && bytes[j] == 0x52_u8 # 'R'
                cols << data.byte_slice(col_start, j - col_start).to_i
                i = j + 1
                next
              end
            end
          end
          leftovers << bytes[i]
          i += 1
        end
        {cols, leftovers}
      end

      def tty? : Bool
        {% if flag?(:unix) %}
          LibCExtra.isatty(STDIN.fd) == 1
        {% else %}
          STDIN.tty?
        {% end %}
      end

      private def size : {Int32, Int32}
        {% if flag?(:unix) %}
          ws = uninitialized LibCExtra::Winsize
          ret = LibCExtra.ioctl(STDOUT.fd, LibCExtra::TIOCGWINSZ, pointerof(ws))
          if ret == 0 && ws.ws_col > 0 && ws.ws_row > 0
            {ws.ws_col.to_i32, ws.ws_row.to_i32}
          else
            env_cols = ENV["COLUMNS"]?.try(&.to_i?) || 80
            env_rows = ENV["LINES"]?.try(&.to_i?) || 24
            {env_cols, env_rows}
          end
        {% else %}
          h = LibCConsole.getStdHandle(LibCConsole::STD_OUTPUT_HANDLE)
          info = uninitialized LibCConsole::ConsoleScreenBufferInfo
          if h && !h.null? && LibCConsole.getConsoleScreenBufferInfo(h, pointerof(info)) != 0
            cols = info.window.right - info.window.left + 1
            rows = info.window.bottom - info.window.top + 1
            if cols > 0 && rows > 0
              {cols.to_i32, rows.to_i32}
            else
              {80, 24}
            end
          else
            env_cols = ENV["COLUMNS"]?.try(&.to_i?) || 80
            env_rows = ENV["LINES"]?.try(&.to_i?) || 24
            {env_cols, env_rows}
          end
        {% end %}
      end
    end

    module ANSI
      ESC = "\e["

      def self.cursor_to(row : Int32, col : Int32) : String
        "#{ESC}#{row + 1};#{col + 1}H"
      end

      def self.cursor_up(n : Int32 = 1) : String
        "#{ESC}#{n}A"
      end

      def self.cursor_down(n : Int32 = 1) : String
        "#{ESC}#{n}B"
      end

      def self.clear_line : String
        "#{ESC}2K"
      end

      def self.clear_screen : String
        "#{ESC}2J"
      end

      def self.clear_below : String
        "#{ESC}J"
      end

      def self.hide_cursor : String
        "#{ESC}?25l"
      end

      def self.show_cursor : String
        "#{ESC}?25h"
      end

      def self.alt_screen_on : String
        "#{ESC}?1049h"
      end

      def self.alt_screen_off : String
        "#{ESC}?1049l"
      end

      def self.color(fg : Int32? = nil, bg : Int32? = nil) : String
        parts = [] of String
        parts << "38;5;#{fg}" if fg
        parts << "48;5;#{bg}" if bg
        parts.empty? ? "" : "#{ESC}#{parts.join(";")}m"
      end

      def self.reset : String
        "#{ESC}0m"
      end

      def self.bold : String
        "#{ESC}1m"
      end

      def self.dim : String
        "#{ESC}2m"
      end

      def self.italic : String
        "#{ESC}3m"
      end

      def self.underline : String
        "#{ESC}4m"
      end

      def self.rgb(r : Int32, g : Int32, b : Int32) : String
        "#{ESC}38;2;#{r};#{g};#{b}m"
      end

      # Truecolor (24-bit) counterpart of `color`: optional fg and bg RGB
      # triples combined into one SGR sequence.
      def self.color24(fg : {Int32, Int32, Int32}? = nil, bg : {Int32, Int32, Int32}? = nil) : String
        parts = [] of String
        parts << "38;2;#{fg[0]};#{fg[1]};#{fg[2]}" if fg
        parts << "48;2;#{bg[0]};#{bg[1]};#{bg[2]}" if bg
        parts.empty? ? "" : "#{ESC}#{parts.join(";")}m"
      end
    end
  end
end
