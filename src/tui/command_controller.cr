# Slash-command handlers, mixed into `TUI::App`. Owns the per-command logic
# that was previously a single ~400-line `case` inside `handle_slash_command`.
# The dispatcher stays in `App#handle_slash_command`; each branch delegates
# here. Methods keep direct ivar access, matching `SetupController`.
module H2code
  module TUI
    module CommandController
      private def cmd_exit : Nil
        @exit_confirm = true
        @exit_key = "CTRL+D"
        @dirty = true
      end

      private def cmd_new : Nil
        if @agent_busy
          emit_to_log(Message.new("error", "Cannot start a new session while a turn is running. Wait or interrupt first."))
        else
          @on_new_session.try(&.call)
          @messages.clear
          @show_welcome = true
          emit_to_log(Message.new("system", H2code.t("ui.new_session_started")))
        end
      end

      private def cmd_sessions : Nil
        if @agent_busy
          emit_to_log(Message.new("error", "Cannot switch sessions while a turn is running."))
        else
          open_session_selector(:resume)
        end
      end

      private def cmd_restore : Nil
        if @agent_busy
          emit_to_log(Message.new("error", "Cannot restore a session while a turn is running."))
        else
          open_session_selector(:restore)
        end
      end

      # Global session search: unlike /resume (current workspace only) this
      # lists sessions from every workspace, archived included.
      private def cmd_search : Nil
        if @agent_busy
          emit_to_log(Message.new("error", "Cannot search sessions while a turn is running."))
        else
          open_session_selector(:search)
        end
      end

      private def cmd_fork : Nil
        if @agent_busy
          emit_to_log(Message.new("error", "Cannot fork while a turn is running. Wait or interrupt first."))
        elsif cb = @on_fork
          cb.call
          emit_to_log(Message.new("system", "Session forked."))
        else
          emit_to_log(Message.new("error", "Session fork is not wired up."))
        end
      end

      private def cmd_archive : Nil
        if @agent_busy
          emit_to_log(Message.new("error", "Cannot archive while a turn is running."))
        elsif cb = @on_archive
          cb.call
          emit_to_log(Message.new("system", H2code.t("ui.session_archived")))
        else
          emit_to_log(Message.new("error", "Session archive is not wired up."))
        end
      end

      private def cmd_rename(args : String) : Nil
        if args.empty?
          emit_to_log(Message.new("system", H2code.t("ui.usage_rename")))
        elsif cb = @on_rename
          cb.call(args)
          emit_to_log(Message.new("system", "Session title set to: #{args}"))
        else
          emit_to_log(Message.new("error", "Session rename is not wired up."))
        end
      end

      private def cmd_clear : Nil
        if @agent_busy
          emit_to_log(Message.new("error", "Cannot clear while a turn is running. Wait or interrupt first."))
        else
          @on_clear.try(&.call)
          @messages.clear
          @show_welcome = true
          emit_to_log(Message.new("system", H2code.t("ui.conversation_cleared")))
        end
      end

      private def cmd_compact : Nil
        if @agent_busy
          emit_to_log(Message.new("error", "Cannot compact while a turn is running. Wait or interrupt first."))
        else
          emit_to_log(Message.new("system", "Compacting context..."))
          @is_compacting = true
          @status = "Compacting..."
          start_spinner
          @dirty = true
          @on_compact.try(&.call)
        end
      end

      private def cmd_status : Nil
        stats = String.build do |s|
          s << "#{H2code.t("ui.status_model")}: #{@model}\n"
          s << "#{H2code.t("ui.permission_label")}: #{@permission_mode}\n"
          if @max_context_tokens > 0
            s << "#{H2code.t("ui.context_label")}: #{build_context_status.split(": ", 2)[1]? || ""}\n"
          else
            s << "#{H2code.t("ui.context_label")}: #{@context_percent.round(1)}%\n"
          end
          s << "#{H2code.t("ui.messages_label")}: #{@messages.size}\n"
          s << "#{H2code.t("ui.queue_label")}: #{@queue.size}\n"
        end
        emit_to_log(Message.new("system", stats.strip))
      end

      private def cmd_undo(args : String) : Nil
        if @agent_busy
          emit_to_log(Message.new("error", H2code.t("ui.cannot_undo_busy")))
        elsif args.strip.empty?
          open_undo_selector
        else
          count = args.strip.to_i? || 1
          @on_undo.try(&.call)
          emit_to_log(Message.new("system", "Undid last #{count} turn(s)."))
        end
      end

      private def cmd_queue(args : String) : Nil
        if args.strip == "clear"
          @queue.clear
          emit_to_log(Message.new("system", H2code.t("ui.queue_cleared")))
        elsif @queue.empty?
          emit_to_log(Message.new("system", H2code.t("ui.queue_empty")))
        else
          preview = @queue.map_with_index { |qm, i| "  #{i + 1}. #{truncate_preview(qm.text)}" }.join("\n")
          emit_to_log(Message.new("system", "Queue (#{@queue.size}):\n#{preview}\n— #{queue_hint}"))
        end
      end

      # /yolo on|off — toggle the persistent YOLO default. Beyond the current
      # session this flips several things at once via apply_permission_mode /
      # on_permission_mode_change: the live Permission::Manager, the plan-mode
      # permission reference, and the `permission.mode` default in config.json
      # (so h2code starts in yolo on every launch, no CLI flags needed).
      private def cmd_yolo(args : String) : Nil
        case args.strip.downcase
        when "on"
          apply_permission_mode("yolo")
          emit_to_log(Message.new("system", "YOLO default saved: tool calls are auto-approved."))
        when "off"
          apply_permission_mode("manual")
          emit_to_log(Message.new("system", "YOLO default off: permission mode reset to manual."))
        when ""
          state = @permission_mode == "yolo" ? "on" : "off"
          emit_to_log(Message.new("system", "YOLO is #{state}. Usage: /yolo on|off"))
        else
          emit_to_log(Message.new("error", "Unknown argument: #{args}. Use: /yolo on|off"))
        end
      end

      private def cmd_auto : Nil
        apply_permission_mode("auto")
      end

      private def cmd_manual : Nil
        apply_permission_mode("manual")
      end

      private def cmd_export_md(args : String) : Nil
        path = args.empty? ? "session-#{Time.utc.to_unix}.md" : args
        @on_export.try(&.call(path))
        emit_to_log(Message.new("system", H2code.t("ui.exported_to", path: path)))
      end

      private def cmd_add_dir(args : String) : Nil
        if args.empty?
          emit_to_log(Message.new("system", H2code.t("ui.usage_add_dir")))
        else
          path = File.expand_path(args.strip, @work_dir)
          if Dir.exists?(path)
            if @additional_dirs.includes?(path)
              emit_to_log(Message.new("system", "Already added: #{path}"))
            else
              @additional_dirs << path
              on_additional_dirs_change.try(&.call(@additional_dirs.dup))
              emit_to_log(Message.new("system",
                H2code.t("ui.added_directory", path: path, count: @additional_dirs.size)))
            end
          else
            emit_to_log(Message.new("error", "Directory does not exist: #{path}"))
          end
        end
      end

      private def cmd_theme(args : String) : Nil
        if args.empty?
          open_theme_selector
        elsif args == "dark"
          @theme = Theme.dark
          emit_to_log(Message.new("system", H2code.t("ui.theme_set", name: "dark")))
        elsif args == "light"
          @theme = Theme.light
          emit_to_log(Message.new("system", H2code.t("ui.theme_set", name: "light")))
        else
          emit_to_log(Message.new("error", H2code.t("ui.theme_unknown", name: args)))
        end
      end

      private def cmd_version : Nil
        version = H2code::VERSION
        build = H2code.build_date || "dev"
        emit_to_log(Message.new("system", "h2code #{version} (#{build})\nCrystal #{Crystal::VERSION}"))
      end

      private def cmd_upgrade : Nil
        emit_to_log(Message.new("system", H2code.t("ui.upgrade_checking")))
        @dirty = true
        render
        ok, msg = H2code::Upgrader.run
        H2code::Upgrader.record_check(nil)
        emit_to_log(Message.new(ok ? "system" : "error", msg))
      end

      # /cleanup — delete sessions and voice messages older than a picked
      # period. No args opens the period selector; a valid period runs
      # directly (e.g. `/cleanup month`).
      private def cmd_cleanup(args : String) : Nil
        period = args.strip.downcase
        if period.empty?
          open_cleanup_selector
        elsif H2code::Session::Cleanup.period_days(period)
          run_cleanup(period)
        else
          emit_to_log(Message.new("error", H2code.t("ui.cleanup_unknown_period", period: period)))
        end
      end

      private def run_cleanup(period : String) : Nil
        label = H2code.t("ui.cleanup_period_#{period}")
        emit_to_log(Message.new("system", H2code.t("ui.cleanup_running", period: label)))
        @dirty = true
        render
        cleanup = H2code::Session::Cleanup.new(@home)
        result = cleanup.run(period, skip_session_ids: [@session_id])
        msg = H2code.t("ui.cleanup_done",
          sessions: result.sessions_removed,
          voice: result.voice_files_removed,
          period: label)
        if result.sessions_skipped > 0
          msg += "\n#{H2code.t("ui.cleanup_skipped", count: result.sessions_skipped)}"
        end
        emit_to_log(Message.new("system", msg))
      end

      private def cmd_usage : Nil
        @usage_panel.show
        @input.drain_pending_enters
        @show_command_hints = false
        @dirty = true
      end

      private def cmd_copy : Nil
        last_assistant = @messages.reverse.find { |m| m.role == "assistant" }
        if last_assistant
          copy_to_clipboard(last_assistant.content)
          emit_to_log(Message.new("system", H2code.t("ui.copied")))
        else
          emit_to_log(Message.new("error", H2code.t("ui.no_assistant_to_copy")))
        end
      end

      private def cmd_permission(args : String) : Nil
        case args.strip.downcase
        when "manual", "auto", "yolo"
          apply_permission_mode(args.strip.downcase)
        when ""
          open_permission_selector
        else
          emit_to_log(Message.new("error", H2code.t("ui.mode_unknown", name: args)))
        end
      end

      private def cmd_sudo(args : String) : Nil
        arg = args.strip.downcase
        if arg.empty?
          open_sudo_selector
          return
        end
        case arg
        when "off"
          apply_sudo_mode(Tools::Bash::SudoMode::Off)
          emit_to_log(Message.new("system", "Sudo mode: off (sudo commands disallowed)"))
        when "request"
          apply_sudo_mode(Tools::Bash::SudoMode::Request)
          emit_to_log(Message.new("system", "Sudo mode: request (ask before each sudo command)"))
        when "always"
          apply_sudo_mode(Tools::Bash::SudoMode::Always)
          emit_to_log(Message.new("system", "Sudo mode: always (sudo commands allowed)"))
        else
          emit_to_log(Message.new("error", "Unknown sudo mode: #{args}. Use: off, request, or always."))
        end
      end

      # Applies the sudo mode to the main Bash instance and persists it
      # app-wide (config.json) so it applies to every chat, not just this one.
      private def apply_sudo_mode(mode : Tools::Bash::SudoMode) : Nil
        @bash_tool.try(&.sudo_mode=(mode))
        @on_sudo_mode_change.try(&.call(mode.to_s.downcase))
      end

      private def cmd_effort(args : String) : Nil
        if args.empty?
          open_effort_selector
        elsif cb = @on_set_effort
          normalized = args.strip.downcase
          cb.call(normalized)
          emit_to_log(Message.new("system", H2code.t("ui.effort_set", name: normalized)))
        else
          emit_to_log(Message.new("system", H2code.t("ui.effort_not_wired")))
        end
      end

      private def cmd_todos(args : String) : Nil
        todos = current_todos
        if todos.nil? || todos.empty?
          emit_to_log(Message.new("system", H2code.t("ui.no_todos")))
        elsif args.strip.downcase == "clear"
          @on_clear_todos.try(&.call)
          emit_to_log(Message.new("system", H2code.t("ui.todos_cleared")))
        else
          body = todos.map_with_index do |(title, status), i|
            marker = case status
                     when "done"        then "✓"
                     when "in_progress" then "▶"
                     else                    "○"
                     end
            "  #{i + 1}. #{marker} #{title}"
          end.join("\n")
          emit_to_log(Message.new("system", "Todos (#{todos.size}):\n#{body}"))
        end
      end

      private def cmd_debug : Nil
        if cb = @on_debug
          cb.call
        else
          emit_to_log(Message.new("error", "/debug is not wired up."))
        end
      end

      private def cmd_feedback(args : String) : Nil
        if args.strip.empty?
          emit_to_log(Message.new("system", H2code.t("ui.usage_feedback")))
        elsif cb = @on_feedback
          cb.call(args.strip)
          emit_to_log(Message.new("system", "Feedback sent. Thank you!"))
        else
          # Local fallback: stash the feedback so it can be retrieved later.
          feedback_path = File.join(@home, ".h2code", "feedback.log")
          Dir.mkdir_p(File.dirname(feedback_path)) rescue nil
          File.write(feedback_path, "[#{Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")}] #{args.strip}\n", mode: "a")
          emit_to_log(Message.new("system", "Feedback saved to #{feedback_path}."))
        end
      end

      private def cmd_reload : Nil
        if cb = @on_reload
          cb.call
          emit_to_log(Message.new("system", "Config and session state reloaded."))
        else
          emit_to_log(Message.new("error", "Reload is not wired up."))
        end
      end

      private def cmd_web : Nil
        url = "https://www.kimi.com/code?session=#{URI.encode_path(@session_id)}"
        emit_to_log(Message.new("system", "Open in Web UI: #{url}"))
      end

      # `/sync [on|off|code|status]` — cloud sync with the PWA. `on`
      # enables it in config.json, tells the running daemon to connect to
      # the relay (control socket) and prints the pairing QR; `off`
      # disables it and drops the daemon's relay connection. Bare `/sync`
      # acts as `/sync code` (current QR, no rotation). The h2code-remote
      # daemon is MANUAL-ONLY (2026-09-03): hcode never spawns or stops
      # it — the daemon is a separate service. Auth is code-only
      # (plans/QrAuth.md) — no email needed.
      private def cmd_sync(args : String) : Nil
        cfg = @app_config
        case args.strip.downcase
        when "on"
          unless cfg
            emit_to_log(Message.new("error", "Config not loaded."))
            return
          end
          cfg.sync.enabled = true
          cfg.save
          emit_to_log(Message.new("system", "Sync enabled. #{Remote::Sync.set_daemon_sync_mode("on")}"))
          emit_to_log(Message.new("system", Remote::Sync.qr_banner(Remote::Sync.read_or_create_code, cfg.sync.relay_url)))
        when "off"
          cfg.try { |c| c.sync.enabled = false; c.save }
          emit_to_log(Message.new("system", "Sync disabled. #{Remote::Sync.set_daemon_sync_mode("off")}"))
        when "code", ""
          # Bare /sync = /sync code: QR of the current pairing code (no
          # rotation; a fresh code comes from `h2code sync resync` only).
          relay = cfg.try(&.sync.relay_url) || ""
          relay = Remote::Sync::DEFAULT_RELAY_URL if relay.empty?
          emit_to_log(Message.new("system", Remote::Sync.qr_banner(Remote::Sync.read_or_create_code, relay)))
        when "status"
          emit_to_log(Message.new("system", sync_status_message(cfg)))
        else
          emit_to_log(Message.new("error", "Usage: /sync [on|off|code]"))
        end
      end

      private def sync_status_message(cfg) : String
        sync = cfg.try(&.sync) || Config::SyncConfig.new
        state = sync.enabled? ? "on" : "off"
        daemon = Remote::Sync.daemon_running? ? "running (#{Remote::Sync.bridge_url})" : "stopped"
        transfer = if st = Remote::Sync.daemon_sync_status
                     "Relay transfer: #{st[0]} (#{st[1] ? "uplink running" : "uplink stopped"})"
                   else
                     "Relay transfer: unknown (daemon not answering)"
                   end
        "Cloud sync: #{state}\nDaemon: #{daemon}\n#{transfer}\nRelay: #{sync.relay_url}"
      end

      private def cmd_settings : Nil
        settings = String.build do |s|
          s << "#{H2code.t("info.provider_label", name: @provider_name)}\n"
          s << "#{H2code.t("ui.status_model")}: #{@model}\n"
          s << "#{H2code.t("ui.permission_label")}: #{@permission_mode}\n"
          s << "#{H2code.t("ui.settings_theme")}: #{@theme.name}\n"
          effort = @on_get_effort.try(&.call) || "off"
          s << "#{H2code.t("ui.settings_effort")}: #{effort}\n"
          s << "Home: #{@home}\n"
          s << "Work dir: #{@work_dir}\n"
          s << "Git branch: #{@git_branch.empty? ? "(none)" : @git_branch}\n"
        end
        emit_to_log(Message.new("system", settings.strip))
      end

      # Mirrors TS `handleInitCommand` → `session.init()`: defer any user
      # messages typed during the run, then send the AGENTS.md generation
      # prompt as a regular turn. The agent walks the repo (Bash, Read, Glob)
      # and writes AGENTS.md to the project root.
      private def cmd_init : Nil
        if @agent_busy
          emit_to_log(Message.new("error", "Cannot /init while a turn is running. Wait or interrupt first."))
        else
          @defer_user_messages = true
          emit_to_log(Message.new("system", "Analyzing codebase and generating AGENTS.md..."))
          @dirty = true
          spawn do
            begin
              start_turn(INIT_PROMPT)
            ensure
              @defer_user_messages = false
            end
          end
        end
      end

      # Mirrors TS `handleExportDebugZipCommand`: bundle the session records
      # (wire.jsonl, state.json), a small manifest (version / provider /
      # model / timestamps), and the global log into a tar.gz the user can
      # share for debugging. Falls back to printing the session dir path if
      # tar is unavailable.
      private def cmd_export_debug_zip : Nil
        path = export_debug_bundle
        if path
          emit_to_log(Message.new("system", "Debug bundle exported to: #{path}"))
        else
          emit_to_log(Message.new("error", "Failed to export debug bundle (tar not available?)."))
        end
      end

      # Mirrors TS `showExperimentsPanel`: enumerate experimental flags and
      # their current state. h2code has no registry yet — flags are env-driven
      # (H2CODE_EXPERIMENTAL_<NAME>) plus the master switch
      # H2CODE_EXPERIMENTAL_FLAG=1. Surface the env so the user knows what is
      # on.
      private def cmd_experiments : Nil
        master = @app_config.try(&.experimental_flag)
        env_flags = ENV.keys.select { |k|
          k.starts_with?("H2CODE_EXPERIMENTAL_") && k != "H2CODE_EXPERIMENTAL_FLAG"
        }.sort!
        body = String.build do |s|
          s << "Master switch (H2CODE_EXPERIMENTAL_FLAG): #{master || "off"}\n"
          if env_flags.empty?
            s << "No individual experimental flags set.\n"
          else
            s << "Active flags:\n"
            env_flags.each do |k|
              s << "  #{k} = #{ENV[k]}\n"
            end
          end
          s << "\nFlags are read at startup; restart h2code after changing them."
        end
        emit_to_log(Message.new("system", body.strip))
      end

      # Subcommands: /mcp status, /mcp update [server], /mcp configure.
      # Bare /mcp defaults to status.
      private def cmd_mcp(args : String) : Nil
        sub = args.strip.split(/\s+/).reject(&.empty?)
        case sub[0]?
        when "update"
          server = sub[1]?
          msg = server ? "Refreshing MCP server '#{server}'..." : "Refreshing all MCP servers..."
          emit_to_log(Message.new("system", msg))
          if cb = @on_mcp_update
            cb.call(server)
          else
            emit_to_log(Message.new("error", "MCP update not available in this run."))
          end
        when "configure"
          emit_to_log(Message.new("system", "MCP configuration: edit ~/.h2code/mcp.json directly, then run /mcp update to refresh the cache."))
        when "help"
          emit_to_log(Message.new("system", MCP_HELP_TEXT))
        else
          # Default: show status.
          status = @on_mcp_status.try(&.call) ||
                   "MCP servers: not available in this run (no client wired)."
          emit_to_log(Message.new("system", status))
        end
      end

      private def cmd_login : Nil
        if cb = @on_login
          emit_to_log(Message.new("system", "Starting OAuth device-code login..."))
          cb.call
        else
          cfg_path = File.join(@home, ".h2code", "config.json")
          cred_path = File.join(@home, ".kimi-code", "credentials", "kimi-code.json")
          body = String.build do |s|
            s << "Interactive login is not available in this build.\n\n"
            s << "Manual authentication options:\n"
            s << "  1. API key in config.json:\n"
            s << "       [provider.moonshot]\n"
            s << "       api_key = \"sk-...\"\n"
            s << "     Path: #{cfg_path}\n"
            s << "  2. OAuth credentials (JSON from kimi-code TS login):\n"
            s << "       #{cred_path}\n"
          end
          emit_to_log(Message.new("system", body.strip))
        end
      end

      private def cmd_logout : Nil
        if cb = @on_logout
          cb.call
          emit_to_log(Message.new("system", "Logged out. API key cleared from config."))
        else
          emit_to_log(Message.new("error", "Logout is not wired up."))
        end
      end

      # `/init` — mirrors TS `DEFAULT_INIT_PROMPT`
      # (`packages/agent-core/src/profile/default/init.md`).
      INIT_PROMPT = <<-TEXT
        You are a software engineering expert with many years of programming experience. Please explore the current project directory to understand the project's architecture and main details.

        Task requirements:
        1. Analyze the project structure and identify key configuration files (such as pyproject.toml, package.json, Cargo.toml, shard.yml, etc.).
        2. Understand the project's technology stack, build process and runtime architecture.
        3. Identify how the code is organized and main module divisions.
        4. Discover project-specific development conventions, testing strategies, and deployment processes.

        After the exploration, do a thorough summary of your findings and write it to the `AGENTS.md` file in the project root, replacing the file's previous content. If the file already exists, read it first and carry forward whatever is still accurate — the result should be one coherent, up-to-date file, not an append.

        For your information, `AGENTS.md` is a file intended to be read by AI coding agents. Expect the reader of this file to know nothing about the project.

        You should compose this file according to the actual project content. Do not make any assumptions or generalizations. Ensure the information is accurate and useful. You must use the natural language that is mainly used in the project's comments and documentation.

        Popular sections that people usually write in `AGENTS.md` are:

        - Project overview
        - Build and test commands
        - Code style guidelines
        - Testing instructions
        - Security considerations
      TEXT

      private def cmd_memory : Nil
        report = @profiler.try(&.format_report) ||
                 "Memory profiler not available in this mode."
        emit_to_log(Message.new("system", report))
      end

      private def cmd_telemetry(args : String) : Nil
        case args.strip.downcase
        when "on"
          @telemetry.enabled = true
          emit_to_log(Message.new("system", H2code.t("ui.telemetry_on")))
        when "off"
          @telemetry.enabled = false
          emit_to_log(Message.new("system", H2code.t("ui.telemetry_off")))
        when ""
          state = @telemetry.enabled? ? H2code.t("ui.telemetry_on_label") : H2code.t("ui.telemetry_off_label")
          counters = @telemetry.counter_names.map do |name|
            flag = @telemetry.counter_enabled?(name) ? "✓" : "✗"
            "  #{flag} #{name}"
          end.join("\n")
          emit_to_log(Message.new("system", H2code.t("ui.telemetry_status", state: state, counters: counters)))
        else
          emit_to_log(Message.new("error", H2code.t("ui.telemetry_usage")))
        end
      end

      # Sets the default voice-message language ("auto" = server-side
      # detection, which can misfire on short/noisy clips). Sent to
      # soroka-server with every transcription request.
      private def cmd_voicelang(args : String) : Nil
        lang = args.strip.downcase
        case lang
        when ""
          current = @app_config.try(&.transcription.language) || "auto"
          emit_to_log(Message.new("system",
            "Voice language: #{current}\nUsage: /voicelang <code|auto>  (e.g. ru, en, uk)"))
        when "auto"
          if cfg = @app_config
            cfg.transcription.language = "auto"
            cfg.save
          end
          emit_to_log(Message.new("system", "Voice language: auto (server-side detection)"))
        when /^[a-z]{2}(-[a-z]{2})?$/
          if cfg = @app_config
            cfg.transcription.language = lang
            cfg.save
          end
          emit_to_log(Message.new("system", "Voice language: #{lang}"))
        else
          emit_to_log(Message.new("error", "Usage: /voicelang <code|auto>  (e.g. ru, en, auto)"))
        end
      end

      private def cmd_sounds(args : String) : Nil
        case args.strip.downcase
        when "on"
          if cfg = @app_config
            cfg.notifications.sound_enabled = true
            if disp = @notify_dispatcher
              unless disp.player
                disp.player = Notify::Player.new(
                  done_path: cfg.notifications.sound_done,
                  alert_path: cfg.notifications.sound_input_required,
                  working_path: cfg.notifications.sound_working,
                  volume: cfg.notifications.sound_volume,
                )
              end
            end
            cfg.save
          end
          emit_to_log(Message.new("system", H2code.t("ui.sounds_on")))
        when "off"
          if cfg = @app_config
            cfg.notifications.sound_enabled = false
            if disp = @notify_dispatcher
              disp.player = nil
            end
            cfg.save
          end
          emit_to_log(Message.new("system", H2code.t("ui.sounds_off")))
        when ""
          enabled = @app_config.try(&.notifications.sound_enabled?) || false
          volume = @app_config.try(&.notifications.sound_volume) || 70
          state = H2code.t(enabled ? "ui.sounds_on_label" : "ui.sounds_off_label")
          emit_to_log(Message.new("system", H2code.t("ui.sounds_status", state: state, volume: volume)))
        else
          emit_to_log(Message.new("error", H2code.t("ui.sounds_usage")))
        end
      end

      # Toggle the startup tip shown under the welcome box. Toggling also
      # applies immediately while the welcome box is still visible (the tip
      # lives in the log cache, so it must be invalidated).
      private def cmd_tips(args : String) : Nil
        case args.strip.downcase
        when "on"
          if cfg = @app_config
            cfg.show_tips = true
            cfg.save
          end
          @startup_tip = H2code::Tips.random_tip(I18n.resolve_locale(@app_config.try(&.language)))
          @log_cache_dirty = true
          emit_to_log(Message.new("system", H2code.t("ui.tip_on")))
        when "off"
          if cfg = @app_config
            cfg.show_tips = false
            cfg.save
          end
          @startup_tip = nil
          @log_cache_dirty = true
          emit_to_log(Message.new("system", H2code.t("ui.tip_off")))
        when ""
          enabled = @app_config.try(&.show_tips?) || false
          state = H2code.t(enabled ? "ui.tip_on_label" : "ui.tip_off_label")
          emit_to_log(Message.new("system", H2code.t("ui.tip_status", state: state)))
        else
          emit_to_log(Message.new("error", H2code.t("ui.tip_usage")))
        end
      end

      private def cmd_volume(args : String) : Nil
        val = args.strip.to_i?
        if val.nil? || val < 0 || val > 100
          current = @app_config.try(&.notifications.sound_volume) || 70
          emit_to_log(Message.new("error", H2code.t("ui.volume_invalid", current: current)))
          return
        end
        if cfg = @app_config
          cfg.notifications.sound_volume = val
          # Update the live player if it currently exists.
          if player = @notify_dispatcher.try(&.player)
            player.volume = val
          end
          cfg.save
        end
        emit_to_log(Message.new("system", H2code.t("ui.volume_set", value: val)))
      end

      # `/github [status|token [clear]]` — GitHub integration settings.
      # `status` (the default) reports whether a token is configured;
      # `token` starts a small wizard that collects a personal access token
      # via the input box and saves it to config `github.token`;
      # `token clear` removes it.
      private def cmd_github(args : String) : Nil
        sub = args.strip.split(/\s+/).reject(&.empty?)
        case sub[0]?
        when nil, "", "status"
          emit_to_log(Message.new("system", github_status_message))
        when "token"
          case sub[1]?
          when nil, ""
            start_github_token_wizard
          when "clear", "remove", "off"
            clear_github_token
          else
            emit_to_log(Message.new("error", H2code.t("ui.usage_github")))
          end
        else
          emit_to_log(Message.new("error", H2code.t("ui.usage_github")))
        end
      end

      private def github_status_message : String
        token = @app_config.try(&.github_token) || ""
        body = token.empty? ? H2code.t("ui.github_token_not_set") : H2code.t("ui.github_token_set", masked: mask_secret(token))
        unless ENV["GITHUB_TOKEN"]?.nil? && ENV["GH_TOKEN"]?.nil?
          body += "\n#{H2code.t("ui.github_token_env_override")}"
        end
        body
      end

      # Short recognisable mask for status output: the token prefix (its
      # type, e.g. ghp_/github_pat_) plus fixed dots — never the secret.
      private def mask_secret(secret : String) : String
        "#{secret[0, {4, secret.size}.min]}#{"•" * 8}"
      end

      # Open the token wizard: the editor collects the pasted token (Enter
      # saves, Esc cancels). Mirrors the setup wizard's input-box flow.
      private def start_github_token_wizard : Nil
        unless @app_config
          emit_to_log(Message.new("error", H2code.t("ui.github_token_no_config")))
          return
        end
        @github_token_mode = true
        @status = H2code.t("ui.github_token_entering")
        @editor.clear
        @show_command_hints = false
        emit_to_log(Message.new("system", H2code.t("ui.github_wizard_intro")))
        @dirty = true
      end

      # Save the token collected by the wizard: config `github.token` plus
      # the live Ci service, so CI observers switch to direct api.github.com
      # polling without a restart. Echo is masked like the setup wizard.
      private def submit_github_token(text : String) : Nil
        token = text.strip
        emit_to_log(Message.new("user", "#{"•" * {token.size, 8}.min}"))
        exit_github_token_wizard
        if token.empty?
          emit_to_log(Message.new("error", H2code.t("ui.github_token_empty")))
          return
        end
        if cfg = @app_config
          cfg.github_token = token
          cfg.save
        end
        if service = Tools::Ci.service.as?(Tools::Ci::LiveCiService)
          service.github_token = token
        end
        emit_to_log(Message.new("system", H2code.t("ui.github_token_saved")))
      end

      private def cancel_github_token_wizard : Nil
        exit_github_token_wizard
        emit_to_log(Message.new("system", H2code.t("ui.github_token_cancelled")))
      end

      private def exit_github_token_wizard : Nil
        @github_token_mode = false
        @status = ""
        @editor.clear
        @show_command_hints = false
        @dirty = true
      end

      # Remove the token from config and the live Ci service. Env vars
      # (GITHUB_TOKEN / GH_TOKEN) still apply on the next launch.
      private def clear_github_token : Nil
        cfg = @app_config
        unless cfg
          emit_to_log(Message.new("error", H2code.t("ui.github_token_no_config")))
          return
        end
        cfg.github_token = ""
        cfg.save
        if service = Tools::Ci.service.as?(Tools::Ci::LiveCiService)
          service.github_token = ""
        end
        emit_to_log(Message.new("system", H2code.t("ui.github_token_cleared")))
      end
    end
  end
end
