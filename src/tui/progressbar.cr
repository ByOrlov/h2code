module H2code
  module TUI
    # ProgressBar — solid one-line progress bar for the active zone.
    #
    # Renders a full-width solid khaki bar with the percent label drawn
    # inside it, centered. Label cells covered by the fill are inverted
    # (black on khaki); cells beyond the fill keep khaki on the terminal
    # background — the same fill/invert convention used by full-width bars
    # elsewhere in the TUI. Used by the TodoList panel to show how much of
    # the plan is complete (done / total, in percent).
    module ProgressBar
      # Foreground for the inverted (filled) cells — ANSI black.
      private BLACK = 0

      # `done` / `total` — completed and total item counts. `width` — bar
      # width in terminal cells; when omitted it is detected from the live
      # terminal via `Terminal.current.cols`. `khaki` — the bar color
      # (theme `logo`).
      def self.render(done : Int32, total : Int32, width : Int32? = nil, khaki : Int32 = 144) : String
        width = Terminal.current.cols if width.nil?
        width = 8 if width < 8

        pct = total > 0 ? (done * 100 // total).clamp(0, 100) : 0
        fill = pct * width // 100

        label = "#{pct}%"
        start = (width - label.size) // 2

        String.build do |s|
          inverted = false
          width.times do |i|
            ch = i >= start && i < start + label.size ? label[i - start] : ' '
            inv = i < fill
            if i == 0 || inv != inverted
              s << ANSI.reset << (inv ? ANSI.color(BLACK, khaki) : ANSI.color(khaki, nil))
              inverted = inv
            end
            s << ch
          end
          s << ANSI.reset
        end
      end
    end
  end
end
