require "../spec_helper"

# Verify the layered width-calculation architecture mirrors the TS pipeline in
# `packages/pi-tui/src/utils.ts` (visibleWidth / asciiVisibleWidth /
# truncateToWidth / sliceWithWidth / extractAnsiCode).
describe H2code::TUI::CharWidth do
  describe ".visible_width (codepoint_width layers)" do
    it "measures ASCII as 1 per char" do
      H2code::TUI::CharWidth.visible_width("hello").should eq(5)
    end

    it "takes the printable-ASCII fast path (spaces ok)" do
      H2code::TUI::CharWidth.visible_width("a b c").should eq(5)
    end

    it "counts default-emoji-presentation glyphs as width 2" do
      H2code::TUI::CharWidth.visible_width("ok \u274C").should eq(5) # 2 + 1 + 2
      H2code::TUI::CharWidth.visible_width("\u2705").should eq(2)    # ✅
      H2code::TUI::CharWidth.visible_width("\u26A1").should eq(2)    # ⚡ emoji-default
      # U+23xx emoji-default glyphs (⏳ ⏰ ⌛ ⏩): without these in
      # EMOJI_RANGES the width fell through to East Asian Width (1) while
      # terminals render them 2 cells wide, shifting table rows (⏳ bug).
      H2code::TUI::CharWidth.visible_width("\u23F3").should eq(2) # ⏳
      H2code::TUI::CharWidth.visible_width("\u23F0").should eq(2) # ⏰
      H2code::TUI::CharWidth.visible_width("\u231B").should eq(2) # ⌛
      H2code::TUI::CharWidth.visible_width("\u23E9").should eq(2) # ⏩
    end

    describe "terminal-probed overrides" do
      after_each do
        H2code::TUI::CharWidth.clear_probed_widths
      end

      it "overrides the static table with measured widths" do
        H2code::TUI::CharWidth.visible_width("\u26A0").should eq(1) # ⚠ table default
        H2code::TUI::CharWidth.apply_probed_widths({0x26A0_u32 => 2})
        H2code::TUI::CharWidth.visible_width("\u26A0").should eq(2)
      end

      it "keeps the override out of unprobed codepoints" do
        H2code::TUI::CharWidth.apply_probed_widths({0x23F3_u32 => 2})
        H2code::TUI::CharWidth.visible_width("\u2705").should eq(2) # ✅ table
        H2code::TUI::CharWidth.visible_width("a").should eq(1)
      end

      it "probes the BMP emoji-presentation set plus anchors" do
        candidates = H2code::TUI::CharWidth.probe_candidates
        candidates.should contain(0x23F3_u32)  # ⏳
        candidates.should contain(0x2705_u32)  # ✅
        candidates.should contain(0x26A0_u32)  # ⚠ text-default anchor
        candidates.should contain(0x1F504_u32) # 🔄 supplementary anchor
      end
    end

    it "treats text-default emoji glyphs as width 1 without VS16" do
      # ⚠ (U+26A0) defaults to TEXT presentation in terminals -> width 1.
      # Mirrors the `\p{RGI_Emoji}` gate in TS `graphemeWidth`: a bare
      # codepoint is width 2 only with Emoji_Presentation=Yes. Regression for
      # the table-alignment bug where the ⚠ row's right border drifted left.
      H2code::TUI::CharWidth.visible_width("\u26A0").should eq(1) # ⚠ bare (text)
    end

    it "promotes a text-default glyph to width 2 with VS16 selector" do
      H2code::TUI::CharWidth.visible_width("\u26A0\uFE0F").should eq(2) # ⚠️
    end

    it "counts CJK as width 2" do
      H2code::TUI::CharWidth.visible_width("\u4f60\u597d").should eq(4) # 你好
    end

    it "counts fullwidth forms as width 2" do
      H2code::TUI::CharWidth.visible_width("\uFF21").should eq(2) # Ａ
    end

    it "counts combining marks as width 0" do
      # e (1) + combining acute (0) = 1
      H2code::TUI::CharWidth.visible_width("e\u0301").should eq(1)
    end

    it "measures Devanagari matras (Hindi) as zero-width" do
      # हिनदी = ह(U+0939,1) + ि(U+093F,0) + न(U+0928,1) + द(U+0926,1) + ी(U+0940,0) = 3
      # Regression for the markdown table misalignment: U+093F / U+0940 were
      # previously missing from the zero-width table and counted as width 1.
      H2code::TUI::CharWidth.visible_width("हिनदी").should eq(3)
      H2code::TUI::CharWidth.codepoint_width(0x093F_u32).should eq(0)
      H2code::TUI::CharWidth.codepoint_width(0x0940_u32).should eq(0)
    end

    it "measures Korean Hangul syllables as width 2 each" do
      # 한국어 = 3 syllables, each width 2 = 6
      H2code::TUI::CharWidth.visible_width("한국어").should eq(6)
    end

    it "measures other Indic combining marks as zero-width" do
      # Thai vowel signs (U+0E34..U+0E3A are Marks)
      H2code::TUI::CharWidth.visible_width("ครับ").should eq(3)
      # Tamil combining marks
      H2code::TUI::CharWidth.codepoint_width(0x0BC2_u32).should eq(0)
    end

    it "treats a ZWJ emoji sequence as a single width-2 cluster" do
      # family: U+1F468 ZWJ U+1F469  -> one cluster, width 2
      H2code::TUI::CharWidth.visible_width("\u{1F468}\u200D\u{1F469}").should eq(2)
    end

    it "counts a regional-indicator pair (flag) as width 2" do
      # 🇯🇵 = JP flag
      H2code::TUI::CharWidth.visible_width("\u{1F1EF}\u{1F1F5}").should eq(2)
    end

    it "ignores ANSI SGR escapes" do
      H2code::TUI::CharWidth.visible_width("\e[1mbold\e[0m").should eq(4)
    end

    it "ignores OSC 8 hyperlink escapes" do
      line = "\e]8;;https://example.test\e\\text\e]8;;\e\\"
      H2code::TUI::CharWidth.visible_width(line).should eq(4)
    end

    it "expands tabs to 3 columns" do
      H2code::TUI::CharWidth.visible_width("a\tb").should eq(5) # 1 + 3 + 1
    end

    it "returns 0 for empty string" do
      H2code::TUI::CharWidth.visible_width("").should eq(0)
    end
  end

  describe ".visible_width cache" do
    it "returns consistent results across calls" do
      H2code::TUI::CharWidth.clear_cache
      # ❌(2) space(1) 你好(4) space(1) ✅(2) = 10
      s = "\u274C \u4f60\u597d \u2705"
      first = H2code::TUI::CharWidth.visible_width(s)
      second = H2code::TUI::CharWidth.visible_width(s)
      second.should eq(first)
      first.should eq(10)
    end
  end

  describe ".ascii_visible_width" do
    it "returns width for plain ASCII" do
      H2code::TUI::CharWidth.ascii_visible_width("hello", 100).should eq(5)
    end

    it "skips ANSI escapes" do
      H2code::TUI::CharWidth.ascii_visible_width("\e[1mhi\e[0m", 100).should eq(2)
    end

    it "returns nil for non-ASCII content" do
      H2code::TUI::CharWidth.ascii_visible_width("café", 100).should be_nil
    end

    it "returns nil for control characters" do
      H2code::TUI::CharWidth.ascii_visible_width("a\tb", 100).should be_nil
    end

    it "early-exits past the limit" do
      val = H2code::TUI::CharWidth.ascii_visible_width("abcdefgh", 3)
      val.should eq(4) # exceeds limit of 3 -> returns partial count
    end
  end

  describe ".extract_ansi_code" do
    it "extracts a CSI SGR sequence" do
      ansi = H2code::TUI::CharWidth.extract_ansi_code("\e[1;31mtext", 0)
      ansi.should_not be_nil
      if a = ansi
        a.code.should eq("\e[1;31m")
        a.length.should eq(7)
      end
    end

    it "extracts an OSC sequence terminated by ST" do
      ansi = H2code::TUI::CharWidth.extract_ansi_code("\e]8;;url\e\\x", 0)
      ansi.should_not be_nil
      if a = ansi
        a.code.should eq("\e]8;;url\e\\")
        a.length.should eq(10)
      end
    end

    it "extracts an OSC sequence terminated by BEL" do
      ansi = H2code::TUI::CharWidth.extract_ansi_code("\e]0;title\u0007x", 0)
      ansi.should_not be_nil
      if a = ansi
        a.code.should eq("\e]0;title\u0007")
      end
    end

    it "returns nil at a non-escape position" do
      H2code::TUI::CharWidth.extract_ansi_code("plain", 0).should be_nil
    end
  end

  describe ".truncate_to_width" do
    it "keeps text shorter than the limit" do
      H2code::TUI::CharWidth.truncate_to_width("hi", 10).should eq("hi")
    end

    it "pads short text when pad is true" do
      H2code::TUI::CharWidth.truncate_to_width("hi", 5, pad: true).should eq("hi   ")
    end

    it "truncates with ellipsis" do
      result = H2code::TUI::CharWidth.truncate_to_width("hello world", 8)
      result.should contain("...")
      H2code::TUI::CharWidth.visible_width(result).should be <= 8
    end

    it "truncates wide-char text by display width" do
      # 4 CJK chars = width 8; truncate to width 6 -> keep 2 chars (4) + ellipsis (3) = 7
      result = H2code::TUI::CharWidth.truncate_to_width("\u4f60\u4eec\u597d\u5417", 6)
      H2code::TUI::CharWidth.visible_width(result).should be <= 6
      result.should contain("...")
    end
  end

  describe ".slice_with_width" do
    it "slices an ASCII range" do
      r = H2code::TUI::CharWidth.slice_with_width("abcdef", 1, 3)
      r.text.should eq("bcd")
      r.width.should eq(3)
    end

    it "counts width correctly across wide chars" do
      # "a你好b": cols a(1) 你(2) 好(2) b(1). Slice cols [1,4) -> 你好 (width 4)
      r = H2code::TUI::CharWidth.slice_with_width("a\u4f60\u597db", 1, 4)
      r.text.should eq("\u4f60\u597d")
      r.width.should eq(4)
    end

    it "returns empty for non-positive length" do
      r = H2code::TUI::CharWidth.slice_with_width("abc", 0, 0)
      r.text.should eq("")
      r.width.should eq(0)
    end
  end

  describe "classification predicates" do
    it "detects emoji codepoints" do
      H2code::TUI::CharWidth.could_be_emoji?(0x274C_u32).should be_true  # ❌
      H2code::TUI::CharWidth.could_be_emoji?(0x0041_u32).should be_false # A
    end

    it "detects zero-width codepoints" do
      H2code::TUI::CharWidth.zero_width?(0x0301_u32).should be_true # combining acute
      H2code::TUI::CharWidth.zero_width?(0xFE0F_u32).should be_true # VS16
      H2code::TUI::CharWidth.zero_width?(0x0041_u32).should be_false
    end

    it "detects CJK for word-breaking" do
      H2code::TUI::CharWidth.cjk_break?(0x4F60_u32).should be_true # 你
      H2code::TUI::CharWidth.cjk_break?(0x0041_u32).should be_false
    end
  end

  describe ".slice_into_width_chunks" do
    it "returns the whole string as a single chunk when it fits" do
      chunks = H2code::TUI::CharWidth.slice_into_width_chunks("hello", 10)
      chunks.should eq(["hello"])
    end

    it "hard-breaks a wide CJK string into column-width chunks" do
      # 6 CJK chars = width 12; max_width 4 -> 3 chunks of width 4 (2 chars each)
      chunks = H2code::TUI::CharWidth.slice_into_width_chunks("\u4f60\u4eec\u597d\u5417\u5927\u5bb6", 4)
      chunks.size.should eq(3)
      chunks.each { |c| H2code::TUI::CharWidth.visible_width(c).should be <= 4 }
    end

    it "handles ASCII longer than max_width" do
      chunks = H2code::TUI::CharWidth.slice_into_width_chunks("abcdefghij", 4)
      chunks.size.should eq(3)
      chunks[0].should eq("abcd")
      chunks[1].should eq("efgh")
      chunks[2].should eq("ij")
    end
  end

  describe ".visible_width cache eviction" do
    it "does not grow beyond WIDTH_CACHE_SIZE" do
      H2code::TUI::CharWidth.clear_cache
      # Insert well over the limit; the soft-clear eviction must keep the
      # cache bounded instead of growing unboundedly.
      (0..5000).each { |i| H2code::TUI::CharWidth.visible_width("k#{i}") }
      H2code::TUI::CharWidth.cache_count.should be <= H2code::TUI::CharWidth::WIDTH_CACHE_SIZE
      H2code::TUI::CharWidth.clear_cache
    end
  end
end
