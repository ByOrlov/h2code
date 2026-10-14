require "spec"
require "../src/hless"

describe Hless do
  describe ".language_for" do
    it "maps extensions to languages" do
      Hless.language_for("README.md").should eq("markdown")
      Hless.language_for("app.cr").should eq("ruby") # crystal → ruby grammar
      Hless.language_for("x.py").should eq("python")
      Hless.language_for("main.go").should eq("go")
    end

    it "special-cases Makefile" do
      Hless.language_for("Makefile").should eq("makefile")
      Hless.language_for("dir/GNUmakefile").should be_nil
    end

    it "returns nil for unknown extensions" do
      Hless.language_for("data.xyz123").should be_nil
      Hless.language_for("noext").should be_nil
    end
  end

  describe ".detect_language" do
    it "detects ruby" do
      Hless.detect_language("def foo(x)\n  puts x\nend\n").should eq("ruby")
    end

    it "returns nil for plain text" do
      Hless.detect_language("just some words here\nnothing special\n").should be_nil
    end
  end

  describe ".expand_tabs" do
    it "expands tabs to the next tab stop" do
      Hless.expand_tabs("a\tb").should eq("a   b")
      Hless.expand_tabs("\tx").should eq("    x")
    end

    it "leaves lines without tabs alone" do
      Hless.expand_tabs("plain").should eq("plain")
    end
  end

  describe ".wrap_ansi" do
    it "wraps plain text at the given width" do
      Hless.wrap_ansi("abcdef", 3).should eq(["abc\e[0m", "def\e[0m"])
    end

    it "keeps a short line as a single chunk" do
      Hless.wrap_ansi("ab", 3).should eq(["ab\e[0m"])
    end

    it "carries ANSI style across the break and resets every chunk" do
      chunks = Hless.wrap_ansi("\e[1mabcdef", 3)
      chunks.should eq(["\e[1mabc\e[0m", "\e[1mdef\e[0m"])
    end

    it "drops the carried style after a reset" do
      chunks = Hless.wrap_ansi("\e[1mabc\e[0mdef", 3)
      chunks.should eq(["\e[1mabc\e[0m\e[0m", "def\e[0m"])
    end

    it "accounts for wide glyphs as two columns" do
      chunks = Hless.wrap_ansi("字字字", 4)
      chunks.map { |c| H2code::TUI::CharWidth.strip_ansi(c) }.should eq(["字字", "字"])
    end
  end

  describe ".highlight_lines" do
    it "returns one ANSI line per source line" do
      theme = H2code::TUI::Theme.dark
      lines = Hless.highlight_lines("puts 'hello'\n# comment\n", "ruby", theme).not_nil!
      lines.size.should eq(3) # trailing newline → empty third line
      H2code::TUI::CharWidth.strip_ansi(lines[0]).should eq("puts 'hello'")
      H2code::TUI::CharWidth.strip_ansi(lines[1]).should eq("# comment")
      lines[0].should contain("\e[")
    end

    it "keeps scope over multiline tokens" do
      theme = H2code::TUI::Theme.dark
      lines = Hless.highlight_lines("=begin\nblock comment\n=end\n", "ruby", theme).not_nil!
      lines[1].should contain("\e[") # still styled on the second line
    end

    it "returns nil for an unknown language" do
      Hless.highlight_lines("x = 1", "no-such-lang", H2code::TUI::Theme.dark).should be_nil
    end
  end

  describe Hless::Doc do
    it "defaults to rendered mode only for markdown" do
      doc = Hless::Doc.new("README.md", "# hi\n", "markdown")
      doc.rendered?.should be_true
      doc = Hless::Doc.new("app.rb", "puts 1\n", "ruby")
      doc.rendered?.should be_false
    end

    it "builds display lines with gutters in raw mode" do
      theme = H2code::TUI::Theme.dark
      doc = Hless::Doc.new("app.rb", "a = 1\nb = 2\nc = 3\n", "ruby")
      doc.rebuild(40, theme)
      doc.lines.size.should eq(4) # 3 source lines + trailing empty
      doc.lines[0].src.should eq(0)
      doc.lines[1].src.should eq(1)
      doc.lines[0].plain.should eq("a = 1")
      doc.gutter_width.should be > 0
    end

    it "splits overlong lines into wrapped continuation lines" do
      theme = H2code::TUI::Theme.dark
      doc = Hless::Doc.new("t.txt", "a" * 100 + "\n", "plaintext")
      doc.rebuild(40, theme)
      doc.lines[0].src.should eq(0)
      doc.lines[1].src.should eq(-1) # continuation has no number
    end

    it "rebuilds only when width or mode changes" do
      theme = H2code::TUI::Theme.dark
      doc = Hless::Doc.new("app.rb", "a = 1\n", "ruby")
      doc.rebuild(80, theme)
      doc.needs_rebuild?(80).should be_false
      doc.needs_rebuild?(100).should be_true
      doc.rendered = true
      doc.needs_rebuild?(80).should be_true
    end
  end

  describe ".run" do
    it "prints usage and returns 1 without arguments" do
      Hless.run([] of String).should eq(1)
    end

    it "rejects unknown options" do
      Hless.run(["--bogus"]).should eq(1)
    end

    it "rejects missing files" do
      Hless.run(["/no/such/file.md"]).should eq(1)
    end
  end
end
