module H2code
  module TUI
    module UIPanels
      private def render_sudo_approval_panel(cols : Int32) : Array(String)
        lines = [] of String
        accent = @theme.colors.primary
        dim = @theme.colors.dim

        render_width = {cols - 4, 20}.max
        border_top = "#{ANSI.color(accent, nil)}  ┌#{ANSI.bold} Sudo command requires approval #{ANSI.reset}#{ANSI.color(accent, nil)}#{"─" * {render_width - 31, 1}.max}┐#{ANSI.reset}"
        border_bot = "#{ANSI.color(accent, nil)}  └#{"─" * {render_width - 1, 1}.max}┘#{ANSI.reset}"

        lines << ""
        lines << border_top

        if cmd = @sudo_approval_pending
          cmd_display = cmd.size > render_width - 6 ? cmd[0, render_width - 9] + "..." : cmd
          lines << "#{ANSI.color(accent, nil)}  │#{ANSI.reset} #{ANSI.color(dim, nil)}$ #{cmd_display}#{ANSI.reset}"
        end

        lines << "#{ANSI.color(accent, nil)}  │#{ANSI.reset}"

        start, count = @sudo_approval_list.visible_window
        count.times do |rel|
          i = start + rel
          item = @sudo_approval_list.item_at(i).to_s
          is_sel = i == @sudo_approval_list.selected
          if is_sel
            lines << "#{ANSI.color(accent, nil)}  │#{ANSI.reset} #{ANSI.color(accent, nil)}#{ANSI.bold}→ #{item}#{ANSI.reset}"
          else
            lines << "#{ANSI.color(accent, nil)}  │#{ANSI.reset} #{ANSI.color(dim, nil)}  #{item}#{ANSI.reset}"
          end
        end

        lines << "#{ANSI.color(accent, nil)}  │#{ANSI.reset}"
        lines << "#{ANSI.color(accent, nil)}  │#{ANSI.reset} #{ANSI.color(dim, nil)}↑↓ select · ↵ confirm · esc deny#{ANSI.reset}"
        lines << border_bot
        lines
      end

      private def render_session_panel(cols : Int32) : Array(String)
        lines = [] of String
        lines << ""
        lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  #{@session_list.title}#{ANSI.reset}"

        start, count = @session_list.visible_window
        if @session_list.scrolled_up?
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↑ #{start} more#{ANSI.reset}"
        end
        count.times do |rel|
          i = start + rel
          item = CharWidth.truncate_to_width(@session_list.item_at(i).to_s, cols - 4)
          if i == @session_list.selected
            lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  ▶ #{item}#{ANSI.reset}"
          else
            lines << "#{ANSI.color(@theme.colors.muted, nil)}    #{item}#{ANSI.reset}"
          end
        end
        if @session_list.scrolled_down?
          remaining = @session_list.filtered_size - (start + count)
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↓ #{remaining} more#{ANSI.reset}"
        end

        lines << "#{ANSI.color(@theme.colors.dim, nil)}  [↑↓] navigate  [type] search  [Enter] select  [Esc] cancel#{ANSI.reset}"
        lines
      end

      private def render_editor(cols : Int32) : Array(String)
        text = @editor.text
        if text.empty?
          return [""]
        end
        text.split('\n')
      end

      # One-line notice directly under the input box, shown while the session
      # lives in a `/fork` sandbox clone: `Clone: <folder>`. Rendered bold in
      # the theme's warning colour so it stands out — a clear "you are NOT on
      # the main checkout" signal. Disappears when `/merge` retargets the
      # session back at the original repository.
      private def render_clone_dir_line(cols : Int32) : Array(String)
        return [] of String unless Worktree.fork_sandbox?(@work_dir, @home)
        line = CharWidth.truncate_to_width("Clone: #{@work_dir}", {cols - 2, 1}.max)
        ["#{ANSI.color(@theme.colors.warning, nil)}#{ANSI.bold}#{line}#{ANSI.reset}"]
      end

      private def render_editor_box(cols : Int32) : Array(String)
        # Use cols-1 so border lines are never exactly cols wide — a full-width
        # line triggers a terminal pending-wrap state that corrupts incremental
        # rendering (cursor_down double-wraps, leaving stale rows).
        box_w = {cols - 1, 10}.max
        # Input frame tint: white in normal mode, yellow (opencode darkYellow
        # #e5c07b) when Plan mode is active.
        border_color = @plan_mode ? 180 : 255
        bc = ANSI.color(border_color, nil)
        pc = ANSI.color(@theme.colors.primary, nil)
        tc = ANSI.color(@theme.colors.text, nil)
        dc = ANSI.color(@theme.colors.dim, nil)
        r = ANSI.reset

        dash = "─" * {0, box_w - 2}.max
        lines = [] of String
        lines << "#{bc}╭#{dash}╮#{r}"

        # When a searchable list (model or session picker) is open, the input
        # box renders the active search query with the cursor at its end,
        # instead of the regular editor content / "send a message" placeholder.
        if search_picker_active?
          query = current_search_query
          prompt = "#{pc}#{ANSI.bold}>#{r} "
          if query.empty?
            body = "#{dc}#{search_placeholder}#{r}"
            lines << build_editor_row(box_w, bc, r, prompt, body)
            @editor.cursor_visual_row = 0
            @editor.cursor_visual_col = 0
          else
            render_query_row(box_w, bc, pc, tc, r, prompt, query, lines)
          end
          lines << "#{bc}╰#{dash}╯#{r}"
          return lines
        end

        if @editor.empty?
          # No content: park the cursor on the single placeholder row.
          prompt = "#{pc}#{ANSI.bold}>#{r} "
          placeholder_text = if @setup_mode && (w = @wizard) && !w.done?
                               w.placeholder
                             elsif @github_token_mode
                               H2code.t("ui.github_token_placeholder")
                             elsif @gitlab_token_mode
                               H2code.t("ui.gitlab_token_placeholder")
                             elsif @plan_mode
                               H2code.t("ui.send_a_message") + " (" + H2code.t("ui.plan_mode_placeholder") + ")"
                             else
                               H2code.t("ui.send_a_message")
                             end
          body = "#{dc}#{placeholder_text}#{r}"
          lines << build_editor_row(box_w, bc, r, prompt, body)
          @editor.cursor_visual_row = 0
          @editor.cursor_visual_col = 0
        else
          cursor_row, cursor_col = @editor.cursor_position
          editor_lines = @editor.text.split('\n')

          # Inner content width: left border(1) + prompt(3) + content + right
          # border(1) = box_w ⇒ content = box_w - 5. Each rendered row is then
          # padded to exactly box_w so the right `│` lines up with the corners.
          inner_w = box_w - 5
          inner_w = 1 if inner_w < 1
          # Wrap one column narrower than the content area so the end-of-line
          # cursor (a highlighted trailing space) always fits without pushing
          # the right border past the box edge. Mirrors pi-tui's
          # `layoutWidth = contentWidth - 1`.
          wrap_w = inner_w - 1
          wrap_w = 1 if wrap_w < 1

          visual_row = 0
          found_cursor = false
          editor_lines.each_with_index do |eline, i|
            is_cursor_line = (i == cursor_row)
            chunks = wrap_editor_line(eline, wrap_w)
            chunks.each_with_index do |(chunk_text, chunk_start, chunk_end), ci|
              first = (i == 0 && ci == 0)
              prompt = first ? "#{pc}#{ANSI.bold}>#{r} " : "  "

              # Mirror pi-tui's layoutText cursor resolution: the cursor lives
              # in the chunk whose [start, end) covers cursor_col, except for
              # the final chunk which also owns the line-end position (>=).
              has_cursor = false
              local = 0
              if is_cursor_line
                is_last_chunk = (ci == chunks.size - 1)
                if is_last_chunk
                  has_cursor = cursor_col >= chunk_start
                else
                  has_cursor = cursor_col >= chunk_start && cursor_col < chunk_end
                end
                local = ({cursor_col - chunk_start, 0}.max)
                local = {local, chunk_text.size}.min if has_cursor
              end

              if has_cursor
                before = chunk_text[0...local]? || ""
                char_at = chunk_text[local]? || " "
                after = chunk_text[(local + 1)..]? || ""
                body = "#{tc}#{before}#{r}#{ANSI.color(nil, @theme.colors.primary)}#{char_at}#{r}#{tc}#{after}#{r}"
                @editor.cursor_visual_col = visible_len(before)
                found_cursor = true
              else
                body = "#{tc}#{chunk_text}#{r}"
              end

              lines << build_editor_row(box_w, bc, r, prompt, body)
              visual_row += 1 unless found_cursor
            end
          end

          @editor.cursor_visual_row = found_cursor ? visual_row : 0
        end

        lines << "#{bc}╰#{dash}╯#{r}"
        lines
      end

      # True when a searchable picker is open — the input box renders the
      # live query instead of normal editor content.
      private def search_picker_active? : Bool
        (@model_list.visible? && @model_list.searchable?) ||
          (@session_list.visible? && @session_list.searchable?)
      end

      # The query string driving the currently open searchable picker.
      private def current_search_query : String
        return @session_list.query if @session_list.visible? && @session_list.searchable?
        @model_list.query
      end

      # Placeholder shown in the input box while the query is empty.
      private def search_placeholder : String
        return H2code.t("ui.search_session") if @session_list.visible? && @session_list.searchable?
        H2code.t("ui.search_model")
      end

      # Renders the fuzzy query as a single-line editor content row, with the
      # cursor highlighted at the end (wrapping into multiple rows if it exceeds
      # the box width). Reuses the editor's wrap + cursor styling so the look
      # matches normal typing.
      private def render_query_row(box_w : Int32, bc : String, pc : String,
                                   tc : String, r : String, prompt : String,
                                   query : String, lines : Array(String)) : Nil
        inner_w = box_w - 5
        inner_w = 1 if inner_w < 1
        wrap_w = inner_w - 1
        wrap_w = 1 if wrap_w < 1

        chunks = wrap_editor_line(query, wrap_w)
        cursor_col = query.size
        visual_row = 0
        found_cursor = false
        chunks.each_with_index do |(chunk_text, chunk_start, chunk_end), ci|
          first = ci == 0
          row_prompt = first ? prompt : "  "
          is_last_chunk = (ci == chunks.size - 1)
          has_cursor = false
          if is_last_chunk
            has_cursor = cursor_col >= chunk_start
          else
            has_cursor = cursor_col >= chunk_start && cursor_col < chunk_end
          end
          local = ({cursor_col - chunk_start, 0}.max)
          local = {local, chunk_text.size}.min if has_cursor

          if has_cursor
            before = chunk_text[0...local]? || ""
            char_at = chunk_text[local]? || " "
            after = chunk_text[(local + 1)..]? || ""
            body = "#{tc}#{before}#{r}#{ANSI.color(nil, @theme.colors.primary)}#{char_at}#{r}#{tc}#{after}#{r}"
            @editor.cursor_visual_col = visible_len(before)
            found_cursor = true
          else
            body = "#{tc}#{chunk_text}#{r}"
          end
          lines << build_editor_row(box_w, bc, r, row_prompt, body)
          visual_row += 1 unless found_cursor
        end
        @editor.cursor_visual_row = found_cursor ? visual_row : 0
      end

      # Build one editor content row padded to exactly `box_w` columns:
      # `│ <prompt><body>    │`. ANSI escapes are zero-width, so padding is
      # computed from visible widths, keeping the right border aligned with
      # the box corners even when `body` carries cursor/colour SGR codes.
      private def build_editor_row(box_w : Int32, bc : String, r : String, prompt : String, body : String) : String
        left = "#{bc}│#{r} #{prompt}"
        right = "#{bc}│#{r}"
        pad = box_w - visible_len(left) - visible_len(body) - visible_len(right)
        pad = 0 if pad < 0
        "#{left}#{body}#{" " * pad}#{right}"
      end

      # Soft-wrap one logical editor line into display chunks that each fit
      # `max_w` visible columns. Returns `{text, start_index, end_index}` per
      # chunk, where the indices are codepoint offsets into `line` (matching
      # the editor's codepoint-based cursor). Mirrors pi-tui's `wordWrapLine`:
      # word-boundary wrapping (break after whitespace) with a force-break
      # fallback for tokens longer than `max_w`, and CJK-aware break points.
      # Keeping grapheme clusters (base + combining marks, ZWJ emoji) intact
      # relies on `CharWidth.zero_width?` / `cjk_break?`.
      def wrap_editor_line(line : String, max_w : Int32) : Array({String, Int32, Int32})
        return [{"", 0_i32, 0_i32}] if line.empty? || max_w <= 0
        cps = line.codepoints.map(&.to_u32)
        n = cps.size

        # Pre-split into grapheme clusters with their start index, visible
        # width, whitespace flag, and base codepoint (for CJK break detection).
        clusters = [] of Tuple(Int32, Int32, Bool, UInt32)
        i = 0
        while i < n
          base = i
          k = i + 1
          while k < n
            cpk = cps[k]
            if CharWidth.zero_width?(cpk)
              k += 1
            elsif cps[k - 1] == 0x200D_u32 # ZWJ keeps the joined emoji in-cluster
              k += 1
            else
              break
            end
          end
          text = cps_to_string(cps, base, k)
          clusters << {base.to_i32, CharWidth.visible_width(text), text == " " || text == "\t", cps[base]}
          i = k
        end

        chunks = [] of {String, Int32, Int32}
        current_w = 0
        chunk_start = 0
        # Wrap opportunity: codepoint index where a break is allowed, plus the
        # visible width consumed up to that point (exclusive).
        wrap_idx = -1
        wrap_w = 0

        clusters.each_with_index do |(idx, w, is_space, base_cp), ci|
          if current_w + w > max_w
            # Single-grapheme guard (mirrors pi-tui editor.ts:172-181): if the
            # overflow is caused by an indivisible cluster wider than `max_w`
            # sitting at the start of the chunk, don't force-break — there's
            # nothing to split, so let the cluster occupy the line as-is.
            if chunk_start == idx && w > max_w
              # Skip break logic; the cluster is added below.
            elsif wrap_idx >= 0 && current_w - wrap_w + w <= max_w
              # Backtrack to the last word boundary — the remaining tail plus
              # this cluster still fits within max_w.
              chunks << {cps_to_string(cps, chunk_start, wrap_idx), chunk_start, wrap_idx}
              chunk_start = wrap_idx
              current_w -= wrap_w
            elsif chunk_start < idx
              # No viable word boundary (or backtracking wouldn't help): force
              # a break at the current cluster boundary.
              chunks << {cps_to_string(cps, chunk_start, idx), chunk_start, idx}
              chunk_start = idx
              current_w = 0
            end
            wrap_idx = -1
            wrap_w = 0
          end

          current_w += w

          if nxt = clusters[ci + 1]?
            _, _, next_space, next_cp = nxt
            if is_space && !next_space
              # Word boundary: whitespace immediately before non-whitespace.
              wrap_idx = idx + 1
              wrap_w = current_w
            elsif !is_space && !next_space && (CharWidth.cjk_break?(base_cp) || CharWidth.cjk_break?(next_cp))
              # CJK allows line breaks between any two adjacent characters.
              wrap_idx = idx + 1
              wrap_w = current_w
            end
          end
        end

        # Flush the trailing chunk (or the whole line when it never overflowed).
        if chunk_start < n || chunks.empty?
          chunks << {cps_to_string(cps, chunk_start, n), chunk_start, n}
        end
        chunks
      end

      private def cps_to_string(cps : Array(UInt32), start_idx : Int32, end_idx : Int32) : String
        return "" if start_idx >= end_idx
        String.build do |io|
          (start_idx...end_idx).each { |k| io << cps[k].chr }
        end
      end

      # Footer context readout. Mirrors the TS TUI's `formatContextStatus`:
      # when both the token count and the window size are known, render
      # `context: NN% (Xk/Yk)`; otherwise fall back to the precomputed
      # percent. The percent is recomputed from the raw counts so it does
      # not lag a step behind `@context_percent`.
      private def build_context_status : String
        label = H2code.t("ui.context_label").downcase
        if @max_context_tokens > 0 && @context_tokens > 0
          pct = (@context_tokens.to_f64 / @max_context_tokens * 100).ceil.to_i
          pct = 100 if pct > 100
          "#{label}: #{pct}% (#{LLM::TokenCounter.format_count(@context_tokens)}/#{LLM::TokenCounter.format_count(@max_context_tokens)})"
        else
          "#{label}: #{@context_percent.round(0).to_i}%"
        end
      end

      # Returns the current TodoList items via the `on_fetch_todos` callback
      # (wired in `h2code.cr` to `Tools::TodoList#todos`). Returns nil if the
      # tool isn't registered or no todos exist, so the panel is hidden.
      private def current_todos : Array({String, String})?
        return nil unless cb = @on_fetch_todos
        cb.call
      end

      # When the live todo list is fully done, freeze it into the transcript as
      # a `todo_snapshot` message (rendered like the live panel but without the
      # active-zone left bar — see `render_message`) and clear the tool's state,
      # so the completed plan migrates into the append-only log and a fresh list
      # can be started. Called after every `tool_result`; a no-op unless all
      # items are done.
      # Renders the todo list. In the active zone (`active = true`) a khaki
      # vertical bar marks the mutable region like other live blocks; the frozen
      # `todo_snapshot` in the log is clean — no bar (immutable history).
      # In the active zone a full-width solid progress bar (done/total, in
      # percent) is drawn below the plan — see `TUI::ProgressBar`.
      private def render_todo_panel(todos : Array({String, String}), cols : Int32, active : Bool = false) : Array(String)
        lines = [] of String
        accent = @theme.colors.primary
        dim = @theme.colors.dim
        success = @theme.colors.success
        warning = @theme.colors.warning

        lead = if active
                 kc = ANSI.color(@theme.colors.logo, nil)
                 "#{kc}#{MessageRenderer::STREAMING_BAR}#{ANSI.reset} "
               else
                 "  "
               end

        pending = todos.count { |(_, s)| s != "done" }
        done = todos.size - pending
        lines << "#{lead}#{ANSI.color(accent, nil)}#{ANSI.bold}Todos (#{done}/#{todos.size})#{ANSI.reset}"
        todos.each do |(title, status)|
          marker, color = case status
                          when "done"        then {"✓", success}
                          when "in_progress" then {"▶", warning}
                          else                    {"○", dim}
                          end
          lines << "#{lead}#{ANSI.color(color, nil)}#{marker} #{title}#{ANSI.reset}"
        end
        if active
          lines << ProgressBar.render(done, todos.size, cols, khaki: @theme.colors.logo)
        else
          lines << "" if pending > 0
        end
        lines
      end

      # Queue pane: lists messages typed while the agent was busy, plus a
      # context-sensitive hint. Mirrors TS `components/panes/queue-pane.ts`.
      # Shown only when `@queue` is non-empty.
      private def render_queue_pane(cols : Int32, active : Bool = false) : Array(String)
        lines = [] of String
        accent = @theme.colors.primary
        dim = @theme.colors.dim

        lead = if active
                 kc = ANSI.color(@theme.colors.logo, nil)
                 "#{kc}#{MessageRenderer::STREAMING_BAR}#{ANSI.reset} "
               else
                 "  "
               end

        lines << "#{lead}#{ANSI.color(accent, nil)}#{ANSI.bold}Queued (#{@queue.size})#{ANSI.reset} " \
                 "#{ANSI.color(dim, nil)}#{queue_hint}#{ANSI.reset}"
        @queue.each_with_index do |qm, i|
          preview = truncate_preview(qm.text)
          prefix = i == 0 ? "▶ " : "  "
          lines << "#{lead}#{ANSI.color(dim, nil)}#{prefix}#{preview}#{ANSI.reset}"
        end
        lines
      end

      private def render_footer(cols : Int32) : String
        # ── WannaExit lock ──
        # When the user pressed Ctrl+C / Ctrl+D once, the footer line is frozen
        # to the exit prompt. No subsequent event — streaming results, status
        # changes, context-token updates — can overwrite it. This guarantees
        # that once the exit confirmation is shown it stays visible until the
        # user confirms (second press) or cancels (Esc), preventing collisions
        # where a background render swapped the last line back to context info.
        if @exit_confirm
          key = @ci_active ? "ui.ci_exit_warning" : "ui.press_to_exit"
          return "#{ANSI.color(@theme.colors.warning, nil)} #{H2code.t(key, btn: @exit_key)}#{ANSI.reset}"
        end

        parts = [
          @provider_name,
          @permission_mode,
          @model,
        ]
        unless @git_branch.empty?
          parts << @git_branch
        end
        ctx_str = build_context_status

        left = parts.join("  ")
        # Right side: context usage + a rotating tip when idle, or just
        # context when the agent is busy (the status line owns the message
        # in that case). Mirrors TS footer tips rotation.
        tip = @agent_busy ? "" : "  " + current_tip
        right = ctx_str + tip

        gap = cols - visible_len(left) - visible_len(right)
        gap = 1 if gap < 1

        "#{ANSI.color(@theme.colors.dim, nil)}#{left}#{" " * gap}#{right}#{ANSI.reset}"
      end

      # Rotating keyboard / workflow hint shown in the footer when idle.
      # Picked by wall-clock seconds so it cycles without per-render state.
      private def render_provider_panel(cols : Int32) : Array(String)
        lines = [] of String
        lines << ""
        lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  #{@provider_list.title}#{ANSI.reset}"

        start, count = @provider_list.visible_window
        if @provider_list.scrolled_up?
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↑ #{start} more#{ANSI.reset}"
        end
        count.times do |rel|
          i = start + rel
          item = @provider_list.items[i]
          info = LLM::Provider.providers.find { |p| p.name == item }
          desc = info.try(&.description) || ""
          marker = item == @provider_name ? " (active)" : ""
          line_text = "#{item.ljust(8)} #{desc}#{marker}"
          line_text = CharWidth.truncate_to_width(line_text, cols - 6)
          if i == @provider_list.selected
            lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  ▶ #{line_text}#{ANSI.reset}"
          else
            lines << "#{ANSI.color(@theme.colors.muted, nil)}    #{line_text}#{ANSI.reset}"
          end
        end
        if @provider_list.scrolled_down?
          remaining = @provider_list.items.size - (start + count)
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↓ #{remaining} more#{ANSI.reset}"
        end

        lines << "#{ANSI.color(@theme.colors.dim, nil)}  [↑↓] navigate  [Enter] select  [Esc] cancel#{ANSI.reset}"
        lines
      end

      private def render_model_panel(cols : Int32) : Array(String)
        lines = [] of String
        lines << ""
        searching = !@model_list.query.empty?
        title = @model_list.title
        lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  #{title}#{ANSI.reset}"

        active_label = H2code.t("ui.model_active")
        start, count = @model_list.visible_window
        if @model_list.scrolled_up?
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↑ #{start} more#{ANSI.reset}"
        end
        count.times do |rel|
          i = start + rel
          item = @model_list.item_at(i).to_s
          positions = @model_list.match_positions_at(i)
          rendered = render_picker_item(item, positions, cols - 4,
            i == @model_list.selected)
          marker = item == @model ? " #{ANSI.color(@theme.colors.success, nil)}#{active_label}#{ANSI.reset}" : ""
          lines << rendered + marker
        end
        if @model_list.scrolled_down?
          remaining = @model_list.filtered_size - (start + count)
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↓ #{remaining} more#{ANSI.reset}"
        end

        # Status line: how many models are visible in the viewport vs total.
        # Shown always — both when searching and when browsing the full list.
        shown = count
        total = @model_list.filtered_size
        if shown < total
          status = H2code.t("ui.models_shown_of", shown: shown, total: total)
        else
          status = H2code.t("ui.models_shown_all")
        end
        lines << "#{ANSI.color(@theme.colors.dim, nil)}  #{status}#{ANSI.reset}"
        lines << "#{ANSI.color(@theme.colors.dim, nil)}  #{model_picker_hint(searching)}#{ANSI.reset}"
        lines
      end

      # Builds the key-hint line from translated action words. The bracketed
      # key symbols are universal; only the action text is localized.
      private def model_picker_hint(searching : Bool) : String
        nav = "[↑↓] #{H2code.t("ui.picker_navigate")}"
        pick = "[Enter] #{H2code.t("ui.picker_select")}"
        cancel = "[Esc] #{H2code.t("ui.picker_cancel")}"
        if searching
          clear = "[⌫] #{H2code.t("ui.picker_clear")}"
          "#{nav}  #{clear}  #{pick}  #{cancel}"
        else
          search = "[#{H2code.t("ui.picker_search")}]"
          "#{nav}  #{search}  #{pick}  #{cancel}"
        end
      end

      # Renders a single picker row with the pointer prefix and optional
      # fuzzy-match highlighting. `selected` swaps the base color to accent and
      # bolds the whole row; matched characters get a stronger emphasis either way.
      private def render_picker_item(text : String, positions : Array(Int32)?,
                                     max_width : Int32, selected : Bool) : String
        base = selected ? @theme.colors.accent : @theme.colors.muted
        pointer = selected ? "▶ " : "  "
        truncated = CharWidth.truncate_to_width(text, max_width, "…")

        # When there is nothing to highlight (no query, or the row was
        # truncated so positions would misalign), emit a single styled run.
        if positions.nil? || positions.empty?
          prefix = "#{ANSI.color(base, nil)}#{selected ? ANSI.bold : ""}  #{pointer}"
          return "#{prefix}#{truncated}#{ANSI.reset}"
        end

        # If truncation dropped characters the highlight indices no longer line
        # up, so fall back to a single run for that row.
        if truncated.size < text.size && !truncated.ends_with?(text[-1])
          prefix = "#{ANSI.color(base, nil)}#{selected ? ANSI.bold : ""}  #{pointer}"
          return "#{prefix}#{truncated}#{ANSI.reset}"
        end

        pos_set = Set(Int32).new(positions)
        io = IO::Memory.new
        io << "#{ANSI.color(base, nil)}  #{pointer}"
        truncated.each_char_with_index do |c, ci|
          if pos_set.includes?(ci)
            io << ANSI.bold << ANSI.color(@theme.colors.success, nil) << c << ANSI.reset
            io << ANSI.color(base, nil)
          else
            io << (selected ? ANSI.bold : "")
            io << c
          end
        end
        io << ANSI.reset
        io.to_s
      end

      private def render_select_panel(list : SelectList, cols : Int32) : Array(String)
        lines = [] of String
        lines << ""
        lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  #{list.title}#{ANSI.reset}"

        active = case list
                 when @permission_list then @permission_mode
                 when @effort_list     then @on_get_effort.try(&.call) || "off"
                 when @theme_list      then @theme.name
                 when @sudo_list       then (@bash_tool.try(&.sudo_mode) || Tools::Bash::SudoMode::Off).to_s.downcase
                 else                       ""
                 end

        start, count = list.visible_window
        if list.scrolled_up?
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↑ #{start} more#{ANSI.reset}"
        end
        count.times do |rel|
          i = start + rel
          item = CharWidth.truncate_to_width(list.items[i], cols - 4)
          marker = item == active ? " (active)" : ""
          if i == list.selected
            lines << "#{ANSI.color(@theme.colors.accent, nil)}#{ANSI.bold}  ▶ #{item}#{marker}#{ANSI.reset}"
          else
            lines << "#{ANSI.color(@theme.colors.muted, nil)}    #{item}#{marker}#{ANSI.reset}"
          end
        end
        if list.scrolled_down?
          remaining = list.items.size - (start + count)
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  ↓ #{remaining} more#{ANSI.reset}"
        end

        lines << "#{ANSI.color(@theme.colors.dim, nil)}  [↑↓] navigate  [Enter] select  [Esc] cancel#{ANSI.reset}"
        lines
      end

      private def render_approval_panel(req : ApprovalRequest, cols : Int32) : Array(String)
        lines = [] of String
        lines << ""

        if danger = req.danger
          lines << "#{ANSI.color(@theme.colors.error, nil)}#{ANSI.bold}  ! DANGER: #{danger}#{ANSI.reset}"
        end

        lines << "#{ANSI.color(@theme.colors.warning, nil)}#{ANSI.bold}  Approve #{req.tool_name}?#{ANSI.reset}"

        tool_preview(req.tool_name, req.args).each do |l|
          lines << "#{ANSI.color(@theme.colors.dim, nil)}  #{l}#{ANSI.reset}"
        end

        lines << ""
        lines << "#{ANSI.color(@theme.colors.muted, nil)}  [y] once  [s] session  [n] reject  [Esc] reject#{ANSI.reset}"
        lines
      end
    end
  end
end
