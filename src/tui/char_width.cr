module H2code
  module TUI
    # Terminal column-width measurement, mirroring the layered architecture of
    # the TypeScript `visibleWidth` pipeline in `packages/pi-tui/src/utils.ts`.
    #
    # Layering (each arrow names the TS counterpart):
    #
    #   printable_ascii?  ---- fast path                          isPrintableAscii
    #   extract_ansi_code ---- strip CSI/OSC/APC escapes          extractAnsiCode
    #   grapheme_width    ---- per-cluster width                  graphemeWidth
    #     |- zero_width?        ---- zero-width codepoints        zeroWidthRegex
    #     |- could_be_emoji?    ---- emoji pre-filter             couldBeEmoji + RGI
    #     |- east_asian_width   ---- W/F codepoints               get-east-asian-width
    #   visible_width     ---- main entry: fast path + LRU cache  visibleWidth
    #                          + normalization + grapheme walk
    #   ascii_visible_width - bounded fast ASCII scan             asciiVisibleWidth
    #   truncate_to_width ---- ellipsis truncation                truncateToWidth
    #   slice_with_width  ---- column-range slicing               sliceWithWidth
    #
    # Crystal has no `Intl.Segmenter`, so grapheme clustering is approximated by
    # an index walker over codepoints (base + combining marks, regional-indicator
    # pairs, ZWJ emoji chains) — sufficient for width accounting.
    module CharWidth
      # ------------------------------------------------------------------------
      # Cache (mirrors `widthCache` + `WIDTH_CACHE_SIZE`, FIFO eviction)
      # ------------------------------------------------------------------------
      WIDTH_CACHE_SIZE = 4096
      @@width_cache = {} of String => Int32

      private def self.cache_get(str : String) : Int32?
        @@width_cache[str]?
      end

      private def self.cache_put(str : String, width : Int32) : Nil
        # Soft eviction: when full, drop the entire cache in one shot rather
        # than evicting key-by-key. Amortizes the O(n) Hash rehash across a
        # full generation of entries (n inserts at O(1), then one O(n) clear),
        # instead of paying O(n) on every insert past the limit. Mirrors the
        # amortization rationale noted in pi-tui's AGENTS.md cache notes.
        @@width_cache.clear if @@width_cache.size >= WIDTH_CACHE_SIZE
        @@width_cache[str] = width
      end

      # Test-only: drop the width cache between cases.
      def self.clear_cache : Nil
        @@width_cache.clear
      end

      # Widths measured from the terminal itself at startup (see
      # `Terminal#probe_codepoint_widths`): the real renderer's answer
      # overrides the static Unicode tables for the probed codepoints.
      @@probed_widths = {} of UInt32 => Int32

      def self.apply_probed_widths(widths : Hash(UInt32, Int32)) : Nil
        @@probed_widths = widths
        # Cached strings were measured with the table defaults.
        @@width_cache.clear
      end

      # Test-only: drop terminal-measured overrides.
      def self.clear_probed_widths : Nil
        @@probed_widths.clear
      end

      def self.cache_bytes : Int64
        @@width_cache.keys.sum(&.profiled_bytes)
      end

      def self.cache_count : Int32
        @@width_cache.size
      end

      # ------------------------------------------------------------------------
      # Classification tables
      # ------------------------------------------------------------------------
      # East Asian Wide / Fullwidth ranges (Unicode East Asian Width property W/F).
      WIDE_RANGES = {
        {0x1100_u32, 0x115F_u32},   # Hangul Jamo
        {0x2329_u32, 0x2329_u32},   # LEFT-POINTING ANGLE BRACKET
        {0x232A_u32, 0x232A_u32},   # RIGHT-POINTING ANGLE BRACKET
        {0x2E80_u32, 0x303E_u32},   # CJK radicals, Kangxi, CJK symbols
        {0x3040_u32, 0x33BF_u32},   # Hiragana, Katakana, Bopomofo, Hangul compat
        {0x3400_u32, 0x4DBF_u32},   # CJK Unified Ideographs Extension A
        {0x4E00_u32, 0xA4CF_u32},   # CJK Unified Ideographs, Yi
        {0xA960_u32, 0xA97F_u32},   # Hangul Jamo Extended-A
        {0xAC00_u32, 0xD7A3_u32},   # Hangul Syllables
        {0xF900_u32, 0xFAFF_u32},   # CJK Compatibility Ideographs
        {0xFE10_u32, 0xFE19_u32},   # Vertical forms
        {0xFE30_u32, 0xFE6F_u32},   # CJK Compatibility Forms
        {0xFF00_u32, 0xFF60_u32},   # Fullwidth Forms
        {0xFFE0_u32, 0xFFE6_u32},   # Fullwidth signs
        {0x1F300_u32, 0x1FAFF_u32}, # Symbols & Pictographs + extensions
        {0x20000_u32, 0x3FFFD_u32}, # CJK Unified Ideographs Extensions B+
      }

      # Broad pre-filter for codepoints that *could* be emoji. Mirrors the
      # `couldBeEmoji` block pre-filter in TS — this is NOT a width decision.
      # A codepoint here is width 2 only if it defaults to emoji presentation
      # (`default_emoji_presentation?`) or is followed by U+FE0F (handled in
      # `grapheme_width`); otherwise it falls through to East Asian Width
      # (e.g. ⚠ U+26A0 renders as text by default → width 1).
      EMOJI_RANGES = {
        {0x231A_u32, 0x231B_u32},   # ⌚ ⌛ (Miscellaneous Technical emoji)
        {0x23E9_u32, 0x23EC_u32},   # ⏩..⏬
        {0x23F0_u32, 0x23F0_u32},   # ⏰
        {0x23F3_u32, 0x23F3_u32},   # ⏳
        {0x2600_u32, 0x26FF_u32},   # Miscellaneous Symbols (⚠ U+26A0 text-default, ⚡ U+26A1 emoji-default)
        {0x2700_u32, 0x27BF_u32},   # Dingbats (incl. ✅ U+2705, ❌ U+274C)
        {0x2B50_u32, 0x2B55_u32},   # Stars
        {0x1F000_u32, 0x1F02F_u32}, # Mahjong tiles
        {0x1F0A0_u32, 0x1F0FF_u32}, # Playing cards
        {0x1F100_u32, 0x1F2FF_u32}, # Enclosed alphanumeric supplement
        {0x1F1E6_u32, 0x1F1FF_u32}, # Regional indicator symbols
        {0x1F300_u32, 0x1FAFF_u32}, # Symbols & Pictographs + extensions (smileys, people, ...)
        {0x1FB00_u32, 0x1FBFF_u32}, # Symbols and Pictographs Extended-A
      }

      # BMP codepoints with `Emoji_Presentation=Yes` — they render as emoji
      # (width 2) by default, without needing a U+FE0F selector. Counterpart
      # of the single-codepoint branch of `\p{RGI_Emoji}` in TS `graphemeWidth`.
      # Supplementary pictograph blocks (>= U+1F000) are emoji by default and
      # handled directly in `default_emoji_presentation?`. Notably EXCLUDES ⚠
      # U+26A0 (text presentation) while INCLUDING its neighbor ⚡ U+26A1.
      EMOJI_PRESENTATION_RANGES = {
        {0x231A_u32, 0x231B_u32}, # ⌚ ⌛
        {0x23E9_u32, 0x23EC_u32}, # ⏩..⏬
        {0x23F0_u32, 0x23F0_u32}, # ⏰
        {0x23F3_u32, 0x23F3_u32}, # ⏳
        {0x25FD_u32, 0x25FE_u32}, # ◽ ◾
        {0x2614_u32, 0x2615_u32}, # ☔ ☕
        {0x2648_u32, 0x2653_u32}, # ♈..♓ zodiac
        {0x267F_u32, 0x267F_u32}, # ♿
        {0x2693_u32, 0x2693_u32}, # ⚓
        {0x26A1_u32, 0x26A1_u32}, # ⚡ (⚠ U+26A0 is NOT in this table)
        {0x26AA_u32, 0x26AB_u32}, # ⚪ ⚫
        {0x26BD_u32, 0x26BE_u32}, # ⚽ ⚾
        {0x26C4_u32, 0x26C5_u32}, # ⛄ ⛅
        {0x26CE_u32, 0x26CE_u32}, # ⛎
        {0x26D4_u32, 0x26D4_u32}, # ⛔
        {0x26EA_u32, 0x26EA_u32}, # ⛪
        {0x26F2_u32, 0x26F3_u32}, # ⛲ ⛳
        {0x26F5_u32, 0x26F5_u32}, # ⛵
        {0x26FA_u32, 0x26FA_u32}, # ⛺
        {0x26FD_u32, 0x26FD_u32}, # ⛽
        {0x2705_u32, 0x2705_u32}, # ✅
        {0x270A_u32, 0x270B_u32}, # ✊ ✋
        {0x2728_u32, 0x2728_u32}, # ✨
        {0x274C_u32, 0x274C_u32}, # ❌
        {0x274E_u32, 0x274E_u32}, # ❎
        {0x2753_u32, 0x2755_u32}, # ❓ ❔ ❕
        {0x2757_u32, 0x2757_u32}, # ❗
        {0x2795_u32, 0x2797_u32}, # ➕ ➖ ➗
        {0x27B0_u32, 0x27B0_u32}, # ➰
        {0x27BF_u32, 0x27BF_u32}, # ➿
        {0x2B1B_u32, 0x2B1C_u32}, # ⬛ ⬜
        {0x2B50_u32, 0x2B50_u32}, # ⭐
        {0x2B55_u32, 0x2B55_u32}, # ⭕
      }

      # All Unicode General_Category=Mark codepoints (Mn|Mc|Me), generated from
      # the engine's `\p{M}` support and coalesced into consecutive ranges.
      # This is the complete `\p{Mark}` counterpart that the TS reference applies
      # via `zeroWidthRegex = /(?:\p{Default_Ignorable_Code_Point}|\p{Control}|\p{Mark}|\p{Surrogate})+/v`.
      # The previous explicit table only covered a fraction of Devanagari and
      # other Indic matras, so e.g. U+093F / U+0940 were mis-measured as width 1
      # and misaligned markdown tables containing Hindi. Sorted ascending;
      # queried via `mark?` (binary search). ZWJ (U+200D) is NOT a Mark and is
      # consumed explicitly by the grapheme walker.
      MARK_RANGES = [
        {0x300_u32, 0x36F_u32},
        {0x483_u32, 0x489_u32},
        {0x591_u32, 0x5BD_u32},
        {0x5BF_u32, 0x5BF_u32},
        {0x5C1_u32, 0x5C2_u32},
        {0x5C4_u32, 0x5C5_u32},
        {0x5C7_u32, 0x5C7_u32},
        {0x610_u32, 0x61A_u32},
        {0x64B_u32, 0x65F_u32},
        {0x670_u32, 0x670_u32},
        {0x6D6_u32, 0x6DC_u32},
        {0x6DF_u32, 0x6E4_u32},
        {0x6E7_u32, 0x6E8_u32},
        {0x6EA_u32, 0x6ED_u32},
        {0x711_u32, 0x711_u32},
        {0x730_u32, 0x74A_u32},
        {0x7A6_u32, 0x7B0_u32},
        {0x7EB_u32, 0x7F3_u32},
        {0x7FD_u32, 0x7FD_u32},
        {0x816_u32, 0x819_u32},
        {0x81B_u32, 0x823_u32},
        {0x825_u32, 0x827_u32},
        {0x829_u32, 0x82D_u32},
        {0x859_u32, 0x85B_u32},
        {0x897_u32, 0x89F_u32},
        {0x8CA_u32, 0x8E1_u32},
        {0x8E3_u32, 0x903_u32},
        {0x93A_u32, 0x93C_u32},
        {0x93E_u32, 0x94F_u32},
        {0x951_u32, 0x957_u32},
        {0x962_u32, 0x963_u32},
        {0x981_u32, 0x983_u32},
        {0x9BC_u32, 0x9BC_u32},
        {0x9BE_u32, 0x9C4_u32},
        {0x9C7_u32, 0x9C8_u32},
        {0x9CB_u32, 0x9CD_u32},
        {0x9D7_u32, 0x9D7_u32},
        {0x9E2_u32, 0x9E3_u32},
        {0x9FE_u32, 0x9FE_u32},
        {0xA01_u32, 0xA03_u32},
        {0xA3C_u32, 0xA3C_u32},
        {0xA3E_u32, 0xA42_u32},
        {0xA47_u32, 0xA48_u32},
        {0xA4B_u32, 0xA4D_u32},
        {0xA51_u32, 0xA51_u32},
        {0xA70_u32, 0xA71_u32},
        {0xA75_u32, 0xA75_u32},
        {0xA81_u32, 0xA83_u32},
        {0xABC_u32, 0xABC_u32},
        {0xABE_u32, 0xAC5_u32},
        {0xAC7_u32, 0xAC9_u32},
        {0xACB_u32, 0xACD_u32},
        {0xAE2_u32, 0xAE3_u32},
        {0xAFA_u32, 0xAFF_u32},
        {0xB01_u32, 0xB03_u32},
        {0xB3C_u32, 0xB3C_u32},
        {0xB3E_u32, 0xB44_u32},
        {0xB47_u32, 0xB48_u32},
        {0xB4B_u32, 0xB4D_u32},
        {0xB55_u32, 0xB57_u32},
        {0xB62_u32, 0xB63_u32},
        {0xB82_u32, 0xB82_u32},
        {0xBBE_u32, 0xBC2_u32},
        {0xBC6_u32, 0xBC8_u32},
        {0xBCA_u32, 0xBCD_u32},
        {0xBD7_u32, 0xBD7_u32},
        {0xC00_u32, 0xC04_u32},
        {0xC3C_u32, 0xC3C_u32},
        {0xC3E_u32, 0xC44_u32},
        {0xC46_u32, 0xC48_u32},
        {0xC4A_u32, 0xC4D_u32},
        {0xC55_u32, 0xC56_u32},
        {0xC62_u32, 0xC63_u32},
        {0xC81_u32, 0xC83_u32},
        {0xCBC_u32, 0xCBC_u32},
        {0xCBE_u32, 0xCC4_u32},
        {0xCC6_u32, 0xCC8_u32},
        {0xCCA_u32, 0xCCD_u32},
        {0xCD5_u32, 0xCD6_u32},
        {0xCE2_u32, 0xCE3_u32},
        {0xCF3_u32, 0xCF3_u32},
        {0xD00_u32, 0xD03_u32},
        {0xD3B_u32, 0xD3C_u32},
        {0xD3E_u32, 0xD44_u32},
        {0xD46_u32, 0xD48_u32},
        {0xD4A_u32, 0xD4D_u32},
        {0xD57_u32, 0xD57_u32},
        {0xD62_u32, 0xD63_u32},
        {0xD81_u32, 0xD83_u32},
        {0xDCA_u32, 0xDCA_u32},
        {0xDCF_u32, 0xDD4_u32},
        {0xDD6_u32, 0xDD6_u32},
        {0xDD8_u32, 0xDDF_u32},
        {0xDF2_u32, 0xDF3_u32},
        {0xE31_u32, 0xE31_u32},
        {0xE34_u32, 0xE3A_u32},
        {0xE47_u32, 0xE4E_u32},
        {0xEB1_u32, 0xEB1_u32},
        {0xEB4_u32, 0xEBC_u32},
        {0xEC8_u32, 0xECE_u32},
        {0xF18_u32, 0xF19_u32},
        {0xF35_u32, 0xF35_u32},
        {0xF37_u32, 0xF37_u32},
        {0xF39_u32, 0xF39_u32},
        {0xF3E_u32, 0xF3F_u32},
        {0xF71_u32, 0xF84_u32},
        {0xF86_u32, 0xF87_u32},
        {0xF8D_u32, 0xF97_u32},
        {0xF99_u32, 0xFBC_u32},
        {0xFC6_u32, 0xFC6_u32},
        {0x102B_u32, 0x103E_u32},
        {0x1056_u32, 0x1059_u32},
        {0x105E_u32, 0x1060_u32},
        {0x1062_u32, 0x1064_u32},
        {0x1067_u32, 0x106D_u32},
        {0x1071_u32, 0x1074_u32},
        {0x1082_u32, 0x108D_u32},
        {0x108F_u32, 0x108F_u32},
        {0x109A_u32, 0x109D_u32},
        {0x135D_u32, 0x135F_u32},
        {0x1712_u32, 0x1715_u32},
        {0x1732_u32, 0x1734_u32},
        {0x1752_u32, 0x1753_u32},
        {0x1772_u32, 0x1773_u32},
        {0x17B4_u32, 0x17D3_u32},
        {0x17DD_u32, 0x17DD_u32},
        {0x180B_u32, 0x180D_u32},
        {0x180F_u32, 0x180F_u32},
        {0x1885_u32, 0x1886_u32},
        {0x18A9_u32, 0x18A9_u32},
        {0x1920_u32, 0x192B_u32},
        {0x1930_u32, 0x193B_u32},
        {0x1A17_u32, 0x1A1B_u32},
        {0x1A55_u32, 0x1A5E_u32},
        {0x1A60_u32, 0x1A7C_u32},
        {0x1A7F_u32, 0x1A7F_u32},
        {0x1AB0_u32, 0x1ACE_u32},
        {0x1B00_u32, 0x1B04_u32},
        {0x1B34_u32, 0x1B44_u32},
        {0x1B6B_u32, 0x1B73_u32},
        {0x1B80_u32, 0x1B82_u32},
        {0x1BA1_u32, 0x1BAD_u32},
        {0x1BE6_u32, 0x1BF3_u32},
        {0x1C24_u32, 0x1C37_u32},
        {0x1CD0_u32, 0x1CD2_u32},
        {0x1CD4_u32, 0x1CE8_u32},
        {0x1CED_u32, 0x1CED_u32},
        {0x1CF4_u32, 0x1CF4_u32},
        {0x1CF7_u32, 0x1CF9_u32},
        {0x1DC0_u32, 0x1DFF_u32},
        {0x20D0_u32, 0x20F0_u32},
        {0x2CEF_u32, 0x2CF1_u32},
        {0x2D7F_u32, 0x2D7F_u32},
        {0x2DE0_u32, 0x2DFF_u32},
        {0x302A_u32, 0x302F_u32},
        {0x3099_u32, 0x309A_u32},
        {0xA66F_u32, 0xA672_u32},
        {0xA674_u32, 0xA67D_u32},
        {0xA69E_u32, 0xA69F_u32},
        {0xA6F0_u32, 0xA6F1_u32},
        {0xA802_u32, 0xA802_u32},
        {0xA806_u32, 0xA806_u32},
        {0xA80B_u32, 0xA80B_u32},
        {0xA823_u32, 0xA827_u32},
        {0xA82C_u32, 0xA82C_u32},
        {0xA880_u32, 0xA881_u32},
        {0xA8B4_u32, 0xA8C5_u32},
        {0xA8E0_u32, 0xA8F1_u32},
        {0xA8FF_u32, 0xA8FF_u32},
        {0xA926_u32, 0xA92D_u32},
        {0xA947_u32, 0xA953_u32},
        {0xA980_u32, 0xA983_u32},
        {0xA9B3_u32, 0xA9C0_u32},
        {0xA9E5_u32, 0xA9E5_u32},
        {0xAA29_u32, 0xAA36_u32},
        {0xAA43_u32, 0xAA43_u32},
        {0xAA4C_u32, 0xAA4D_u32},
        {0xAA7B_u32, 0xAA7D_u32},
        {0xAAB0_u32, 0xAAB0_u32},
        {0xAAB2_u32, 0xAAB4_u32},
        {0xAAB7_u32, 0xAAB8_u32},
        {0xAABE_u32, 0xAABF_u32},
        {0xAAC1_u32, 0xAAC1_u32},
        {0xAAEB_u32, 0xAAEF_u32},
        {0xAAF5_u32, 0xAAF6_u32},
        {0xABE3_u32, 0xABEA_u32},
        {0xABEC_u32, 0xABED_u32},
        {0xFB1E_u32, 0xFB1E_u32},
        {0xFE00_u32, 0xFE0F_u32},
        {0xFE20_u32, 0xFE2F_u32},
        {0x101FD_u32, 0x101FD_u32},
        {0x102E0_u32, 0x102E0_u32},
        {0x10376_u32, 0x1037A_u32},
        {0x10A01_u32, 0x10A03_u32},
        {0x10A05_u32, 0x10A06_u32},
        {0x10A0C_u32, 0x10A0F_u32},
        {0x10A38_u32, 0x10A3A_u32},
        {0x10A3F_u32, 0x10A3F_u32},
        {0x10AE5_u32, 0x10AE6_u32},
        {0x10D24_u32, 0x10D27_u32},
        {0x10D69_u32, 0x10D6D_u32},
        {0x10EAB_u32, 0x10EAC_u32},
        {0x10EFC_u32, 0x10EFF_u32},
        {0x10F46_u32, 0x10F50_u32},
        {0x10F82_u32, 0x10F85_u32},
        {0x11000_u32, 0x11002_u32},
        {0x11038_u32, 0x11046_u32},
        {0x11070_u32, 0x11070_u32},
        {0x11073_u32, 0x11074_u32},
        {0x1107F_u32, 0x11082_u32},
        {0x110B0_u32, 0x110BA_u32},
        {0x110C2_u32, 0x110C2_u32},
        {0x11100_u32, 0x11102_u32},
        {0x11127_u32, 0x11134_u32},
        {0x11145_u32, 0x11146_u32},
        {0x11173_u32, 0x11173_u32},
        {0x11180_u32, 0x11182_u32},
        {0x111B3_u32, 0x111C0_u32},
        {0x111C9_u32, 0x111CC_u32},
        {0x111CE_u32, 0x111CF_u32},
        {0x1122C_u32, 0x11237_u32},
        {0x1123E_u32, 0x1123E_u32},
        {0x11241_u32, 0x11241_u32},
        {0x112DF_u32, 0x112EA_u32},
        {0x11300_u32, 0x11303_u32},
        {0x1133B_u32, 0x1133C_u32},
        {0x1133E_u32, 0x11344_u32},
        {0x11347_u32, 0x11348_u32},
        {0x1134B_u32, 0x1134D_u32},
        {0x11357_u32, 0x11357_u32},
        {0x11362_u32, 0x11363_u32},
        {0x11366_u32, 0x1136C_u32},
        {0x11370_u32, 0x11374_u32},
        {0x113B8_u32, 0x113C0_u32},
        {0x113C2_u32, 0x113C2_u32},
        {0x113C5_u32, 0x113C5_u32},
        {0x113C7_u32, 0x113CA_u32},
        {0x113CC_u32, 0x113D0_u32},
        {0x113D2_u32, 0x113D2_u32},
        {0x113E1_u32, 0x113E2_u32},
        {0x11435_u32, 0x11446_u32},
        {0x1145E_u32, 0x1145E_u32},
        {0x114B0_u32, 0x114C3_u32},
        {0x115AF_u32, 0x115B5_u32},
        {0x115B8_u32, 0x115C0_u32},
        {0x115DC_u32, 0x115DD_u32},
        {0x11630_u32, 0x11640_u32},
        {0x116AB_u32, 0x116B7_u32},
        {0x1171D_u32, 0x1172B_u32},
        {0x1182C_u32, 0x1183A_u32},
        {0x11930_u32, 0x11935_u32},
        {0x11937_u32, 0x11938_u32},
        {0x1193B_u32, 0x1193E_u32},
        {0x11940_u32, 0x11940_u32},
        {0x11942_u32, 0x11943_u32},
        {0x119D1_u32, 0x119D7_u32},
        {0x119DA_u32, 0x119E0_u32},
        {0x119E4_u32, 0x119E4_u32},
        {0x11A01_u32, 0x11A0A_u32},
        {0x11A33_u32, 0x11A39_u32},
        {0x11A3B_u32, 0x11A3E_u32},
        {0x11A47_u32, 0x11A47_u32},
        {0x11A51_u32, 0x11A5B_u32},
        {0x11A8A_u32, 0x11A99_u32},
        {0x11C2F_u32, 0x11C36_u32},
        {0x11C38_u32, 0x11C3F_u32},
        {0x11C92_u32, 0x11CA7_u32},
        {0x11CA9_u32, 0x11CB6_u32},
        {0x11D31_u32, 0x11D36_u32},
        {0x11D3A_u32, 0x11D3A_u32},
        {0x11D3C_u32, 0x11D3D_u32},
        {0x11D3F_u32, 0x11D45_u32},
        {0x11D47_u32, 0x11D47_u32},
        {0x11D8A_u32, 0x11D8E_u32},
        {0x11D90_u32, 0x11D91_u32},
        {0x11D93_u32, 0x11D97_u32},
        {0x11EF3_u32, 0x11EF6_u32},
        {0x11F00_u32, 0x11F01_u32},
        {0x11F03_u32, 0x11F03_u32},
        {0x11F34_u32, 0x11F3A_u32},
        {0x11F3E_u32, 0x11F42_u32},
        {0x11F5A_u32, 0x11F5A_u32},
        {0x13440_u32, 0x13440_u32},
        {0x13447_u32, 0x13455_u32},
        {0x1611E_u32, 0x1612F_u32},
        {0x16AF0_u32, 0x16AF4_u32},
        {0x16B30_u32, 0x16B36_u32},
        {0x16F4F_u32, 0x16F4F_u32},
        {0x16F51_u32, 0x16F87_u32},
        {0x16F8F_u32, 0x16F92_u32},
        {0x16FE4_u32, 0x16FE4_u32},
        {0x16FF0_u32, 0x16FF1_u32},
        {0x1BC9D_u32, 0x1BC9E_u32},
        {0x1CF00_u32, 0x1CF2D_u32},
        {0x1CF30_u32, 0x1CF46_u32},
        {0x1D165_u32, 0x1D169_u32},
        {0x1D16D_u32, 0x1D172_u32},
        {0x1D17B_u32, 0x1D182_u32},
        {0x1D185_u32, 0x1D18B_u32},
        {0x1D1AA_u32, 0x1D1AD_u32},
        {0x1D242_u32, 0x1D244_u32},
        {0x1DA00_u32, 0x1DA36_u32},
        {0x1DA3B_u32, 0x1DA6C_u32},
        {0x1DA75_u32, 0x1DA75_u32},
        {0x1DA84_u32, 0x1DA84_u32},
        {0x1DA9B_u32, 0x1DA9F_u32},
        {0x1DAA1_u32, 0x1DAAF_u32},
        {0x1E000_u32, 0x1E006_u32},
        {0x1E008_u32, 0x1E018_u32},
        {0x1E01B_u32, 0x1E021_u32},
        {0x1E023_u32, 0x1E024_u32},
        {0x1E026_u32, 0x1E02A_u32},
        {0x1E08F_u32, 0x1E08F_u32},
        {0x1E130_u32, 0x1E136_u32},
        {0x1E2AE_u32, 0x1E2AE_u32},
        {0x1E2EC_u32, 0x1E2EF_u32},
        {0x1E4EC_u32, 0x1E4EF_u32},
        {0x1E5EE_u32, 0x1E5EF_u32},
        {0x1E8D0_u32, 0x1E8D6_u32},
        {0x1E944_u32, 0x1E94A_u32},

      ] of {UInt32, UInt32}

      # Non-Mark codepoints that contribute no advance width: the
      # `\p{Default_Ignorable_Code_Point}` / `\p{Control}` / `\p{Format}`
      # remainder of the TS `zeroWidthRegex` that is NOT covered by
      # `\p{Mark}` above. ZWJ (U+200D) is handled by the grapheme walker and
      # intentionally excluded here.
      NON_MARK_ZERO_WIDTH_RANGES = {
        {0x0000_u32, 0x001F_u32},   # C0 controls
        {0x007F_u32, 0x009F_u32},   # DEL + C1 controls
        {0x0600_u32, 0x0605_u32},   # Arabic number marks
        {0x061C_u32, 0x061C_u32},   # Arabic letter mark
        {0x06DD_u32, 0x06DD_u32},   # Arabic end of ayah
        {0x070F_u32, 0x070F_u32},   # Syriac abbreviation mark
        {0x0890_u32, 0x0891_u32},   # Arabic signs
        {0x08E2_u32, 0x08E2_u32},   # Arabic disputed end of ayah
        {0x180E_u32, 0x180E_u32},   # Mongolian vowel separator
        {0x200B_u32, 0x200F_u32},   # ZWSP, ZWNJ, ZWJ, LRM, RLM (ZWJ re-checked in walker)
        {0x202A_u32, 0x202E_u32},   # Bidi controls
        {0x2060_u32, 0x2064_u32},   # Word joiner etc.
        {0x2066_u32, 0x206F_u32},   # Bidi isolate controls
        {0xFEFF_u32, 0xFEFF_u32},   # BOM
        {0xFFF9_u32, 0xFFFB_u32},   # Interlinear annotation
        {0x110BD_u32, 0x110BD_u32}, # Kaithi number sign
        {0x110CD_u32, 0x110CD_u32},
        {0x13430_u32, 0x13438_u32}, # Egyptian hieroglyph format controls
        {0x1BCA0_u32, 0x1BCA3_u32}, # Shorthand format controls
        {0x1D173_u32, 0x1D17A_u32}, # Musical format controls
        {0xE0000_u32, 0xE0FFF_u32}, # Tags (language tags)
      }

      # CJK script ranges for word-breaking (counterpart of `cjkBreakRegex`).
      CJK_SCRIPT_RANGES = {
        {0x1100_u32, 0x11FF_u32}, # Hangul Jamo
        {0x2E80_u32, 0x2EFF_u32}, # CJK Radicals Supplement
        {0x2F00_u32, 0x2FDF_u32}, # Kangxi Radicals
        {0x3000_u32, 0x303F_u32}, # CJK Symbols and Punctuation
        {0x3040_u32, 0x309F_u32}, # Hiragana
        {0x30A0_u32, 0x30FF_u32}, # Katakana
        {0x3100_u32, 0x312F_u32}, # Bopomofo
        {0x3130_u32, 0x318F_u32}, # Hangul Compatibility Jamo
        {0x3400_u32, 0x4DBF_u32}, # CJK Unified Ideographs Extension A
        {0x4E00_u32, 0x9FFF_u32}, # CJK Unified Ideographs
        {0xAC00_u32, 0xD7A3_u32}, # Hangul Syllables
        {0xF900_u32, 0xFAFF_u32}, # CJK Compatibility Ideographs
        {0xFF00_u32, 0xFFEF_u32}, # Fullwidth Forms
      }

      private def self.in_range?(cp : UInt32, ranges) : Bool
        ranges.each do |(lo, hi)|
          return true if cp >= lo && cp <= hi
        end
        false
      end

      # Binary search over the sorted `MARK_RANGES` tuple — the complete
      # `\p{Mark}` set (320 disjoint ranges). O(log n) per codepoint instead
      # of the O(n) linear `in_range?` scan, keeping the hot width path fast.
      private def self.mark?(cp : UInt32) : Bool
        lo = 0
        hi = MARK_RANGES.size - 1
        while lo <= hi
          mid = (lo + hi) // 2
          range = MARK_RANGES[mid]
          if cp < range[0]
            hi = mid - 1
          elsif cp > range[1]
            lo = mid + 1
          else
            return true
          end
        end
        false
      end

      # ------------------------------------------------------------------------
      # Classification predicates (mirror couldBeEmoji / zeroWidthRegex test)
      # ------------------------------------------------------------------------

      # Counterpart of `couldBeEmoji` heuristic (broad block pre-filter).
      def self.could_be_emoji?(cp : UInt32) : Bool
        in_range?(cp, EMOJI_RANGES)
      end

      # Whether a codepoint renders as emoji (width 2) by default presentation,
      # i.e. `Emoji_Presentation=Yes`. Counterpart of the single-codepoint RGI
      # gate applied by `rgiEmojiRegex.test(segment)` in TS `graphemeWidth` when
      # the segment has no VS16 selector. BMP coverage is enumerated explicitly
      # (see EMOJI_PRESENTATION_RANGES); supplementary pictograph blocks
      # (>= U+1F000) are emoji by default.
      private def self.default_emoji_presentation?(cp : UInt32) : Bool
        return true if cp >= 0x1F000
        in_range?(cp, EMOJI_PRESENTATION_RANGES)
      end

      # Codepoints the startup probe measures against the real terminal
      # (`Terminal#probe_codepoint_widths`): every BMP emoji-default
      # presentation glyph — the set terminals actually disagree about —
      # plus ⚠ (text-default) and 🔄 (supplementary) as anchors.
      def self.probe_candidates : Array(UInt32)
        cps = [] of UInt32
        EMOJI_PRESENTATION_RANGES.each do |(lo, hi)|
          cp = lo
          while cp <= hi
            cps << cp
            cp += 1
          end
        end
        cps << 0x26A0_u32  # ⚠ text-default anchor
        cps << 0x1F504_u32 # 🔄 supplementary anchor
        cps
      end

      # Counterpart of `zeroWidthRegex.test`: a codepoint is zero-width when it
      # is a Mark (`\p{Mark}`, the complete set via `mark?`) OR belongs to the
      # non-Mark Default_Ignorable/Control/Format remainder. ZWJ (U+200D) is
      # excluded here because the grapheme walker consumes it explicitly.
      def self.zero_width?(cp : UInt32) : Bool
        return true if cp == 0x200D
        mark?(cp) || in_range?(cp, NON_MARK_ZERO_WIDTH_RANGES)
      end

      private def self.combining_mark?(cp : UInt32) : Bool
        return false if cp == 0x200D
        mark?(cp) || in_range?(cp, NON_MARK_ZERO_WIDTH_RANGES)
      end

      private def self.regional_indicator?(cp : UInt32) : Bool
        cp >= 0x1F1E6 && cp <= 0x1F1FF
      end

      # Counterpart of `cjkBreakRegex.test(segment)` for word-breaking.
      def self.cjk_break?(cp : UInt32) : Bool
        in_range?(cp, CJK_SCRIPT_RANGES)
      end

      # Counterpart of `eastAsianWidth(cp)` from `get-east-asian-width`.
      private def self.east_asian_width(cp : UInt32) : Int32
        in_range?(cp, WIDE_RANGES) ? 2 : 1
      end

      # ------------------------------------------------------------------------
      # Per-codepoint / per-grapheme width (mirror graphemeWidth)
      # ------------------------------------------------------------------------

      # Width of a single base codepoint. Counterpart of the body of
      # `graphemeWidth` for a single codepoint cluster: tab→3, control/zero→0,
      # emoji/regional indicator→2, East Asian Wide/Fullwidth→2, else 1.
      def self.codepoint_width(cp : UInt32) : Int32
        return 3 if cp == 0x09 # \t
        return 0 if cp < 0x20 || cp == 0x7F
        return 0 if mark?(cp) || in_range?(cp, NON_MARK_ZERO_WIDTH_RANGES)
        # Terminal-measured override wins over every static table below.
        if w = @@probed_widths[cp]?
          return w
        end
        return 2 if regional_indicator?(cp)
        # Width 2 only when the codepoint defaults to emoji presentation. BMP
        # chars in emoji blocks that default to TEXT (e.g. ⚠ U+26A0) fall
        # through to East Asian Width (Ambiguous -> 1), matching the RGI gate
        # in TS `graphemeWidth`. VS16 promotion is handled in `grapheme_width`.
        return 2 if could_be_emoji?(cp) && default_emoji_presentation?(cp)
        east_asian_width(cp)
      end

      # Convenience overload for `Char`.
      def self.codepoint_width(c : Char) : Int32
        codepoint_width(c.ord.to_u32)
      end

      # Width of a base codepoint followed by a trailing fullwidth/halfwidth
      # tail within the same grapheme cluster (mirrors the trailing-forms loop
      # in `graphemeWidth`). `tail` is the list of codepoints after the base.
      private def self.grapheme_width(base : UInt32, tail : Array(UInt32)) : Int32
        w = codepoint_width(base)
        # VS16 (U+FE0F) after an emoji-capable base that defaults to TEXT
        # presentation (e.g. ⚠ -> ⚠️) promotes the cluster to emoji width 2.
        # Mirrors `rgiEmojiRegex` matching `<base>\uFE0F` as an RGI Emoji.
        if w < 2 && could_be_emoji?(base) && tail.includes?(0xFE0F_u32)
          w = 2
        end
        tail.each do |c|
          if c >= 0xFF00 && c <= 0xFFEF
            w += east_asian_width(c)
          elsif c == 0x0E33 || c == 0x0EB3 # Thai/Lao AM vowels segment with base
            w += 1
          end
        end
        w
      end

      # ------------------------------------------------------------------------
      # Grapheme-cluster width walk (approximates `Intl.Segmenter` + sum of
      # `graphemeWidth`). Operates on an ANSI-free codepoint array.
      # ------------------------------------------------------------------------
      private def self.sum_grapheme_width(cps : Array(UInt32)) : Int32
        width = 0
        i = 0
        n = cps.size
        while i < n
          cp = cps[i]

          # CR LF
          if cp == 0x0D && i + 1 < n && cps[i + 1] == 0x0A
            i += 2
            next
          end

          # Regional indicator pairs (flag emoji): each pair = one cluster = 2.
          if regional_indicator?(cp)
            j = i
            while j < n && regional_indicator?(cps[j])
              j += 1
            end
            count = j - i
            width += 2 * ((count + 1) // 2)
            i = j
            next
          end

          # Base + trailing combining marks (and ZWJ emoji chains).
          tail = [] of UInt32
          k = i + 1
          # consume plain combining marks attached to this base
          while k < n && combining_mark?(cps[k])
            tail << cps[k]
            k += 1
          end
          # ZWJ + emoji extension keeps the cluster at the base's width
          while k < n && cps[k] == 0x200D && k + 1 < n && could_be_emoji?(cps[k + 1])
            tail << cps[k]     # ZWJ
            tail << cps[k + 1] # joined emoji (no extra width)
            k += 2
            while k < n && combining_mark?(cps[k])
              tail << cps[k]
              k += 1
            end
          end

          width += grapheme_width(cp, tail)
          i = k
        end
        width
      end

      # ------------------------------------------------------------------------
      # ANSI escape extraction (mirror extractAnsiCode: CSI / OSC / APC)
      # ------------------------------------------------------------------------
      record AnsiCode, code : String, length : Int32

      # Extracts a supported ANSI/OSC/APC escape sequence beginning at `pos`.
      # Returns `nil` if there is no well-formed sequence there.
      def self.extract_ansi_code(str : String, pos : Int32) : AnsiCode?
        return nil if pos >= str.bytesize
        return nil unless str.byte_at(pos) == 0x1b # ESC

        bytes = str.to_slice
        return nil if pos + 1 >= bytes.size
        next_b = bytes[pos + 1]

        # CSI: ESC [ ... <final>   (final in 0x40..0x7e, e.g. m G K H J)
        if next_b == 0x5B # '['
          j = pos + 2
          while j < bytes.size
            b = bytes[j]
            return AnsiCode.new(str.byte_slice(pos, j + 1 - pos), j + 1 - pos) if b >= 0x40 && b <= 0x7e
            j += 1
          end
          return nil
        end

        # OSC: ESC ] ... BEL | ST (ESC \)
        if next_b == 0x5D # ']'
          j = pos + 2
          while j < bytes.size
            if bytes[j] == 0x07 # BEL
              return AnsiCode.new(str.byte_slice(pos, j + 1 - pos), j + 1 - pos)
            end
            if bytes[j] == 0x1b && j + 1 < bytes.size && bytes[j + 1] == 0x5c # ST (ESC \)
              return AnsiCode.new(str.byte_slice(pos, j + 2 - pos), j + 2 - pos)
            end
            j += 1
          end
          return nil
        end

        # APC: ESC _ ... BEL | ST (ESC \)
        if next_b == 0x5F # '_'
          j = pos + 2
          while j < bytes.size
            if bytes[j] == 0x07
              return AnsiCode.new(str.byte_slice(pos, j + 1 - pos), j + 1 - pos)
            end
            if bytes[j] == 0x1b && j + 1 < bytes.size && bytes[j + 1] == 0x5c
              return AnsiCode.new(str.byte_slice(pos, j + 2 - pos), j + 2 - pos)
            end
            j += 1
          end
          return nil
        end

        nil
      end

      private def self.utf8_byte_length(leading_byte : UInt8) : Int32
        return 1 if leading_byte < 0x80
        return 2 if leading_byte < 0xE0
        return 3 if leading_byte < 0xF0
        4
      end

      def self.strip_ansi(str : String) : String
        return str unless str.includes?('\e')
        bytes = str.to_slice
        out_str = IO::Memory.new
        i = 0
        while i < bytes.size
          if bytes[i] == 0x1b
            ansi = extract_ansi_code(str, i)
            if ansi
              i += ansi.length
              next
            end
          end
          char_len = utf8_byte_length(bytes[i])
          out_str.write(bytes[i, char_len])
          i += char_len
        end
        out_str.to_s
      end

      # ------------------------------------------------------------------------
      # Printable ASCII fast path (mirror isPrintableAscii)
      # ------------------------------------------------------------------------
      private def self.printable_ascii?(str : String) : Bool
        str.each_byte do |b|
          return false if b < 0x20 || b > 0x7e
        end
        true
      end

      # ------------------------------------------------------------------------
      # Main entry (mirror visibleWidth)
      # ------------------------------------------------------------------------
      # Visible terminal width of `str` in columns. Skips ANSI/OSC/APC escapes,
      # expands tabs to 3 columns, and weighs grapheme clusters (emoji and East
      # Asian Wide/Fullwidth count as 2). Results are cached (FIFO, 4096 slots).
      def self.visible_width(str : String) : Int32
        return 0 if str.empty?

        # Fast path: pure printable ASCII.
        return str.size if printable_ascii?(str)

        # Cache lookup keyed by the original string (with escapes).
        if cached = cache_get(str)
          return cached
        end

        # Normalize: tabs -> 3 spaces, then strip escape sequences.
        clean = str.includes?('\t') ? str.gsub('\t', "   ") : str
        clean = strip_ansi(clean) if clean.includes?('\e')

        width = sum_grapheme_width(clean.codepoints.map(&.to_u32))

        cache_put(str, width)
        width
      end

      # ------------------------------------------------------------------------
      # Bounded fast ASCII scan (mirror asciiVisibleWidth)
      # ------------------------------------------------------------------------
      # Fast visible-width scan for lines whose printable content is plain ASCII,
      # skipping ANSI escape sequences. Returns the visible width, or `nil` when
      # the line contains control characters or non-ASCII content (caller should
      # fall back to `visible_width`). Early-exits as soon as width exceeds
      # `limit`, returning the partial count.
      def self.ascii_visible_width(line : String, limit : Int32) : Int32?
        width = 0
        i = 0
        bytes = line.to_slice
        while i < bytes.size
          if bytes[i] == 0x1b
            ansi = extract_ansi_code(line, i)
            return nil unless ansi
            i += ansi.length
            next
          end
          code = bytes[i].to_u32
          return nil if code < 0x20 || code > 0x7e
          width += 1
          return width if width > limit
          i += 1
        end
        width
      end

      # ------------------------------------------------------------------------
      # Truncate by display width (mirror truncateToWidth)
      # ------------------------------------------------------------------------
      private def self.finalize_truncated(prefix : String, prefix_w : Int32,
                                          ellipsis : String, ellipsis_w : Int32,
                                          max_width : Int32, pad : Bool) : String
        reset = ANSI.reset
        result = ellipsis.empty? ? "#{prefix}#{reset}" : "#{prefix}#{reset}#{ellipsis}#{reset}"
        pad ? result + (" " * {0, max_width - (prefix_w + ellipsis_w)}.max) : result
      end

      private def self.truncate_fragment(text : String, max_width : Int32) : {String, Int32}
        return {"", 0} if max_width <= 0 || text.empty?

        if printable_ascii?(text)
          clipped = text[0...max_width]
          return {clipped, clipped.size}
        end

        result = IO::Memory.new
        width = 0
        cps = text.codepoints.map(&.to_u32)
        i = 0
        n = cps.size
        while i < n
          cp = cps[i]
          cw = codepoint_width(cp)
          # Consume trailing combining marks as part of this grapheme.
          k = i + 1
          while k < n && combining_mark?(cps[k])
            cw += 0
            k += 1
          end
          break if width + cw > max_width
          result << cps[i...k].map(&.chr).join
          width += cw
          i = k
        end
        {result.to_s, width}
      end

      # Truncate `text` to `max_width` columns, appending `ellipsis` and optional
      # right-padding. Counterpart of `truncateToWidth`.
      def self.truncate_to_width(text : String, max_width : Int32,
                                 ellipsis : String = "...", pad : Bool = false) : String
        return "" if max_width <= 0
        return pad ? " " * max_width : "" if text.empty?

        ellipsis_w = visible_width(ellipsis)
        if ellipsis_w >= max_width
          text_w = visible_width(text)
          return pad ? text + (" " * {0, max_width - text_w}.max) : text if text_w <= max_width

          clipped = truncate_fragment(ellipsis, max_width)
          return finalize_truncated("", 0, clipped[0], clipped[1], max_width, pad) if clipped[1] == 0
          return finalize_truncated("", 0, clipped[0], clipped[1], max_width, pad)
        end

        if printable_ascii?(text)
          return pad ? text + (" " * {0, max_width - text.size}.max) : text if text.size <= max_width
          target = max_width - ellipsis_w
          return finalize_truncated(text[0...target], target, ellipsis, ellipsis_w, max_width, pad)
        end

        # General path: walk graphemes, keep a contiguous prefix within budget.
        target = max_width - ellipsis_w
        result = IO::Memory.new
        kept_w = 0
        visible_so_far = 0
        overflowed = false
        cps = text.codepoints.map(&.to_u32)
        i = 0
        n = cps.size
        while i < n
          cp = cps[i]
          k = i + 1
          while k < n && combining_mark?(cps[k])
            k += 1
          end
          w = grapheme_width(cp, cps[(i + 1)...k])

          if kept_w + w <= target
            result << cps[i...k].map(&.chr).join
            kept_w += w
          end
          visible_so_far += w
          if visible_so_far > max_width
            overflowed = true
            break
          end
          i = k
        end

        return pad ? text + (" " * {0, max_width - visible_width(text)}.max) : text unless overflowed

        finalize_truncated(result.to_s, kept_w, ellipsis, ellipsis_w, max_width, pad)
      end

      # ------------------------------------------------------------------------
      # Column slicing (mirror sliceWithWidth / sliceByColumn)
      # ------------------------------------------------------------------------
      record SliceResult, text : String, width : Int32

      # Slice the columns [`start_col`, `start_col + length`) from `line`,
      # preserving ANSI codes that fall inside the range. Counterpart of
      # `sliceWithWidth`.
      def self.slice_with_width(line : String, start_col : Int32, length : Int32,
                                strict : Bool = false) : SliceResult
        return SliceResult.new("", 0) if length <= 0
        end_col = start_col + length

        result = IO::Memory.new
        result_w = 0
        current_col = 0
        pending_ansi = IO::Memory.new

        bytes = line.to_slice
        i = 0
        bsize = bytes.size
        while i < bsize
          if bytes[i] == 0x1b
            ansi = extract_ansi_code(line, i)
            if ansi
              if current_col >= start_col && current_col < end_col
                result << ansi.code
              elsif current_col < start_col
                pending_ansi << ansi.code
              end
              i += ansi.length
              next
            end
          end

          # Consume a run of non-escape chars, then walk grapheme clusters.
          run_end = i
          while run_end < bsize && !(bytes[run_end] == 0x1b && extract_ansi_code(line, run_end))
            run_end += utf8_byte_length(bytes[run_end])
          end
          cps = line.byte_slice(i, run_end - i).codepoints.map(&.to_u32)
          ci = 0
          cn = cps.size
          while ci < cn
            cp = cps[ci]
            ck = ci + 1
            while ck < cn && combining_mark?(cps[ck])
              ck += 1
            end
            w = grapheme_width(cp, cps[(ci + 1)...ck])
            in_range = current_col >= start_col && current_col < end_col
            fits = !strict || current_col + w <= end_col
            if in_range && fits
              unless pending_ansi.empty?
                result << pending_ansi.to_s
                pending_ansi.clear
              end
              result << cps[ci...ck].map(&.chr).join
              result_w += w
            end
            current_col += w
            break if current_col >= end_col
            ci = ck
          end

          i = run_end
          break if current_col >= end_col
        end

        SliceResult.new(result.to_s, result_w)
      end

      # Convenience: return just the sliced text. Counterpart of `sliceByColumn`.
      def self.slice_by_column(line : String, start_col : Int32, length : Int32,
                               strict : Bool = false) : String
        slice_with_width(line, start_col, length, strict).text
      end

      # Split `text` into consecutive column-width chunks, each at most
      # `max_width` wide. Preserves ANSI escapes inside each chunk. Used by the
      # word-wrap fallback to hard-break a single token wider than the column.
      def self.slice_into_width_chunks(text : String, max_width : Int32) : Array(String)
        return [text] if max_width <= 0
        chunks = [] of String
        col = 0
        total = visible_width(text)
        while col < total
          # strict: true so a wide grapheme straddling the boundary doesn't
          # make the chunk exceed max_width.
          chunks << slice_with_width(text, col, max_width, strict: true).text
          col += max_width
        end
        chunks.empty? ? [text] : chunks
      end
    end
  end
end
