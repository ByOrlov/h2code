require "../spec_helper"

# Strip SGR escape sequences to get the visible cell content.
private def strip_ansi(s : String) : String
  s.gsub(/\e\[[0-9;]*m/, "")
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
    end
  end
end
