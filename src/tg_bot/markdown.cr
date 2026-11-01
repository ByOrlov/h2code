module TgBot
  # Markdown → Telegram MarkdownV2 converter for assistant replies.
  #
  # Telegram renders a restricted dialect: no headings, lists or tables, and
  # every one of `_ * [ ] ( ) ~ ` > # + - = | { } . !` must be
  # backslash-escaped outside entities — one bare dot aborts the whole
  # sendMessage. This maps the subset agents actually emit:
  #
  #   ```fences```     → ```pre``` (content verbatim except ` and \)
  #   `inline code`   → `code`
  #   **bold**        → *bold*
  #   *italic* / _it_ → _italic_ (not across word chars — snake_case stays)
  #   ~~strike~~      → ~strike~
  #   [text](url)     → kept as a link
  #   # headings      → *bold line*
  #   - / 1. lists    → • / n. with inline formatting kept
  #   | tables |      → wrapped into a pre block (Telegram has no tables)
  #
  # Unparseable constructs degrade to escaped plain text; if the result still
  # offends the API, the sender falls back to plain text (see Bot#say_md).
  module MarkdownV2
    ESCAPES = {'_', '*', '[', ']', '(', ')', '~', '`', '>', '#', '+', '-', '=',
               '|', '{', '}', '.', '!'}

    def self.convert(text : String) : String
      out = String.build do |io|
        convert_block(text.split('\n'), io)
      end
      out.chomp('\n')
    end

    private def self.convert_block(lines : Array(String), io : IO) : Nil
      in_code = false
      table = [] of String

      lines.each do |line|
        stripped = line.strip

        if stripped.starts_with?("```")
          flush_table(table, io) unless table.empty?
          table.clear
          if in_code
            in_code = false
            io << "```" << '\n'
          else
            in_code = true
            io << "```" << code(stripped[3..].strip) << '\n'
          end
          next
        end

        if in_code
          io << code(line) << '\n'
          next
        end

        if stripped.starts_with?('|')
          table << line
          next
        elsif !table.empty?
          flush_table(table, io)
          table.clear
        end

        io << block_line(line) << '\n'
      end

      flush_table(table, io) unless table.empty?
      # A fence clipped by the message-size limit must not leave an
      # unterminated entity — Telegram rejects the whole message over it.
      io << "```" << '\n' if in_code
    end

    private def self.flush_table(rows : Array(String), io : IO) : Nil
      io << "```" << '\n'
      rows.each { |r| io << code(r) << '\n' }
      io << "```" << '\n'
    end

    private def self.block_line(line : String) : String
      stripped = line.strip

      # Horizontal rules have no equivalent — a rule of box-drawing chars
      # reads the same and needs no escaping.
      return "───" if stripped.matches?(/\A(-{3,}|\*{3,}|_{3,})\Z/)

      # Headings become bold lines (Telegram has no heading levels).
      if stripped.starts_with?('#')
        rest = stripped.lstrip('#')
        if !rest.empty? && rest.starts_with?(' ')
          return "*#{inline(rest.strip)}*"
        end
      end

      if (m = line.match(/\A(\s*)[-*+]\s+(.+)\z/))
        return "#{m[1]}• #{inline(m[2])}"
      end
      if (m = line.match(/\A(\s*)(\d+)[.)]\s+(.+)\z/))
        # The dot after the number is ordinary text here, not entity syntax.
        return "#{m[1]}#{m[2]}\\. #{inline(m[3])}"
      end

      inline(line)
    end

    private def self.inline(text : String) : String
      String.build do |io|
        i = 0
        prev = '\0'
        n = text.size
        while i < n
          c = text[i]
          step = 1
          if c == '`' && (close = text.index('`', i + 1))
            io << '`' << code(text[i + 1...close]) << '`'
            step = close + 1 - i
          elsif c == '*' && text[i + 1]? == '*' && (close = text.index("**", i + 2))
            io << '*' << inline(text[i + 2...close]) << '*'
            step = close + 2 - i
          elsif (c == '*' || c == '_') && boundary?(prev) &&
                (close = text.index(c, i + 1)) && text[close + 1]? != '*'
            io << '_' << inline(text[i + 1...close]) << '_'
            step = close + 1 - i
          elsif c == '~' && text[i + 1]? == '~' && (close = text.index("~~", i + 2))
            io << '~' << inline(text[i + 2...close]) << '~'
            step = close + 2 - i
          elsif c == '[' && (link = parse_link(text, i))
            label, url = link
            io << '[' << inline(label) << "](" << escape_url(url) << ')'
            step = label.size + url.size + 4
          elsif ESCAPES.includes?(c)
            io << '\\' << c
          else
            io << c
          end
          prev = text[i + step - 1]? || c
          i += step
        end
      end
    end

    # `[label](url)` starting at `start` — nil when the brackets never close.
    private def self.parse_link(text : String, start : Int32) : {String, String}?
      close_br = text.index(']', start + 1)
      return nil unless close_br && text[close_br + 1]? == '('
      close_par = text.index(')', close_br + 2)
      return nil unless close_par
      {text[start + 1...close_br], text[close_br + 2...close_par]}
    end

    # Inside pre/code entities only ` and \ need escaping.
    private def self.code(text : String) : String
      text.gsub({'\\' => "\\\\", '`' => "\\`"})
    end

    # Inside the (...) part of a link only ) and \ need escaping.
    private def self.escape_url(url : String) : String
      url.gsub({'\\' => "\\\\", ')' => "\\)"})
    end

    # Emphasis does not open mid-word (`foo_bar_baz` stays literal).
    private def self.boundary?(prev : Char) : Bool
      !prev.alphanumeric? && prev != '_'
    end
  end
end
