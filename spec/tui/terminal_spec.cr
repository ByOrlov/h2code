require "../spec_helper"

describe H2code::TUI::Terminal do
  describe ".extract_dsr_replies" do
    it "extracts cursor columns in reply order" do
      cols, leftovers = H2code::TUI::Terminal.extract_dsr_replies("\e[1;3R\e[2;5R")
      cols.should eq([3, 5])
      leftovers.should be_empty
    end

    it "keeps interleaved keystrokes as leftovers" do
      cols, leftovers = H2code::TUI::Terminal.extract_dsr_replies("a\e[1;2Rbc\e[3;4Rd")
      cols.should eq([2, 4])
      leftovers.map(&.chr).join.should eq("abcd")
    end

    it "does not mistake key encodings for CPR replies" do
      # kitty CSI-u and arrow sequences never end in R
      cols, leftovers = H2code::TUI::Terminal.extract_dsr_replies("\e[97;1u\e[1;5A\eA")
      cols.should be_empty
      leftovers.map(&.chr).join.should eq("\e[97;1u\e[1;5A\eA")
    end

    it "ignores malformed escapes" do
      input = {"\e[;R", "\e[12;R", "\e[1;xR"}
      cols, leftovers = H2code::TUI::Terminal.extract_dsr_replies(input.join)
      cols.should be_empty
      leftovers.map(&.chr).join.should eq(input.join)
    end
  end
end
