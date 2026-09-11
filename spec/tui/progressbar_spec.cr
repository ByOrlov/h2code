require "../spec_helper"

# Strip SGR escape sequences to get the visible cell content.
private def strip_ansi(s : String) : String
  s.gsub(/\e\[[0-9;]*m/, "")
end

# Per-cell bg colors, expanded from SGR runs — one String per visible
# cell, in order: the 256-color index ("144") or the truecolor triple
# ("175;175;135").
private def fill_bgs(line : String) : Array(String)
  bgs = [] of String
  line.scan(/\e\[(?:38;5;\d+;|38;2;\d+;\d+;\d+;)?48;(?:5;(\d+)|2;(\d+;\d+;\d+))m([^\e]*)/) do |m|
    color = m[1]? || m[2]
    m[3].size.times { bgs << color } if color
  end
  bgs
end

module H2code
  module TUI
    describe ProgressBar do
      it "draws a full-width solid bar with a centered percent label" do
        line = ProgressBar.render(5, 10, 20, khaki: 144)
        stripped = strip_ansi(line)
        stripped.size.should eq(20)
        stripped.should contain("50%")
        # Label centered: (20 - 3) // 2 = 8 → cells 8..10.
        stripped.index("50%").should eq(8)
      end

      it "inverts the label inside the fill and keeps khaki outside it" do
        line = ProgressBar.render(5, 10, 20, khaki: 144)
        # fill = 50 * 20 // 100 = 10 cells; the label straddles the boundary
        # (cells 8..10), so both the inverted and the normal segment appear.
        line.should contain(ANSI.color(0, 144))   # black on khaki (inverted)
        line.should contain(ANSI.color(144, nil)) # khaki on default bg
      end

      it "renders a fully filled inverted bar at 100%" do
        line = ProgressBar.render(4, 4, 20, khaki: 144)
        strip_ansi(line).should contain("100%")
        line.should contain(ANSI.color(0, 144))
        line.should_not contain(ANSI.color(144, nil))
      end

      it "renders an empty track with a khaki label at 0%" do
        line = ProgressBar.render(0, 3, 20, khaki: 144)
        stripped = strip_ansi(line)
        stripped.strip.should eq("0%")
        line.should contain(ANSI.color(144, nil))
        line.should_not contain(ANSI.color(0, 144))
      end

      it "treats a zero total as 0% without dividing by zero" do
        line = ProgressBar.render(0, 0, 20, khaki: 144)
        strip_ansi(line).should contain("0%")
      end

      it "clamps out-of-range inputs" do
        line = ProgressBar.render(9, 4, 20, khaki: 144)
        strip_ansi(line).should contain("100%")
      end

      it "detects the terminal width by default" do
        line = ProgressBar.render(1, 2)
        stripped = strip_ansi(line)
        stripped.size.should be > 0
        stripped.should contain("50%")
      end

      it "enforces a sane minimum width" do
        line = ProgressBar.render(1, 2, 0, khaki: 144)
        stripped = strip_ansi(line)
        stripped.size.should eq(8)
        stripped.should contain("50%")
      end

      describe "gradient carousel" do
        it "renders the flat 256-color base at phase 0" do
          line = ProgressBar.render(5, 10, 20, khaki: 144, phase: 0)
          line.should contain(ANSI.color(0, 144))
          line.should_not contain("48;2;")
        end

        it "scrolls the seamless logo ramp over the fill" do
          # Reference: tmp/gradient_progressbar.rb §3. Carousel stops over
          # width 20, offset 1: cell x samples t = ((x-1) mod 20)/20 of the
          # ping-pong ramp ink → olive → dim khaki → khaki (144 = #afaf87
          # = 175;175;135) → dim khaki → olive → ink.
          bgs = fill_bgs(ProgressBar.render(10, 10, 20, khaki: 144, phase: 1))
          bgs.size.should eq(20)
          bgs[1].should eq("26;26;26")     # t=0 — ink
          bgs[2].should eq("47;45;40")     # ink→olive, u=2/7
          bgs[6].should eq("122;118;94")   # olive→dim, u=3/7
          bgs[11].should eq("175;175;135") # t=0.5 — exactly the theme khaki crest
          bgs[19].should eq("67;63;53")    # olive→ink, u=3/7 on the way back
        end

        it "closes the cycle without a seam" do
          # The ping-pong ramp is symmetric: t just below 1.0 mirrors
          # t just above 0.0, so the wrap cell matches cell 2.
          bgs = fill_bgs(ProgressBar.render(10, 10, 20, khaki: 144, phase: 1))
          bgs[0].should eq(bgs[2])
        end

        it "keeps the track beyond the fill dark ink" do
          bgs = fill_bgs(ProgressBar.render(5, 10, 20, khaki: 144, phase: 1))
          bgs.size.should eq(20)
          (10...20).each { |i| bgs[i].should eq("26;26;26") }
        end

        it "overlays the label in bold with per-cell contrast" do
          # Width 20, 50%: the centered "50%" straddles bright fill cells
          # (ink text) and the dark ink track (white text) — per-cell luma.
          line = ProgressBar.render(5, 10, 20, khaki: 144, phase: 1)
          line.should contain(ANSI.bold)
          line.should contain("\e[38;2;255;255;255m") # white on the dark track
          line.should contain("\e[38;2;26;26;26m")    # ink on bright cells
        end

        it "scrolls one cell per tick" do
          one = fill_bgs(ProgressBar.render(10, 10, 20, khaki: 144, phase: 1))
          two = fill_bgs(ProgressBar.render(10, 10, 20, khaki: 144, phase: 2))
          two.should eq([one.last] + one[0..-2])
        end

        it "wraps around after a full width of ticks" do
          ProgressBar.render(10, 10, 20, khaki: 144, phase: 21)
            .should eq(ProgressBar.render(10, 10, 20, khaki: 144, phase: 1))
        end

        it "uses the theme color as the carousel crest" do
          # 250 is grayscale 188;188;188 — the crest at t=0.5 follows.
          bgs = fill_bgs(ProgressBar.render(10, 10, 20, khaki: 250, phase: 1))
          bgs[11].should eq("188;188;188")
        end

        it "renders system-palette colors flat" do
          # 0..15 have no fixed RGB mapping — static 256-color bar.
          line = ProgressBar.render(5, 10, 20, khaki: 9, phase: 1)
          line.should contain(ANSI.color(0, 9))
          line.should_not contain("48;2;")
        end
      end
    end
  end
end
