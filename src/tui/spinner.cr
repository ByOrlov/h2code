module H2code
  module TUI
    class Spinner
      FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

      # Animated bullet for running Bash commands: pulses ● → • → ⋅ → • → …
      # 4 frames, ~250ms each (3 ticks × ~80ms).
      BASH_BULLET_FRAMES = ["\u25cf", "\u2022", "\u22c5", "\u2022"]

      # Animated circle for the CI observer wait line: grows and shrinks
      # ○ → ◐ → ◑ → ◉ → ● → ◉ → ◑ → ◐ → … 8 frames, ~160ms each
      # (2 ticks × ~80ms).
      CI_BULLET_FRAMES = ["\u25cb", "\u25d0", "\u25d1", "\u25c9", "\u25cf",
                          "\u25c9", "\u25d1", "\u25d0"]

      @frame : Int32 = 0
      @active : Bool = false
      @last_update : Time::Span = Time.monotonic

      def active? : Bool
        @active
      end

      def start : Nil
        @active = true
        @frame = 0
        @last_update = Time.monotonic
      end

      def stop : Nil
        @active = false
      end

      def render(io : IO, color : Int32 = 75) : Nil
        return unless @active

        now = Time.monotonic
        if (now - @last_update).total_milliseconds >= 80
          @frame = (@frame + 1) % FRAMES.size
          @last_update = now
        end

        io << ANSI.color(color, nil)
        io << FRAMES[@frame]
        io << ANSI.reset
      end

      def current_char : String
        FRAMES[@frame]
      end
    end
  end
end
