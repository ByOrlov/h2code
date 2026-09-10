require "../worktree"

module H2code
  module TUI
    class App
      include Zones
      include SetupController
      include CommandController
      include EventController
      include InputController
      include TurnController
      include RenderController
      include MessageRenderer
      include UIPanels
      include VoiceController

      @terminal : Terminal
      getter terminal
      @input : Input
      @editor : Editor
      @spinner : Spinner
      @theme : Theme
      getter theme
      @messages : Array(Message) = [] of Message
      # Last fully rendered frame (log + active combined). Kept for the
      # `/memory` profiler (`render_buffer_*`).
      @previous_lines : Array(String) = [] of String
      # Previous-frame geometry / scroll state for incremental rendering.
      @previous_viewport_top : Int32 = 0
      @prev_log_count : Int32 = 0
      @prev_active_visible : Int32 = 0
      # The two render zones (see `docs/TUI_ZONES.md`). LogZone tracks which
      # finalized log lines have already been emitted; ActiveZone is a stateless
      # renderer that paints the transient region at the bottom of the screen.
      @log_zone : LogZone = LogZone.new
      @active_zone : ActiveZone = ActiveZone.new
      @last_cols : Int32 = 0
      @last_rows : Int32 = 0
      @cursor_line : Int32 = 0
      @first_render : Bool = true
      @streaming_text : String = ""
      @streaming_thinking : String = ""
      @streaming_tool : String?
      # High-water mark of the streaming assistant block's rendered height
      # (see MessageRenderer#render_streaming_text). The block is re-rendered
      # every frame over the full buffer and markdown re-interpretation can
      # transiently shrink it (an open inline delimiter renders raw/wider; a
      # bare ordered-list digit renders as a paragraph for one frame). The
      # active zone must never shrink, so the block is padded to the tallest
      # height it has reached during this stream. Reset when the stream
      # finalizes and migrates to the log.
      @streaming_hwm : Int32 = 0
      @status : String = ""
      @agent_status : AgentStatus = AgentStatus::Hello
      # Accumulated tool calls across all steps in the current turn, shown in
      # the Done summary. Reset on each new turn.
      @turn_tool_count : Int32 = 0
      @model : String = "kimi-for-coding"
      @provider_name : String = "moonshot"
      @permission_mode : String = "manual"
      @context_percent : Float64 = 0.0
      @context_tokens : Int32 = 0
      @max_context_tokens : Int32 = 262144
      @running : Bool = true
      @agent_busy : Bool = false
      @is_compacting : Bool = false
      @defer_user_messages : Bool = false
      @compaction_msg : Message? = nil
      # Set during the brief window between "shifted a queued message out of
      # the array" and "actually started its turn" so a queued-message
      # dispatcher doesn't see an empty queue + idle phase and race itself.
      @dispatch_pending : Bool = false
      # The turn callback normally installed by `run`; a property so tests
      # and embedded drivers can install one without entering the event loop.
      property run_turn_cb : (String, Bool, Array(LLM::ContentPart)? -> Nil)? = nil
      # Media pasted into the input box (Ctrl+V). Placeholders in the editor
      # text resolve against this store on submit — see MediaAttachmentStore.
      property media_store : MediaAttachmentStore = MediaAttachmentStore.new
      # Plan mode mirrors TS: while on, tools that mutate state are blocked
      # and the agent only researches. Toggled via `/plan` or `EnterPlanMode`.
      property? plan_mode : Bool = false
      @queue : Array(QueuedMessage) = [] of QueuedMessage
      @spin_phase : Int32 = 0
      @dirty : Bool = true
      # When true, a terminal-exec (sudo) session owns the screen — skip TUI
      # rendering so it doesn't clobber the alt-screen output.
      property? terminal_exec_active : Bool = false
      @last_render : Time::Span = Time.monotonic
      # Serializes rendering across fibers. STDOUT writes can yield to the
      # scheduler (when the kernel write buffer is full), so without this guard
      # the main render loop and the event/render_now path interleave separate
      # ANSI frames and corrupt the screen.
      @render_mutex = Mutex.new
      # Render-pressure counters: events received since the last completed
      # render and the last measured render duration. On large chats every
      # event triggers a full rebuild of all messages, so a high pending
      # count indicates the event fiber is outpacing the renderer.
      @render_pending : Int32 = 0
      @render_ms : Int64 = 0
      # Sync-bug detector for the debug zone. Stores the last two
      # {LogZone flushed, ActiveZone size} samples; when the combined
      # coverage shrinks between samples a line was lost (the active zone
      # shrank faster than the log grew) — that is a desync. See
      # SyncBugsCount in the debug status line.
      @sync_bugs_count : Int32 = 0
      @sync_prev_states : Array({Int32, Int32}) = [] of {Int32, Int32}
      # Counter-delta telemetry: tracks render-quality counters (e.g.
      # SyncBugsCount) and reports increases as yellow lines attached to the
      # tool call that triggered the render. Toggled via `/telemetry`.
      @telemetry : Telemetry = Telemetry.new
      getter telemetry
      getter sync_bugs_count
      # Cached rendered lines for the log zone. Log-zone messages are immutable
      # once finalized, so their rendered output is cached here and only
      # rebuilt when @messages changes or terminal width changes. During
      # streaming (text_delta / thinking_delta) the cache is NOT invalidated —
      # only the active zone is re-rendered — making each streaming frame O(1)
      # instead of O(N). See docs/TUI_ZONES.md.
      @log_lines_cache : Array(String) = [] of String
      @log_cache_dirty : Bool = true
      @log_cache_cols : Int32 = 0
      # True while at least one swarm/agent subagent is running — drives the
      # 80ms animation tick independently of @agent_busy so progress bars
      # keep moving even when the parent turn is in a tool-call gap.
      @swarm_active : Bool = false
      # True while a CI observer is watching a pushed commit — drives the
      # animated "Waiting for CI for commit <sha>" active-zone lines (one per
      # pending observer), their 80ms animation
      # tick, and the Ctrl+D exit warning. Mirrors @swarm_active's role.
      @ci_active : Bool = false
      @exit_confirm : Bool = false
      @exit_key : String = "CTRL+C"
      @current_step : Int32 = 0
      @step_tool_count : Int32 = 0
      @pending_read_group : Message? = nil
      # Voice recording (Ctrl+R or double-Space): index of the in-flight
      # RECORDING tool message in @messages, plus live session state for the
      # active-zone renderer (timer, level meter, engine). See VoiceController.
      @voice_msg_idx : Int32? = nil
      @voice_recording : Bool = false
      @voice_level : Float64 = 0.0
      @voice_started_at : Time::Span? = nil
      @voice_engine : String = ""
      # Duration frozen at stop: shown on the transcribing frame so the
      # recording block keeps its two-line height (an active-zone shrink
      # mid-flight repaints scrollback rows and duplicates content).
      @voice_recorded_ms : Int64 = 0_i64
      # Voice-server presence probe (port + OS adapter, see
      # Transcription::Presence); a property so tests can inject a fake
      # instead of probing the real filesystem.
      property voice_presence : Transcription::VoicePresencePort = Transcription::VoicePresencePort.default
      # Monotonic timestamp of the last plain Space press, used by the
      # double-Space voice trigger (see InputController#handle_key).
      @last_space_at : Time::Span? = nil

      # Command state
      @show_command_hints : Bool = false
      @command_hints : Array(CommandInfo) = [] of CommandInfo
      @command_hint_selected : Int32 = 0
      @command_hint_scroll : Int32 = 0
      @export_path : String?
      @on_compact : (-> Nil)?
      @on_clear : (-> Nil)?
      @on_undo : (-> Nil)?
      @on_cancel : (-> Nil)?
      @on_new_session : (-> Nil)?
      @on_export : (String -> Nil)?
      @on_provider_change : (String -> Bool)?
      @on_model_change : (String -> Bool)?
      @on_fetch_models : (-> Array(String))?
      # Fetch the model list for an arbitrary provider name — used by the
      # setup wizard's Model step to call the real provider API.
      @on_fetch_models_for : (String -> Array(String))?
      # Returns true when the named provider has credentials configured and
      # needs no further setup. Used by /provider to decide whether to launch
      # the setup wizard for the selected provider.
      @on_provider_configured : (String -> Bool)?
      @on_resume_session : (String -> Nil)?
      # `/fork` into an isolated worktree: the host creates the worktree +
      # branch, forks the session, retargets the path-bound tools and
      # reports the outcome itself. Returns true on success.
      @on_fork : (-> Bool)? = nil
      # `/merge` completion: the host retargets the path-bound tools and the
      # session cwd back to the original repository directory.
      @on_worktree_exit : (String -> Nil)? = nil
      # `/fork go <id>`: the host retargets the path-bound tools and the
      # session cwd into an existing fork sandbox directory.
      @on_fork_go : (String -> Nil)? = nil
      # In-flight `/merge`: checked when the merge turn ends to decide
      # whether the worktree is removed and the tools switched back.
      @pending_merge : Worktree::PendingMerge? = nil
      @on_archive : (-> Nil)?
      @on_rename : (String -> Nil)?
      @on_debug : (-> Nil)?

      # Setup wizard state (first-run provider configuration). When
      # `@setup_mode` is true the editor input is intercepted: the provider
      # selector drives the first step, subsequent submits feed the wizard,
      # and completion invokes `on_setup_complete`.
      @setup_mode : Bool = false
      @wizard : Setup::Wizard? = nil
      property? setup_mode : Bool = false
      property wizard : Setup::Wizard? = nil
      property on_setup_complete : (Setup::Wizard -> Nil)? = nil

      # GitHub token wizard (`/github token`). While true the editor input
      # is intercepted: the user types/pastes the token, Enter saves it to
      # config `github.token` (and the live Ci service), Esc cancels.
      property? github_token_mode : Bool = false

      # GitLab token wizard (`/gitlab token`). Same flow as the GitHub one;
      # saves to config `gitlab.token`.
      property? gitlab_token_mode : Bool = false

      # Approval state
      @approval_pending : ApprovalRequest?
      @approval_channel = Channel(Permission::ApprovalChoice).new
      # Sudo approval popup: a SelectList shown when a sudo command needs
      # interactive approval. Blocks the agent fiber on this channel.
      @sudo_approval_list : SelectList
      @sudo_approval_pending : String? = nil
      @sudo_approval_channel = Channel(Tools::Bash::SudoApprovalChoice).new
      # Notification subsystem: owns the current agent status and fans every
      # real transition out to the dispatcher. nil when notifications are
      # disabled (no dispatcher wired up) → transitions become no-ops.
      @status_tracker : Notify::StatusTracker?
      # Direct reference to the notification dispatcher so slash commands can
      # toggle the sound player at runtime without rebuilding the tracker.
      property notify_dispatcher : Notify::Dispatcher? = nil
      # Full config for persisting sound/volume changes via /sounds and /volume.
      property app_config : H2code::Config::Config? = nil
      @markdown : Markdown
      @provider_list : SelectList
      @model_list : SelectList
      @session_list : SelectList
      @permission_list : SelectList
      @effort_list : SelectList
      @theme_list : SelectList
      @sudo_list : SelectList
      @cleanup_list : SelectList
      @question_dialog : QuestionDialog
      @plan_review_dialog : PlanReviewDialog
      @undo_dialog : UndoDialog
      @tasks_browser : TasksBrowser
      @help_panel : HelpPanel
      @usage_panel : UsagePanel
      property session_entries : Array(Session::SessionEntry) = [] of Session::SessionEntry
      # Search query (downcased substring) → set of original `@session_entries`
      # indices whose wire log contains it. Cached for the lifetime of one
      # open session picker; `Session::Index#substring_hits` also uses cached
      # shorter prefixes to prune scans as the query grows.
      @session_search_hits : Hash(String, Set(Int32)) = Hash(String, Set(Int32)).new
      # Producer/consumer state for the async session search. Keystrokes
      # (producers) only bump the generation, record the latest query in
      # `@session_search_pending`, and nudge the channel — a lossy
      # latest-value mailbox. The worker fiber (consumer) applies the filter
      # for the newest query and cancels its own stale passes by comparing
      # the generation it started with against the current one.
      @session_search_pending : String? = nil
      @session_search_wakeup : Channel(Nil)? = nil
      @session_search_generation : Int32 = 0
      # Cancellation check shared with the scan (`Session::SearchCancelled`
      # when true). nil while no cancellable scan should run.
      @session_search_cancel_check : (-> Bool)? = nil
      @session_picker_mode : Symbol = :resume
      @show_welcome : Bool = true
      # Random startup tip (see H2code::Tips), rendered right under the
      # welcome box in the active-zone green with a `│` bar. nil = no tip
      # (disabled in config or no tips files found).
      property startup_tip : String? = nil
      # Actionable startup warning (same tip layout, warning-yellow bar +
      # text), e.g. the "GitHub Actions without a token" hint. nil = none.
      property startup_warning_tip : String? = nil
      property? debug_zones : Bool = false
      property on_debug_zones_change : (Bool -> Nil)? = nil
      @session_id : String = ""
      @work_dir : String = ""
      @additional_dirs : Array(String) = [] of String
      @home : String = HomePort.home
      @git_branch : String = ""

      property model : String
      property provider_name : String
      property permission_mode : String
      property context_percent : Float64
      property context_tokens : Int32
      property max_context_tokens : Int32
      property session_id : String
      # Read-only accessor; the setter refreshes the cached branch below.
      getter work_dir : String
      property additional_dirs : Array(String)
      # Fired when `/add-dir` adds a directory; the host rebuilds the system
      # prompt (so the new dir shows up in the workspace tree) and may extend
      # the tools' permission scope. Receives the full updated list.
      property on_additional_dirs_change : (Array(String) -> Nil)?
      property home : String
      property git_branch : String
      property on_compact : (-> Nil)?
      property on_clear : (-> Nil)?
      property on_undo : (-> Nil)?
      property on_cancel : (-> Nil)?
      property on_new_session : (-> Nil)?
      property on_export : (String -> Nil)?
      property on_provider_change : (String -> Bool)?
      property on_model_change : (String -> Bool)?
      property on_fetch_models : (-> Array(String))?
      # Fetch the model list for an arbitrary provider name — used by the
      # setup wizard's Model step to call the real provider API.
      property on_fetch_models_for : (String -> Array(String))?
      # Returns true when the named provider has credentials configured and
      # needs no further setup. Used by /provider to decide whether to launch
      # the setup wizard for the selected provider.
      property on_provider_configured : (String -> Bool)?
      property on_resume_session : (String -> Nil)?
      property on_fork : (-> Bool)?
      property on_worktree_exit : (String -> Nil)?
      property on_fork_go : (String -> Nil)?
      property pending_merge : Worktree::PendingMerge?
      property on_archive : (-> Nil)?
      property on_rename : (String -> Nil)?
      property on_debug : (-> Nil)?
      property on_persist_queued : (String, String -> Nil)?
      property on_steer : (String -> Nil)?
      # Thinking-effort selectors (off/low/medium/high). Effort strings are
      # provider-specific in shape but the TUI uses the neutral words.
      property on_get_effort : (-> String)?
      property on_set_effort : (String -> Nil)?
      # Plan-mode toggle: receives the next desired state, returns true if it
      # was applied (false → not wired up / not supported by this provider).
      property on_plan_mode : (Bool -> Bool)?
      # Returns the current TodoList items (or nil if the tool isn't loaded).
      # The TUI renders these in a panel above the editor when non-empty.
      @on_fetch_todos : (-> Array({String, String})?)? = nil
      property on_fetch_todos : (-> Array({String, String})?)?
      # Clear the TodoList tool's state (only meaningful when the agent has
      # registered a TodoList tool).
      @on_clear_todos : (-> Nil)? = nil
      property on_clear_todos : (-> Nil)?
      # Send a feedback message to the team. Backed by an HTTP POST when wired
      # up; otherwise the local `/feedback` handler appends to a log file.
      @on_feedback : (String -> Nil)? = nil
      property on_feedback : (String -> Nil)?
      # Called once when the TUI is about to exit (clean SIGINT while idle),
      # before the terminal is restored. Used to flush cron state and stop
      # background processes.
      @on_exit : (-> Nil)? = nil
      property on_exit : (-> Nil)?
      # Reload `config.json` + session state without restarting the process.
      @on_reload : (-> Nil)? = nil
      property on_reload : (-> Nil)?
      @on_login : (-> Nil)? = nil
      property on_login : (-> Nil)?
      # Returns the on-disk directory for the current session (where
      # `wire.jsonl` / `state.json` live). Used by `/export-debug-zip`.
      @on_session_dir : (-> String?)? = nil
      property on_session_dir : (-> String?)?
      # Logout: clear stored credentials (API key from config.json).
      @on_logout : (-> Nil)? = nil
      property on_logout : (-> Nil)?
      # Undo N turns (count is the selected turn's index). When wired, opens
      # the undo selector; falls back to single-turn `on_undo`.
      @on_undo_count : (Int32 -> Nil)? = nil
      property on_undo_count : (Int32 -> Nil)?
      # Returns user-turn candidates that can be undone, oldest→newest.
      # Each entry: {count, input, label}. nil = not wired up → fallback path.
      @on_fetch_undo_choices : (-> Array({Int32, String, String})?)? = nil
      property on_fetch_undo_choices : (-> Array({Int32, String, String})?)?
      # Tasks browser: data source for the background-task list.
      @on_fetch_tasks : (-> Array(Tools::AgentTaskInfo))? = nil
      property on_fetch_tasks : (-> Array(Tools::AgentTaskInfo))?
      # Tasks browser: stop a task by id (user-confirmed).
      @on_stop_task : (String -> Nil)? = nil
      property on_stop_task : (String -> Nil)?
      # Tasks browser: open the full output for a task.
      @on_open_task_output : (String -> Nil)? = nil
      property on_open_task_output : (String -> Nil)?
      # Persist a queued message to JSONL (so drain survives resume). The
      # wire event type is the argument: "turn.prompt" or "turn.steer".
      property on_persist_queued : (String, String -> Nil)?
      # Steer: inject `text` into the running turn (Agent#steer).
      property on_steer : (String -> Nil)?
      property on_language_change : (String -> Nil)? = nil
      # `/sudo`: persists the app-wide sudo mode ("off"/"request"/"always")
      # to config.json so it applies to every chat and survives restarts.
      property on_sudo_mode_change : (String -> Nil)? = nil
      # Permission-mode switches (/yolo on|off, /permission, /auto, /manual):
      # updates the live Permission::Manager + plan-mode reference and
      # persists the `permission.mode` default to config.json.
      property on_permission_mode_change : (String -> Nil)? = nil
      property on_get_language : (-> String)? = nil
      # `/mcp`: returns the live MCP server status text, or nil when no client
      # is wired (e.g. headless path).
      property on_mcp_status : (-> String)? = nil
      property on_mcp_update : ((String?) -> Nil)? = nil
      # Plugin slash commands loaded from installed plugins.
      property plugin_commands : Array(H2code::Plugin::PluginCommandDef) = [] of H2code::Plugin::PluginCommandDef
      # `/plugins` subcommand handler: receives the raw args string, returns
      # text to display in the transcript.
      property on_plugins_command : (String -> String)? = nil
      # Memory profiler registry backing the `/memory` command. Wired in
      # `run_interactive` after the long-lived collections are created.
      property profiler : ProfiledMemory? = nil
      # The active Bash tool instance, wired in `run_interactive`. Lets `/sudo`
      # and the status panel read/mutate the per-agent sudo mode (now an
      # instance field) instead of the former class-level global.
      property bash_tool : Tools::Bash? = nil

      def initialize(
        @terminal : Terminal = Terminal.current,
        @theme : Theme = Theme.dark,
        dispatcher : Notify::Dispatcher? = nil,
      )
        @input = Input.new
        @editor = Editor.new("")
        @editor.fg_color = @theme.colors.text
        @editor.accent_color = @theme.colors.primary
        @spinner = Spinner.new
        @markdown = Markdown.new(@theme)
        @provider_list = SelectList.new([] of String, @theme)
        @provider_list.max_visible = 15
        @model_list = SelectList.new([] of String, @theme)
        @model_list.searchable = true
        @model_list.max_visible = 50
        @session_list = SelectList.new([] of String, @theme)
        @session_list.searchable = true
        @session_list.content_filter = ->(query : String, idx : Int32) { session_content_matches?(query, idx) }
        # Content scans stream wire logs — defer them off the typing path:
        # edits only schedule the debounced search worker (see
        # `start_session_search_worker`), which re-applies the filter later.
        @session_list.deferred_filter = true
        @session_list.on_query_changed = ->(query : String) { schedule_session_search(query) }
        start_session_search_worker
        @permission_list = SelectList.new([] of String, @theme)
        @effort_list = SelectList.new([] of String, @theme)
        @theme_list = SelectList.new([] of String, @theme)
        @sudo_list = SelectList.new([] of String, @theme)
        @cleanup_list = SelectList.new([] of String, @theme)
        @sudo_approval_list = SelectList.new([] of String, @theme)
        @question_dialog = QuestionDialog.new(@theme)
        @plan_review_dialog = PlanReviewDialog.new(@theme)
        @undo_dialog = UndoDialog.new(@theme)
        @tasks_browser = TasksBrowser.new(@theme)
        @help_panel = HelpPanel.new(@theme)
        @usage_panel = UsagePanel.new(@theme)
        @work_dir = Dir.current
        @git_branch = detect_git_branch
        # Wire the notification dispatcher into a StatusTracker. The tracker
        # lives on the App so UI transitions (start_turn, turn_end, approval)
        # can drive it directly.
        if disp = dispatcher
          @notify_dispatcher = disp
          @status_tracker = Notify::StatusTracker.new { |t| disp.on_transition(t) }
        end
      end

      def stop : Nil
        @running = false
      end

      def run(initial_prompt : String? = nil,
              &run_turn : String, Bool, Array(LLM::ContentPart)? -> Nil) : Nil
        @terminal.raw!
        @terminal.refresh_size
        @run_turn_cb = run_turn

        {% if flag?(:unix) %}
          Signal::INT.trap do
            if @agent_busy
              @status = "Cancelling..."
              @dirty = true
              @on_cancel.try(&.call)
            else
              @running = false
              # Move cursor to end and print newline before restoring
              if @cursor_line > 0
                print "\r"
              end
              print "\n"
              STDOUT.flush
              @on_exit.try(&.call)
              @terminal.restore!
              print "\n"
              exit(0)
            end
          end
        {% end %}

        {% if flag?(:unix) %}
          Signal::WINCH.trap do
            @terminal.refresh_size
            @first_render = true
            @dirty = true
          end
        {% end %}

        render

        # Auto-submit an initial prompt (used by mock demo tasks) so the user
        # immediately sees streaming without typing anything.
        if ip = initial_prompt
          submit_message(ip)
        end

        while @running
          # When a terminal-exec (sudo) session owns the screen, the TUI must
          # not read from STDIN — the child process reads password input
          # directly from /dev/tty (same fd). Skip input + render, just idle.
          if @terminal_exec_active
            sleep 50.milliseconds
            next
          end

          key = @input.read_key

          if key
            handle_key(key)
          end

          now = Time.monotonic
          elapsed = (now - @last_render).total_milliseconds

          if (@agent_busy || @swarm_active || @ci_active || voice_active?) && elapsed >= 80
            @spin_phase += 1
            @dirty = true
          end

          # During active streaming (thinking or text), render immediately on
          # dirty — bypassing the 80ms spinner throttle — so the user sees
          # progressive content updates instead of only the finalized block.
          streaming = !@streaming_thinking.empty? || !@streaming_text.empty?
          if @dirty && !@terminal_exec_active && (!@agent_busy || streaming || elapsed >= 80)
            render
            @dirty = @log_zone.pending?
            @last_render = now
          end

          sleep 20.milliseconds unless key
        end

        # Move the hardware cursor to the bottom row before restoring the
        # terminal, so the shell prompt lands below the last rendered frame
        # instead of wherever the editor/list left it. This matters for the
        # welcome wizard, where ESC exits from an input positioned partway up
        # the screen and leaves stale content above an awkwardly placed prompt.
        move_cursor_to_bottom

        @terminal.restore!
      end

      # Restore the terminal out of raw mode. Used by /debug before dumping the
      # full session transcript to stdout and exiting.
      def restore_terminal : Nil
        @terminal.restore!
      end

      # Position the hardware cursor on the terminal's last row, column 1. Run
      # just before restoring the terminal on exit so the restored shell prompt
      # appears at the bottom of the screen rather than at the row the TUI's
      # editor/list last painted on.
      private def move_cursor_to_bottom : Nil
        return if @terminal.rows <= 0
        print ANSI.cursor_to(@terminal.rows - 1, 0)
        print "\r"
        STDOUT.flush
      end

      def add_message(role : String, content : String) : Nil
        emit_to_log(Message.new(role, content))
      end

      def dirty! : Nil
        @dirty = true
      end

      def force_redraw! : Nil
        @first_render = true
        @dirty = true
      end

      # Retargeting the workspace (/fork into a worktree, /merge back to
      # the main checkout) also refreshes the cached status-bar branch.
      def work_dir=(dir : String) : String
        @work_dir = dir
        refresh_git_branch!
        dir
      end

      # Deep byte size of the on-screen transcript — the TUI-side duplicate of
      # the conversation history. Used by the `/memory` profiler.
      def profiled_bytes : Int64
        @messages.sum(&.profiled_bytes)
      end

      def profiled_count : Int32
        @messages.size
      end

      def render_buffer_bytes : Int64
        @previous_lines.sum(&.profiled_bytes)
      end

      def render_buffer_count : Int32
        @previous_lines.size
      end

      def queue_bytes : Int64
        @queue.sum(&.text.profiled_bytes)
      end

      def queue_count : Int32
        @queue.size
      end
    end
  end
end
