# hless — a less-style terminal pager with syntax highlighting.
#
# Markdown files are rendered by default (H2code::TUI::Markdown); `r`
# toggles to the raw source highlighted as markdown. Everything else is
# highlighted via the highlight.cr shard (language by extension, then
# auto-detection).
#
#   hless README.md          rendered markdown, `r` → raw
#   hless src/*.cr           highlighted source
#   hless -l ruby dump.txt   force a language
#
# Keys: j/k/↑/↓ scroll · Space/PgDn, b/PgUp page · d/u half-page ·
# g/G home/end · / n N search · r toggle md mode · ]/[ next/prev file ·
# ? help · q quit.
#
# Entry point: bin/hless.cr (the shard target). This file only defines the
# Hless module so specs can require it without side effects.

require "./tui/terminal"
require "./tui/input_wait"
require "./tui/input"
require "./tui/char_width"
require "./tui/theme"
require "./tui/markdown"
require "./version"
require "highlight_cr"

module Hless
  ANSI = H2code::TUI::ANSI

  TAB_STOP = 4

  # ------------------------------------------------------------------------
  # Language detection
  # ------------------------------------------------------------------------

  # Crystal has no grammar in highlight.js' common bundle — `.cr` renders
  # well enough with the ruby grammar.
  EXT_LANGS = {
    "md" => "markdown", "markdown" => "markdown",
    "sh" => "bash", "bash" => "bash", "zsh" => "bash",
    "c" => "c", "h" => "c",
    "cpp" => "cpp", "cc" => "cpp", "cxx" => "cpp", "hpp" => "cpp", "hh" => "cpp",
    "cs" => "csharp",
    "css" => "css",
    "diff" => "diff", "patch" => "diff",
    "rb" => "ruby", "cr" => "ruby",
    "go" => "go",
    "graphql" => "graphql", "gql" => "graphql",
    "ini" => "ini", "toml" => "ini",
    "java" => "java",
    "js" => "javascript", "mjs" => "javascript", "cjs" => "javascript", "jsx" => "javascript",
    "json" => "json",
    "kt" => "kotlin", "kts" => "kotlin",
    "less" => "less",
    "lua" => "lua",
    "mk" => "makefile",
    "pl" => "perl", "pm" => "perl",
    "m" => "objectivec",
    "php" => "php",
    "py" => "python", "pyi" => "python",
    "r" => "r",
    "rs" => "rust",
    "scss" => "scss",
    "sql" => "sql",
    "swift" => "swift",
    "yml" => "yaml", "yaml" => "yaml",
    "ts" => "typescript", "tsx" => "typescript",
    "vb" => "vbnet",
    "wat" => "wasm", "wasm" => "wasm",
    "xml" => "xml", "html" => "xml", "htm" => "xml", "svg" => "xml", "vue" => "xml",
    "txt" => "plaintext",
  } of String => String

  def self.language_for(path : String) : String?
    return "makefile" if File.basename(path).downcase == "makefile"
    ext = File.extname(path).downcase
    ext = ext[1..] unless ext.empty?
    EXT_LANGS[ext]?
  end

  # Auto-detection sample cap: highlight_auto runs every registered grammar
  # over the text, so feeding it whole multi-megabyte files is wasteful —
  # the first few KB decide the language just as well.
  AUTODETECT_SAMPLE = 8192

  def self.detect_language(text : String) : String?
    sample = text.bytesize > AUTODETECT_SAMPLE ? text.byte_slice(0, AUTODETECT_SAMPLE) : text
    result = Highlight.highlight_auto(sample)
    lang = result.language
    return nil if lang.nil? || lang == "plaintext"
    # Noise text still collects stray relevance (e.g. sql scores 1 on plain
    # English); real code lands well above 2.
    return nil if result.relevance < 2
    lang
  end

  # ------------------------------------------------------------------------
  # Token → ANSI rendering
  # ------------------------------------------------------------------------

  # Map an hljs scope ("title.function" → "title") to an ANSI style built
  # from the h2code theme palette.
  def self.style_for(scope : String?, theme : H2code::TUI::Theme) : String
    return "" if scope.nil? || scope.empty?
    base = scope.split('.').first
    c = theme.colors
    case base
    when "comment"                                        then ANSI.color(c.dim, nil) + ANSI.italic
    when "string"                                         then ANSI.color(c.success, nil)
    when "regexp"                                         then ANSI.color(c.error, nil)
    when "char"                                           then ANSI.color(c.warning, nil) # char.escape
    when "keyword", "doctag"                              then ANSI.color(c.accent, nil) + ANSI.bold
    when "title", "function"                              then ANSI.color(c.info, nil) + ANSI.bold
    when "number", "literal", "symbol"                    then ANSI.color(c.warning, nil)
    when "attr", "attribute", "property", "selector-attr" then ANSI.color(c.info, nil)
    when "variable"                                       then ANSI.color(c.text, nil)
    when "type", "class", "built_in"                      then ANSI.color(c.primary, nil)
    when "meta"                                           then ANSI.color(c.muted, nil)
    when "section"                                        then ANSI.color(c.warning, nil) + ANSI.bold
    when "bullet"                                         then ANSI.color(c.accent, nil)
    when "code"                                           then ANSI.color(c.success, nil)
    when "emphasis"                                       then ANSI.italic
    when "strong"                                         then ANSI.bold
    when "link", "url"                                    then ANSI.color(c.link, nil) + ANSI.underline
    when "subst", "template-variable"                     then ANSI.color(c.warning, nil)
    when "tag", "name"                                    then ANSI.color(c.accent, nil)
    else                                                       ""
    end
  end

  # Whole-file highlight → one ANSI string per source line. Multi-line
  # tokens (block comments, heredocs) keep their scope across the newline.
  # Returns nil for an unregistered language — the caller degrades to plain.
  def self.highlight_lines(code : String, lang : String,
                           theme : H2code::TUI::Theme) : Array(String)?
    tokens = Highlight.tokens(code, lang)
    return nil if tokens.nil?

    lines = [] of String
    buf = String::Builder.new

    tokens.each do |scope, text|
      style = style_for(scope, theme)
      buf << ANSI.reset << style unless style.empty?
      rest = text
      while nl = rest.index('\n')
        chunk = rest[0...nl]
        buf << chunk unless chunk.empty?
        lines << buf.to_s
        buf = String::Builder.new
        buf << ANSI.reset << style unless style.empty?
        rest = rest[(nl + 1)..]
      end
      buf << rest unless rest.empty?
    end
    lines << buf.to_s
  end

  # ------------------------------------------------------------------------
  # Line preparation
  # ------------------------------------------------------------------------

  def self.expand_tabs(line : String) : String
    return line unless line.includes?('\t')
    out = String::Builder.new
    col = 0
    line.each_char do |c|
      if c == '\t'
        nxt = (col // TAB_STOP + 1) * TAB_STOP
        (nxt - col).times { out << ' ' }
        col = nxt
      else
        out << c
        col += 1
      end
    end
    out.to_s
  end

  # Wrap an ANSI-decorated line to *width* display columns. The SGR state
  # active at the break point is re-emitted at the start of the next chunk;
  # every chunk ends with a reset so highlighting never bleeds into the
  # gutter or the status bar.
  def self.wrap_ansi(line : String, width : Int32) : Array(String)
    return [""] of String if width <= 0

    chunks = [] of String
    buf = String::Builder.new
    carry = "" # active SGR state, re-emitted after a break
    col = 0

    reader = Char::Reader.new(line)
    while reader.has_next?
      pos = reader.pos
      if line.byte_at(pos) == 0x1b && (ansi = H2code::TUI::CharWidth.extract_ansi_code(line, pos))
        buf << ansi.code
        if ansi.code == ANSI.reset
          carry = ""
        elsif ansi.code.ends_with?('m')
          carry += ansi.code
        end
        reader.pos = pos + ansi.length
        next
      end

      c = reader.current_char
      w = H2code::TUI::CharWidth.codepoint_width(c)
      if w > 0 && col + w > width
        chunks << buf.to_s + ANSI.reset
        buf = String::Builder.new
        buf << carry unless carry.empty?
        col = 0
      end
      buf << c
      col += w
      reader.next_char
    end

    chunks << buf.to_s + ANSI.reset
  end

  # ------------------------------------------------------------------------
  # Document
  # ------------------------------------------------------------------------

  # One display line: ANSI text for rendering, ANSI-stripped twin for
  # search, and the source line number for the gutter (-1 = continuation
  # of a wrapped line, or a rendered-markdown line).
  record DispLine, text : String, plain : String, src : Int32

  class Doc
    property path : String
    property text : String
    property lang : String?
    property? rendered : Bool = false
    property lines : Array(DispLine) = [] of DispLine
    property gutter_width : Int32 = 0
    property built_width : Int32 = -1
    property? built_rendered : Bool = false

    def initialize(@path, @text, @lang)
      @rendered = Hless.language_for(path) == "markdown"
    end

    def markdown? : Bool
      Hless.language_for(@path) == "markdown"
    end

    def needs_rebuild?(width : Int32) : Bool
      built_width != width || built_rendered? != rendered?
    end

    def rebuild(width : Int32, theme : H2code::TUI::Theme) : Nil
      lines = [] of DispLine
      gutter = 0

      if rendered?
        rendered_lines = H2code::TUI::Markdown.new(theme).render(@text, width)
        rendered_lines.each do |line|
          Hless.wrap_ansi(line, width).each do |chunk|
            lines << DispLine.new(chunk, H2code::TUI::CharWidth.strip_ansi(chunk), -1)
          end
        end
      else
        src_lines = nil
        if lang = @lang
          src_lines = Hless.highlight_lines(@text, lang, theme)
        end
        src_lines = @text.split('\n') unless src_lines
        gutter = src_lines.size.to_s.size + 1
        content_width = {1, width - gutter - 3}.max # "NNN │ " tail included
        src_lines.each_with_index do |line, i|
          Hless.wrap_ansi(Hless.expand_tabs(line), content_width).each_with_index do |chunk, ci|
            lines << DispLine.new(chunk,
              H2code::TUI::CharWidth.strip_ansi(chunk),
              ci == 0 ? i : -1)
          end
        end
      end

      @lines = lines
      @gutter_width = gutter
      @built_width = width
      @built_rendered = rendered?
    end
  end

  # ------------------------------------------------------------------------
  # Pager
  # ------------------------------------------------------------------------

  class Pager
    HELP = [
      "hless — keys",
      "",
      "  j / ↓, k / ↑        scroll one line",
      "  Space / PgDn, b / PgUp   scroll one page",
      "  d, u                scroll half a page",
      "  g / Home, G / End   jump to top / bottom",
      "  /pattern, n, N      search forward / next / previous",
      "  r                   toggle rendered ↔ raw markdown",
      "  ] / [               next / previous file",
      "  ?                   toggle this help",
      "  q, Ctrl+C           quit",
    ] of String

    property docs : Array(Doc)
    property theme : H2code::TUI::Theme
    @term : H2code::TUI::Terminal
    @input : H2code::TUI::Input
    @doc_idx : Int32
    @offset : Int32
    @help : Bool
    @searching : Bool
    @query : String
    @regex : Regex?
    @status : String

    def initialize(@docs, @theme)
      @term = H2code::TUI::Terminal.current
      @input = H2code::TUI::Input.new
      @doc_idx = 0
      @offset = 0
      @help = false
      @searching = false
      @query = ""
      @regex = nil
      @status = ""
    end

    def run : Nil
      @term.raw!
      print ANSI.alt_screen_on
      loop do
        check_resize
        render
        break if handle_keys.nil?
      end
    ensure
      print ANSI.alt_screen_off
      @term.restore!
    end

    private def doc : Doc
      @docs[@doc_idx]
    end

    private def avail_rows : Int32
      {@term.rows - 1, 1}.max
    end

    private def max_offset : Int32
      {0, doc.lines.size - avail_rows}.max
    end

    private def check_resize : Nil
      old = {@term.cols, @term.rows}
      @term.refresh_size
      clamp_offset if old != {@term.cols, @term.rows}
    end

    private def clamp_offset : Nil
      @offset = @offset.clamp(0, max_offset)
    end

    private def scroll(delta : Int32) : Nil
      @offset = (@offset + delta).clamp(0, max_offset)
    end

    # Returns nil to quit.
    private def handle_keys : Bool?
      loop do
        event = @input.read_key
        if event.nil?
          sleep 15.milliseconds
          check_resize
          next
        end
        return handle_key(event)
      end
    end

    private def handle_key(event : H2code::TUI::KeyEvent) : Bool?
      return search_key(event) if @searching

      case event.key
      when .char?
        if char = event.char
          result = handle_char(char)
          return result if result.nil?
        end
      when .down?             then scroll(1)
      when .up?               then scroll(-1)
      when .page_down?        then scroll(avail_rows)
      when .page_up?          then scroll(-avail_rows)
      when .home?             then @offset = 0
      when .end?              then @offset = max_offset
      when .ctrl_c?, .ctrl_d? then return nil
      when .ctrl_l?           then @status = ""
      end
      char = event.char
      @status = "" unless char && "nN".includes?(char)
      true
    end

    # Returns nil to quit.
    private def handle_char(char : Char) : Bool?
      case char
      when 'q' then return nil
      when 'j' then scroll(1)
      when 'k' then scroll(-1)
      when ' ' then scroll(avail_rows)
      when 'b' then scroll(-avail_rows)
      when 'd' then scroll(avail_rows // 2)
      when 'u' then scroll(-(avail_rows // 2))
      when 'g' then @offset = 0
      when 'G' then @offset = max_offset
      when 'r' then toggle_mode
      when '/' then start_search
      when 'n' then jump_match(forward: true, from: @offset + 1)
      when 'N' then jump_match(forward: false, from: @offset - 1)
      when ']' then switch_file(1)
      when '[' then switch_file(-1)
      when '?' then @help = !@help
      end
      true
    end

    private def toggle_mode : Nil
      if doc.markdown?
        doc.rendered = !doc.rendered?
        clamp_offset
      else
        @status = "not a markdown file"
      end
    end

    private def switch_file(delta : Int32) : Nil
      return @status = "single file" if @docs.size == 1
      @doc_idx = (@doc_idx + delta) % @docs.size
      @offset = 0
      @status = ""
    end

    # --- search -------------------------------------------------------------

    private def start_search : Nil
      @searching = true
      @query = ""
    end

    private def search_key(event : H2code::TUI::KeyEvent) : Bool?
      case event.key
      when .enter?
        @searching = false
        if @query.empty?
          @regex = nil
        else
          begin
            @regex = Regex.new(Regex.escape(@query), Regex::Options::IGNORE_CASE)
            jump_match(forward: true, from: @offset)
          rescue ex : ArgumentError
            @status = "bad pattern: #{ex.message}"
            @regex = nil
          end
        end
      when .escape?, .ctrl_c?, .ctrl_d?
        @searching = false
        @query = ""
      when .backspace?
        @query = @query.rchop
      when .char?
        if char = event.char
          @query += char
        end
      end
      true
    end

    private def jump_match(forward : Bool, from : Int32? = nil) : Nil
      regex = @regex
      return @status = "no pattern" if regex.nil?

      lines = doc.lines
      total = lines.size
      return if total == 0

      # Fresh search starts at the current top line; n/N continue from just
      # past/before it. The scan wraps around the whole document once.
      start = from || @offset
      total.times do |k|
        i = forward ? (start + k) % total : ((start - k) % total + total) % total
        next if k > 0 && i == start # full circle without a match
        if lines[i].plain.matches?(regex)
          @offset = {0, i - avail_rows // 2}.max.clamp(0, max_offset)
          @status = "match at line #{i + 1}"
          return
        end
      end
      @status = "not found"
    end

    # --- rendering ----------------------------------------------------------

    private def render : Nil
      doc.rebuild(@term.cols, @theme) if doc.needs_rebuild?(@term.cols)
      clamp_offset

      scr = IO::Memory.new
      c = @theme.colors

      if @help
        avail_rows.times do |r|
          scr << ANSI.cursor_to(r, 0) << ANSI.clear_line
          scr << ANSI.color(c.info, nil) << ANSI.bold << (HELP[r]? || "") << ANSI.reset
        end
      else
        avail_rows.times do |r|
          scr << ANSI.cursor_to(r, 0) << ANSI.clear_line
          line = doc.lines[@offset + r]?
          next unless line
          unless doc.rendered?
            if line.src >= 0
              num = (line.src + 1).to_s.rjust(doc.gutter_width)
              scr << ANSI.color(c.muted, nil) << num << ANSI.reset
            else
              scr << " " * doc.gutter_width
            end
            scr << ANSI.color(c.border, nil) << " │ " << ANSI.reset
          end
          scr << line.text
        end
      end

      scr << ANSI.cursor_to(avail_rows, 0) << ANSI.clear_line
      scr << status_bar
      print scr.to_s
      STDOUT.flush
    end

    private def status_bar : String
      c = @theme.colors
      bar = String::Builder.new
      bar << ANSI.color(c.primary, nil) << ANSI.bold << " hless " << ANSI.reset

      if @searching
        bar << ANSI.color(c.highlight, nil) << "/" << @query << "█" << ANSI.reset
        return bar.to_s
      end

      bar << " " << doc.path << ANSI.reset
      mode = doc.rendered? ? "md:rendered" : "md:raw"
      unless doc.markdown?
        mode = doc.lang || "plain"
      end
      bar << "  " << ANSI.color(c.muted, nil) << "[#{mode}]" << ANSI.reset
      bar << "  " << ANSI.color(c.muted, nil) << "(#{@doc_idx + 1}/#{@docs.size})" << ANSI.reset if @docs.size > 1

      pct = if doc.lines.empty?
              "empty"
            elsif @offset >= max_offset
              "END"
            else
              "#{(@offset * 100) // {1, max_offset}.max}%"
            end
      bar << "  " << pct

      bar << "  " << ANSI.color(c.warning, nil) << @status << ANSI.reset unless @status.empty?
      bar.to_s
    end
  end

  # ------------------------------------------------------------------------
  # CLI
  # ------------------------------------------------------------------------

  USAGE = <<-TEXT
    hless — less-style pager with syntax highlighting

    usage: hless [options] FILE...

    options:
      -l, --lang LANG   force the highlighting language
      -h, --help        show this help
      -v, --version     show version
    TEXT

  def self.run(argv : Array(String)) : Int32
    lang_override : String? = nil
    paths = [] of String

    i = 0
    while i < argv.size
      arg = argv[i]
      case arg
      when "-h", "--help"    then puts USAGE; return 0
      when "-v", "--version" then puts "hless #{H2code::VERSION}"; return 0
      when "-l", "--lang"
        lang_override = argv[i + 1]?
        if lang_override.nil?
          STDERR.puts "error: #{arg} requires a language argument"
          return 1
        end
        i += 1
      when .starts_with?("--lang=")
        lang_override = arg.split('=', 2)[1]?
      when .starts_with?("-")
        STDERR.puts "error: unknown option #{arg}"
        STDERR.puts USAGE
        return 1
      else
        paths << arg
      end
      i += 1
    end

    if paths.empty?
      STDERR.puts USAGE
      return 1
    end

    theme = H2code::TUI::Theme.dark
    docs = [] of Doc
    paths.each do |path|
      unless File.file?(path)
        STDERR.puts "error: #{path}: not a file"
        return 1
      end
      text = File.read(path).gsub("\r\n", "\n")
      lang = lang_override || language_for(path) || detect_language(text)
      docs << Doc.new(path, text, lang)
    rescue ex : IO::Error
      STDERR.puts "error: #{path}: #{ex.message}"
      return 1
    end

    Pager.new(docs, theme).run
    0
  end
end
