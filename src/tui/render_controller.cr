module H2code
  module TUI
    module RenderController
      def render : Nil
        @render_mutex.synchronize do
          t0 = Time.monotonic
          print build_render_output
          STDOUT.flush
          @render_ms = ((Time.monotonic - t0).total_milliseconds + 0.5).to_i64
          @render_pending = 0
        end
      end

      # Synchronous render called from the agent fiber after event processing.
      # Guarantees every state change is drawn immediately, eliminating the
      # race between events and the timer-based render loop. Serialization is
      # provided by @render_mutex inside render(): STDOUT writes can yield to
      # the scheduler (when the kernel write buffer fills), and the mutex
      # ensures a concurrent render from the main loop cannot interleave its
      # frame. Clears @dirty so the main loop's next iteration doesn't
      # re-render redundantly; leaves @last_render untouched so the 80ms
      # spinner tick keeps its own timing.
      private def render_now : Nil
        return unless @running
        return if @first_render
        render
        @dirty = @log_zone.pending?
      end

      # Build the full ANSI frame string that render() writes to the terminal.
      # Extracted so tests can assert on the raw escape sequences without
      # redirecting STDOUT.
      def build_render_output : String
        io = IO::Memory.new
        port = AnsiTerminalPort.new(io, @terminal)
        do_render(port)
        io.to_s
      end

      # Render one frame into an arbitrary `TerminalPort` (used by tests that
      # drive the real render path through `TerminalMock`). Geometry is read
      # from the port so a fixed-size mock activates the scroll/viewport logic.
      def render_to(port : TerminalPort) : Nil
        do_render(port)
      end

      # Cap how many NEW log lines are flushed in a single frame. The chunk is
      # the remaining space after the active zone so that the throttled frame
      # fits inside the viewport without scrolling.
      private def throttle_log(log_lines : Array(String), active_lines : Array(String), rows : Int32) : Array(String)
        chunk = {rows - active_lines.size, 1}.max
        reveal = @log_zone.reveal_limit(log_lines.size, chunk)
        return log_lines if reveal >= log_lines.size
        @dirty = true if @log_zone.pending?
        log_lines[0...reveal]
      end

      def render_zones(port : TerminalPort, log_lines : Array(String), active_lines : Array(String)) : Nil
        cols = port.cols
        rows = port.rows

        log_lines = throttle_log(log_lines, active_lines, rows)
        total = log_lines.size + active_lines.size

        port.begin_frame
        incremental_render(port, log_lines, active_lines, rows)
        port.end_frame

        @previous_lines = log_lines + active_lines
        @last_cols = cols
        @last_rows = rows
        @cursor_line = total
        @first_render = false
      end

      private def do_render(port : TerminalPort) : Nil
        cols = port.cols
        rows = port.rows

        log_lines, active_lines, editor_content_line = build_rendered_lines_split(cols)
        # Log lines are already truncated/reset at cache-fill time (they are
        # immutable); throttle just slices the array. Only the repainted active
        # zone needs per-frame post-processing below — this keeps the frame
        # cost O(new log lines + active zone) instead of O(total history).
        full_log_size = log_lines.size
        log_lines = throttle_log(log_lines, active_lines, rows)
        if log_lines.size < full_log_size
          editor_content_line = editor_content_line - full_log_size + log_lines.size
        end
        truncate_render_lines(active_lines, cols)
        apply_line_resets(active_lines)

        port.begin_frame
        incremental_render(port, log_lines, active_lines, rows)
        position_cursor(port, log_lines, active_lines, editor_content_line)
        port.end_frame

        @previous_lines = log_lines + active_lines
        @last_cols = cols
        @last_rows = rows
        @cursor_line = log_lines.size + active_lines.size
        @first_render = false
      end

      # Test-compatible view of a frame: returns the merged frame lines, the
      # editor content line (absolute), and the active-zone start index. Log
      # lines come pre-processed from the cache; only the active zone gets the
      # truncate + SGR reset post-processing here, matching `do_render`.
      def build_rendered_lines(cols : Int32) : {Array(String), Int32, Int32}
        log_lines, active_lines, editor_content_line = build_rendered_lines_split(cols)
        truncate_render_lines(active_lines, cols)
        apply_line_resets(active_lines)
        {log_lines + active_lines, editor_content_line, log_lines.size}
      end

      # Mark the cached log-zone lines as stale. Called whenever @messages is
      # modified (append, mutation, rebuild) or @show_welcome changes. During
      # streaming (text_delta / thinking_delta) this is NOT called, so the
      # cache stays valid and the render is O(1).
      private def invalidate_log_cache! : Nil
        @log_cache_dirty = true
      end

      # Build the frame split into the two render zones (see `docs/TUI_ZONES.md`):
      # `log_lines` (append-only history) and `active_lines` (the repainted
      # region). Returns `{log_lines, active_lines, editor_content_line}` where
      # `editor_content_line` is the absolute (log + active) index of the first
      # editor content row + 1. Log lines are returned fully post-processed
      # (truncated to `cols` + trailing SGR reset — applied once at cache-fill
      # time); active lines are raw and are post-processed by the caller.
      def build_rendered_lines_split(cols : Int32) : {Array(String), Array(String), Int32}
        log_lines = [] of String
        active_lines = [] of String

        # Full-screen modal takeovers (tasks browser, plan full-view) replace
        # the entire layout — mirrors TS container-swap mount. They occupy the
        # active zone only.
        if @tasks_browser.visible?
          @tasks_browser.rows = @terminal.rows
          active_lines.concat(@tasks_browser.render(cols))
          return {log_lines, active_lines, 0}
        end

        if @plan_review_dialog.visible? && @plan_review_dialog.viewing_full?
          @plan_review_dialog.rows = @terminal.rows
          @plan_review_dialog.terminal_width = cols
          active_lines.concat(@plan_review_dialog.render(cols))
          return {log_lines, active_lines, 0}
        end

        # ── LOG zone (cached — rebuilt only when @messages or cols change) ──
        # Finalized messages are immutable, so their rendered lines are cached.
        # During streaming the cache is not invalidated, making each frame O(1)
        # instead of O(N). Pending tool calls (no result yet) are skipped here —
        # they live in the active zone and migrate into the cache once their
        # result arrives (which sets @log_cache_dirty).
        #
        # Per-line post-processing (width truncation + SGR reset) also runs
        # HERE, at fill time — the cached lines are immutable until the next
        # invalidation and the cache is already keyed on `cols`. Re-running it
        # from the caller made every frame O(total history): render time grew
        # linearly with chat length, amplified by the CharWidth width-cache
        # thrashing past its 4096-entry cap (wholesale clear + sequential
        # access = ~0% hit rate, so every non-ASCII line re-ran the full
        # grapheme walk each frame).
        if @log_cache_dirty || cols != @log_cache_cols
          @log_lines_cache.clear
          if @show_welcome
            @log_lines_cache.concat(render_welcome_box(cols))
            if tip = @startup_tip
              # Startup tip: dark green `│` bar (no indent), gray text.
              @log_lines_cache << ""
              bar = ANSI.color(@theme.colors.secondary, nil)
              gray = ANSI.color(@theme.colors.dim, nil)
              wrap_text(tip, cols - 2).each do |line|
                @log_lines_cache << "#{bar}│#{ANSI.reset}#{gray} #{line}#{ANSI.reset}"
              end
            end
            if warning = @startup_warning_tip
              # Actionable startup warning: same tip layout, but warning
              # yellow (bar + text) so it reads as a hint that matters.
              @log_lines_cache << ""
              bar = ANSI.color(@theme.colors.warning, nil)
              wrap_text(warning, cols - 2).each do |line|
                @log_lines_cache << "#{bar}│#{ANSI.reset}#{bar} #{line}#{ANSI.reset}"
              end
            end
            @log_lines_cache << ""
          end
          @messages.each do |msg|
            next if msg.role == "tool" && msg.tool_name && msg.tool_result.nil? &&
                    msg.read_group.nil?
            @log_lines_cache.concat(render_message(msg, cols))
          end
          truncate_render_lines(@log_lines_cache, cols)
          apply_line_resets(@log_lines_cache)
          @log_cache_dirty = false
          @log_cache_cols = cols
        end
        log_lines.concat(@log_lines_cache)

        # ── ACTIVE zone (repainted every frame) ──
        unless @streaming_thinking.empty?
          active_lines.concat(render_live_thinking(cols))
        end

        unless @streaming_text.empty?
          active_lines.concat(render_streaming_text(cols))
        end

        # Pending tool calls (no result yet) live in the active zone — they
        # migrate to the log zone once their result arrives. See TUI_ZONES.md.
        @messages.each do |m|
          next unless m.role == "tool" && (name = m.tool_name) && m.tool_result.nil? &&
                      m.read_group.nil?
          if !m.swarm_members.empty?
            active_lines.concat(render_swarm_progress(m, name, cols))
          else
            active_lines.concat(render_running_tool(m, cols))
          end
        end

        # CI observer wait lines — pulsing circle (Spinner::CI_BULLET_FRAMES)
        # per watched commit, one line for each pending observer (every push
        # gets its own observer). Rendered only while @ci_active is set by
        # on_ci_update; returns empty otherwise so the active zone never
        # shows stale rows.
        if ci_lines = render_ci_wait_lines
          active_lines.concat(ci_lines)
        end

        # AgentStatus line — always present (one row), never disappears.
        active_lines << render_agent_status_line

        if req = @approval_pending
          active_lines.concat(render_approval_panel(req, cols))
        end

        if @question_dialog.visible?
          active_lines.concat(@question_dialog.render(cols))
        end

        if @plan_review_dialog.visible? && !@plan_review_dialog.viewing_full?
          @plan_review_dialog.terminal_width = cols
          active_lines.concat(@plan_review_dialog.render(cols))
        end

        if @undo_dialog.visible?
          active_lines.concat(@undo_dialog.render(cols))
        end

        if @provider_list.visible?
          active_lines.concat(render_provider_panel(cols))
        end

        if @model_list.visible?
          active_lines.concat(render_model_panel(cols))
        end

        if @session_list.visible?
          active_lines.concat(render_session_panel(cols))
        end

        if @permission_list.visible?
          active_lines.concat(render_select_panel(@permission_list, cols))
        end

        if @effort_list.visible?
          active_lines.concat(render_select_panel(@effort_list, cols))
        end

        if @theme_list.visible?
          active_lines.concat(render_select_panel(@theme_list, cols))
        end

        if @sudo_list.visible?
          active_lines.concat(render_select_panel(@sudo_list, cols))
        end

        if @cleanup_list.visible?
          active_lines.concat(render_select_panel(@cleanup_list, cols))
        end

        if @sudo_approval_list.visible?
          active_lines.concat(render_sudo_approval_panel(cols))
        end

        if todos = current_todos
          active_lines.concat(render_todo_panel(todos, cols, active: true))
        end
        unless @queue.empty?
          active_lines.concat(render_queue_pane(cols, active: true))
        end
        editor_start = active_lines.size
        if @help_panel.visible?
          # Modal `/help` replaces the editor — mirrors JS `mountEditorReplacement`.
          # Skip command hints too: the editor (and its autocomplete) is hidden.
          active_lines.concat(@help_panel.render(cols))
        elsif @usage_panel.visible?
          active_lines.concat(@usage_panel.render(cols, @provider_name, @model,
            @context_tokens, @max_context_tokens, @context_percent,
            @messages.size, @queue.size))
        else
          active_lines.concat(render_editor_box(cols))
          active_lines.concat(render_clone_dir_line(cols))

          if @show_command_hints && @command_hints.size > 0
            start, count = command_hint_window
            if start > 0
              active_lines << "#{ANSI.color(@theme.colors.dim, nil)}    ↑ #{start} more#{ANSI.reset}"
            end
            count.times do |rel|
              i = start + rel
              hint = @command_hints[i]
              usage_part = hint.usage.empty? ? "" : " #{ANSI.color(@theme.colors.dim, nil)}#{hint.usage}#{ANSI.reset}"
              if i == @command_hint_selected
                active_lines << "#{ANSI.color(@theme.colors.primary, nil)}#{ANSI.bold}  → #{hint.name.ljust(14)} #{hint.description}#{usage_part}#{ANSI.reset}"
              else
                active_lines << "#{ANSI.color(@theme.colors.dim, nil)}    #{hint.name.ljust(14)} #{hint.description}#{usage_part}#{ANSI.reset}"
              end
            end
            remaining = @command_hints.size - (start + count)
            if remaining > 0
              active_lines << "#{ANSI.color(@theme.colors.dim, nil)}    ↓ #{remaining} more#{ANSI.reset}"
            end
          end
        end

        active_lines << render_footer(cols)

        # Sync-bug detection runs unconditionally (not just under @debug_zones)
        # so the telemetry tracker can sample SyncBugsCount even when the debug
        # overlay is hidden. Detect a missing-line desync: the combined coverage
        # (LogZone flushed + pending + ActiveZone size) must never shrink — when
        # the active zone drops faster than the log grows (counting pending
        # lines not yet flushed), a line was lost.
        active_zone_size_dbg = active_lines.size + 1
        pending_dbg = log_lines.size - @log_zone.flushed
        log_zone_full = @log_zone.flushed + pending_dbg
        curr_state = {log_zone_full, active_zone_size_dbg}
        if prev = @sync_prev_states.last?
          @sync_bugs_count &+= 1 if prev[0] + prev[1] > curr_state[0] + curr_state[1]
        end
        @sync_prev_states << curr_state
        @sync_prev_states.shift if @sync_prev_states.size > 2

        if @debug_zones
          rows = @terminal.rows
          total = log_lines.size + active_zone_size_dbg

          # Render-time colour cue: >20ms yellow (warning), >50ms red (error).
          render_time_color =
            if @render_ms > 50
              @theme.colors.error
            elsif @render_ms > 20
              @theme.colors.warning
            else
              @theme.colors.dim
            end

          active_lines << String.build do |s|
            s << ANSI.color(@theme.colors.dim, nil)
            s << "Msgs: #{@messages.size}, "
            s << "LogZone: #{@log_zone.flushed}/#{log_lines.size}"
            s << (pending_dbg > 0 ? " (pending: #{pending_dbg})" : "")
            s << ", "
            s << "ActiveZone: #{active_zone_size_dbg}, "
            s << ANSI.color(render_time_color, nil)
            s << "RenderQuery: #{@render_pending} (#{@render_ms}ms)"
            s << ANSI.reset
            s << ANSI.color(@theme.colors.dim, nil)
            s << ", "
            s << "Cache: #{@log_cache_dirty ? "dirty" : "hit"}"
            s << ", "
            s << "Rows: #{rows} (total: #{total})"
            s << ", SyncBugsCount: #{@sync_bugs_count}"
            s << ANSI.reset
          end
        end

        editor_content_line = log_lines.size + editor_start + 1
        {log_lines, active_lines, editor_content_line}
      end

      # Truncate each rendered line to `cols` visible columns. Uses the ASCII
      # fast path and only falls back to the grapheme walk for non-ASCII lines,
      # matching pi-tui's per-row truncate in `doRender`.
      private def truncate_render_lines(lines : Array(String), cols : Int32) : Nil
        return if cols <= 0
        lines.map_with_index! do |line, _|
          # Expand tabs to 3 spaces (matching CharWidth.visible_width's tab=3
          # model) BEFORE measuring/clamping. Without this a raw tab reaches the
          # terminal, which expands it to the next multiple of 8 — wider than
          # the 3 columns we budgeted, pushing the right border off its row.
          line = line.gsub('\t', "   ") if line.includes?('\t')
          w = CharWidth.ascii_visible_width(line, cols) || CharWidth.visible_width(line)
          w > cols ? CharWidth.slice_by_column(line, 0, cols, strict: true) : line
        end
      end

      # Ensure each line ends with an SGR reset so color can't leak into the
      # next rendered element. Counterpart of pi-tui's `applyLineResets`.
      private def apply_line_resets(lines : Array(String)) : Nil
        reset = ANSI.reset
        lines.map_with_index! do |line, _|
          line.ends_with?(reset) ? line : line + reset
        end
      end

      # Full render is temporarily disabled: it was redrawing the entire screen
      # (including the logo) on unexpected fallback paths, so the app now relies
      # on incremental_render only. Keep the method commented out for now.
      # private def full_render(port : TerminalPort, log_lines : Array(String), active_lines : Array(String), rows : Int32) : Nil
      #   # Avoid \e[2J (full-screen erase) — it blanks the entire visible area
      #   # before any new content is written, causing a visible flicker/"clear"
      #   # even inside a synchronized update. Instead, go to the home position
      #   # and rewrite each line in place with \e[K (erase-to-end-of-line),
      #   # then wipe any leftover rows below with \e[J. This never produces a
      #   # fully blank frame.
      #   # \e[3J would clear the scrollback buffer — never use it in the main
      #   # screen buffer, it destroys the user's terminal scroll history.
      #   port.cursor_home
      #   (log_lines + active_lines).each_with_index do |line, i|
      #     port.newline if i > 0
      #     port.clear_line
      #     port.write(line)
      #   end
      #   port.clear_below
      #
      #   total = log_lines.size + active_lines.size
      #   viewport_top = {0, total - rows}.max
      #   active_visible = Math.min(active_lines.size, rows)
      #
      #   @hardware_cursor_row = {0, total - 1}.max
      #   @previous_viewport_top = viewport_top
      #   @prev_log_count = log_lines.size
      #   @prev_active_visible = active_visible
      #   # A full repaint commits every line to the terminal — realign the log
      #   # emission cursor so the next incremental frame starts from a known state.
      #   @log_zone.reset
      #   @log_zone.mark_flushed(log_lines.size)
      #   @first_render = false
      # end

      # Incremental repaint driven by the two zones. The active zone is painted
      # at the bottom of the visible area every frame; freed rows are cleared
      # with \e[J. There is no manual blank/scroll simulation.
      #
      # Cursor positioning uses absolute CUP (`cursor_to_row`) everywhere — no
      # shadow `@hardware_cursor_row` to desynchronize at the screen edge or
      # after a clamp.
      private def incremental_render(port : TerminalPort, log_lines : Array(String), active_lines : Array(String), rows : Int32) : Nil
        total = log_lines.size + active_lines.size
        viewport_top = {0, total - rows}.max
        scroll_delta = viewport_top - @previous_viewport_top

        first_frame = @first_render
        port.cursor_home if first_frame

        # ── 1. Scroll the terminal up if the viewport moved down ──
        if scroll_delta > 0
          port.cursor_to_row(rows)
          scroll_delta.times { port.newline }
        end

        # ── Full repaint when the viewport moved UP or the log shrank ──
        # The terminal cannot scroll down on its own. When viewport_top
        # decreases (or compaction cleared lines beyond the flush cursor), every
        # visible row now maps to different content, but the old pixels stay on
        # screen. Every visible line is rewritten from the top.
        #
        # Known limitation: a log line that scrolled into scrollback, was
        # rewritten here, and later scrolls off again will appear twice in
        # scrollback. This is an inherent limitation of the terminal's immutable
        # scrollback — the alternative (leaving such rows blank) is worse
        # because it creates visible gaps in the output.
        if (scroll_delta < 0 || @log_zone.shrank?(log_lines.size)) && !first_frame
          all_lines = log_lines + active_lines
          visible_count = {total - viewport_top, rows}.min

          visible_count.times do |i|
            port.cursor_to_row(i + 1)
            port.clear_line
            port.write(all_lines[viewport_top + i])
          end
          if visible_count < rows
            port.cursor_to_row(visible_count + 1) if visible_count > 0
            port.clear_below
          end

          @log_zone.mark_flushed(log_lines.size)
          @prev_active_visible = Math.min(active_lines.size, rows)
          @previous_viewport_top = viewport_top
          @prev_log_count = log_lines.size
          @first_render = false
          return
        end

        # ── 2. Write any new log lines ──
        new_log_count = log_lines.size - @log_zone.flushed
        if new_log_count > 0
          write_from = {@log_zone.flushed, viewport_top}.max
          port.cursor_to_row(write_from - viewport_top + 1)
          @log_zone.flush(port, log_lines)
        else
          @log_zone.mark_flushed(log_lines.size)
        end

        # ── 3. Render the active zone anchored at the bottom of the viewport ──
        active_visible = Math.min(active_lines.size, rows)
        active_start = total - active_visible

        port.cursor_to_row(active_start - viewport_top + 1)
        @prev_active_visible = @active_zone.render(
          port, active_lines, rows, @prev_active_visible
        )

        # Clear stale rows below the active zone when it shrank or on first
        # frame. Only do this when content doesn't fill the screen — when the
        # active zone reaches the bottom row, cursor_to_row clamps to the last
        # row and clear_below would wipe the last active line instead of
        # clearing below.
        screen_end = total - viewport_top
        if screen_end < rows
          port.cursor_to_row(total - viewport_top + 1)
          port.clear_below
        end

        @previous_viewport_top = viewport_top
        @prev_log_count = log_lines.size
      end

      private def position_cursor(
        port : TerminalPort,
        log_lines : Array(String),
        active_lines : Array(String),
        editor_content_line : Int32,
      ) : Nil
        rows = port.rows
        total = log_lines.size + active_lines.size
        viewport_top = @previous_viewport_top

        # WannaExit lock: hide the cursor and park it on the footer line (which
        # now carries the exit prompt). Without this the cursor stays visible in
        # the editor area — a leftover from the previous frame — causing visual
        # noise / flicker while the prompt is shown.
        if @exit_confirm
          port.hide_cursor
          target_row = {total - 1, 0}.max
          target_screen = {0, {target_row - viewport_top, rows - 1}.min}.max
          port.cursor_to_row(target_screen + 1)
          port.carriage_return
          return
        end

        # No editor is rendered while a full-screen takeover owns the screen
        # (tasks browser, plan-review full-plan viewer) — park the hardware
        # cursor on the last line and hide it. The next normal render restores
        # positioning. Without this the editor-positioning math below leaves the
        # cursor floating mid-row at the editor's text column.
        if (@tasks_browser.visible?) ||
           (@plan_review_dialog.visible? && @plan_review_dialog.viewing_full?)
          port.hide_cursor
          target_row = {total - 1, 0}.max
          target_screen = {0, {target_row - viewport_top, rows - 1}.min}.max
          port.cursor_to_row(target_screen + 1)
          return
        end

        # No editor is rendered while the help overlay is open — park the
        # hardware cursor on the panel's last line and leave it hidden. The
        # next non-help render restores normal positioning.
        if @help_panel.visible?
          port.hide_cursor
          target_row = {total - 1, 0}.max
          target_screen = {0, {target_row - viewport_top, rows - 1}.min}.max
          port.cursor_to_row(target_screen + 1)
          return
        end

        port.show_cursor

        return if active_lines.empty?

        # The editor lives inside the active zone. Figure out where the active
        # zone actually starts on screen, accounting for tail-clipping when the
        # zone is taller than the viewport.
        active_visible = Math.min(active_lines.size, rows)
        active_skip = active_lines.size - active_visible
        active_start = total - active_visible

        editor_start = editor_content_line - log_lines.size - 1
        # +1 because cursor_visual_row is relative to the first editor content
        # row, while editor_start points at the box top border.
        editor_row = active_start + (editor_start - active_skip) + 1 + @editor.cursor_visual_row

        # Clamp to the visible active zone so the hardware cursor never drifts
        # below the rendered block cursor.
        editor_row = {
          active_start,
          {
            editor_row,
            active_start + active_visible - 1,
          }.min,
        }.max

        target_screen = {0, {editor_row - viewport_top, rows - 1}.min}.max
        port.cursor_to_row(target_screen + 1)

        editor_text_col = 5 + @editor.cursor_visual_col
        port.cursor_to_column(editor_text_col)
      end

      # CI observer wait lines: pulsing circle (Spinner::CI_BULLET_FRAMES)
      # while a pushed commit's build is pending. One line per pending
      # observer — multiple pushes are each watched in their own row, oldest
      # commit first — each ending with a clickable `link: <url>` to the
      # commit's Actions checks page when the owner/repo pair is known.
      # Rendered only while @ci_active is set by on_ci_update;
      # returns an empty Array otherwise so the active zone never shows
      # stale rows.
      private def render_ci_wait_lines : Array(String)
        return [] of String unless @ci_active
        svc = Tools::Ci.service
        return [] of String if svc.nil? || !svc.pending?
        obs_list = svc.pending_observers
        return [] of String if obs_list.empty?
        frame = Spinner::CI_BULLET_FRAMES[(@spin_phase // 2) % Spinner::CI_BULLET_FRAMES.size]
        obs_list.map do |obs|
          String.build do |s|
            s << ANSI.color(@theme.colors.warning, nil)
            s << ' ' << frame << ' '
            s << H2code.t("ui.ci_waiting", sha: obs.short_sha, elapsed: DurationFormat.hms(obs.elapsed_s))
            unless obs.actions_url.empty?
              s << "  link: " << obs.actions_url
            end
            s << ANSI.reset
          end
        end
      end

      # Permanent one-line agent status indicator (always visible in the active
      # zone, right above the editor). Colour-coded by lifecycle phase:
      #
      #   Hello   — bar khaki (logo), text gray (dim)
      #   Busy    — blue (info), animated spinner frame, "Busy: …" prefix
      #   Waiting — yellow (warning), static bullet
      #   Done    — bar khaki (logo), text gray (dim), ✓ check mark
      #   Error   — red (error), ✗ mark
      private def render_agent_status_line : String
        bar = MessageRenderer::STREAMING_BAR
        String.build do |s|
          case @agent_status
          when .busy?
            s << ANSI.color(@theme.colors.info, nil)
            s << bar
            s << ANSI.reset
            s << ' '
            s << ANSI.color(@theme.colors.info, nil)
            s << Spinner::FRAMES[@spin_phase % Spinner::FRAMES.size]
            s << ANSI.reset
            s << ' '
            s << ANSI.color(@theme.colors.info, nil)
            s << "Busy:"
            s << ANSI.reset
            s << ' '
            s << ANSI.color(@theme.colors.muted, nil)
            s << @status
            s << ANSI.reset
          when .hello?
            s << ""
          when .done?
            s << ANSI.color(@theme.colors.dim, nil)
            s << " ✓ "
            s << @status
            s << ANSI.reset
          when .waiting?
            s << ANSI.color(@theme.colors.warning, nil)
            s << bar << " "
            s << @status
            s << ANSI.reset
          when .error?
            s << ANSI.color(@theme.colors.error, nil)
            s << bar << " ✗ "
            s << @status
            s << ANSI.reset
          end
        end
      end
    end
  end
end
