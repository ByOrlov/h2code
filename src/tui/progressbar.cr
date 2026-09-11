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
    #
    # With a nonzero `phase` (driven by the 80ms animation tick while the
    # agent is busy) the bar becomes a gradient carousel — the Crystal
    # port of tmp/gradient_progressbar.rb §3: a multi-stop logo ramp
    # (ink → olive → dim khaki → khaki, white end cut) closed into a
    # seamless cycle by ping-pong, stretched over the bar width, and
    # scrolled by one cell per tick. Filled cells show the scrolling
    # gradient, the track beyond stays ink; the centered percent label is
    # overlaid in bold with per-cell contrast (ink on light cells, white
    # on dark ones). `phase == 0` renders the flat base color,
    # byte-for-byte the same as the non-animated bar.
    module ProgressBar
      # Foreground for the inverted (filled) cells — ANSI black.
      private BLACK = 0

      # Logo palette (tmp/gradient_progressbar.rb): ink track background,
      # olive, dim khaki; the khaki crest comes from the theme color's RGB.
      private INK       = {26, 26, 26}
      private WHITE     = {255, 255, 255}
      private OLIVE     = {98, 91, 74}
      private KHAKI_DIM = {155, 155, 120}

      # Relative-luminance threshold deciding ink vs white label text.
      private LUMA_TEXT = 140

      # xterm-256 channel levels of the 6x6x6 color cube.
      private CUBE_LEVELS = [0, 95, 135, 175, 215, 255]

      private alias RGB = {Int32, Int32, Int32}
      private alias Stop = {Float64, RGB}

      # `done` / `total` — completed and total item counts. `width` — bar
      # width in terminal cells; when omitted it is detected from the live
      # terminal via `Terminal.current.cols`. `khaki` — the bar color
      # (theme `logo`). `phase` — animation tick counter (0 = static).
      def self.render(done : Int32, total : Int32, width : Int32? = nil, khaki : Int32 = 144, phase : Int32 = 0) : String
        width = Terminal.current.cols if width.nil?
        width = 8 if width < 8

        pct = total > 0 ? (done * 100 // total).clamp(0, 100) : 0
        fill = pct * width // 100

        label = "#{pct}%"
        start = (width - label.size) // 2

        base_rgb = rgb256(khaki)

        # One carousel frame: the cyclic logo ramp sampled across the bar
        # width (nil → static render).
        pattern = nil
        if phase > 0 && (base = base_rgb)
          stops = carousel(base)
          pattern = Array.new(width) { |i| sample(stops, i.to_f / width) }
        end

        String.build do |s|
          if pat = pattern
            overlay = width >= label.size + 2

            prev = ""
            width.times do |i|
              color = i < fill ? pat[(i - phase) % width] : INK
              in_label = overlay && i >= start && i < start + label.size
              run =
                if in_label
                  ink = luma(color) > LUMA_TEXT ? INK : WHITE
                  ANSI.bold + ANSI.color24(ink, nil) + ANSI.color24(nil, color)
                else
                  ANSI.color24(nil, color)
                end
              if run != prev
                s << ANSI.reset << run
                prev = run
              end
              s << (in_label ? label[i - start] : ' ')
            end
          else
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
          end
          s << ANSI.reset
        end
      end

      # Logo ramp, dark → khaki (tmp/gradient_progressbar.rb): ink →
      # olive → dim khaki → the theme khaki. The white end is cut — in the
      # palette it only occupied the t=0.85..1.0 tail.
      private def self.logo_ramp(khaki : RGB) : Array(Stop)
        [{0.0, INK}, {0.35, OLIVE}, {0.7, KHAKI_DIM}, {1.0, khaki}]
      end

      # Cyclic version of the logo ramp: the same gradient traversed there
      # and back (ping-pong), so it closes without a seam — first and last
      # stops match (INK).
      private def self.carousel(khaki : RGB) : Array(Stop)
        ramp = logo_ramp(khaki)
        ramp.map { |p, c| {p / 2.0, c} } +
          ramp.reverse.skip(1).map { |p, c| {1 - p / 2.0, c} }
      end

      # Color at normalized position `t` (0..1) of a multi-stop ramp:
      # piecewise RGB interpolation between the two stops around `t`.
      private def self.sample(stops : Array(Stop), t : Float64) : RGB
        return stops.first[1] if t <= stops.first[0]
        return stops.last[1] if t >= stops.last[0]
        (stops.size - 1).times do |i|
          p0, c0 = stops[i]
          p1, c1 = stops[i + 1]
          next unless t >= p0 && t <= p1
          return mix(c0, c1, (t - p0) / (p1 - p0))
        end
        stops.last[1]
      end

      # RGB linear interpolation.
      private def self.mix(c0 : RGB, c1 : RGB, t : Float64) : RGB
        {
          (c0[0] + (c1[0] - c0[0]) * t).round.to_i,
          (c0[1] + (c1[1] - c0[1]) * t).round.to_i,
          (c0[2] + (c1[2] - c0[2]) * t).round.to_i,
        }
      end

      # Relative luminance of an RGB color.
      private def self.luma(c : RGB) : Float64
        0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
      end

      # Truecolor RGB of a 256-color index (the 6x6x6 cube and the
      # grayscale ramp). The 0..15 system palette has no fixed RGB mapping
      # — nil, and the bar renders statically.
      private def self.rgb256(color : Int32) : RGB?
        return nil if color < 16 || color > 255
        if color >= 232
          g = 8 + 10 * (color - 232)
          {g, g, g}
        else
          idx = color - 16
          {CUBE_LEVELS[idx // 36], CUBE_LEVELS[idx % 36 // 6], CUBE_LEVELS[idx % 6]}
        end
      end
    end
  end
end
