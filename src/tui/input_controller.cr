module H2code
  module TUI
    module InputController
      # Maximum number of slash-command hints rendered at once. The list scrolls
      # when there are more matches, keeping the selection always visible.
      COMMAND_HINT_MAX = 10

      # Maximum gap between two Space presses for the double-Space voice
      # trigger (mirrors common double-tap cutoffs).
      DOUBLE_SPACE_MS = 500

      # Debounce window for the session picker's async content search. This
      # only coalesces keystroke bursts — stale scans are cancelled at their
      # next line checkpoint (see `start_session_search_worker`), so the
      # window can stay small and results still land near-instantly.
      SESSION_SEARCH_DEBOUNCE_MS = 30

      private def handle_key(key : KeyEvent) : Nil
        if @exit_confirm
          case key.key
          when .ctrl_c?
            @running = false if @exit_key == "CTRL+C"
          when .ctrl_d?
            @running = false if @exit_key == "CTRL+D"
          when .escape?
            @exit_confirm = false
            @dirty = true
          else
            @exit_confirm = false
            @dirty = true
          end
          return
        end

        if @approval_pending
          handle_approval_key(key)
          return
        end

        # Setup wizard: intercept all keys while the wizard is active. The
        # provider selector handles its own input; other steps read the editor.
        if @setup_mode
          if @provider_list.visible?
            handle_setup_provider_key(key)
            return
          end
          # While the model selector is open in the Model step it owns input;
          # ESC closes the selector first, a second ESC steps back.
          if @model_list.visible?
            handle_setup_model_key(key)
            return
          end
          case key.key
          when .enter?
            wizard = @wizard
            step = wizard.try(&.step)
            # On endpoint/model an empty Enter keeps the default. Credentials
            # requires a non-empty key, so the submit gate stays there. Yolo
            # counts an empty Enter as "yes" (trust by default).
            if step == Setup::Wizard::Step::Endpoint || step == Setup::Wizard::Step::Model ||
               step == Setup::Wizard::Step::Yolo
              text = @editor.empty? ? "" : @editor.submit!
              submit_setup_text(text)
            elsif !@editor.empty?
              text = @editor.submit!
              submit_setup_text(text)
            end
          when .escape?, .ctrl_d?
            back_setup_step
          when .paste?
            # Bracketed paste: insert the text into the editor, same logic as
            # the normal input handler. Without this, pasting an API key into
            # the setup wizard silently does nothing.
            if text = key.text
              paste_lines = text.count('\n') + 1
              if paste_lines > 10 || text.size > 1000
                @editor.insert_paste_marker(text, paste_lines)
              else
                @editor.insert_text(text)
              end
            end
          else
            @editor.handle_input(key)
          end
          @dirty = true
          return
        end

        # GitHub token wizard (/github token): the editor collects the token.
        # Enter saves it (non-empty input only), Esc cancels. Paste goes
        # through the same marker path as the setup wizard so a long pasted
        # token never floods the input box.
        if @github_token_mode
          case key.key
          when .enter?
            unless @editor.empty?
              text = @editor.submit!
              submit_github_token(text)
            end
          when .escape?, .ctrl_d?
            cancel_github_token_wizard
          when .paste?
            if text = key.text
              paste_lines = text.count('\n') + 1
              if paste_lines > 10 || text.size > 1000
                @editor.insert_paste_marker(text, paste_lines)
              else
                @editor.insert_text(text)
              end
            end
          else
            @editor.handle_input(key)
          end
          @dirty = true
          return
        end

        # GitLab token wizard (/gitlab token): same input flow as /github.
        if @gitlab_token_mode
          case key.key
          when .enter?
            unless @editor.empty?
              text = @editor.submit!
              submit_gitlab_token(text)
            end
          when .escape?, .ctrl_d?
            cancel_gitlab_token_wizard
          when .paste?
            if text = key.text
              paste_lines = text.count('\n') + 1
              if paste_lines > 10 || text.size > 1000
                @editor.insert_paste_marker(text, paste_lines)
              else
                @editor.insert_text(text)
              end
            end
          else
            @editor.handle_input(key)
          end
          @dirty = true
          return
        end

        if @tasks_browser.visible?
          @tasks_browser.rows = @terminal.rows
          @tasks_browser.handle_input(key)
          @dirty = true
          return
        end

        if @undo_dialog.visible?
          @undo_dialog.handle_input(key)
          @dirty = true
          return
        end

        if @question_dialog.visible?
          @question_dialog.handle_input(key)
          @dirty = true
          return
        end

        if @plan_review_dialog.visible?
          @plan_review_dialog.rows = @terminal.rows
          @plan_review_dialog.terminal_width = @terminal.cols
          @plan_review_dialog.handle_input(key)
          @dirty = true
          return
        end

        if @help_panel.visible?
          handle_help_key(key)
          return
        end

        if @usage_panel.visible?
          if @usage_panel.handle_input(key)
            @dirty = true
          end
          return
        end

        if @provider_list.visible?
          handle_provider_key(key)
          return
        end

        if @model_list.visible?
          handle_model_key(key)
          return
        end

        if @session_list.visible?
          handle_session_key(key)
          return
        end

        if @permission_list.visible?
          handle_permission_list_key(key)
          return
        end

        if @effort_list.visible?
          handle_effort_list_key(key)
          return
        end

        if @theme_list.visible?
          handle_theme_list_key(key)
          return
        end

        if @sudo_list.visible?
          handle_sudo_list_key(key)
          return
        end

        if @cleanup_list.visible?
          handle_cleanup_list_key(key)
          return
        end

        if @sudo_approval_list.visible?
          handle_sudo_approval_key(key)
          return
        end

        # While a voice recording is in flight, Escape cancels it (audio
        # discarded, no transcription) while Space stops it with
        # transcription (same as Ctrl+R) — both instead of their normal
        # editing behavior. Space stops the recording only when the editor
        # is empty: mid-typing it must insert a space, otherwise input like
        # "/tips off" loses the space and becomes an unknown command.
        if voice_recording? && key.key.escape?
          cancel_voice_recording
          @dirty = true
          return
        end

        if voice_recording? && @editor.empty? && key.key.char? && key.char == ' '
          toggle_voice_recording
          @dirty = true
          return
        end

        # Double-Space voice trigger (see handle_space_tap): the first tap
        # falls through to normal editing, the second toggles recording. Any
        # other key resets the sequence; handle_space_tap additionally checks
        # the editor content, so text that snuck in between the presses
        # without a key event still disqualifies the trigger.
        if key.key.char? && key.char == ' ' && !key.ctrl? && !key.alt?
          return if handle_space_tap(key)
        else
          @last_space_at = nil
        end

        case key.key
        when .ctrl_c?
          if @agent_busy
            @status = "Cancelling..."
            @dirty = true
            @on_cancel.try(&.call)
          else
            @exit_confirm = true
            @exit_key = "CTRL+C"
            @dirty = true
          end
        when .ctrl_d?
          @exit_confirm = true
          @exit_key = "CTRL+D"
          @dirty = true
        when .enter?
          if !@editor.empty?
            text = @editor.submit!

            if text.starts_with?('/')
              handle_slash_command(text)
            else
              submit_message(text)
            end
          end
        when .ctrl_s?
          if !@editor.empty?
            text = @editor.submit!
            steer_or_queue(text)
          elsif !@queue.empty?
            steer_queued
          end
        when .ctrl_r?
          toggle_voice_recording
        when .ctrl_g?
          handle_external_editor
        when .up?
          if @show_command_hints && @command_hints.size > 0
            @command_hint_selected = (@command_hint_selected - 1 + @command_hints.size) % @command_hints.size
            @dirty = true
          else
            @editor.handle_input(key)
          end
        when .down?
          if @show_command_hints && @command_hints.size > 0
            @command_hint_selected = (@command_hint_selected + 1) % @command_hints.size
            @dirty = true
          else
            @editor.handle_input(key)
          end
        when .tab?
          if @show_command_hints && @command_hints.size > 0
            selected = @command_hints[@command_hint_selected]
            @editor.set("#{selected.name} ")
            @show_command_hints = false
            @dirty = true
          else
            toggle_plan_mode
          end
        when .escape?
          if @agent_busy
            @status = "Cancelling..."
            @dirty = true
            @on_cancel.try(&.call)
          elsif !@editor.empty?
            @editor.clear
            update_command_hints
          end
        when .paste?
          if text = key.text
            paste_lines = text.count('\n') + 1
            if paste_lines > 10 || text.size > 1000
              @editor.insert_paste_marker(text, paste_lines)
            else
              @editor.insert_text(text)
            end
            update_command_hints
          end
        when .ctrl_e?
          @editor.expand_markers
        when .backspace?
          @editor.handle_input(key)
          update_command_hints
        when .delete?
          @editor.handle_input(key)
        else
          @editor.handle_input(key)
          update_command_hints
        end

        @dirty = true
      end

      # Double-Space voice trigger: two plain Space presses within
      # DOUBLE_SPACE_MS toggle voice recording (same as Ctrl+R), with nothing
      # typed between them — the editor character right before the cursor must
      # be the first press's space. The first press was already inserted into
      # the editor by normal editing, so it is removed when the second one
      # fires. Returns true when the key was consumed; returns false when this
      # press is not the second of a pair (it is then typed normally). The
      # config is deliberately not checked here: start_voice_recording emits
      # the disabled/missing-[transcription] error, so the double tap surfaces
      # it instead of silently doing nothing. Public so specs can drive the
      # same path as handle_key.
      def handle_space_tap(key : KeyEvent) : Bool
        return false if !key.key.char? || key.char != ' ' || key.ctrl? || key.alt?
        now = Time.monotonic
        last = @last_space_at
        if last && (now - last).total_milliseconds <= DOUBLE_SPACE_MS &&
           @editor.char_before_cursor == ' '
          @last_space_at = nil
          @editor.handle_input(KeyEvent.new(Key::Backspace))
          toggle_voice_recording
          @dirty = true
          true
        else
          # Not a trigger: either the window expired or something was typed
          # between the presses. This press may still arm the next pair.
          @last_space_at = now
          false
        end
      end

      private def handle_approval_key(key : KeyEvent) : Nil
        case key.key
        when .char?
          case key.char
          when 'y', 'Y'
            @approval_channel.send(Permission::ApprovalChoice::ApproveOnce)
          when 's', 'S'
            @approval_channel.send(Permission::ApprovalChoice::ApproveSession)
          when 'n', 'N'
            @approval_channel.send(Permission::ApprovalChoice::Deny)
          end
        when .escape?
          @approval_channel.send(Permission::ApprovalChoice::Deny)
        end
      end

      private def update_command_hints : Nil
        text = @editor.text
        if text.starts_with?('/') && !text.includes?(' ')
          matches = CommandRegistry.match(text)
          if matches.size > 0
            @show_command_hints = true
            @command_hints = matches
            @command_hint_selected = {@command_hint_selected, matches.size - 1}.min
            @command_hint_scroll = 0
          else
            @show_command_hints = false
          end
        else
          @show_command_hints = false
        end
      end

      # Compute the visible window [start, count) for command hints, mirroring
      # `SelectList#visible_window`: adjust `@command_hint_scroll` so the
      # selected row is always on screen.
      private def command_hint_window : {Int32, Int32}
        size = @command_hints.size
        return {0, 0} if size == 0
        mv = {COMMAND_HINT_MAX, size}.min
        if @command_hint_selected < @command_hint_scroll
          @command_hint_scroll = @command_hint_selected
        elsif @command_hint_selected >= @command_hint_scroll + mv
          @command_hint_scroll = {@command_hint_selected - mv + 1, 0}.max
        end
        max_offset = {size - mv, 0}.max
        @command_hint_scroll = {@command_hint_scroll, max_offset}.min
        {@command_hint_scroll, mv}
      end

      private def handle_external_editor : Nil
        cfg = @app_config
        editor_cmd = cfg.try(&.editor) || "vim"
        tmp_dir = cfg.try(&.tmp_dir) || Dir.tempdir
        tmp_file = File.join(tmp_dir, "h2code-edit-#{Random::Secure.hex(4)}.md")
        File.write(tmp_file, @editor.expanded_text)

        @terminal.restore!

        Process.run("#{editor_cmd} #{tmp_file}", shell: true)

        content = File.exists?(tmp_file) ? File.read(tmp_file) : ""
        File.delete(tmp_file) rescue nil

        @terminal.raw!
        @editor.set(content.strip)
        @dirty = true
      end

      # Copy `text` to the system clipboard using whichever native helper is
      # available on this OS. Falls back silently — a missing helper should
      # never break the session. Mirrors TS `utils/clipboard.ts`.
      private def copy_to_clipboard(text : String) : Nil
        cmd = clipboard_command
        return unless cmd
        begin
          io = IO::Memory.new(text)
          Process.run(cmd[0], cmd[1], input: io, output: Process::Redirect::Close, error: Process::Redirect::Close)
        rescue
        end
      end

      # Resolve the first available clipboard helper as `{program, [args]}`.
      # Order mirrors the TS version (pbcopy → wl-copy → xclip → xsel).
      private def clipboard_command : Tuple(String, Array(String))?
        candidates = [
          {"pbcopy", [] of String},
          {"wl-copy", [] of String},
          {"xclip", ["-selection", "clipboard"]},
          {"xsel", ["--clipboard", "--input"]},
        ]
        candidates.each do |c|
          if Process.find_executable(c[0])
            return c
          end
        end
        nil
      end

      # Bundle the current session (wire.jsonl, state.json) plus a manifest
      # (h2code version, provider, model, session id) into a tar.gz the user
      # can share for debugging. Output goes to the OS temp dir. Returns nil
      # when `tar` is unavailable or the session dir is unknown. Mirrors TS
      # `handleExportDebugZipCommand` (which additionally includes the global
      # log — we add the ~/.h2code log file too when it exists).
      private def export_debug_bundle : String?
        return nil if @session_id.empty?
        return nil unless session_dir = @on_session_dir.try(&.call)
        return nil unless Process.find_executable("tar")

        tmp_dir = @app_config.try(&.tmp_dir) || Dir.tempdir
        bundle_dir = File.join(tmp_dir, "h2code-debug-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(bundle_dir)

        # Manifest with version / provider / model / timestamps.
        manifest_path = File.join(bundle_dir, "manifest.txt")
        manifest = String.build do |s|
          s << "h2code_version=#{H2code::VERSION}\n"
          s << "build=#{H2code.build_date || "dev"}\n"
          s << "crystal=#{Crystal::VERSION}\n"
          s << "session_id=#{@session_id}\n"
          s << "provider=#{@provider_name}\n"
          s << "model=#{@model}\n"
          s << "permission=#{@permission_mode}\n"
          s << "exported_at=#{Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")}\n"
        end
        File.write(manifest_path, manifest)

        # Copy session records if present.
        wire_src = File.join(session_dir, "wire.jsonl")
        File.copy(wire_src, File.join(bundle_dir, "wire.jsonl")) if File.exists?(wire_src)
        state_src = File.join(session_dir, "state.json")
        File.copy(state_src, File.join(bundle_dir, "state.json")) if File.exists?(state_src)

        # Copy the global log when present.
        global_log = File.join(@home, ".h2code", "h2code.log")
        if File.exists?(global_log)
          File.copy(global_log, File.join(bundle_dir, "h2code.log"))
        end

        out_path = File.join(tmp_dir, "h2code-debug-#{Time.utc.to_unix}.tar.gz")
        begin
          Process.run("tar", ["-czf", out_path, "-C", File.dirname(bundle_dir), File.basename(bundle_dir)],
            output: Process::Redirect::Close, error: Process::Redirect::Close)
          out_path if File.exists?(out_path)
        rescue
          nil
        ensure
          FileUtils.rm_r(bundle_dir) rescue nil
        end
      end

      # Toggle Plan mode on/off (wired to both `/plan` and the Tab shortcut).
      # Mirrors the TS rule: tools that mutate state are blocked while on, so
      # the agent only researches. Returns to normal mode on the next toggle.
      # The active state is signalled visually by the input frame colour and
      # the placeholder text, not by a transcript system message.
      private def toggle_plan_mode : Nil
        cb = @on_plan_mode
        if cb.nil?
          emit_to_log(Message.new("error", H2code.t("ui.plan_not_wired")))
          return
        end
        desired = !@plan_mode
        if cb.call(desired)
          @plan_mode = desired
        else
          # Callback exists but failed (e.g. service raised). Sync from the
          # service when possible so the flag tracks reality instead of
          # flipping blindly, and surface a distinct error.
          emit_to_log(Message.new("error", H2code.t("ui.plan_toggle_failed")))
        end
      end

      # `/debugzones`: toggle an overlay showing the current log-zone and
      # active-zone line counts on the last rendered row, so zone-size
      # regressions (overflow, wrong split) are visible at a glance.
      private def toggle_debug_zones : Nil
        @debug_zones = !@debug_zones
        @on_debug_zones_change.try(&.call(@debug_zones))
        state = @debug_zones ? H2code.t("ui.debugzones_on") : H2code.t("ui.debugzones_off")
        emit_to_log(Message.new("system", "#{H2code.t("commands.debugzones")}: #{state}"))
      end

      private def handle_slash_command(input : String) : Nil
        parsed = CommandRegistry.parse(input)
        unless parsed
          submit_message(input)
          return
        end

        parsed = parsed || raise "parsed should not be nil"
        cmd = parsed.command
        args = parsed.args

        # Plugin slash commands: `/<plugin_id>:<command> [args]`
        if cmd.includes?(':')
          if handle_plugin_command(cmd, args)
            return
          end
        end

        case cmd
        when "/help"
          open_help_panel
        when "/exit", "/quit"
          cmd_exit
          return
        when "/new"
          cmd_new
        when "/sessions", "/resume"
          cmd_sessions
        when "/restore"
          cmd_restore
        when "/search"
          cmd_search
        when "/fork"
          cmd_fork
        when "/archive"
          cmd_archive
        when "/rename", "/title"
          cmd_rename(args)
        when "/clear"
          cmd_clear
        when "/compact"
          cmd_compact
        when "/status"
          cmd_status
        when "/undo"
          cmd_undo(args)
        when "/queue"
          cmd_queue(args)
        when "/yolo"
          cmd_yolo(args)
        when "/auto"
          cmd_auto
        when "/manual"
          cmd_manual
        when "/model"
          open_model_selector
        when "/provider"
          open_provider_selector
        when "/export-md"
          cmd_export_md(args)
        when "/add-dir"
          cmd_add_dir(args)
        when "/theme"
          cmd_theme(args)
        when "/version"
          cmd_version
        when "/upgrade"
          cmd_upgrade
        when "/usage"
          cmd_usage
        when "/editor"
          handle_external_editor
        when "/copy"
          cmd_copy
        when "/permission"
          cmd_permission(args)
        when "/voicelang"
          cmd_voicelang(args)
        when "/sudo"
          cmd_sudo(args)
        when "/sounds"
          cmd_sounds(args)
        when "/tips"
          cmd_tips(args)
        when "/volume"
          cmd_volume(args)
        when "/effort"
          cmd_effort(args)
        when "/plan"
          toggle_plan_mode
        when "/swarm"
          handle_swarm_command(args)
        when "/todos"
          cmd_todos(args)
        when "/debug"
          cmd_debug
        when "/debugzones"
          toggle_debug_zones
        when "/feedback"
          cmd_feedback(args)
        when "/reload"
          cmd_reload
        when "/web"
          cmd_web
        when "/sync"
          cmd_sync(args)
        when "/settings"
          cmd_settings
        when "/init"
          cmd_init
        when "/export-debug-zip"
          cmd_export_debug_zip
        when "/experiments"
          cmd_experiments
        when "/mcp"
          cmd_mcp(args)
        when "/plugins"
          handle_plugins_command(args)
        when "/login"
          cmd_login
        when "/logout"
          cmd_logout
        when "/tasks", "/task"
          open_tasks_browser
        when "/memory"
          cmd_memory
        when "/telemetry"
          cmd_telemetry(args)
        when "/goal"
          handle_goal_command(args)
        when "/language"
          handle_language_command(args)
        when "/cleanup"
          cmd_cleanup(args)
        when "/github"
          cmd_github(args)
        when "/gitlab"
          cmd_gitlab(args)
        else
          emit_to_log(Message.new("error", H2code.t("ui.unknown_command", cmd: cmd)))
        end

        @show_command_hints = false
        invalidate_log_cache!
        @dirty = true
      end

      private def handle_swarm_command(args : String) : Nil
        service = H2code::Tools::SwarmMode.service
        unless service
          emit_to_log(Message.new("error", H2code.t("ui.swarm_not_wired")))
          return
        end

        sub = args.strip.downcase
        case sub
        when "on"
          enable_swarm_mode(service, H2code::Tools::SwarmTrigger::Manual)
        when "off"
          disable_swarm_mode(service)
        when ""
          service.active? ? disable_swarm_mode(service) : enable_swarm_mode(service, H2code::Tools::SwarmTrigger::Manual)
        else
          # `/swarm <prompt>`: a one-shot swarm task. Enters with the `task`
          # trigger so `Loop::Agent` auto-exits (and leaves an exit-reminder)
          # at the end of this turn.
          if @agent_busy
            emit_to_log(Message.new("error", H2code.t("ui.swarm_busy")))
            return
          end
          service.enter(H2code::Tools::SwarmTrigger::Task)
          emit_to_log(Message.new("system", H2code.t("ui.swarm_task_started")))
          start_turn(args.strip)
        end
      end

      private def enable_swarm_mode(service : H2code::Tools::SwarmModeService,
                                    trigger : H2code::Tools::SwarmTrigger) : Nil
        if service.active?
          emit_to_log(Message.new("system", H2code.t("ui.swarm_already_on")))
          return
        end
        service.enter(trigger)
        emit_to_log(Message.new("system", H2code.t("ui.swarm_mode_state",
          state: H2code.t("ui.swarm_mode_on"))))
      end

      private def disable_swarm_mode(service : H2code::Tools::SwarmModeService) : Nil
        unless service.active?
          emit_to_log(Message.new("system", H2code.t("ui.swarm_already_off")))
          return
        end
        service.exit
        emit_to_log(Message.new("system", H2code.t("ui.swarm_mode_state",
          state: H2code.t("ui.swarm_mode_off"))))
      end

      private def handle_plugins_command(args : String) : Nil
        if cb = @on_plugins_command
          result = cb.call(args)
          emit_to_log(Message.new("system", result))
        else
          emit_to_log(Message.new("system", "Plugin management is not available."))
        end
      end

      private def handle_plugin_command(cmd : String, args : String) : Bool
        # cmd is like "/<plugin_id>:<command>"
        full = cmd.lchop('/')
        plugin_id = full.split(':', 2)[0]?
        command_name = full.split(':', 2)[1]?

        return false unless plugin_id && command_name

        match = @plugin_commands.find do |c|
          c.plugin_id == plugin_id && c.name == command_name
        end
        return false unless match

        expanded = H2code::Plugin::CommandLoader.expand_arguments(match.body, args)
        submit_message(expanded)
        true
      end

      private def handle_goal_command(args : String) : Nil
        service = H2code::Tools::Goal.service
        unless service
          emit_to_log(Message.new("error", "Goal service is not wired up."))
          return
        end

        sub = args.strip.downcase
        case sub
        when "", "status"
          snapshot = service.get_goal
          if snapshot
            emit_to_log(Message.new("system", format_goal_snapshot(snapshot)))
          else
            emit_to_log(Message.new("system", H2code.t("ui.no_active_goal")))
          end
        when "pause"
          begin
            snapshot = service.pause_goal
            emit_to_log(Message.new("system", "#{H2code.t("ui.goal_paused")}\n#{format_goal_snapshot(snapshot)}"))
          rescue ex
            emit_to_log(Message.new("error", H2code.t("ui.cannot_pause", message: ex.message.to_s)))
          end
        when "resume"
          begin
            snapshot = service.resume_goal
            emit_to_log(Message.new("system", "#{H2code.t("ui.goal_resumed")}\n#{format_goal_snapshot(snapshot)}"))
          rescue ex
            emit_to_log(Message.new("error", H2code.t("ui.cannot_resume", message: ex.message.to_s)))
          end
        when "cancel"
          begin
            snapshot = service.cancel_goal
            emit_to_log(Message.new("system", "#{H2code.t("ui.goal_cancelled")}\n#{format_goal_snapshot(snapshot)}"))
          rescue ex
            emit_to_log(Message.new("error", H2code.t("ui.cannot_cancel", message: ex.message.to_s)))
          end
        else
          emit_to_log(Message.new("error", H2code.t("ui.usage_goal")))
        end
      end

      private def format_goal_snapshot(s : H2code::Tools::GoalSnapshot) : String
        String.build do |str|
          str << "#{H2code.t("ui.goal_label")}: #{s.objective}\n"
          str << "#{H2code.t("ui.goal_status")}: #{s.status}\n"
          str << "#{H2code.t("ui.goal_id")}: #{s.goal_id}\n"
          if c = s.completion_criterion
            str << "#{H2code.t("ui.goal_completion")}: #{c}\n"
          end
          if r = s.terminal_reason
            str << "#{H2code.t("ui.goal_reason")}: #{r}\n"
          end
        end.strip
      end

      private def handle_language_command(args : String) : Nil
        supported = H2code::I18n.available_locales
        lang = args.strip.downcase
        if lang.empty?
          current = @on_get_language.try(&.call) || H2code::I18n.resolve_locale
          emit_to_log(Message.new("system",
            "#{H2code.t("ui.current_language", name: current)}\n" \
            "#{H2code.t("ui.available_languages", list: supported.join(", "))}\n" \
            "#{H2code.t("ui.usage_language", list: supported.join("|"))}"))
          return
        end
        unless supported.includes?(lang)
          emit_to_log(Message.new("error",
            H2code.t("language.unknown", name: lang) + "\n" +
            H2code.t("language.available", list: supported.join(", "))))
          return
        end
        @on_language_change.try(&.call(lang))
        H2code::I18n.activate(lang)
        emit_to_log(Message.new("system", H2code.t("language.changed", name: lang)))
      end

      private def open_tasks_browser : Nil
        unless cb = @on_fetch_tasks
          emit_to_log(Message.new("error", "Tasks browser is not wired up (no task service)."))
          return
        end

        on_select = ->(_task_id : String) { nil }
        on_toggle = -> : Nil do
          @tasks_browser.filter = @tasks_browser.filter == TasksBrowser::Filter::Active ? TasksBrowser::Filter::All : TasksBrowser::Filter::Active
          @tasks_browser.refresh_tasks
          nil
        end
        on_refresh = -> : Nil do
          @tasks_browser.refresh_tasks
          @tasks_browser.flash_message = "Refreshed."
          nil
        end
        on_stop_confirmed = ->(task_id : String) do
          @on_stop_task.try(&.call(task_id))
          @tasks_browser.flash_message = "Stopping #{task_id}..."
          @tasks_browser.refresh_tasks
          nil
        end
        on_stop_ignored = ->(task_id : String) do
          @tasks_browser.flash_message = "#{task_id} is already finished."
          nil
        end
        on_open_output = ->(task_id : String) do
          @on_open_task_output.try(&.call(task_id))
          @tasks_browser.flash_message = "Opening output for #{task_id}..."
          nil
        end
        on_cancel = -> : Nil do
          @tasks_browser.hide
          @dirty = true
          nil
        end

        @tasks_browser.show(
          cb,
          on_select: on_select,
          on_toggle_filter: on_toggle,
          on_refresh: on_refresh,
          on_stop_confirmed: on_stop_confirmed,
          on_stop_ignored: on_stop_ignored,
          on_open_output: on_open_output,
          on_cancel: on_cancel,
          initial_filter: TasksBrowser::Filter::Active,
        )
        @input.drain_pending_enters
        @dirty = true
      end

      private def open_undo_selector : Nil
        unless cb = @on_fetch_undo_choices
          @on_undo.try(&.call)
          emit_to_log(Message.new("system", "Undid last turn."))
          return
        end

        raw = cb.call
        if raw.nil? || raw.empty?
          emit_to_log(Message.new("system", "No turns to undo."))
          return
        end

        choices = raw.map_with_index do |(count, input, label), i|
          UndoDialog::Choice.new("undo-#{i}", count, input, label)
        end

        on_select = ->(c : UndoDialog::Choice) do
          if cb2 = @on_undo_count
            cb2.call(c.count)
          else
            @on_undo.try(&.call)
          end
          emit_to_log(Message.new("system", "Undid #{c.count} turn(s)."))
          nil
        end

        @undo_dialog.show(choices, on_select)
        @input.drain_pending_enters
        @dirty = true
      end

      private def open_help_panel : Nil
        @help_panel.show
        # Discard a queued Enter that was batched with the /help submit,
        # otherwise it would immediately dismiss the panel on the next read_key.
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_help_key(key : KeyEvent) : Nil
        @help_panel.handle_input(key)
        @dirty = true
      end

      private def open_provider_selector : Nil
        items = LLM::Provider.providers.map(&.name)
        @provider_list.show(H2code.t("ui.select_provider"), items)
        @provider_list.selected = items.index(@provider_name) || 0
        # Discard a queued Enter that was batched with the /provider submit,
        # otherwise it would close the selector on the very next read_key.
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_provider_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @provider_list.handle_input(key)
          @dirty = true
        when .enter?
          name = @provider_list.current || @provider_name
          @provider_list.hide
          @dirty = true
          if name == @provider_name
            emit_to_log(Message.new("system", "Provider already set to #{name}."))
          elsif needs_setup?(name)
            # Credentials missing for the selected provider: launch the setup
            # wizard for it instead of failing the switch.
            start_setup_for_provider(name)
          elsif cb = @on_provider_change
            if cb.call(name)
              @provider_name = name
              emit_to_log(Message.new("system", "Switched provider to #{name}."))
            end
          else
            emit_to_log(Message.new("error", "Provider switching is not wired up."))
          end
        when .escape?
          @provider_list.hide
          @dirty = true
        end
      end

      # Does the named provider need the setup wizard? True when a configured
      # check is wired up and it reports the provider as not yet configured.
      private def needs_setup?(name : String) : Bool
        if cb = @on_provider_configured
          !cb.call(name)
        else
          false
        end
      end

      # Launch the setup wizard at runtime for an already-chosen provider. The
      # welcome message and provider selector are skipped: we already know the
      # provider, so the wizard drops straight into the Credentials step.
      private def start_setup_for_provider(name : String) : Nil
        wizard = Setup::Wizard.new
        wizard.select_provider(name)
        @wizard = wizard
        @setup_mode = true
        @provider_name = name
        @status = "Setup: #{wizard.step.to_s.downcase}"
        @editor.clear
        emit_to_log(Message.new("user", provider_label(name)))
        if wizard.step == Setup::Wizard::Step::Endpoint
          # Keyless provider: jump straight to endpoint, but still show a
          # transcript entry so the user knows why no key was asked.
          emit_to_log(Message.new("system", "No API key needed for #{name}."))
        end
        advance_setup_step
      end

      private def provider_label(name : String) : String
        if choice = Setup::Wizard.choices.find { |c| c.name == name }
          choice.label
        else
          name
        end
      end

      PERMISSION_MODES = ["manual", "auto", "yolo"]
      EFFORT_LEVELS    = ["off", "low", "medium", "high"]
      THEMES           = ["dark", "light"]
      SUDO_MODES       = ["request", "always", "off"]
      # Minimum-age options for /cleanup, aligned with Session::Cleanup::PERIODS.
      CLEANUP_PERIODS = ["week", "month", "6months", "year"]

      private def open_permission_selector : Nil
        @permission_list.show(H2code.t("ui.select_permission"), PERMISSION_MODES)
        @permission_list.selected = PERMISSION_MODES.index(@permission_mode) || 0
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_permission_list_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @permission_list.handle_input(key)
          @dirty = true
        when .enter?
          mode = @permission_list.current || @permission_mode
          @permission_list.hide
          @dirty = true
          apply_permission_mode(mode)
        when .escape?
          @permission_list.hide
          @dirty = true
        end
      end

      private def apply_permission_mode(mode : String) : Nil
        @permission_mode = mode
        emit_to_log(Message.new("system", "Permission mode: #{mode}"))
        # Propagate to the live Permission::Manager + plan-mode reference and
        # persist the default to config.json (wired in run_interactive).
        @on_permission_mode_change.try(&.call(mode))
        @dirty = true
      end

      private def open_effort_selector : Nil
        current = @on_get_effort.try(&.call) || "off"
        @effort_list.show(H2code.t("ui.select_effort"), EFFORT_LEVELS)
        @effort_list.selected = EFFORT_LEVELS.index(current) || 0
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_effort_list_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @effort_list.handle_input(key)
          @dirty = true
        when .enter?
          effort = @effort_list.current || "off"
          @effort_list.hide
          @dirty = true
          if cb = @on_set_effort
            cb.call(effort)
            emit_to_log(Message.new("system", H2code.t("ui.effort_set", name: effort)))
          else
            emit_to_log(Message.new("system", H2code.t("ui.effort_not_wired")))
          end
        when .escape?
          @effort_list.hide
          @dirty = true
        end
      end

      private def open_theme_selector : Nil
        @theme_list.show(H2code.t("ui.select_theme"), THEMES)
        @theme_list.selected = THEMES.index(@theme.name) || 0
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_theme_list_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @theme_list.handle_input(key)
          @dirty = true
        when .enter?
          name = @theme_list.current || "dark"
          @theme_list.hide
          @dirty = true
          @theme = name == "light" ? Theme.light : Theme.dark
          emit_to_log(Message.new("system", H2code.t("ui.theme_set", name: name)))
          invalidate_log_cache!
        when .escape?
          @theme_list.hide
          @dirty = true
        end
      end

      private def open_cleanup_selector : Nil
        # Show what each option would delete so the choice is informed.
        counts = H2code::Session::Cleanup.new(@home).counts([@session_id])
        labels = CLEANUP_PERIODS.map do |p|
          pc = counts[p]? || H2code::Session::Cleanup::PeriodCounts.new
          "#{H2code.t("ui.cleanup_period_#{p}")} — #{pc.sessions} #{H2code.t("ui.cleanup_word_sessions")}, #{pc.voice_files} #{H2code.t("ui.cleanup_word_voice")}"
        end
        @cleanup_list.show(H2code.t("ui.select_cleanup"), labels)
        @cleanup_list.selected = 0
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_cleanup_list_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @cleanup_list.handle_input(key)
          @dirty = true
        when .enter?
          idx = @cleanup_list.selected
          period = CLEANUP_PERIODS[idx]? || CLEANUP_PERIODS[0]
          @cleanup_list.hide
          @dirty = true
          run_cleanup(period)
        when .escape?
          @cleanup_list.hide
          @dirty = true
        end
      end

      private def open_sudo_selector : Nil
        @sudo_list.show("Select sudo mode", SUDO_MODES)
        current = (@bash_tool.try(&.sudo_mode) || Tools::Bash::SudoMode::Off).to_s.downcase
        @sudo_list.selected = SUDO_MODES.index(current) || 0
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_sudo_list_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @sudo_list.handle_input(key)
          @dirty = true
        when .enter?
          mode_str = @sudo_list.current || "request"
          @sudo_list.hide
          @dirty = true
          mode = case mode_str
                 when "off"    then Tools::Bash::SudoMode::Off
                 when "always" then Tools::Bash::SudoMode::Always
                 else               Tools::Bash::SudoMode::Request
                 end
          apply_sudo_mode(mode)
          emit_to_log(Message.new("system", "Sudo mode: #{mode_str}"))
        when .escape?
          @sudo_list.hide
          @dirty = true
        end
      end

      private def handle_sudo_approval_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @sudo_approval_list.handle_input(key)
          @dirty = true
        when .enter?
          idx = @sudo_approval_list.selected
          choice = case idx
                   when 0 then Tools::Bash::SudoApprovalChoice::AllowOnce
                   when 1 then Tools::Bash::SudoApprovalChoice::AlwaysAllow
                   else        Tools::Bash::SudoApprovalChoice::Deny
                   end
          @sudo_approval_channel.send(choice)
        when .escape?
          @sudo_approval_channel.send(Tools::Bash::SudoApprovalChoice::Deny)
        end
      end

      private def open_session_selector(mode : Symbol) : Nil
        @session_picker_mode = mode
        # :restore shows archived sessions too; :search goes further — it
        # drops the workspace scoping entirely so every session on the
        # machine is findable, archived included.
        include_archived = mode != :resume
        global = mode == :search
        title = case mode
                when :restore then H2code.t("ui.restore_session")
                when :search  then H2code.t("ui.search_sessions_all")
                else               H2code.t("ui.resume_session")
                end

        # Scope to the current workspace so sessions from other folders don't
        # mix in (:search ignores the scope). Falls back to all sessions when
        # @work_dir is unset (e.g. in tests or non-standard entry points).
        index = Session::Index.new(@home)
        ws_id = (!global && !@work_dir.empty?) ? Session::Index.workspace_id(@work_dir) : nil
        entries = index.list(ws_id, include_archived: include_archived)
        if entries.empty?
          emit_to_log(Message.new("system", "No sessions found."))
          return
        end

        @session_entries = entries
        @session_search_hits.clear
        @session_search_pending = nil
        items = entries.map { |e| session_picker_label(e, show_cwd: global) }
        @session_list.show(title, items)
        @session_list.selected = 0
        @input.drain_pending_enters
        @dirty = true
      end

      private def session_picker_label(entry : Session::SessionEntry, show_cwd : Bool = false) : String
        label = sanitize_picker_text(entry.label)
        preview_raw = entry.preview
        preview = preview_raw.empty? ? "" : " — #{sanitize_picker_text(preview_raw)}"
        time = entry.updated_at.to_s("%Y-%m-%d %H:%M")
        # In global search sessions from other workspaces mix together, so
        # surface each one's directory.
        cwd = (show_cwd && !entry.cwd.empty?) ? "  #{sanitize_picker_text(entry.cwd)}" : ""
        "#{label}#{preview}  (#{time})#{cwd}"
      end

      # Strip ANSI escapes, literal caret-escaped sequences (^[[A etc.), and
      # other control characters that corrupt line-oriented TUI rendering.
      private def sanitize_picker_text(text : String) : String
        cleaned = CharWidth.strip_ansi(text)
        # Remove literal caret-escaped ANSI sequences (e.g. "^[[A" from pasted
        # terminal output) that appear as visible garbage in the selector.
        cleaned = cleaned.gsub(/\^\[\[[0-9;?]*[A-Za-z]/, "")
        cleaned = cleaned.gsub(/[\x00-\x08\x0B-\x1F\x7F]/, "")
        # Collapse whitespace runs (including embedded newlines/tabs) to spaces.
        cleaned = cleaned.gsub(/\s+/, " ").strip
        cleaned
      end

      # True when the session-picker search query occurs as a substring
      # (spaces included) in a session's wire log. Results are cached per
      # picker open with prefix pruning — see `Session::Index#substring_hits`.
      # A stale pass may raise SearchCancelled (see the worker).
      private def session_content_matches?(query : String, idx : Int32) : Bool
        needle = query.downcase
        return false if needle.empty?
        Session::Index.new(@home)
          .substring_hits(@session_entries, needle, @session_search_hits, @session_search_cancel_check)
          .includes?(idx)
      end

      # Record the latest picker query and nudge the search worker fiber.
      # This is the producer side of a latest-value mailbox: every keystroke
      # bumps the generation (invalidating in-flight scans for older
      # queries) and overwrites the pending query; the channel send never
      # blocks — a queued wakeup means the worker will run and read
      # `@session_search_pending` directly.
      private def schedule_session_search(query : String) : Nil
        @session_search_generation += 1
        @session_search_pending = query
        if ch = @session_search_wakeup
          select
          when ch.send(nil)
          else
          end
        end
      end

      # Long-lived consumer fiber applying the session picker's content
      # filter. Typing never blocks: keystrokes only publish to the mailbox,
      # and the scan itself yields cooperatively
      # (`SUBSTRING_SCAN_YIELD_BYTES`) so the input loop keeps running
      # while it works.
      #
      # A pass started for generation G cancels itself as soon as a newer
      # keystroke arrives (generation moves past G): the scan raises
      # SearchCancelled at its next line checkpoint, nothing partial is
      # cached, and the loop immediately retries with the newest query — no
      # fixed delay between passes.
      private def start_session_search_worker : Nil
        return if @session_search_wakeup
        ch = Channel(Nil).new(1)
        @session_search_wakeup = ch
        spawn do
          loop do
            ch.receive
            # Tiny coalescing window so a keystroke burst collapses into
            # one scan instead of one pass per character.
            sleep SESSION_SEARCH_DEBOUNCE_MS.milliseconds
            while @session_search_pending && @session_list.visible?
              @session_search_pending = nil
              start_gen = @session_search_generation
              @session_search_cancel_check = -> { @session_search_generation != start_gen }
              begin
                @session_list.flush_filter!
              rescue Session::SearchCancelled
                # Stale pass dropped — the newer pending query above (or the
                # one already in @session_list.query) retriggers instantly.
              ensure
                @session_search_cancel_check = nil
                @dirty = true
              end
            end
          end
        end
      end

      private def handle_session_key(key : KeyEvent) : Nil
        case key.key
        when .enter?
          # Apply the latest query synchronously before reading the
          # selection. Uncancellable by design: Enter must see the final
          # result, and this also disarms any in-flight background pass.
          @session_search_cancel_check = nil
          @session_search_pending = nil
          @session_list.flush_filter!
          # Nothing matched the filter: keep the picker open instead of
          # silently picking the top entry of the unfiltered list.
          return if @session_list.filtered_size == 0
          # Map the filtered-list cursor back to the entry array — with an
          # active search the visible order differs from `@session_entries`.
          idx = @session_list.selected_original_index
          entry = @session_entries[idx]?
          @session_list.hide
          @dirty = true
          unless entry
            emit_to_log(Message.new("error", "No session selected."))
            return
          end
          case @session_picker_mode
          when :restore
            Session::Lifecycle.new(@home).restore(entry)
            emit_to_log(Message.new("system", "Restored session: #{entry.label}"))
          else
            if cb = @on_resume_session
              emit_to_log(Message.new("system", "Resuming session: #{entry.label}"))
              begin
                cb.call(entry.path)
              rescue ex : Session::FileDeletedError
                # The session files vanished between listing and picking
                # (or while the app ran). Keep the current session intact.
                emit_to_log(Message.new("error",
                  "Session file was deleted, cannot resume: #{entry.label} (#{ex.session_dir})"))
              rescue ex : Session::SessionBusyError
                # Another live h2code process owns the session — a second
                # writer would interleave two conversations into one wire
                # log. Keep the current session intact.
                emit_to_log(Message.new("error",
                  "Session is open in another h2code process, cannot resume: #{entry.label} (#{ex.message})"))
              end
            else
              emit_to_log(Message.new("error", "Session resume is not wired up."))
            end
          end
        when .escape?
          # A single Esc clears an active search first; a second Esc closes.
          cleared = @session_list.clear_query
          @session_list.hide unless cleared
          @session_search_pending = nil
          # Invalidate any in-flight scan: its generation is now stale, so
          # it cancels at the next checkpoint.
          @session_search_generation += 1
          @dirty = true
        else
          # ↑/↓, Backspace, and typed characters drive the content filter.
          @session_list.handle_input(key)
          @dirty = true
        end
      end

      private def open_model_selector : Nil
        cb = @on_fetch_models
        if cb.nil?
          emit_to_log(Message.new("error", "Model fetching is not wired up."))
          return
        end

        @status = "Fetching models..."
        @dirty = true

        spawn do
          begin
            models = cb.call
            if models.empty?
              emit_to_log(Message.new("system", "No models available for current provider."))
            else
              @model_list.show(H2code.t("ui.select_model", name: @provider_name), models)
              @model_list.selected = models.index(@model) || 0
            end
          rescue ex
            emit_to_log(Message.new("error", "Failed to fetch models: #{ex.message}"))
          ensure
            @status = ""
            @dirty = true
          end
        end
      end

      private def handle_model_key(key : KeyEvent) : Nil
        case key.key
        when .enter?
          model = @model_list.current || @model
          @model_list.hide
          @dirty = true
          if model == @model
            emit_to_log(Message.new("system", "Model already set to #{model}."))
          elsif cb = @on_model_change
            if cb.call(model)
              @model = model
              emit_to_log(Message.new("system", "Switched model to #{model}."))
            end
          else
            emit_to_log(Message.new("error", "Model switching is not wired up."))
          end
        when .escape?
          # A single Esc clears an active search first; a second Esc closes.
          @model_list.clear_query || @model_list.hide
          @dirty = true
        else
          # ↑/↓, Backspace, and typed characters drive the fuzzy filter.
          @model_list.handle_input(key)
          @dirty = true
        end
      end
    end
  end
end
