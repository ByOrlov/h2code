module H2code
  module TUI
    module MessageRenderer
      THINKING_PREVIEW_LINES = 2
      THINKING_INDENT        = "  "
      STATUS_BULLET          = "● "
      ASSISTANT_BULLET       = "💬 "
      USER_BULLET            = "👤 "
      # Vertical bar drawn on the left of the streaming assistant block in the
      # Active zone. Colored khaki (logo color from the theme), it visually
      # marks the mutable region that is repainted every frame. Finalized text
      # in the Log zone is clean — no bar. Uses the U+2503 box-drawing heavy
      # vertical, which fonts vertically seam across rows (unlike U+258C half
      # block, which splits into separate rectangles under macOS Terminal's
      # large line height).
      STREAMING_BAR = "┃"
      # Lines reserved for the rest of the active zone (spinner, editor box,
      # footer, etc.) when capping the streaming text window. The streaming
      # block is mutable and must never scroll into immutable scrollback, so
      # only the tail within this budget is kept.
      STREAMING_RESERVE  = 10
      TOOL_PREVIEW_LINES = 10

      def render_message(msg : Message, cols : Int32) : Array(String)
        lines = [] of String

        case msg.role
        when "user"
          bullet_w = CharWidth.visible_width(USER_BULLET)
          bullet = "#{ANSI.color(@theme.colors.user_msg, nil)}#{ANSI.bold}#{USER_BULLET}#{ANSI.reset}"
          indent = " " * bullet_w
          wrap_text(msg.content, cols - bullet_w).each_with_index do |l, i|
            prefix = i == 0 ? bullet : indent
            lines << "#{prefix}#{ANSI.color(@theme.colors.user_msg, nil)}#{ANSI.bold}#{l}#{ANSI.reset}"
          end
          lines << ""
        when "assistant"
          unless msg.content.empty?
            bullet = "#{ANSI.color(@theme.colors.text, nil)}#{ASSISTANT_BULLET}#{ANSI.reset}"
            md_lines = @markdown.render(msg.content, cols)
            md_lines.each_with_index do |l, i|
              if i == 0
                body = l.starts_with?("  ") ? l[2..] : l
                lines << "#{bullet}#{body}"
              else
                lines << l
              end
            end
            lines << ""
          end
        when "tool"
          if name = msg.tool_name
            if !msg.swarm_members.empty?
              lines.concat(render_swarm_progress(msg, name, cols))
            elsif group = msg.read_group
              # Normal TUI never expands tool output; /debug mode shows full history.
              lines.concat(render_read_group(group, name, false, cols))
            else
              has_result = !msg.tool_result.nil?
              # Pending tool calls (no result yet) are rendered in the active
              # zone, not here — the log is append-only. Once the result
              # arrives the complete entry appears below. See TUI_ZONES.md.
              return lines unless has_result
              lines << tool_header(name, msg.tool_args, msg.tool_result, has_result, msg.is_error?)
              if args = msg.tool_args
                # The header already shows the key argument for most tools;
                # keep the body preview only when there is no header argument
                # (e.g. Bash still shows the command under the label header).
                key_arg = extract_key_argument(name, args)
                if name == Tools::Names::BASH || key_arg.nil?
                  preview = tool_preview(name, args)
                  preview.each { |l| lines << "#{ANSI.color(@theme.colors.dim, nil)}  #{l}#{ANSI.reset}" }
                end

                if name == Tools::Names::EDIT
                  render_edit_diff(msg.tool_display, args).each { |l| lines << l }
                end
              end
              if result = msg.tool_result
                # tool_result is already a short preview; full output is in JSONL.
                result.each_line do |l|
                  lines << "#{ANSI.color(@theme.colors.tool_result, nil)}  #{l}#{ANSI.reset}"
                end
              end
              # --ram: dim+italic line right under the result preview, so the
              # RSS progression stays visually attached to the tool that
              # caused it instead of floating off as a separate info block.
              if ram = msg.ram_line
                lines << "#{ANSI.color(@theme.colors.dim, nil)}#{ANSI.italic}  #{ram}#{ANSI.reset}"
              end
              # Telemetry line: rendered in yellow (bold) right under the RAM
              # line so render-quality regressions are visually attached to the
              # tool call that triggered them.
              if tl = msg.telemetry_line
                lines << "#{ANSI.color(@theme.colors.telemetry, nil)}#{ANSI.bold}  #{tl}#{ANSI.reset}"
              end
              lines << ""
            end
          end
        when "error"
          # Split by `\n` so each rendered line maps to one `lines[]` entry —
          # the diff-renderer invariant (1 entry == 1 terminal row) must hold.
          ec = ANSI.color(@theme.colors.error, nil)
          dc = ANSI.color(@theme.colors.dim, nil)
          r = ANSI.reset
          err_lines = msg.content.split('\n')
          err_lines.each_with_index do |l, idx|
            if idx == 0
              lines << "#{ec}✗ #{l}#{r}"
            else
              lines << "#{dc}  #{l}#{r}"
            end
          end
          lines << ""
        when "exception"
          # A Crystal exception caught by the loop interceptor. Rendered as a
          # red exception block so the user sees what blew up and can continue
          # typing instead of the TUI crumbling. First line is the class +
          # message; the rest is the backtrace (dimmed).
          ec = ANSI.color(@theme.colors.error, nil)
          dc = ANSI.color(@theme.colors.dim, nil)
          r = ANSI.reset
          lines << "#{ec}💥 Exception#{r}"
          msg.content.split('\n').each do |l|
            lines << "#{dc}  #{l}#{r}" unless l.empty?
          end
          lines << ""
        when "status"
          msg.content.split('\n').each do |l|
            lines << "  #{ANSI.color(@theme.colors.error, nil)}#{l}#{ANSI.reset}"
          end
          lines << ""
        when "system"
          msg.content.split('\n').each do |l|
            lines << "#{ANSI.color(@theme.colors.dim, nil)}#{ANSI.italic}#{l}#{ANSI.reset}"
          end
          lines << ""
        when "ci_success", "task_success"
          # Good-news system lines (CI success outcome, completed background
          # task) — rendered bright green (bold success color) instead of the
          # dim italic gray used for regular system messages.
          msg.content.split('\n').each do |l|
            lines << "#{ANSI.bold}#{ANSI.color(@theme.colors.success, nil)}#{l}#{ANSI.reset}"
          end
          lines << ""
        when "spacer"
          # A blank line flushed into the log to balance the active zone: when
          # the transient spinner-status line ("thinking N time, call M tools")
          # is hidden, nothing migrates to the log by default — the combined
          # coverage shrinks and SyncBugsCount fires. This spacer keeps the
          # log line count in sync with what was shown.
          lines << ""
        when "thinking"
          lines.concat(render_thinking_block(msg.content, msg.expanded?, cols))
        when "plan_box"
          lines.concat(render_plan_box(msg, cols))
        when "compaction"
          lines.concat(render_compaction_block(msg, cols))
        when "todo_snapshot"
          # Frozen copy of the live todo panel — appended to the log so
          # completed plans scroll into history instead of pinning the active
          # zone. Rendered clean (no active-zone left bar) since the log is
          # immutable history. See TUI_ZONES.md.
          if items = msg.todo_items
            lines.concat(render_todo_panel(items, cols))
            lines << ""
          end
        end

        lines
      end

      # Render the streaming assistant text in the active zone with a khaki
      # vertical bar on the left (blockquote style) and a capped window so the
      # mutable block never overflows into scrollback. Only the tail within the
      # viewport budget is shown — the rest appears once the message finalizes
      # and migrates to the Log zone (clean, without the bar).
      private def render_streaming_text(cols : Int32) : Array(String)
        lines = [] of String
        return lines if @streaming_text.empty?

        kc = ANSI.color(@theme.colors.logo, nil) # khaki
        dc = ANSI.color(@theme.colors.dim, nil)
        r = ANSI.reset
        bullet = "#{ANSI.color(@theme.colors.text, nil)}#{ASSISTANT_BULLET}#{ANSI.reset}"
        # Lead prefix on every line: the khaki bar (1 col) + a gap (1 col).
        # On the first line the 💬 bullet follows the bar; on the rest a
        # 3-space indent aligns body text under the bullet (emoji is 2 cols +
        # 1 trailing space). This keeps a continuous vertical bar down the left
        # edge of the whole streaming block.
        lead = "#{kc}#{STREAMING_BAR}#{r} "
        rest_indent = "   "

        # During streaming the input may end with an incomplete markdown block
        # marker (e.g. a bare "-" at the start of a new line). Rendering that
        # marker as a paragraph adds a transient blank line that disappears when
        # the next token arrives, causing the Active zone to shrink/grow and
        # SyncBugsCount to fire. Strip such trailing fragments so they are only
        # rendered once complete.
        render_text = strip_streaming_incomplete(@streaming_text)

        rows = @terminal.rows
        budget = {rows - STREAMING_RESERVE, 3}.max

        # The whole input is a trailing incomplete marker — render nothing, but
        # keep the reserved height so the block does not shrink.
        if render_text.empty?
          target = {@streaming_hwm, budget + 2}.min
          @streaming_hwm = target
          return Array.new(target) { "" }
        end

        # Render markdown narrower to make room for the lead + bullet/indent.
        md_lines = @markdown.render(render_text, {cols - 5, 10}.max)

        # Windowing: cap the streaming block so the active zone stays within the
        # viewport. Streaming content is mutable — it must not scroll into
        # immutable scrollback. Keep the tail (most recent tokens).
        hidden = 0
        if md_lines.size > budget
          hidden = md_lines.size - budget
          md_lines = md_lines[-budget..]
        end

        if hidden > 0
          lines << "#{lead}#{dc}↑ #{hidden} lines streaming…#{r}"
        end

        md_lines.each_with_index do |l, i|
          body = l.starts_with?("  ") ? l[2..] : l
          if i == 0
            lines << "#{lead}#{bullet}#{body}"
          else
            lines << "#{lead}#{rest_indent}#{body}"
          end
        end
        lines << ""

        # High-water mark: the markdown re-interpretation of already-received
        # tokens is not monotonic in line count (an open `**`/`*`/`~~`/`` ` ``
        # renders raw and wider, so the closing delimiter can re-wrap the
        # paragraph onto fewer lines). The active zone must never shrink, so
        # pad the block to the tallest height it has reached this stream. The
        # blank rows fill in as content grows and any residual deficit is
        # compensated with log spacers when the stream finalizes
        # (EventController#flush_streaming_text!). Clamped to the current
        # window budget so a resize can still shrink the block (a resize
        # triggers the full-repaint path, which makes shrinking safe).
        target = {@streaming_hwm, budget + 2}.min
        lines.concat(Array.new(target - lines.size) { "" }) if lines.size < target
        @streaming_hwm = lines.size

        lines
      end

      # During streaming the input may end with an incomplete markdown block
      # marker (e.g. a bare "-" at the start of a new line). Rendering that
      # marker as a paragraph adds a transient blank line that disappears when
      # the next token arrives, causing the Active zone to shrink/grow and
      # SyncBugsCount to fire. Strip such trailing fragments so they are only
      # rendered once complete.
      private def strip_streaming_incomplete(text : String) : String
        text = text.rstrip('\n')

        # Remove a trailing incomplete list/ordered-list marker that starts its
        # own line and has no content after it.
        if md = text.match(/(\n(?:[-*+]|\d+\.)\s*)\z/)
          text = text[0...md.begin(0)]
        end

        text
      end

      private def render_live_thinking(cols : Int32) : Array(String)
        lines = [] of String
        dc = ANSI.color(@theme.colors.dim, nil)
        pc = ANSI.color(@theme.colors.primary, nil)
        mc = ANSI.color(@theme.colors.muted, nil)
        r = ANSI.reset

        # Khaki vertical bar mirroring `render_streaming_text`, so the live
        # thinking preview shares the active-zone mutable-region marker.
        kc = ANSI.color(@theme.colors.logo, nil)
        # `lead` is visually 2 cols (bar + space), matching THINKING_INDENT, so
        # the wrapping math below stays correct.
        lead = "#{kc}#{STREAMING_BAR}#{r} "

        lines << ""

        content_lines = wrap_thinking(@streaming_thinking, cols - THINKING_INDENT.size)
        if content_lines.size > THINKING_PREVIEW_LINES
          preview_lines = content_lines[-THINKING_PREVIEW_LINES..]
        else
          preview_lines = content_lines
        end

        lines << String.build do |s|
          s << lead
          s << pc
          s << Spinner::FRAMES[@spin_phase % Spinner::FRAMES.size]
          s << r
          s << " "
          s << mc
          s << "thinking..."
          s << r
        end

        preview_lines.each do |cl|
          lines << "#{lead}#{dc}#{ANSI.italic}#{cl}#{r}"
        end

        lines
      end

      # ExitPlanMode result strings carry an approved / auto-approved / rejected
      # plan body prefixed with a known marker. Mirrors TS `tool-call.ts`:
      #   - "## Approved Plan:"                          → approved
      #   - "## Plan (auto-approved, not user-reviewed):" → auto_approved
      #   - "Plan rejected by user." / "User rejected"   → rejected
      # When the marker is found, push a "plan_box" message into the transcript
      # so `render_message` can draw a bordered box for the plan body. Mirrors
      # `buildPlanPreview` in `tool-call.ts` which lifts the plan out of the
      # result into a `PlanBoxComponent`.
      private def render_compaction_block(msg : Message, cols : Int32) : Array(String)
        lines = [] of String
        success = @theme.colors.success
        warning = @theme.colors.warning
        primary = @theme.colors.primary
        dim = @theme.colors.dim
        text_c = @theme.colors.text

        case msg.compaction_state
        when "done"
          bullet = "#{ANSI.color(success, nil)}#{STATUS_BULLET}#{ANSI.reset}"
          label = "#{ANSI.color(success, nil)}#{ANSI.bold}Compaction complete#{ANSI.reset}"
          detail = ""
          if (tb = msg.tokens_before) && (ta = msg.tokens_after)
            detail = " #{ANSI.color(dim, nil)}(#{tb} → #{ta} tokens)#{ANSI.reset}"
          end
          hint = ""
          unless msg.summary.empty?
            hint = " #{ANSI.color(dim, nil)}(Ctrl-O to #{msg.expanded? ? "hide" : "show"} compaction summary)#{ANSI.reset}"
          end
          lines << ""
          lines << "#{bullet}#{label}#{detail}#{hint}"
          if msg.expanded? && !msg.summary.empty?
            msg.summary.split('\n').each do |sl|
              lines << "#{ANSI.color(dim, nil)}  #{sl}#{ANSI.reset}"
            end
          end
        when "cancelled"
          bullet = "#{ANSI.color(warning, nil)}#{STATUS_BULLET}#{ANSI.reset}"
          label = "#{ANSI.color(warning, nil)}#{ANSI.bold}Compaction cancelled#{ANSI.reset}"
          lines << ""
          lines << "#{bullet}#{label}"
        else
          # Running: blink the bullet every 500ms — same cadence as TS.
          blink_on = ((Time.utc.to_unix_ms // 500) % 2) == 0
          bullet = blink_on ? "#{ANSI.color(text_c, nil)}#{STATUS_BULLET}#{ANSI.reset}" : "  "
          label = "#{ANSI.color(primary, nil)}#{ANSI.bold}Compacting context...#{ANSI.reset}"
          tip = ""
          unless msg.tip.empty?
            tip = " #{ANSI.color(dim, nil)}· Tip: #{msg.tip}#{ANSI.reset}"
          end
          lines << ""
          lines << "#{bullet}#{label}#{tip}"
        end
        lines
      end

      def render_plan_box(msg : Message, cols : Int32) : Array(String)
        lines = [] of String
        border = ANSI.color(@theme.colors.success, nil)
        border = ANSI.color(@theme.colors.error, nil) if msg.plan_kind == "rejected"

        left_margin = 2
        side_padding = 1
        safe_cols = cols < 6 ? 6 : cols
        horz_len = {2, safe_cols - left_margin - 2}.max
        content_width = {1, horz_len - 2 * side_padding}.max

        # Title row: " plan: <basename>" or " plan"; Rejected badge appended.
        path_part = msg.plan_path.try { |p| ": #{File.basename(p)}" } || ""
        status_suffix = msg.plan_kind == "rejected" ? " · #{ANSI.color(@theme.colors.error, nil)}Rejected#{ANSI.reset}" : ""
        title = " plan#{path_part}#{status_suffix} "
        title_display = title_visible(title)
        if visible_len(title_display) > horz_len - 1
          title = " plan "
          title_display = title_visible(title)
        end
        trailing = (horz_len - visible_len(title_display)).clamp(0..)
        top = "#{" " * left_margin}#{border}┌#{title}#{border}#{"─" * trailing}┐#{ANSI.reset}"

        lines << ""
        lines << top

        body_lines = render_plan_body_lines(msg.content, content_width)
        body_lines.each do |raw|
          # Clamp to content_width so a long line (e.g. code inside the plan)
          # can't overflow the box and push the right border onto the next
          # terminal row — which reads as a stray blank line.
          vw = visible_len(raw)
          raw = CharWidth.slice_by_column(raw, 0, content_width, strict: true) if vw > content_width
          pad = (content_width - visible_len(raw)).clamp(0..)
          lines << "#{" " * left_margin}#{border}│#{ANSI.reset} #{raw}#{" " * pad} #{border}│#{ANSI.reset}"
        end

        lines << "#{" " * left_margin}#{border}└#{"─" * horz_len}┘#{ANSI.reset}"
        lines
      end

      # `title` is a String that may contain ANSI escapes (for the Rejected
      # badge); this returns only the visible-char count for box math.
      private def title_visible(title : String) : String
        title
      end

      # Render the plan body via the markdown renderer (already width-aware),
      # falling back to simple wrapping if markdown returns nothing.
      private def render_plan_body_lines(body : String, width : Int32) : Array(String)
        rendered = @markdown.render(body, width)
        rendered.empty? ? wrap_thinking(body, width) : rendered
      end

      private def render_thinking_block(content : String, expanded : Bool, cols : Int32) : Array(String)
        lines = [] of String
        dc = ANSI.color(@theme.colors.dim, nil)
        r = ANSI.reset
        indent = THINKING_INDENT

        content_lines = wrap_thinking(content, cols - indent.size)

        content_lines.each_with_index do |cl, i|
          prefix = i == 0 ? "#{dc}#{STATUS_BULLET}" : indent
          lines << "#{prefix}#{dc}#{ANSI.italic}#{cl}#{r}"
        end

        if !expanded && content_lines.size > THINKING_PREVIEW_LINES
          shown = lines[0...THINKING_PREVIEW_LINES]
          remaining = content_lines.size - THINKING_PREVIEW_LINES
          hint = "... (#{remaining} more lines, load session in /debug mode to expand)"
          shown << "#{indent}#{dc}#{hint}#{r}"
          lines = shown
        end

        # Follow the same convention as every other message type: one trailing
        # blank line acts as the separator between messages. The previous code
        # emitted a LEADING blank (and no trailing one), which produced two
        # blanks before the block and none after it when sandwiched between
        # tool results.
        lines << ""
        lines
      end

      private def wrap_thinking(text : String, max_width : Int32) : Array(String)
        return [""] if text.empty?
        max_width = 1 if max_width < 1

        text.split('\n').flat_map do |line|
          line_w = CharWidth.visible_width(line)
          if line_w <= max_width
            [line]
          else
            words = line.split(' ')
            result = [] of String
            current = String::Builder.new
            current_w = 0

            words.each do |word|
              w = CharWidth.visible_width(word)
              if w > max_width
                if current_w > 0
                  result << current.to_s
                  current = String::Builder.new
                  current_w = 0
                end
                CharWidth.slice_into_width_chunks(word, max_width).each do |chunk|
                  result << chunk
                end
                next
              end

              sep = current_w > 0 ? 1 : 0
              if current_w + sep + w > max_width && current_w > 0
                result << current.to_s
                current = String::Builder.new
                current_w = 0
              end
              current << ' ' if current_w > 0
              current << word
              current_w += (current_w > 0 ? 1 : 0) + w
            end
            result << current.to_s if current_w > 0
            result
          end
        end.to_a
      end

      private def render_read_group(group : Array(ReadGroupEntry), name : String,
                                    expanded : Bool, cols : Int32) : Array(String)
        lines = [] of String
        total = group.size
        pending = group.count { |e| e.tool_result.nil? }
        failed = group.count { |e| e.is_error? }
        done_lines = group.sum { |e| count_non_empty_lines(e.tool_result) }

        header = String.build do |s|
          s << ANSI.color(@theme.colors.tool_header, nil)
          s << ANSI.bold
          s << "▶ "
          if pending > 0
            s << "Reading #{total} files…"
          elsif failed == total
            s << "Read #{total} files · failed"
          else
            s << "Read #{total} files"
            s << " · #{done_lines} #{done_lines == 1 ? "line" : "lines"}"
            s << " · #{failed} failed" if failed > 0
          end
          s << ANSI.reset
        end
        lines << header

        visible_entries = group.select { |e| read_group_file_path(e.tool_args) }
        visible_entries.each_with_index do |entry, idx|
          is_last = idx == visible_entries.size - 1
          branch = is_last ? "└─" : "├─"
          path = read_group_file_path(entry.tool_args) || "?"
          tail = if entry.tool_result.nil?
                   " · reading…"
                 elsif entry.is_error?
                   " · failed"
                 else
                   line_count = count_non_empty_lines(entry.tool_result)
                   " · #{line_count} #{line_count == 1 ? "line" : "lines"}"
                 end
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  #{branch} #{path}#{tail}#{ANSI.reset}"
        end

        if expanded
          group.each do |entry|
            next unless result = entry.tool_result
            result_lines = result.split('\n')
            max_lines = 200
            shown = result_lines.first(max_lines)
            shown.each do |l|
              lines << "#{ANSI.color(@theme.colors.tool_result, nil)}    #{l}#{ANSI.reset}"
            end
            if result_lines.size > max_lines
              lines << "#{ANSI.color(@theme.colors.dim, nil)}    ... (#{result_lines.size - max_lines} more)#{ANSI.reset}"
            end
          end
        end

        lines << ""
        lines
      end

      private def count_non_empty_lines(text : String?) : Int32
        return 0 if text.nil? || text.empty?
        text.split('\n').count { |line| !line.empty? }
      end

      private def read_group_file_path(args : String) : String?
        parsed = JSON.parse(args)
        path = parsed["filePath"]?.try(&.to_s) || parsed["path"]?.try(&.to_s)
        return nil if path.nil? || path.empty?
        path
      rescue
        nil
      end

      def render_welcome_box(cols : Int32) : Array(String)
        # Clamp to the logo width so the ASCII art (14 cols wide) can't push
        # the right border off-screen on very narrow terminals.
        box_w = {cols, 14}.max
        inner_w = box_w - 4

        logo_lines = [
          "    █   █     ",
          "  █████████   ",
          "  ██🔴█🔴██   ",
          "█████████████ ",
          "██▙▄▄▄▄▄▄▄▟██ ",
        ]

        lines = [] of String

        bc = ANSI.color(@theme.colors.border, nil)
        gc = ANSI.color(@theme.colors.logo, nil)
        rc = ANSI.color(@theme.colors.error, nil)
        mc = ANSI.color(@theme.colors.muted, nil)
        tc = ANSI.color(@theme.colors.text, nil)
        r = ANSI.reset

        lines << "#{bc}╭#{"─" * (box_w - 2)}╮#{r}"

        # Optional side text + color matched to each logo line by index.
        # Logo lines beyond this list render on their own (logo only), so
        # adding rows to `logo_lines` is automatically reflected in the box.
        side_texts = [
          {"#{ANSI.bold}#{H2code.t("ui.welcome")}#{r}", tc},
          {H2code.t("ui.send_help"), mc},
          {"", tc},
        ] of Tuple(String, String)

        logo_lines.each_with_index do |logo, i|
          text = ""
          color = tc
          if entry = side_texts[i]?
            text, color = entry
          end
          content_w = visible_len(text)
          used = 2 + visible_len(logo) + 2 + content_w
          pad = inner_w + 2 - used
          pad = 1 if pad < 1
          lines << "#{bc}│#{r}  #{colorize_logo(logo, gc, rc, r)}  #{color}#{text}#{" " * pad}#{bc}│#{r}"
        end

        lines << "#{bc}│#{r}#{" " * (box_w - 2)}#{bc}│#{r}"

        info = [
          {H2code.t("ui.status_directory"), @work_dir},
          {H2code.t("ui.status_session"), @session_id.empty? ? H2code.t("ui.status_new") : @session_id},
          {H2code.t("ui.status_model"), @model},
          {H2code.t("ui.status_version"), H2code::VERSION},
        ]

        info.each do |label, value|
          content = "  #{mc}#{label}:#{r} #{tc}#{value}#{r}"
          pad = box_w - 2 - visible_len(content)
          pad = 1 if pad < 1
          lines << "#{bc}│#{r}#{content}#{" " * pad}#{bc}│#{r}"
        end

        lines << "#{bc}╰#{"─" * (box_w - 2)}╯#{r}"
        lines
      end

      # Render a logo line with two-tone coloring: the body uses `gray`, while
      # the 🔴 eye markers use `red`. Splitting on the eye marker (kept via the
      # capture group) lets us recolor each segment independently, so the eyes
      # stay red regardless of how the terminal applies ANSI fg to emoji.
      private def colorize_logo(logo : String, gray : String, red : String, r : String) : String
        return "#{gray}#{logo}#{r}" unless logo.includes?('🔴')
        String.build do |io|
          logo.split(/(🔴)/).each do |seg|
            if seg == "🔴"
              io << red << seg << r
            else
              io << gray << seg << r
            end
          end
        end
      end

      private def tool_preview(name : String, args : String) : Array(String)
        parsed = JSON.parse(args)
        case name
        when Tools::Names::BASH
          cmd = parsed["command"]?.try(&.to_s) || ""
          # Mirror ShellExecutionComponent in the JS TUI: split the command
          # by `\n` so each source line is its own entry in the returned
          # array (1 entry == 1 terminal row, the renderer invariant). The
          # caller wraps each entry in dim + a 2-space indent; the first
          # line carries the `$ ` prompt, continuations carry a 2-space
          # prefix so they line up under the command body. Cap at
          # TOOL_PREVIEW_LINES so a giant script doesn't flood the transcript.
          cmd_lines = cmd.split('\n')
          shown = cmd_lines.size > TOOL_PREVIEW_LINES ? cmd_lines[0...TOOL_PREVIEW_LINES] : cmd_lines
          Array(String).new(shown.size) do |i|
            i == 0 ? "$ #{shown[i]}" : "  #{shown[i]}"
          end
        when Tools::Names::READ, Tools::Names::WRITE, Tools::Names::EDIT
          path = (parsed["path"]? || parsed["filePath"]?).try(&.to_s) || ""
          ["file: #{path}"]
        when Tools::Names::GLOB
          pattern = parsed["pattern"]?.try(&.to_s) || ""
          ["pattern: #{pattern}"]
        when Tools::Names::GREP
          pattern = parsed["pattern"]?.try(&.to_s) || ""
          ["search: #{pattern}"]
        else
          [] of String
        end
      rescue
        [] of String
      end

      private def render_edit_diff(display : Tools::ToolDisplay?, args : String) : Array(String)
        # Prefer the structured display carried on the tool result (populated
        # by the Edit tool itself); fall back to parsing the raw `tool_args`
        # for sessions recorded before the display channel existed. Both the
        # snake_case canonical names (`old_string`/`new_string`, as declared
        # in the Edit schema) and the legacy camelCase aliases are accepted,
        # mirroring `extract_key_argument`'s `path`/`filePath` form.
        old_str = ""
        new_str = ""

        if display
          old_str = display.before || ""
          new_str = display.after || ""
        else
          parsed = JSON.parse(args)
          old_str = (parsed["old_string"]? || parsed["oldString"]?).try(&.to_s) || ""
          new_str = (parsed["new_string"]? || parsed["newString"]?).try(&.to_s) || ""
        end

        lines = [] of String
        changed = DiffComputer.changed_lines(old_str, new_str)

        added = changed.count(&.kind.add?)
        removed = changed.count(&.kind.delete?)
        header = ""
        header += "#{ANSI.bold}#{ANSI.color(@theme.colors.success, nil)}+#{added} #{ANSI.reset}" if added > 0
        header += "#{ANSI.bold}#{ANSI.color(@theme.colors.error, nil)}-#{removed} #{ANSI.reset}" if removed > 0
        lines.unshift(header) unless header.empty?

        changed.each do |dl|
          case dl.kind
          when .delete?
            lines << "#{ANSI.color(@theme.colors.error, nil)}  - #{dl.content}#{ANSI.reset}"
          when .add?
            lines << render_highlighted_add(dl)
          end
        end

        lines
      rescue
        [] of String
      end

      # Renders an added diff line with word-level emphasis: the common
      # prefix/suffix are dimmed, the changed middle span is bold. Falls back
      # to a plain green line when no highlight span is attached.
      private def render_highlighted_add(dl : DiffComputer::DiffLine) : String
        content = dl.content
        span = dl.highlight

        prefix = "  + "
        unless span && span.length > 0
          return "#{ANSI.color(@theme.colors.success, nil)}#{prefix}#{content}#{ANSI.reset}"
        end

        before = content[0, span.start]
        changed_text = content[span.start, span.length]
        after = content[(span.start + span.length)..]

        String.build do |s|
          s << ANSI.color(@theme.colors.success, nil)
          s << prefix
          s << before if span.start > 0
          s << ANSI.bold
          s << changed_text
          s << ANSI.reset
          s << ANSI.color(@theme.colors.success, nil)
          s << after unless after.empty?
          s << ANSI.reset
        end
      end

      # Render a pending (in-flight) tool call for the ACTIVE zone. Mirrors
      # `tool_header` for the no-result case but replaces the static bullet
      # with an animated spinner, so the user sees live progress. The body
      # preview (e.g. the Bash command) matches what the log entry will show
      # once the result arrives.
      private def render_running_tool(msg : Message, cols : Int32) : Array(String)
        lines = [] of String
        name = msg.tool_name
        return lines unless name

        return render_recording_tool(msg, cols) if name == VoiceController::RECORDING_TOOL

        # Pulsing circle animation ● → • → ⋅ → •, advancing every 3 ticks
        # (~250ms). Matches the settled `●` bullet the log entry will show
        # once the result arrives.
        bullet_frame = Spinner::BASH_BULLET_FRAMES[(@spin_phase // 3) % Spinner::BASH_BULLET_FRAMES.size]
        pc = ANSI.color(@theme.colors.primary, nil)
        tc = ANSI.color(@theme.colors.text, nil)
        dc = ANSI.color(@theme.colors.dim, nil)
        r = ANSI.reset

        # Left vertical bar (rectangle) drawn down the whole running-tool block,
        # mirroring `render_streaming_text`'s STREAMING_BAR so every active-zone
        # tool shares the same mutable-region marker. Khaki (logo color).
        kc = ANSI.color(@theme.colors.logo, nil)
        lead = "#{kc}#{STREAMING_BAR}#{r} "
        rest_indent = "  "

        if name == Tools::Names::BASH
          label_color = sudo_command?(msg.tool_args) ? @theme.colors.warning : @theme.colors.primary
          pc = ANSI.color(label_color, nil)
          lines << "#{lead}#{tc}#{bullet_frame}#{r} #{pc}#{ANSI.bold}#{H2code.t("tools.running_command")}#{r}"
        else
          verb = H2code.t("tools.using")
          key_arg = extract_key_argument(name, msg.tool_args)
          tool_label = "#{pc}#{ANSI.bold}#{name}#{r}"
          arg_str = key_arg ? "#{dc} (#{key_arg})#{r}" : ""
          lines << "#{lead}#{tc}#{bullet_frame}#{r} #{verb} #{tool_label}#{arg_str}"
        end

        if args = msg.tool_args
          key_arg = extract_key_argument(name, args)
          if name == Tools::Names::BASH || key_arg.nil?
            tool_preview(name, args).each { |l| lines << "#{lead}#{rest_indent}#{dc}#{l}#{r}" }
          end
        end

        lines
      end

      LEVEL_BLOCKS = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█']

      # Live view of a voice recording (Ctrl+R): "● REC 00:12 ▄▆▅" with a VU
      # meter while capturing, then a spinner while the server transcribes.
      # Rendered in the active zone like any pending tool call. Both frames
      # draw exactly TWO lines: the block must never shrink mid-flight (a
      # shrink fires SyncBugsCount and the viewport-shrink full repaint
      # rewrites rows already sitting in the immutable scrollback).
      private def render_recording_tool(msg : Message, cols : Int32) : Array(String)
        lines = [] of String
        ec = ANSI.color(@theme.colors.error, nil)
        pc = ANSI.color(@theme.colors.primary, nil)
        dc = ANSI.color(@theme.colors.dim, nil)
        tc = ANSI.color(@theme.colors.text, nil)
        r = ANSI.reset

        kc = ANSI.color(@theme.colors.logo, nil)
        lead = "#{kc}#{STREAMING_BAR}#{r} "

        if voice_recording?
          # Pulsing red bullet — same cadence as the running-tool bullet.
          bullet_frame = Spinner::BASH_BULLET_FRAMES[(@spin_phase // 3) % Spinner::BASH_BULLET_FRAMES.size]
          meter_idx = (Math.sqrt(@voice_level) * LEVEL_BLOCKS.size).clamp(0..(LEVEL_BLOCKS.size - 1)).to_i
          meter = LEVEL_BLOCKS[meter_idx]
          lines << "#{lead}#{ec}#{bullet_frame}#{r} #{ec}#{ANSI.bold}REC#{r} #{tc}#{format_voice_time(voice_elapsed_ms)}#{r} #{pc}#{meter}#{r}"
          lines << "#{lead}  #{dc}Ctrl+R / Space — stop and transcribe · Esc — cancel#{r}"
        else
          sp = Spinner::FRAMES[@spin_phase % Spinner::FRAMES.size]
          engine = @voice_engine.empty? ? "" : " · #{@voice_engine}"
          lines << "#{lead}#{tc}#{STATUS_BULLET}#{r} #{pc}#{sp}#{r} #{tc}#{ANSI.bold}Transcribing#{r}#{dc}#{engine}#{r}"
          # Frozen recorded duration instead of the capture hint (meaningless
          # mid-transcription) — keeps the block at two lines, no shrink.
          lines << "#{lead}  #{dc}#{format_voice_time(@voice_recorded_ms)} recorded#{r}"
        end
        lines
      end

      # mm:ss from milliseconds.
      private def format_voice_time(ms : Int64) : String
        total = ms // 1000
        "%02d:%02d" % {total // 60, total % 60}
      end

      # Header for a finished voice recording: "● Voice message · 00:07 ·
      # gigaam" (duration/engine/language from the meta JSON stored in
      # tool_args), "○ Cancelled · 00:04" for a discarded recording, or
      # "✗ Recording failed" when the session errored.
      private def voice_tool_header(args : String?, has_result : Bool, is_error : Bool) : String
        return "#{ANSI.color(@theme.colors.error, nil)}✗ #{ANSI.reset}#{ANSI.color(@theme.colors.error, nil)}#{ANSI.bold}Recording failed#{ANSI.reset}" if is_error

        duration = ""
        engine = ""
        cancelled = false
        if args
          begin
            parsed = JSON.parse(args)
            if (ms = parsed["duration_ms"]?.try(&.as_i64?)) && ms > 0
              duration = format_voice_time(ms)
            end
            engine = parsed["engine"]?.try(&.to_s) || ""
            cancelled = parsed["cancelled"]?.try(&.as_bool?) || false
          rescue JSON::ParseException
          end
        end
        if cancelled
          bullet = "#{ANSI.color(@theme.colors.dim, nil)}○ #{ANSI.reset}"
          label = "#{ANSI.color(@theme.colors.dim, nil)}Cancelled#{ANSI.reset}"
          detail = duration.empty? ? "" : "#{ANSI.color(@theme.colors.dim, nil)} · #{duration}#{ANSI.reset}"
          return "#{bullet}#{label}#{detail}"
        end
        bullet = "#{ANSI.color(@theme.colors.success, nil)}● #{ANSI.reset}"
        label = "#{ANSI.color(@theme.colors.primary, nil)}#{ANSI.bold}Voice message#{ANSI.reset}"
        detail = "#{ANSI.color(@theme.colors.dim, nil)} · #{[duration, engine].reject(&.empty?).join(" · ")}#{ANSI.reset}"
        "#{bullet}#{label}#{detail}"
      end

      private def tool_header(name : String, args : String?, tool_result : String?,
                              has_result : Bool, is_error : Bool) : String
        bullet =
          if is_error
            "#{ANSI.color(@theme.colors.error, nil)}✗ #{ANSI.reset}"
          elsif has_result
            "#{ANSI.color(@theme.colors.success, nil)}● #{ANSI.reset}"
          else
            "#{ANSI.color(@theme.colors.text, nil)}● #{ANSI.reset}"
          end

        if name == VoiceController::RECORDING_TOOL
          return voice_tool_header(args, has_result, is_error)
        end

        if name == Tools::Names::BASH
          label = has_result ? H2code.t("tools.ran_command") : H2code.t("tools.running_command")
          tone = is_error ? @theme.colors.error : (sudo_command?(args) ? @theme.colors.warning : @theme.colors.primary)
          return "#{bullet}#{ANSI.color(tone, nil)}#{ANSI.bold}#{label}#{ANSI.reset}"
        end

        verb = has_result ? H2code.t("tools.used") : H2code.t("tools.using")
        key_arg = extract_key_argument(name, args)
        tool_label = "#{ANSI.color(@theme.colors.primary, nil)}#{ANSI.bold}#{name}#{ANSI.reset}"
        arg_str = key_arg ? "#{ANSI.color(@theme.colors.dim, nil)} (#{key_arg})#{ANSI.reset}" : ""
        chip_str = ""

        if name == Tools::Names::READ && has_result && !is_error
          if result = tool_result
            lines_count = count_non_empty_lines(result)
            chip_str = "#{ANSI.color(@theme.colors.dim, nil)} · #{lines_count} #{lines_count == 1 ? H2code.t("tools.line") : H2code.t("tools.lines")}#{ANSI.reset}"
          end
        end

        "#{bullet}#{verb} #{tool_label}#{arg_str}#{chip_str}"
      end

      BRAILLE_LEVELS = ['⣀', '⣄', '⣤', '⣦', '⣶', '⣷', '⣿']

      # Render a live progress grid for an AgentSwarm/Agent tool call. Each
      # subagent is one row: an animated braille bar + phase label + item text.
      # The bar's fill is estimated from tick count relative to the max across
      # siblings, and the spinner phase animates on each render tick.
      private def render_swarm_progress(msg : Message, tool_name : String, cols : Int32) : Array(String)
        lines = [] of String
        c = @theme.colors
        pc = ANSI.color(c.primary, nil)
        dc = ANSI.color(c.dim, nil)
        sc = ANSI.color(c.success, nil)
        ec = ANSI.color(c.error, nil)
        tc = ANSI.color(c.text, nil)
        mc = ANSI.color(c.muted, nil)
        r = ANSI.reset

        # Khaki vertical bar mirroring `render_streaming_text` /
        # `render_running_tool`, so swarm calls share the active-zone
        # mutable-region marker.
        kc = ANSI.color(c.logo, nil)
        lead = "#{kc}#{STREAMING_BAR}#{r} "
        rest_indent = "  "

        members = msg.swarm_members

        # Header: ● AgentSwarm (description) — Working... / Completed.
        has_result = !msg.tool_result.nil?
        bullet =
          if msg.is_error?
            "#{ec}✗ #{r}"
          elsif has_result
            "#{sc}● #{r}"
          else
            "#{tc}● #{r}"
          end

        description = extract_key_argument(tool_name, msg.tool_args) || tool_name
        running = members.any?(&.running?)
        failed = members.count(&.failed?)

        status_label =
          if !has_result && running
            sp = Spinner::FRAMES[@spin_phase % Spinner::FRAMES.size]
            "#{pc}#{sp}#{r} "
          else
            ""
          end

        status_word =
          if has_result
            failed > 0 ? "Completed with #{failed} failed." : "Completed."
          elsif running
            "Working..."
          else
            "Done."
          end

        tool_label = "#{pc}#{ANSI.bold}#{tool_name}#{r}"
        arg_str = "#{dc} (#{description})#{r}"
        lines << "#{lead}#{bullet}#{tool_label}#{arg_str}"

        # Per-member rows.
        max_ticks = members.max_of(&.ticks)
        max_ticks = 1 if max_ticks < 1

        members.each do |sm|
          if sm.completed?
            mark = "#{sc}✓#{r}"
            phase_str = "#{sc}done#{r}"
          elsif sm.failed?
            mark = "#{ec}✗#{r}"
            phase_str = "#{ec}#{sm.phase}#{r}"
          elsif sm.running?
            mark = "#{pc}#{Spinner::FRAMES[@spin_phase % Spinner::FRAMES.size]}#{r}"
            phase_str = "#{mc}running#{r}"
          else
            mark = "#{dc}·#{r}"
            phase_str = "#{dc}#{sm.phase}#{r}"
          end

          # Braille bar: fill proportional to ticks relative to max.
          fill = (sm.ticks.to_f / max_ticks * BRAILLE_LEVELS.size).clamp(0..(BRAILLE_LEVELS.size - 1)).to_i
          # Animate: nudge the fill up by one level on odd spin phases for
          # running agents so the bar shimmers even without new events.
          if sm.running? && (@spin_phase % 4) < 2
            fill = {fill + 1, BRAILLE_LEVELS.size - 1}.min
          end
          bar_char = BRAILLE_LEVELS[fill]
          bar_color = sm.completed? ? sc : (sm.failed? ? ec : pc)
          bar = "#{bar_color}#{bar_char}#{r}"

          item = sm.item_text.empty? ? sm.agent_id : sm.item_text
          # Truncate item text to fit within the terminal width.
          max_item_w = {cols - 16, 10}.max
          if CharWidth.visible_width(item) > max_item_w
            item = CharWidth.truncate_to_width(item, max_item_w)
          end

          # For running members with streaming text, replace the static
          # "running" label with the latest line of their output — mirrors
          # kimi-code's runningCellLabelText (latestModelText).
          preview_lines = [] of String
          if sm.running? && !sm.latest_text.empty?
            preview_lines = latest_non_empty_lines(sm.latest_text, 3)
            if first_line = preview_lines[0]?
              phase_str = "#{mc}#{CharWidth.truncate_to_width(first_line, max_item_w)}#{r}"
            end
          end

          lines << "#{lead}#{mark} #{bar} #{tc}#{item}#{r} #{phase_str}"

          # For a single-agent call, show 2 extra streaming preview lines below
          # the member row so the user sees ~3 lines of live output (the first
          # line is already in the row label). Skipped for multi-agent swarms
          # to keep the grid compact.
          if sm.running? && members.size == 1 && preview_lines.size > 1
            max_preview_w = {cols - 6, 10}.max
            preview_lines[1..].each do |pline|
              lines << "#{lead}#{rest_indent}#{dc}#{CharWidth.truncate_to_width(pline, max_preview_w)}#{r}"
            end
          end
        end

        # Footer: aggregate status line.
        lines << "#{lead}#{dc}#{status_label}#{status_word}#{r}"
        lines << ""
      end

      # Extract the last `max` non-empty, stripped lines from a streaming text
      # buffer, preserving order (oldest first). Used to show a live preview of
      # each subagent's assistant output in the swarm grid.
      private def latest_non_empty_lines(text : String, max : Int32) : Array(String)
        result = [] of String
        text.split('\n').reverse_each do |line|
          stripped = line.strip
          next if stripped.empty?
          result.unshift(stripped)
          break if result.size >= max
        end
        result
      end

      private def extract_key_argument(name : String, args : String?) : String?
        return nil unless args
        parsed = JSON.parse(args)
        case name
        when Tools::Names::READ, Tools::Names::WRITE, Tools::Names::EDIT
          path = parsed["filePath"]?.try(&.to_s) || parsed["path"]?.try(&.to_s)
          return path if path && !path.empty?
        when Tools::Names::GLOB, Tools::Names::GREP
          pattern = parsed["pattern"]?.try(&.to_s)
          return pattern if pattern && !pattern.empty?
        end
        nil
      rescue
        nil
      end

      private def sudo_command?(args : String?) : Bool
        return false unless args
        parsed = JSON.parse(args)
        command = parsed["command"]?.try(&.to_s) || ""
        Permission::Danger.detect_command(command) == "elevated privileges"
      rescue
        false
      end

      private def wrap_text(text : String, max_width : Int32) : Array(String)
        return [""] if text.empty?
        max_width = 1 if max_width < 1

        text.split('\n').flat_map do |line|
          line_w = CharWidth.visible_width(line)
          if line_w <= max_width
            [line]
          else
            words = line.split(' ')
            result = [] of String
            current = String::Builder.new
            current_w = 0

            words.each do |word|
              w = CharWidth.visible_width(word)
              # Hard-break a single token wider than max_width so it can't
              # overflow the column (CJK / long paths / no-space strings).
              if w > max_width
                if current_w > 0
                  result << current.to_s
                  current = String::Builder.new
                  current_w = 0
                end
                CharWidth.slice_into_width_chunks(word, max_width).each do |chunk|
                  result << chunk
                end
                next
              end

              sep = current_w > 0 ? 1 : 0
              if current_w + sep + w > max_width && current_w > 0
                result << current.to_s
                current = String::Builder.new
                current_w = 0
              end
              current << ' ' if current_w > 0
              current << word
              current_w += (current_w > 0 ? 1 : 0) + w
            end
            result << current.to_s if current_w > 0
            result
          end
        end.to_a
      end
    end
  end
end
