require "json"
require "http/client"
require "uri"
require "file"
require "file_utils"
require "dir"
require "io"
require "regex"
require "time"
require "random/secure"
require "system"
require "colorize"

require "./version"
require "./version_compare"
require "./duration_format"
require "./upgrader"
require "./exception_handler"
require "./process_port"
require "./home_port"
require "./worktree"
require "./shell_port"
require "./llm/types"
require "./llm/token_counter"
require "./llm/http_transport"
require "./llm/provider"
require "./llm/openai_chat_provider"
require "./llm/moonshot_provider"
require "./auth/oauth"
require "./llm/zai_provider"
require "./llm/ollama_provider"
require "./llm/lmstudio_provider"
require "./llm/deepseek_provider"
require "./llm/groq_provider"
require "./llm/openrouter_provider"
require "./llm/xai_provider"
require "./llm/cerebras_provider"
require "./llm/fireworks_provider"
require "./llm/together_provider"
require "./llm/mock_provider"
require "./tools/tool"
require "./tools/names"
require "./tools/registry"
require "./tools/line_endings"
require "./tools/sensitive"
require "./tools/path_access"
require "./tools/run_rg"
require "./tools/bash"
require "./tools/read"
require "./tools/write"
require "./tools/edit"
require "./tools/glob"
require "./tools/grep"
require "./tools/todo_list"
require "./tools/agent_swarm"
require "./tools/swarm_mode"
require "./tools/agent"
require "./tools/ask_user_question"
require "./tools/fetch_url"
require "./tools/web_search"
require "./tools/skill"
require "./tools/plan_mode"
require "./tools/goal"
require "./tools/task"
require "./remote/control_socket"
require "./remote/qr"
require "./remote/sync"
require "./tools/cron"
require "./tools/ci"
require "./tools/wait_for_ci"
require "./tools/read_media"
require "./tools/select_tools"
require "./tools/curr_time"
require "./tools/get_context_remaining"
require "./tools/apply_patch"
require "./tools/interactive_shell"
require "./mcp/types"
require "./mcp/tool_naming"
require "./mcp/transport"
require "./mcp/http_transport"
require "./mcp/jsonrpc"
require "./mcp/oauth"
require "./mcp/config"
require "./mcp/client"
require "./mcp/proxy_tool"
require "./mcp/lazy_proxy_tool"
require "./mcp/tool_cache"
require "./mcp/output"
require "./mcp/auth_tool"
require "./mcp/manager"
require "./context/memory"
require "./context/budget"
require "./context/undo"
require "./context/overflow"
require "./context/compaction"
require "./loop/retry"
require "./profiled_memory"
require "./loop/events"
require "./loop/abort"
require "./loop/dedup"
require "./loop/agent"
require "./loop/subagent_registry"
require "./loop/subagent_agent_runner"
require "./loop/subagent_swarm_runner"
require "./permission/manager"
require "./notify/config"
require "./notify/status"
require "./notify/terminal"
require "./notify/player"
require "./notify/webhook"
require "./notify/dispatcher"
require "./config/config"
require "./tips/tips"
require "./transcription/presence"
require "./transcription/client"
require "./i18n/i18n"
require "./hooks/engine"
require "./plugin/types"
require "./plugin/store"
require "./plugin/source"
require "./plugin/manifest"
require "./plugin/archive"
require "./plugin/github_resolver"
require "./plugin/commands"
require "./plugin/injector"
require "./plugin/manager"
require "./prompt/template"
require "./prompt/agents_md"
require "./prompt/system_prompt"
require "./session/store"
require "./session/index"
require "./session/lifecycle"
require "./session/cleanup"
require "./acp/json_rpc"
require "./acp/event_translator"
require "./acp/approval"
require "./acp/session"
require "./acp/server"
require "./setup/wizard"
require "./tui/terminal"
require "./tui/char_width"
require "./tui/theme"
require "./tui/input_wait"
require "./tui/input"
require "./tui/component"
require "./tui/text"
require "./tui/spinner"
require "./tui/agent_status"
require "./tui/editor"
require "./tui/image_paste_port"
require "./tui/media_attachment_store"
require "./tui/markdown"
require "./tui/fuzzy"
require "./tui/select_list"
require "./tui/commands"
require "./tui/help_panel"
require "./tui/question_dialog"
require "./tui/plan_review_dialog"
require "./tui/undo_dialog"
require "./tui/tasks_browser"
require "./tui/setup_controller"
require "./tui/command_controller"
require "./tui/app_models"
require "./tui/telemetry"
require "./tui/event_controller"
require "./tui/input_controller"
require "./tui/turn_controller"
require "./tui/render_controller"
require "./tui/message_renderer"
require "./tui/ui_panels"
require "./tui/voice_controller"
require "./tui/terminal_port"
require "./tui/terminal_mock"
require "./tui/ansi_terminal_port"
require "./tui/log_zone"
require "./tui/active_zone"
require "./tui/zones"
require "./tui/app"
require "./tui/diff"
require "./tui/usage_panel"

module H2code
  # Headless print-mode palette, ported from the original Moonshot kimi-code
  # TUI dark theme (apps/kimi-code/src/tui/theme/colors.ts).
  C_SUCCESS = Colorize::ColorRGB.new(0x4E, 0xC8, 0x7E)
  C_ERROR   = Colorize::ColorRGB.new(0xE8, 0x54, 0x54)
  C_PRIMARY = Colorize::ColorRGB.new(0x4F, 0xA8, 0xFF)
  C_SHELL   = Colorize::ColorRGB.new(0xBD, 0x93, 0xF9)
  C_DIM     = Colorize::ColorRGB.new(0x88, 0x88, 0x88)
  C_MUTED   = Colorize::ColorRGB.new(0x6B, 0x6B, 0x6B)

  # Raised when a provider cannot be built from the current config (missing
  # credentials, unknown name, ...). At startup it is rescued and turned into
  # an exit; at runtime the /provider selector catches it to show an inline
  # error without leaving the TUI.
  ProviderConfigError = LLM::ProviderConfigError

  class CLI
    # Set by `--ram`. When true, every tool_result event prints RSS + tool
    # name + result size to stderr so live memory growth can be observed
    # without a debugger (Crystal + Boehm GC is hard to attach to).
    class_property ram_tracer : RamTracer = RamTracer.new

    # Read current process RSS in MB. Delegates to ProfiledMemory so the
    # profiler stays self-contained (no dependency back into the CLI module).
    def self.rss_mb : Float64
      ProfiledMemory.rss_mb
    end

    def self.run(argv : Array(String)) : Nil
      # Subcommand dispatch: `h2code acp` starts the ACP server for IDE integration.
      if argv.size > 0 && argv[0] == "acp"
        return run_acp(argv[1..])
      end

      # `h2code sync` — cloud-sync management (see Remote::Sync).
      if argv.size > 0 && argv[0] == "sync"
        return run_sync(argv[1..])
      end

      # `h2code resync [url]` — shortcut for `h2code sync resync`: fresh
      # pairing code + QR, optionally pointing at a new relay.
      if argv.size > 0 && argv[0] == "resync"
        return run_sync(["resync"] + argv[1..])
      end

      prompt = nil
      tui_prompt = nil
      work_dir = Dir.current
      model = nil
      session_id = nil
      permission_mode = nil
      show_help = false
      show_version = false
      continue_session = false
      hi_mode = false

      i = 0
      while i < argv.size
        case argv[i]
        when "-p", "--prompt"
          i += 1
          prompt = argv[i]? || ""
        when "--tui-prompt"
          i += 1
          tui_prompt = argv[i]? || ""
        when "-d", "--work-dir"
          i += 1
          work_dir = argv[i]? || Dir.current
        when "-m", "--model"
          i += 1
          model = argv[i]
        when "-s", "--session"
          i += 1
          session_id = argv[i]
        when "-c", "--continue"
          continue_session = true
        when "--permission"
          i += 1
          permission_mode = argv[i]
        when "--yolo"
          permission_mode = "yolo"
        when "--auto"
          permission_mode = "auto"
        when "--hi"
          hi_mode = true
        when "--ram"
          CLI.ram_tracer = RamTracer.new(enabled: true)
        when "-h", "--help"
          show_help = true
        when "-v", "--version"
          show_version = true
        end
        i += 1
      end

      if show_help
        print_usage
        return
      end

      if show_version
        puts "H2Code #{VERSION}"
        return
      end

      config = Config::Config.load

      H2code::I18n.init(H2code::I18n.resolve_locale(config.language))

      config.model = model if model
      if pm = permission_mode
        config.permission_mode = pm
      end
      config.ensure_h2code_home

      home = HomePort.home

      oauth_path = File.join(home, ".kimi-code", "credentials", "kimi-code.json")
      oauth = LLM::OAuthCredentials.load(oauth_path)

      # First-run gate: if no provider is configured yet, either run the
      # interactive setup wizard (TTY) or fail with a clear message (non-TTY).
      unless config.provider_name && config.provider_configured?
        if STDIN.tty? && !hi_mode && prompt.nil?
          # User aborted setup (Esc/Ctrl+D at the wizard) — exit cleanly
          # instead of falling through to build_provider, which would raise.
          exit(0) unless run_setup_wizard(config)
        else
          STDERR.puts H2code.t("errors.no_provider")
          STDERR.puts ""
          STDERR.puts H2code.t("errors.setup_hint")
          STDERR.puts H2code.t("errors.setup_hint_provider")
          STDERR.puts H2code.t("errors.setup_hint_key")
          STDERR.puts ""
          STDERR.puts H2code.t("errors.setup_hint_help")
          exit(2)
        end
      end

      provider = build_provider(config, oauth)
      web_search_service = build_web_search_service(config, provider)
      Tools::WebSearch.service = web_search_service

      if hi_mode
        run_hi(provider)
        return
      end

      memory = Context::Memory.new
      memory.max_context_tokens = config.max_context_tokens

      tools = Tools::Registry.new
      # Bash is registered later, once the TaskService + session dir are
      # available, so both headless and interactive paths get the same
      # fully-wired instance (background execution, sudo bridges added by
      # the TUI afterwards).
      tools.register(Tools::Read.new(work_dir))
      tools.register(Tools::Write.new(work_dir))
      tools.register(Tools::Edit.new(work_dir))
      tools.register(Tools::Glob.new(work_dir))
      tools.register(Tools::Grep.new(work_dir))
      tools.register(Tools::TodoList.new)
      tools.register(Tools::AgentSwarm.new)
      tools.register(Tools::Agent.new)
      tools.register(Tools::AskUserQuestion.new)
      tools.register(Tools::FetchURL.new)
      tools.register(Tools::WebSearch.new) if web_search_service.get_web_search_provider
      tools.register(Tools::Skill.new)
      tools.register(Tools::EnterPlanMode.new)
      tools.register(Tools::ExitPlanMode.new)
      tools.register(Tools::CreateGoal.new)
      tools.register(Tools::GetGoal.new)
      tools.register(Tools::UpdateGoal.new)
      tools.register(Tools::SetGoalBudget.new)
      tools.register(Tools::TaskList.new)
      tools.register(Tools::TaskOutput.new)
      tools.register(Tools::TaskStop.new)
      tools.register(Tools::CronCreate.new)
      tools.register(Tools::CronList.new)
      tools.register(Tools::CronDelete.new)
      tools.register(Tools::WaitForCI.new(work_dir))
      # Media runtime wiring: local FS, default capabilities (image input
      # on, video off until a provider needs it), and the ImageMagick
      # processor when available (pass-through fallback otherwise).
      Tools::Media.fs ||= Tools::LocalMediaFileSystem.new
      Tools::Media.capabilities ||= Tools::ModelCapabilities.new(image_in: true, video_in: false)
      Tools::Media.image_processor ||= Tools::ImageMagickImageProcessor.resolve
      tools.register(Tools::ReadMediaFile.new)
      # Progressive tool disclosure (experimental, off by default):
      # H2CODE_EXPERIMENTAL_TOOL_SELECT=1 or the master flag enable it. The
      # select_tools tool is only advertised when the service is active.
      if Tools.tool_select_enabled_from_env?
        Tools::ToolSelect.service ||= Tools::AgentToolSelectService.new(tools)
      end
      tools.register(Tools::SelectTools.new) if Tools::ToolSelect.service.try(&.enabled?)

      # Shared CI observer service for all run modes (TUI attaches delivery +
      # session store later; headless/ACP keep the bare observer loop). The
      # GitHub token enables direct REST polling (no gh CLI); the GitLab
      # token (optional) covers private GitLab projects.
      Tools::Ci.service ||= Tools::Ci::LiveCiService.new(
        github_token: config.github_token,
        gitlab_token: config.gitlab_token,
        gitlab_endpoint: config.gitlab_endpoint,
      )
      tools.register(Tools::CurrentTime.new)
      tools.register(Tools::GetContextRemaining.new(memory))
      tools.register(Tools::ApplyPatchTool.new)
      tools.register(Tools::InteractiveShellTool.new)

      permission = Permission::Manager.new(Permission::Mode.parse(config.permission_mode))

      # Load installed plugins and merge their declared capabilities (skills,
      # MCP servers, hooks, commands, session-start) into the session.
      plugin_manager = Plugin::Manager.new(home, config.tmp_dir)
      plugin_manager.load
      plugin_mcp_servers = plugin_manager.enabled_mcp_servers
      plugin_hooks = plugin_manager.enabled_hooks

      # Connect configured MCP servers (config.toml + plugins) and register
      # their tools. Supports stdio (child process) and HTTP (Streamable HTTP
      # + SSE, OAuth) transports. Failures are isolated per server — a broken
      # server is reported, not fatal. `shutdown` is wired into both exit paths
      # below. Interactive runs connect in the background so a slow server
      # never blocks the TUI; headless runs block so tools are ready.
      merged_mcp = config.mcp_servers + plugin_mcp_servers
      # Auto-config provider-specific MCP servers (e.g. Z.AI web search).
      # Skip entries whose URL already exists in manual/plugin config.
      auto_mcp = config.auto_mcp_servers
      existing_urls = Set(String).new
      merged_mcp.each { |c| (u = c.url) && existing_urls << u }
      auto_mcp.reject! { |c| c.url.try { |u| existing_urls.includes?(u) } || false }
      merged_mcp = merged_mcp + auto_mcp
      mcp_manager = Mcp::Manager.new(home)
      mcp_manager.register_from_cache(merged_mcp, tools,
        active_provider: config.provider_name, blocking: prompt ? true : false)

      home = HomePort.home
      lifecycle = H2code::Session::Lifecycle.new(home)
      store = begin
        if sid = session_id
          # Resolve across every workspace + legacy flat layout.
          entry = lifecycle.index.get(sid)
          dir = entry ? entry.path : File.join(home, ".h2code", "sessions", sid)
          # open_existing! refuses to silently resurrect a deleted
          # session as an empty one (which would lose everything on
          # the next save) and raises FileDeletedError instead.
          begin
            H2code::Session::Store.open_existing!(dir)
          rescue H2code::Session::FileDeletedError
            STDERR.puts H2code.t("errors.session_deleted", id: sid)
            exit(1)
          end
        elsif continue_session
          ws_id = H2code::Session::Index.workspace_id(work_dir)
          entry = lifecycle.index.find_most_recent(ws_id) ||
                  lifecycle.index.find_most_recent
          unless entry
            STDERR.puts H2code.t("errors.no_previous_session")
            exit(1)
          end
          begin
            H2code::Session::Store.open_existing!(entry.path)
          rescue H2code::Session::FileDeletedError
            STDERR.puts H2code.t("errors.session_deleted", id: entry.id)
            exit(1)
          end
        else
          fresh = lifecycle.create(work_dir)
          # Fresh session + cloud sync on → ping the daemon right away, so
          # remote clients (PWA) see the new session without waiting for
          # the daemon's 3s disk rescan (Remote::Sync.notify_session_created).
          if config.sync.enabled?
            sid = fresh.read_state.try(&.id) || fresh.meta_id?
            Remote::Sync.notify_session_created(sid) if sid
          end
          fresh
        end
      rescue e : H2code::Session::SessionBusyError
        # Another live h2code process owns the session; two writers on one
        # wire.jsonl corrupt it, so refuse instead of interleaving.
        STDERR.puts H2code.t("errors.session_busy", id: session_id || File.basename(e.session_dir))
        STDERR.puts e.message
        exit(1)
      end

      # Session↔sandbox link: a resumed session born from /fork records its
      # sandbox folder in state.json — switch the whole run (system prompt,
      # skills, path-bound tools) back into it. An empty or missing folder
      # means a plain checkout session: no switch. A vanished sandbox
      # (merged and cleaned elsewhere) falls back to the given work dir.
      if (sandbox = store.read_state.try(&.sandbox_folder)) && !sandbox.empty? && Dir.exists?(sandbox)
        work_dir = sandbox
        {Tools::Names::READ, Tools::Names::WRITE, Tools::Names::EDIT,
         Tools::Names::GLOB, Tools::Names::GREP, Tools::Names::WAIT_FOR_CI}.each do |name|
          tools.get(name).try do |tool|
            tool.work_dir = sandbox if tool.responds_to?(:work_dir=)
          end
        end
      end

      # TodoList persistence: todos survive restarts via
      # <session_dir>/todo.json (in-memory only for subagents / ACP).
      if todo_tool = tools.get(Tools::Names::TODO_LIST).as?(Tools::TodoList)
        todo_tool.session_dir = store.session_dir
        todo_tool.load_persisted
      end

      if continue_session || session_id
        store.replay(memory)
      end

      # Bind the session to the provider so the backend caches the prompt
      # prefix keyed by the session id — without this every step reprocesses
      # the full growing context from scratch.
      sid_for_cache = (store.read_state.try(&.id) || store.meta_id? || session_id || Random::Secure.hex(12))
      configure_provider(provider, config, sid_for_cache)

      agent = Loop::Agent.new(provider, memory, tools, permission)
      agent.debug = config.debug?
      merged_hooks = config.hooks + plugin_hooks
      agent.hooks = Hooks::Engine.new(merged_hooks, cwd: work_dir, session_id: store.meta_id?) unless merged_hooks.empty?

      # Discover skills from disk (user home + project root) plus plugin skills,
      # and register them in the global catalog so the Skill tool can resolve them.
      discovered = H2code::Tools::SkillDiscovery.discover(home, work_dir)
      discovered += plugin_manager.plugin_skills
      skill_catalog = H2code::Tools::InMemorySkillCatalog.new(discovered)
      H2code::Tools::Skill.catalog = skill_catalog
      H2code::Tools::Skill.memory = memory

      system_prompt = Prompt::SystemPrompt.build(work_dir,
        additional_dirs: [] of String,
        skills_listing: skill_catalog.model_listing,
        shell: config.shell)

      task_service = H2code::Tools::InMemoryTaskService.new(store)
      H2code::Tools::Task.service = task_service

      # App-wide sudo mode from config: every Bash instance (main agent,
      # subagents, ACP) starts with it; the TUI `/sudo` command changes it
      # at runtime and persists the new value back to config.json.
      Tools::Bash.default_sudo_mode = Tools::Bash::SudoMode.parse?(config.sudo_mode) || Tools::Bash::SudoMode::Off
      # Register Bash with the shared TaskService + session dir so background
      # execution works in both headless and interactive modes. The TUI adds
      # the delivery/terminal/sudo-approval bridges to this same instance
      # later; headless runs leave them nil.
      bash_tool = Tools::Bash.new(work_dir, task_service, store.session_dir)
      # Propagate OS-env proxies from Config so all Bash instances (main,
      # subagents, ACP) share the same values without re-reading ENV.
      Tools::Bash.git_terminal_prompt = config.git_terminal_prompt
      Tools::Bash.shell = config.shell
      # Windows: advertise the configured bash location to the model. cmd.exe
      # always executes commands; this only tells the model where bash is so
      # it can invoke it explicitly for POSIX-only tasks. bash_path is a
      # class-level setting (inert on Unix) — set it on ShellPort, not on
      # the SHELL_PORT instance.
      H2code::ShellPort.bash_path = config.bash_available
      tools.register(bash_tool)

      goal_service = H2code::Tools::AgentGoalService.new
      H2code::Tools::Goal.service = goal_service
      agent_runner, swarm_runner = wire_subagent_runners(agent, task_service, system_prompt, work_dir, config)

      begin
        if prompt
          run_headless(prompt, agent, system_prompt, store, config, task_service, mcp_manager)
        else
          run_interactive(agent, system_prompt, store, config, permission, oauth, home, work_dir, tui_prompt, agent_runner, swarm_runner, task_service, mcp_manager, plugin_manager)
        end
      rescue ex : Loop::UserCancellationError
        # Expected user-initiated interruption; not a crash.
        raise ex
      rescue ex
        ExceptionHandler.report_and_notify(ex, "CLI.run")
        raise ex
      end
    end

    # Startup entry: build the configured provider, exiting the process with a
    # clear message if config is incomplete.
    private def self.build_provider(config, oauth) : LLM::Provider
      build_named_provider(config.provider_name, config, oauth)
    rescue ex : ProviderConfigError
      STDERR.puts H2code.t("errors.generic", message: ex.message.to_s)
      exit(1)
    end

    # Build a provider by name from the current config. Raises
    # ProviderConfigError on missing credentials or an unknown name, so callers
    # that must not exit (e.g. the /provider selector at runtime) can rescue
    # and surface the message instead.
    def self.build_named_provider(name : String?, config, oauth) : LLM::Provider
      if name.nil? || name.empty?
        available = LLM::Provider.providers.map(&.name).join(", ")
        raise ProviderConfigError.new("No provider configured. Available: #{available}")
      end
      registration = LLM::Provider.find(name)
      unless registration
        available = LLM::Provider.providers.map(&.name).join(", ")
        raise ProviderConfigError.new("Unknown provider '#{name}'. Available: #{available}")
      end
      registration.builder.call(config, oauth)
    end

    # Fold the runtime request-config into a freshly built provider: the
    # session prompt-cache key (so the backend caches the prompt prefix across
    # steps), the configured thinking effort, and the model context window
    # (used to clamp the per-step completion budget). The setters are no-ops on
    # providers that don't override them (e.g. Mock), so this is safe to call
    # uniformly on any backend.
    def self.configure_provider(provider, config, cache_key : String?) : Nil
      provider.thinking_effort = config.thinking_effort
      provider.max_context_tokens = config.max_context_tokens
      provider.prompt_cache_key = cache_key
      provider.debug = config.debug?
    end

    # Build the WebSearch service for the current session. Explicit
    # `[services.moonshot_search]` config wins; otherwise derive the search
    # backend from the active provider (Moonshot endpoint + auth token).
    def self.build_web_search_service(config : Config::Config,
                                      provider : LLM::Provider) : Tools::WebSearchProviderService
      ms = config.services.moonshot_search
      config_service = Tools::ConfigWebSearchService.new(
        ms.try(&.base_url),
        ms.try(&.api_key),
        {} of String => String,
        ms.try(&.custom_headers) || {} of String => String,
      )
      provider_service = Tools::ProviderWebSearchService.new(provider)
      Tools::CompositeWebSearchService.new(config_service, provider_service)
    end

    # Smoke test: send "hi" to the configured provider and report the
    # result. No tools, no system prompt, no agent loop — just a raw
    # chat call to verify the key, endpoint, model, and balance.
    private def self.run_hi(provider : LLM::Provider) : Nil
      puts H2code.t("info.provider_label", name: provider.name)
      puts H2code.t("info.model_label", name: provider.model_name)
      puts H2code.t("info.prompt_label")
      puts H2code.t("info.separator")

      messages = [LLM::Message.user("hi")]
      text = IO::Memory.new

      begin
        result = provider.chat(messages, nil) do |part|
          case part
          when LLM::TextPart
            print part.text.colorize.fore(C_DIM)
            STDOUT.flush
            text << part.text
          end
        end

        puts ""
        puts ""
        puts H2code.t("info.ok_replied", tokens: result.usage.total_tokens)
          .colorize.fore(C_SUCCESS)
        exit(0)
      rescue ex : LLM::ApiError
        STDERR.puts ""
        STDERR.puts H2code.t("info.http_error", code: ex.status_code, message: ex.message.to_s)
          .colorize.fore(C_ERROR)
        exit(1)
      rescue ex
        STDERR.puts ""
        STDERR.puts H2code.t("info.error_prefix", message: ex.message.to_s).colorize.fore(C_ERROR)
        exit(1)
      end
    end

    private def self.wire_subagent_runners(agent : Loop::Agent,
                                           task_service : Tools::InMemoryTaskService,
                                           system_prompt : String,
                                           work_dir : String,
                                           config : Config::Config) : {Loop::SubagentAgentRunner, Loop::SubagentSwarmRunner}
      registry = Loop::SubagentRegistry.new
      permission_mode = Permission::Mode.parse(config.permission_mode)

      agent_runner = Loop::SubagentAgentRunner.new(
        registry: registry,
        parent_agent: agent,
        task_service: task_service,
        system_prompt: system_prompt,
        work_dir: work_dir,
        permission_mode: permission_mode,
        subagent_timeout_ms: config.subagent_timeout_ms,
      )
      swarm_runner = Loop::SubagentSwarmRunner.new(
        registry: registry,
        parent_agent: agent,
        system_prompt: system_prompt,
        work_dir: work_dir,
        permission_mode: permission_mode,
        subagent_timeout_ms: config.subagent_timeout_ms,
      )
      Tools::Agent.runner = agent_runner
      Tools::AgentSwarm.runner = swarm_runner
      # TaskList/TaskOutput/TaskStop are registered for the main agent, so
      # background subagent execution is available.
      Tools::Agent.background_enabled = true
      {agent_runner, swarm_runner}
    end

    private def self.run_headless(prompt, agent, system_prompt, store, config, task_service, mcp_manager)
      store.append_simple("turn.prompt", "prompt", prompt)

      {% if flag?(:unix) %}
        Signal::INT.trap do
          STDERR.puts "\nInterrupted."
          agent.cancel
          # Kill any background processes spawned during this headless run.
          task_service.stop_all_on_exit("process interrupted")
          H2code::Tools::InteractiveShell.service.try(&.stop_all)
          mcp_manager.shutdown
        end
      {% end %}

      # Headless dispatcher: useful for CI/automation webhooks. StatusTracker
      # drives Working→Done around the single turn.
      dispatcher = Notify::Dispatcher.from_config(config.notifications)
      status_tracker = Notify::StatusTracker.new { |t| dispatcher.on_transition(t) }
      status_tracker.transition!(Notify::AgentStatus::Working)

      assistant_buf = IO::Memory.new
      assistant_open = false
      thinking_open = false
      pending_calls = {} of String => {String, String}

      begin
        result = agent.run_goal_turn(prompt, system_prompt) do |event|
          case event.type
          when .step_begin?
            assistant_buf.clear
          when .thinking_delta?
            unless thinking_open
              puts
              thinking_open = true
            end
            print event.text.colorize.fore(:light_gray).dim
            STDOUT.flush
          when .text_delta?
            if thinking_open
              puts
              puts
              thinking_open = false
            end
            unless assistant_open
              print " ● ".colorize.fore(:light_gray).dim
              assistant_open = true
            end
            assistant_buf << event.text
            print event.text.colorize.fore(:light_gray).dim
            STDOUT.flush
          when .assistant_text?
            data = {"content" => JSON::Any.new(assistant_buf.to_s)} of String => JSON::Any
            if (t = event.thinking) && !t.empty?
              data["thinking"] = JSON::Any.new(t)
            end
            store.append("assistant.text", data)
            if assistant_open
              puts
              puts
              assistant_open = false
            end
          when .tool_call_start?
            store.append("tool.call", {
              "tool_call_id" => JSON::Any.new(event.tool_call_id),
              "tool_name"    => JSON::Any.new(event.tool_name),
              "arguments"    => JSON::Any.new(event.tool_args),
            })
            pending_calls[event.tool_call_id] = {event.tool_name, event.tool_args}
          when .tool_result?
            store.append("tool.result", {
              "tool_call_id" => JSON::Any.new(event.tool_call_id),
              "content"      => JSON::Any.new(event.text),
            })
            if assistant_open
              puts
              puts
              assistant_open = false
            end
            name, args = pending_calls.delete(event.tool_call_id) || {"Tool", ""}
            render_tool_block(name, args, event.text, event.is_error?)
            if line = CLI.ram_tracer.line(name, event.text.bytesize, event.is_error?)
              puts line.colorize.yellow
            end
          when .info?
            puts "[#{event.text}]".colorize.yellow
          when .error?
            STDERR.puts H2code.t("errors.generic", message: event.text).colorize.red
          end
        end

        puts
        puts "#{H2code.t("info.done", steps: result.steps)}" \
             "#{result.usage.total_tokens} tokens)".colorize.fore(C_SUCCESS)
        puts
        status_tracker.transition!(Notify::AgentStatus::Done, H2code.t("status.turn_complete"))
        status_tracker.transition!(Notify::AgentStatus::Idle)
      rescue ex : Loop::UserCancellationError
        agent.context.add_user(H2code.t("status.interrupted"))
        puts H2code.t("info.interrupted_by_user").colorize.yellow
        status_tracker.transition!(Notify::AgentStatus::Done, H2code.t("status.cancelled"))
        status_tracker.transition!(Notify::AgentStatus::Idle)
      rescue ex : Loop::NetworkFailureError
        puts "\n#{ex.message}".colorize.yellow
        status_tracker.transition!(Notify::AgentStatus::Done, H2code.t("status.network_failure"))
        status_tracker.transition!(Notify::AgentStatus::Idle)
      rescue ex
        STDERR.puts H2code.t("errors.fatal", message: ex.message.to_s).colorize.red
        ex.backtrace.each { |b| STDERR.puts "  #{b}" } if config.debug?
        ExceptionHandler.report_and_notify(ex, "run_headless")
        exit(1)
      ensure
        mcp_manager.shutdown
      end
    end

    # `h2code sync [on|off|code|resync|status]` — headless twin of the TUI `/sync`
    # command. Bare `h2code sync` acts as `sync code` (current QR, no rotation).
    # Flips `sync.enabled` in config.json, shows the pairing QR/relay, and
    # toggles the running daemon's relay data-transfer mode over its control
    # socket (on = connect + stream, off = drop the relay connection).
    # The h2code-remote daemon is MANUAL-ONLY (2026-09-03): hcode never
    # spawns or stops it — the daemon is a separate service the user runs
    # himself. `resync [url]` issues a fresh pairing code + QR, optionally
    # for a new relay (`h2code resync` is the shortcut). Auth is code-only
    # (plans/QrAuth.md) — no email needed.

    # Продакшн-релей по умолчанию — общий с TUI `/sync`, живёт в
    # Remote::Sync::DEFAULT_RELAY_URL.

    private def self.run_sync(rest_argv : Array(String)) : Nil
      config = Config::Config.load
      config.ensure_h2code_home
      # Без аргументов — как `sync code`: показать QR текущего кода
      # (без ротации; свежий код выдаёт только resync).
      cmd = rest_argv[0]? || "code"
      case cmd
      when "on"
        # Без явного relay в конфиге подставляем продакшн (h2code.dev);
        # локальный LAN-релей — только явным relay_url в конфиге.
        if config.sync.relay_url.empty?
          config.sync.relay_url = Remote::Sync::DEFAULT_RELAY_URL
          config.save
        end
        config.sync.enabled = true
        config.save
        puts "sync enabled; #{Remote::Sync.set_daemon_sync_mode("on")}"
        puts Remote::Sync.qr_banner(Remote::Sync.read_or_create_code, config.sync.relay_url)
      when "off"
        config.sync.enabled = false
        config.save
        puts "sync disabled; #{Remote::Sync.set_daemon_sync_mode("off")}"
      when "code"
        if config.sync.relay_url.empty?
          config.sync.relay_url = Remote::Sync::DEFAULT_RELAY_URL
          config.save
        end
        puts Remote::Sync.qr_banner(Remote::Sync.read_or_create_code, config.sync.relay_url)
      when "resync"
        # Fresh pairing code + QR, optionally for a new relay URL. The old
        # code dies with the old relay — the daemon restart (if running)
        # picks up the regenerated code. Without an explicit URL the relay
        # comes from the running h2code-remote daemon (it publishes the
        # external form of its `--cloud` uplink on startup), so the config
        # self-heals stale LAN addresses on every resync.
        relay = rest_argv[1]?
        relay = Remote::Sync.stored_relay_url if relay.nil? || relay.empty?
        relay = config.sync.relay_url if relay.nil? || relay.empty?
        if relay.nil? || relay.empty?
          relay = Remote::Sync::DEFAULT_RELAY_URL
        end
        config.sync.relay_url = relay
        config.save
        code = Remote::Sync.regenerate_code
        # The daemon (manual, separate service) re-keys its relay uplink on
        # its own when the pairing code changes — nothing to restart here.
        puts Remote::Sync.qr_banner(code, relay)
      when "status"
        daemon = Remote::Sync.daemon_running? ? "running" : "stopped"
        puts "cloud sync: #{config.sync.enabled? ? "on" : "off"}"
        puts "daemon: #{daemon} (manual — hcode never starts/stops it)"
        if st = Remote::Sync.daemon_sync_status
          puts "relay transfer: #{st[0]} (#{st[1] ? "uplink running" : "uplink stopped"})"
        end
        puts "relay: #{config.sync.relay_url}"
        puts "bridge: #{Remote::Sync.bridge_url}" if Remote::Sync.daemon_running?
      else
        STDERR.puts "usage: h2code sync [on|off|code|resync [relay-url]|status]"
        STDERR.puts "       h2code resync [relay-url]   # same as `h2code sync resync`"
        exit 2
      end
    end

    # Start the ACP (Agent Client Protocol) server for IDE integration.
    # Communicates with ACP clients (Zed, JetBrains, Neovim, etc.) over
    # JSON-RPC on stdin/stdout. See `src/acp/` and `plans/ACP-Plan.md`.
    private def self.run_acp(rest_argv : Array(String)) : Nil
      # Handle --login flag (terminal-auth pivot)
      if rest_argv.includes?("--login")
        config = Config::Config.load
        H2code::I18n.init(H2code::I18n.resolve_locale(config.language))
        config.ensure_h2code_home

        unless config.provider_name && config.provider_configured?
          if STDIN.tty?
            run_setup_wizard(config)
          else
            STDERR.puts H2code.t("errors.no_provider")
            exit(2)
          end
        end
        # After login/setup, exit — the IDE will re-invoke without --login
        return
      end

      config = Config::Config.load
      H2code::I18n.init(H2code::I18n.resolve_locale(config.language))
      config.ensure_h2code_home

      # Provider gate
      unless config.provider_name && config.provider_configured?
        STDERR.puts H2code.t("errors.no_provider")
        STDERR.puts ""
        STDERR.puts H2code.t("errors.setup_hint")
        exit(2)
      end

      home = HomePort.home
      oauth_path = File.join(home, ".kimi-code", "credentials", "kimi-code.json")
      oauth = LLM::OAuthCredentials.load(oauth_path)

      server = Acp::Server.new(config, home, oauth)
      server.run
    end

    # the provider choice and credentials, writes them to config.json, then
    # returns so the caller can build the real provider and proceed.
    # Returns true if the wizard completed and wrote a provider to `config`,
    # false if the user aborted (Esc/Ctrl+D). On abort the caller should exit
    # cleanly rather than fall through to `build_provider`, which would raise
    # "No provider configured".
    private def self.run_setup_wizard(config) : Bool
      app = TUI::App.new
      app.work_dir = Dir.current
      app.start_setup
      app.on_setup_complete = ->(wizard : Setup::Wizard) do
        wizard.apply_to(config)
        config.save
        app.provider_name = wizard.provider_name.to_s
        app.model = wizard.model.to_s
        nil
      end

      # The wizard runs in a closed TUI loop without an agent. On completion
      # the on_setup_complete callback fires; we exit the loop by toggling
      # the running flag indirectly via the app's setup_mode.
      spawn do
        # Wait for setup to finish, then stop the loop.
        while app.setup_mode?
          Fiber.yield
        end
        app.stop
      end

      app.run { |_text, _persisted| }

      # If setup_mode is still true, the user aborted before completing.
      !app.setup_mode?
    end

    # Retarget every path-bound tool (and the subagent runners) at a new
    # working directory — the idle-boundary cwd switch behind `/fork` and
    # `/merge`. Only called while the agent is idle, so no in-flight turn
    # observes the change.
    private def self.rebind_path_tools(agent, agent_runner, swarm_runner, new_work_dir : String) : Nil
      {Tools::Names::READ, Tools::Names::WRITE, Tools::Names::EDIT,
       Tools::Names::GLOB, Tools::Names::GREP, Tools::Names::BASH,
       Tools::Names::WAIT_FOR_CI, Tools::Names::APPLY_PATCH}.each do |name|
        agent.tools.get(name).try do |tool|
          tool.work_dir = new_work_dir if tool.responds_to?(:work_dir=)
        end
      end
      agent_runner.try(&.work_dir=(new_work_dir))
      swarm_runner.try(&.work_dir=(new_work_dir))
    end

    private def self.run_interactive(agent, system_prompt, store, config, permission, oauth, home, work_dir, initial_prompt = nil,
                                     agent_runner : Loop::SubagentAgentRunner? = nil,
                                     swarm_runner : Loop::SubagentSwarmRunner? = nil,
                                     task_service : Tools::InMemoryTaskService? = nil,
                                     mcp_manager : Mcp::Manager = Mcp::Manager.new,
                                     plugin_manager : Plugin::Manager = Plugin::Manager.new(home))
      dispatcher = Notify::Dispatcher.from_config(config.notifications)
      # Age-based sandbox GC: drop fully merged, clean sandboxes untouched
      # for two weeks. Unmerged work is never collected. Best-effort — a
      # failure here must not block startup.
      begin
        H2code::Worktree.gc(home)
      rescue
      end
      app = TUI::App.new(dispatcher: dispatcher)
      app.app_config = config
      # Random startup tip (shown under the welcome box) — data-driven, read
      # from tips/*.json next to the config (see H2code::Tips).
      app.startup_tip = H2code::Tips.random_tip(I18n.resolve_locale(config.language)) if config.show_tips?
      # CI-token hint: when the repo is CI-eligible (GitHub Actions workflows
      # + github.com remote, or .gitlab-ci.yml + a GitLab remote) but the
      # matching token is not configured, CI polling runs in its fallback
      # mode (gh CLI on GitHub; anonymous API on GitLab) — show a
      # warning-yellow tip with the token instructions instead.
      if ci_service = Tools::Ci.service.as?(Tools::Ci::LiveCiService)
        case ci_service.repo_info(work_dir).try(&.provider)
        when Tools::Ci::Provider::Gitlab
          if config.gitlab_token.empty?
            app.startup_warning_tip = H2code.t("ui.ci_token_tip_gitlab")
          end
        when Tools::Ci::Provider::Github
          if config.github_token.empty?
            app.startup_warning_tip = H2code.t("ui.ci_token_tip")
          end
        end
      end
      app.model = agent.provider.model_name
      app.provider_name = config.provider_name.to_s
      app.permission_mode = config.permission_mode
      app.max_context_tokens = agent.context.max_context_tokens
      app.home = home
      app.work_dir = work_dir
      app.debug_zones = config.debug_zones?
      # The session expects a /fork sandbox that no longer exists (merged
      # and cleaned elsewhere): run() fell back to the given work dir —
      # say so instead of silently switching directories.
      if (sf = store.read_state.try(&.sandbox_folder)) && !sf.empty? && sf != work_dir
        app.add_message("system",
          "This session's sandbox (#{sf}) no longer exists; continuing in #{work_dir}.")
      end

      # Wire subagent lifecycle events from the runners into the TUI so the
      # swarm progress panel animates live. Each event is routed to
      # app.on_event just like any other Loop event.
      if ar = agent_runner
        ar.event_sink = ->(event : Loop::Event) { app.on_event(event) }
      end
      if sr = swarm_runner
        sr.event_sink = ->(event : Loop::Event) { app.on_event(event) }
      end

      lifecycle = Session::Lifecycle.new(home)

      # `/add-dir` rebuilds the system prompt so the new directory appears in
      # the workspace tree and the agent knows about it. `system_prompt` is the
      # method argument captured by the `app.run` block below; reassigning it
      # here updates what every subsequent turn sees.
      app.on_additional_dirs_change = ->(dirs : Array(String)) do
        catalog = H2code::Tools::Skill.catalog
        listing = catalog.is_a?(H2code::Tools::InMemorySkillCatalog) ? catalog.model_listing : ""
        # Reassigning the captured arg is intentional: other closures capturing
        # `system_prompt` read the new value (closures share it by reference).
        system_prompt = Prompt::SystemPrompt.build(work_dir, dirs, listing, shell: config.shell) # ameba:disable Lint/ShadowedArgument
        nil
      end

      permission.approval_callback = ->(tool_name : String, args : String, danger : String?) do
        app.request_approval(tool_name, args, danger)
      end

      # Wire the AskUserQuestion tool to the TUI's structured question dialog.
      # When the agent calls AskUserQuestion, the QuestionService implementation
      # pushes the questions into the App's dialog and blocks until the user
      # answers. Mirrors TS `reverse-rpc/question-adapter.ts`.
      H2code::Tools::AskUserQuestion.service = AppQuestionService.new(app)

      # Wire the Bash tool's TUI-only bridges onto the instance registered in
      # `run`. terminal_exec routes sudo commands into a real terminal (alt
      # screen + cooked termios) where /dev/tty is available; sudo_approval is
      # the callback invoked under SudoMode::Request to ask the user before
      # running a sudo command (reuses the y/n/s approval panel). The instance
      # is shared with the headless path; these bridges are TUI-only.
      bash_tool = agent.tools.get(Tools::Names::BASH).as(Tools::Bash)
      bash_tool.terminal_exec = AppTerminalExecService.new(app)
      bash_tool.sudo_approval = ->(command : String) do
        app.request_sudo_approval(command)
      end
      app.bash_tool = bash_tool

      # Plan-mode wiring: instantiate the per-session plan service, expose its
      # permission mode, and bridge ExitPlanMode's interactive review to the
      # TUI's PlanReviewDialog. `/plan` toggles the mode through on_plan_mode.
      plan_service = H2code::Tools::AgentPlanService.new(store.session_dir, "main")
      H2code::Tools::PlanMode.plan_service = plan_service
      # Swarm-mode wiring: a fresh in-memory service per interactive session.
      H2code::Tools::SwarmMode.service = H2code::Tools::SwarmModeService.new
      H2code::Tools::PlanMode.permission_mode = H2code::Tools::PermissionModeRef.new(
        auto: permission.mode.auto?)
      H2code::Tools::PlanMode.plan_review_service = AppPlanReviewService.new(app)
      app.on_plan_mode = ->(next_on : Bool) do
        svc = H2code::Tools::PlanMode.plan_service
        return false if svc.nil?
        begin
          # Idempotent: only transition when the desired state differs from
          # the current one, so a stray double-toggle (or a TUI flag that is
          # out of sync with the service) does not raise "Already in plan mode".
          current = !svc.status.nil?
          if next_on && !current
            svc.enter
          elsif !next_on && current
            svc.cancel
          end
          true
        rescue
          false
        end
      end

      # TaskService was already created and assigned in `run` so the headless
      # path shares the same instance; reuse it here for the profilers and the
      # /tasks browser.
      ts = task_service || H2code::Tools::Task.service.as(H2code::Tools::InMemoryTaskService)

      # Wire background-task + cron delivery into the TUI. `deliver_external_prompt`
      # enqueues the message (without a wire-log write) when busy, or starts a
      # fresh turn when idle.
      delivery = ->(text : String) { app.deliver_external_prompt(text) }

      # Attach the TUI delivery callback to the already-registered Bash tool so
      # background-completion notifications land in the active turn. The
      # TaskService/session_dir were wired in `run`.
      bash_tool.delivery = delivery

      # Create + start the cron scheduler. Reconcile any persisted tasks on
      # resume; missed fires are coalesced on the next tick.
      cron_service = H2code::Tools::LiveCronService.new(
        store: store,
        agent: agent,
        delivery: delivery,
        enabled: config.cron_enabled?,
        no_stale: config.cron_no_stale?,
      )
      H2code::Tools::Cron.service = cron_service
      H2code::Tools::InteractiveShell.service = H2code::Tools::InteractiveShellService.new
      ts.mark_lost_on_resume
      cron_service.start

      # Attach TUI delivery + session store to the CI observer service
      # created in the shared setup. `on_update` drives the active-zone
      # "Waiting for CI" lines (one per pending commit) and the per-commit
      # outcome log lines; the delivery callback wakes the agent on
      # failures so it can fix the build.
      ci_svc = H2code::Tools::Ci.service.as?(H2code::Tools::Ci::LiveCiService)
      unless ci_svc.nil?
        ci_svc.delivery = delivery
        ci_svc.store = store
        ci_svc.on_update = ->(obs : H2code::Tools::Ci::Observer) { app.on_ci_update(obs) }
      end

      # Flush cron state + kill background processes on clean exit.
      # Control socket for h2code-remote: lets the remote daemon inject
      # prompts/interrupts into this live TUI session (external input path).
      control_socket = Remote::ControlSocket.new(
        ->(text : String) { app.deliver_external_prompt(text) },
        -> { agent.cancel },
        -> { app.agent_busy? }
      )
      control_socket.rebind(store.session_dir)
      app.on_exit = -> {
        cron_service.stop
        ts.stop_all_on_exit("process exited")
        H2code::Tools::InteractiveShell.service.try(&.stop_all)
        control_socket.close
        mcp_manager.shutdown
        nil
      }

      # `/mcp` panel: surface live connection status from the manager.
      app.on_mcp_status = -> { mcp_manager.status_text }

      # `/mcp update [server]`: force reconnect + refresh cache.
      app.on_mcp_update = ->(server : String?) do
        mcp_manager.update_cache(server)
        nil
      end

      profiler = ProfiledMemory.new
      app.profiler = profiler
      register_profilers(agent, app, permission, ts, system_prompt, profiler)

      app.on_clear = -> { agent.context.clear }
      app.on_undo = -> { agent.context.undo(1) }
      app.on_cancel = -> { agent.cancel }
      app.on_undo_count = ->(count : Int32) do
        agent.context.undo(count)
        nil
      end
      # Build the undo-selector candidate list from user messages in the
      # agent's history. Each choice represents "remove N turns down to
      # and including this user turn".
      app.on_fetch_undo_choices = -> : Array({Int32, String, String})? do
        history = agent.context.history
        choices = [] of {Int32, String, String}
        # Walk history; each user message marks a turn boundary. The count
        # for entry i = messages to drop from the end back to and including
        # that user message.
        history.each_with_index do |cm, idx|
          next unless cm.message.role == "user" && cm.origin.normal?
          input = cm.message.text
          preview = input.empty? ? "(empty)" : input[0...60].gsub('\n', " ")
          count = history.size - idx
          choices << {count, input, "##{idx + 1}: #{preview}"}
        end
        choices.empty? ? nil : choices
      end
      app.on_compact = -> : Nil do
        spawn do
          agent.trigger_compaction_tui(system_prompt) do |event|
            app.on_event(event)
          end
        end
      end
      # Surface automatic wire recovery in the transcript so the user knows
      # the session file vanished externally and was rebuilt from the
      # in-memory journal (otherwise the fix is invisible).
      store.on_wire_recovered = -> {
        app.add_message("system",
          "Session file was deleted externally; restored the full history from the in-memory journal.")
        nil
      }

      app.on_new_session = -> {
        agent.context.clear
        new_store = lifecycle.create(work_dir)
        # A /new started inside a sandbox keeps working there — record the
        # link so a later resume switches into the sandbox as well.
        if H2code::Worktree.worktree?(work_dir)
          if meta = new_store.read_state
            meta.sandbox_folder = work_dir
            new_store.write_state(meta)
          end
        end
        store.adopt(new_store)
        store.ensure_wire
        app.session_id = store.read_state.try(&.id) || ""
        # `/new` — same immediate daemon ping as at TUI startup (see run):
        # the new session must appear in the PWA at once, not on rescan.
        if config.sync.enabled? && !app.session_id.empty?
          Remote::Sync.notify_session_created(app.session_id)
        end
        H2code::Tools::PlanMode.plan_service = H2code::Tools::AgentPlanService.new(store.session_dir, "main")
        # Restart the cron scheduler against the fresh session store.
        cron_service.stop
        new_cron = H2code::Tools::LiveCronService.new(
          store: store,
          agent: agent,
          delivery: delivery,
          enabled: config.cron_enabled?,
          no_stale: config.cron_no_stale?,
        )
        H2code::Tools::Cron.service = new_cron
        new_cron.start
        control_socket.rebind(store.session_dir)
        nil
      }
      app.on_resume_session = ->(path : String) do
        # Resuming the session this h2code already owns would trip the
        # session lock (held by this very process) — treat as a no-op.
        if path.chomp("/") == store.session_dir.chomp("/")
          app.add_message("system", "This session is already open in this h2code.")
        else
          # open_existing! raises FileDeletedError when the picked
          # session's files are gone, and SessionBusyError when another
          # live process owns it — resuming a deleted session would
          # silently create an empty wire log and a second writer would
          # interleave two conversations into one wire. Both errors
          # propagate to the TUI, which reports them; the current session
          # and its context stay untouched.
          resumed = Session::Store.open_existing!(path)
          agent.context.clear
          resumed.replay(agent.context)
          store.adopt(resumed)
          app.session_id = resumed.read_state.try(&.id) || resumed.meta_id? || ""
          app.load_transcript_from(agent.context)
          # Session↔sandbox link: a session that lives in a /fork sandbox
          # resumes inside it; an empty sandbox_folder keeps the current
          # work dir (no switch).
          if (sandbox = resumed.read_state.try(&.sandbox_folder)) && !sandbox.empty?
            if Dir.exists?(sandbox)
              if sandbox != work_dir
                rebind_path_tools(agent, agent_runner, swarm_runner, sandbox)
                app.work_dir = sandbox
                work_dir = sandbox
              end
            else
              app.add_message("system",
                "This session's sandbox (#{sandbox}) no longer exists; continuing in #{work_dir}.")
            end
          end
          H2code::Tools::PlanMode.plan_service = H2code::Tools::AgentPlanService.new(store.session_dir, "main")
          # Restart the cron scheduler against the resumed session store and
          # reconcile persisted task records (mark non-terminal as Lost).
          cron_service.stop
          new_cron = H2code::Tools::LiveCronService.new(
            store: store,
            agent: agent,
            delivery: delivery,
            enabled: config.cron_enabled?,
            no_stale: config.cron_no_stale?,
          )
          H2code::Tools::Cron.service = new_cron
          new_cron.start
          ts.mark_lost_on_resume
          control_socket.rebind(store.session_dir)
        end
        nil
      end
      app.on_fork = -> : Bool do
        session_id = store.meta_id? || app.session_id
        session_id = Random::Secure.hex(12) if session_id.empty?
        result = H2code::Worktree.create(work_dir, session_id, home)
        if error = result.error
          app.add_message("error", H2code.t("ui.fork_failed", error: error))
          false
        elsif (path = result.path) && (branch = result.branch)
          # Fork the conversation into the sandbox: the fresh session's cwd
          # is the sandbox dir, so a later resume lands there as well.
          forked = lifecycle.fork(store, cwd: path)
          store.adopt(forked)
          app.session_id = forked.read_state.try(&.id) || ""
          # Persist the session↔sandbox link: resume switches back into the
          # sandbox only when sandbox_folder is set.
          if meta = forked.read_state
            meta.sandbox_folder = path
            forked.write_state(meta)
          end
          rebind_path_tools(agent, agent_runner, swarm_runner, path)
          app.work_dir = path
          work_dir = path
          control_socket.rebind(store.session_dir)
          app.add_message("system", H2code.t("ui.fork_created", branch: branch, path: path))
          true
        else
          app.add_message("error", H2code.t("ui.fork_failed", error: "inconsistent create result"))
          false
        end
      end
      app.on_worktree_exit = ->(repo : String) do
        # /merge finished: retarget the tools and the session back at the
        # original checkout. The sandbox link is cleared — the session no
        # longer lives in a sandbox, so resume must not switch.
        rebind_path_tools(agent, agent_runner, swarm_runner, repo)
        app.work_dir = repo
        work_dir = repo
        if meta = store.read_state
          meta.cwd = repo
          meta.sandbox_folder = ""
          meta.updated_at = Time.utc.to_rfc3339
          store.write_state(meta)
        end
        nil
      end
      app.on_fork_go = ->(path : String) do
        # /fork go: retarget the tools and the session at an existing fork
        # sandbox (same plumbing as on_worktree_exit) and record the link.
        rebind_path_tools(agent, agent_runner, swarm_runner, path)
        app.work_dir = path
        work_dir = path
        if meta = store.read_state
          meta.cwd = path
          meta.sandbox_folder = path
          meta.updated_at = Time.utc.to_rfc3339
          store.write_state(meta)
        end
        nil
      end
      app.on_archive = -> {
        id = store.read_state.try(&.id) || store.meta_id? || File.basename(store.session_dir)
        lifecycle.archive(id)
      }
      app.on_rename = ->(title : String) do
        id = store.read_state.try(&.id) || store.meta_id? || File.basename(store.session_dir)
        entry = lifecycle.index.get(id)
        if entry
          lifecycle.rename(entry, title)
        else
          # Fallback: write state directly when the index has not indexed it yet.
          meta = store.read_state || Session::StateMeta.new(id)
          meta.title = title
          store.write_state(meta)
        end
      end
      app.on_export = ->(path : String) {
        export_session(agent.context, path)
      }
      app.on_provider_change = ->(name : String) : Bool do
        begin
          provider = build_named_provider(name, config, oauth)
          configure_provider(provider, config, store.meta_id?)
          agent.swap_provider!(provider)
          Tools::WebSearch.service = build_web_search_service(config, provider)
          config.provider_name = name
          config.save
          mcp_manager.reconcile(name)
          app.model = provider.model_name
          true
        rescue ex : ProviderConfigError
          app.add_message("error", H2code.t("errors.provider_switch_failed", message: ex.message.to_s))
          false
        rescue ex
          app.add_message("error", H2code.t("errors.provider_switch_failed", message: ex.message.to_s))
          false
        end
      end

      app.on_model_change = ->(model : String) : Bool do
        begin
          case config.provider_name
          when "moonshot"
            config.model = model
          when "zai"
            config.zai_model = model
          when "zai-coding-plan"
            config.zai_coding_plan_model = model
          when "ollama"
            config.ollama_model = model
          when "lmstudio"
            config.lmstudio_model = model
          end
          provider = build_named_provider(config.provider_name, config, oauth)
          configure_provider(provider, config, store.meta_id?)
          agent.swap_provider!(provider)
          Tools::WebSearch.service = build_web_search_service(config, provider)
          config.save
          true
        rescue ex : ProviderConfigError
          app.add_message("error", H2code.t("errors.model_switch_failed", message: ex.message.to_s))
          false
        rescue ex
          app.add_message("error", H2code.t("errors.model_switch_failed", message: ex.message.to_s))
          false
        end
      end

      app.on_fetch_models = -> : Array(String) do
        agent.provider.fetch_models
      end

      # Whether the named provider already has credentials configured. The TUI
      # uses this to decide whether /provider can switch directly or must run
      # the setup wizard first.
      app.on_provider_configured = ->(name : String) : Bool do
        config.provider_configured?(name)
      end

      # Fetch the live model list for an arbitrary provider name. Used by the
      # setup wizard's Model step to show a real selector instead of a text
      # input. Builds a throwaway provider so the running agent is untouched.
      app.on_fetch_models_for = ->(name : String) : Array(String) do
        provider = build_named_provider(name, config, oauth)
        provider.fetch_models
      end

      # Runtime setup-wizard completion (vs the first-run path wired in
      # `run_setup_wizard`). Applies the collected values, rebuilds the agent's
      # provider, and persists the config.
      app.on_setup_complete = ->(wizard : Setup::Wizard) do
        wizard.apply_to(config)
        config.save
        # A yolo answer in the wizard also flips the live manager + TUI state
        # so the running session picks it up without a restart.
        if wizard.yolo?
          permission.mode = Permission::Mode::Yolo
          H2code::Tools::PlanMode.permission_mode.try(&.auto = false)
          app.permission_mode = "yolo"
        end
        begin
          provider = build_named_provider(wizard.provider_name, config, oauth)
          configure_provider(provider, config, store.meta_id?)
          agent.swap_provider!(provider)
          mcp_manager.reconcile(wizard.provider_name.to_s)
          app.model = provider.model_name
        rescue ex : ProviderConfigError
          app.add_message("error", H2code.t("errors.provider_switch_failed", message: ex.message.to_s))
        end
        nil
      end

      # Expose the TodoList tool's state to the TUI so it can render a
      # progress panel above the editor. Returns nil if the tool isn't
      # registered (no TodoList in this agent) or the list is empty.
      app.on_fetch_todos = -> : Array({String, String})? do
        todo_tool = agent.tools.get(Tools::Names::TODO_LIST)
        return nil unless t = todo_tool.as?(H2code::Tools::TodoList)
        todos = t.todos
        return nil if todos.empty?
        todos.map { |todo| {todo.title, todo.status.to_s.downcase} }
      end
      app.on_clear_todos = -> : Nil do
        todo_tool = agent.tools.get(Tools::Names::TODO_LIST)
        return nil unless t = todo_tool.as?(H2code::Tools::TodoList)
        # clear! (not `todos.clear`) so the cleared state is persisted and a
        # restart / --resume doesn't resurrect the old list from todo.json.
        t.clear!
        nil
      end

      # `/export-debug-zip` reads wire.jsonl/state.json from the session dir.
      app.on_session_dir = -> : String? do
        dir = store.session_dir
        dir.empty? ? nil : dir
      end

      # `/tasks` browser: pull the current task list from the service,
      # stop a task, open its full output.
      app.on_fetch_tasks = -> : Array(H2code::Tools::AgentTaskInfo) do
        task_service.list(active_only: false, limit: 100)
      end
      app.on_stop_task = ->(task_id : String) do
        task_service.stop_by_user(task_id)
        nil
      end
      app.on_open_task_output = ->(task_id : String) do
        snapshot = task_service.get_output_snapshot(task_id, 8192)
        preview = snapshot.preview
        # Surface the output inline as a system message so the user can read
        # it without leaving the transcript.
        app.add_message("system", "#{H2code.t("info.output_of", task_id: task_id)}\n#{preview}")
        nil
      end
      # `/logout` clears the configured API keys and re-saves config.json.
      app.on_logout = -> : Nil do
        config.api_key = ""
        config.zai_api_key = ""
        config.save
        nil
      end

      login_cb = Proc(Nil).new do
        spawn do
          begin
            cred_path = File.join(home, ".kimi-code", "credentials", "kimi-code.json")
            creds = Auth::OAuth.login(credentials_path: cred_path) do |auth|
              app.on_event(Loop::Event.info(H2code.t("info.open_auth_url", url: auth.verification_uri_complete)))
              app.on_event(Loop::Event.info(H2code.t("info.user_code", code: auth.user_code)))
            end
            # Rebuild the provider with fresh credentials so the next turn uses
            # them without a restart.
            provider = LLM::MoonshotProvider.new(
              model: config.model || "kimi-for-coding",
              endpoint: config.endpoint || LLM::MoonshotProvider::DEFAULT_ENDPOINT,
              oauth: creds,
              api_key: "",
              temperature: config.temperature,
            )
            agent.swap_provider!(provider)
            app.on_event(Loop::Event.info(H2code.t("info.login_success", path: cred_path)))
          rescue ex : Auth::OAuth::OAuthError
            app.on_event(Loop::Event.error(H2code.t("errors.login_failed", message: ex.message.to_s)))
          rescue ex
            app.on_event(Loop::Event.error(H2code.t("errors.login_error", message: ex.message.to_s)))
          end
        end
      end
      app.on_login = login_cb

      # Thinking-effort selector (off/low/medium/high/...). Backed by the
      # provider's `thinking_effort` property; setting it persists into the
      # next chat request via `build_request`.
      app.on_get_effort = -> : String do
        agent.provider.thinking_effort || "off"
      end
      app.on_set_effort = ->(effort : String) do
        normalized = case effort.downcase
                     when "off", "none", "0" then nil
                     else                         effort.downcase
                     end
        agent.provider.thinking_effort = normalized
        nil
      end

      app.on_get_language = -> : String do
        config.language || H2code::I18n.resolve_locale
      end
      app.on_language_change = ->(lang : String) do
        config.language = lang
        config.save
        nil
      end
      # `/sudo`: persist the app-wide sudo mode so it survives restarts and
      # applies to every chat (main agent, subagents, ACP).
      app.on_sudo_mode_change = ->(mode : String) do
        config.sudo_mode = mode if mode.in?("off", "request", "always")
        config.save
        nil
      end
      # Permission-mode switches (/yolo on|off, /permission, /auto, /manual):
      # flip the live manager and the plan-mode reference, and persist the
      # default so every future launch starts in the chosen mode (e.g. yolo
      # with no CLI flags).
      app.on_permission_mode_change = ->(mode : String) do
        if mode.in?("manual", "auto", "yolo")
          permission.mode = Permission::Mode.parse(mode)
          H2code::Tools::PlanMode.permission_mode.try(&.auto = permission.mode.auto?)
          config.permission_mode = mode
          config.save
        end
        nil
      end
      app.on_debug_zones_change = ->(on : Bool) do
        config.debug_zones = on
        config.save
        nil
      end

      # Steer: inject the text into the running turn's context so the model
      # sees it on its next step. Mirrors `session.steer(text)` in TS.
      app.on_steer = ->(text : String) do
        agent.steer(text)
        nil
      end

      # Persist queued / steered messages to the wire log so the queue
      # survives a resume. Wire type distinguishes the two flows.
      app.on_persist_queued = ->(wire_type : String, text : String) do
        store.append_simple(wire_type, "prompt", text)
        nil
      end

      app.on_debug = -> : Nil do
        app.restore_terminal
        render_debug_transcript(store)
        exit(0)
      end

      # read_state covers the v2 layout (state.json); meta_id? is the
      # legacy flat-layout fallback. meta.json alone misses fresh v2
      # sessions, which left the welcome box showing "new" all session.
      app.session_id = store.read_state.try(&.id) || store.meta_id? || ""

      # Plugin session-start: inject skill text into context on the first
      # turn of a new or resumed session (mirrors TS PluginSessionStartInjector).
      session_starts = plugin_manager.enabled_session_starts
      unless session_starts.empty?
        catalog = H2code::Tools::Skill.catalog
        Plugin::SessionStartInjector.render(session_starts, catalog, agent.context)
      end

      # Plugin slash commands: register them so `/<plugin_id>:<command>` dispatches.
      plugin_commands = plugin_manager.enabled_commands
      unless plugin_commands.empty?
        app.plugin_commands = plugin_commands
      end

      # `/plugins` subcommand handler — all plugin management operations.
      app.on_plugins_command = ->(raw_args : String) do
        handle_plugins_subcommand(plugin_manager, raw_args)
      end

      # Background update check (non-blocking): runs in a fiber so the TUI
      # starts immediately. Respects a 24h cache — most startups are a no-op.
      # If a newer version exists, surfaces it as a system message.
      spawn do
        if msg = H2code::Upgrader.background_check
          app.add_message("system", msg)
          app.dirty!
        end
      end

      app.run(initial_prompt: initial_prompt) do |prompt_text, persisted, parts|
        store.append_simple("turn.prompt", "prompt", prompt_text) unless persisted

        # tool_call_id → tool_name, populated by tool_call_start and consumed
        # by tool_result so the --ram log can show which tool ran. Lives one
        # turn at a time; cleared at turn end.
        pending_tool_names = {} of String => String

        begin
          agent.run_goal_turn(prompt_text, system_prompt, parts: parts) do |event|
            case event.type
            when .text_delta?
              app.on_event(Loop::Event.text_delta(event.text))
            when .thinking_delta?
              app.on_event(event)
            when .assistant_text?
              data = {"content" => JSON::Any.new(event.text)} of String => JSON::Any
              if (t = event.thinking) && !t.empty?
                data["thinking"] = JSON::Any.new(t)
              end
              store.append("assistant.text", data)
              app.on_event(event)
            when .tool_call_start?
              store.append("tool.call", {
                "tool_call_id" => JSON::Any.new(event.tool_call_id),
                "tool_name"    => JSON::Any.new(event.tool_name),
                "arguments"    => JSON::Any.new(event.tool_args),
              })
              pending_tool_names[event.tool_call_id] = event.tool_name
              app.on_event(event)
            when .tool_result?
              store.append("tool.result", {
                "tool_call_id" => JSON::Any.new(event.tool_call_id),
                "content"      => JSON::Any.new(event.text),
              })
              # Resolve tool name from the event itself (Event.tool_result
              # does not carry it; the prior tool_call_start had it).
              tname = pending_tool_names.delete(event.tool_call_id) || "Tool"
              # Attach the RAM line so the TUI renders it inside the tool
              # block rather than as a separate info message.
              event.ram_line = CLI.ram_tracer.line(tname, event.text.bytesize, event.is_error?)
              app.on_event(event)
              # Keep the TUI's plan-mode flag in sync with the service: the
              # model can toggle it directly via EnterPlanMode/ExitPlanMode,
              # bypassing toggle_plan_mode, which would otherwise leave the
              # input-frame tint and placeholder stale.
              if svc = H2code::Tools::PlanMode.plan_service
                app.plan_mode = !svc.status.nil?
              end
            when .step_begin?, .step_end?, .info?, .error?, .turn_end?,
                 .compaction_started?, .compaction_completed?, .compaction_cancelled?
              app.on_event(event)
              app.context_percent = agent.context.token_usage_percent
              app.context_tokens = agent.context.token_count
            end
          end

          app.context_percent = agent.context.token_usage_percent
          app.context_tokens = agent.context.token_count
        rescue ex : Loop::UserCancellationError
          agent.context.add_user("Interrupted by user")
          app.show_interrupted
        rescue ex : Loop::NetworkFailureError
          app.show_interrupted(ex.message.to_s)
        rescue ex
          ExceptionHandler.report(ex, "interactive turn")
          app.on_event(Loop::Event.error(ex.message.to_s))
        end
      end
    end

    # Register the long-lived growing collections with the memory profiler.
    # Each closure captures an owner that is already alive for the whole
    # process, so no extra GC pressure is introduced. `/memory` walks these
    # on demand to report current consumption.
    private def self.register_profilers(agent : Loop::Agent, app : TUI::App,
                                        permission : Permission::Manager,
                                        task_service : Tools::InMemoryTaskService,
                                        system_prompt : String,
                                        profiler : ProfiledMemory) : Nil
      ctx_mem = agent.context
      perm_mgr = permission
      dedup = agent.dedup
      tools = agent.tools
      profiler.register("context:history", "context history",
        calc: -> { ctx_mem.profiled_bytes }, count: -> { ctx_mem.profiled_count })
      profiler.register("tui:messages", "TUI transcript",
        calc: -> { app.profiled_bytes }, count: -> { app.profiled_count })
      profiler.register("tui:render_buf", "render buffer",
        calc: -> { app.render_buffer_bytes }, count: -> { app.render_buffer_count })
      profiler.register("tui:queue", "queued messages",
        calc: -> { app.queue_bytes }, count: -> { app.queue_count })
      profiler.register("perm:approvals", "session approvals",
        calc: -> { perm_mgr.profiled_bytes }, count: -> { perm_mgr.profiled_count })
      profiler.register("tasks", "background tasks",
        calc: -> { task_service.profiled_bytes }, count: -> { task_service.profiled_count })
      profiler.register("dedup:history", "dedup tracker",
        calc: -> { dedup.profiled_bytes }, count: -> { dedup.profiled_count })
      profiler.register("tools:registry", "tool registry",
        calc: -> { tools.profiled_bytes }, count: -> { tools.profiled_count })
      profiler.register("tui:width_cache", "width cache",
        calc: -> { TUI::CharWidth.cache_bytes }, count: -> { TUI::CharWidth.cache_count })
      unless system_prompt.empty?
        sp = system_prompt
        profiler.register("system_prompt", "system prompt",
          calc: -> { sp.profiled_bytes })
      end
      todo_tool = tools.get(Tools::Names::TODO_LIST)
      register_todo_profiler(todo_tool, profiler) if todo_tool.is_a?(Tools::TodoList)
      register_cron_profiler(profiler)
      register_skill_profiler(profiler)
    end

    private def self.register_todo_profiler(todo : Tools::TodoList, profiler : ProfiledMemory) : Nil
      profiler.register("todos", "todo list",
        calc: -> { todo.profiled_bytes },
        count: -> { todo.profiled_count })
    end

    private def self.register_cron_profiler(profiler : ProfiledMemory) : Nil
      service = Tools::Cron.service
      return unless service.is_a?(Tools::InMemoryCronService)
      profiler.register("cron:tasks", "cron tasks",
        calc: -> { service.profiled_bytes },
        count: -> { service.profiled_count })
    end

    private def self.register_skill_profiler(profiler : ProfiledMemory) : Nil
      catalog = Tools::Skill.catalog
      return unless catalog.is_a?(Tools::InMemorySkillCatalog)
      profiler.register("skills:catalog", "skill catalog",
        calc: -> { catalog.profiled_bytes },
        count: -> { catalog.profiled_count })
    end

    private def self.export_session(memory, path : String) : Nil
      content = String.build do |s|
        s << "# Session Export\n\n"
        memory.messages.each do |msg|
          case msg.role
          when "user"
            s << "## User\n\n#{msg.text}\n\n"
          when "assistant"
            s << "## Assistant\n\n#{msg.text}\n\n"
          when "tool"
            s << "### Tool: #{msg.tool_calls.try(&.first).try(&.name) || "??"}\n\n"
            s << "```\n#{msg.text}\n```\n\n"
          end
        end
      end
      File.write(path, content)
    end

    private def self.handle_plugins_subcommand(plugin_manager : Plugin::Manager, raw_args : String) : String
      parts = raw_args.split(/\s+/, 2)
      sub = parts[0]? || ""
      rest = parts[1]? || ""

      case sub
      when "", "list"
        render_plugins_list(plugin_manager)
      when "install"
        if rest.empty?
          "Usage: /plugins install <path-or-url>"
        else
          begin
            record = plugin_manager.install(rest.strip)
            "Installed plugin \"#{record.display_name}\" (#{record.id}) v#{record.version || "?"}.\n" \
            "Run /reload or /new to activate."
          rescue ex
            "Install failed: #{ex.message}"
          end
        end
      when "info"
        id = rest.strip
        return "Usage: /plugins info <id>" if id.empty?
        render_plugin_info(plugin_manager, id)
      when "enable"
        begin
          plugin_manager.set_enabled(rest.strip, true)
          "Plugin \"#{rest.strip}\" enabled. Run /reload or /new to activate."
        rescue ex
          ex.message.to_s
        end
      when "disable"
        begin
          plugin_manager.set_enabled(rest.strip, false)
          "Plugin \"#{rest.strip}\" disabled. Run /reload or /new to activate."
        rescue ex
          ex.message.to_s
        end
      when "remove"
        begin
          plugin_manager.remove(rest.strip)
          "Plugin \"#{rest.strip}\" removed. Run /reload or /new to apply."
        rescue ex
          ex.message.to_s
        end
      when "reload"
        summary = plugin_manager.reload
        msg = String.build do |s|
          s << "Reloaded #{plugin_manager.list.size} plugin(s)."
          s << "\nAdded: #{summary.added.join(", ")}" unless summary.added.empty?
          s << "\nRemoved: #{summary.removed.join(", ")}" unless summary.removed.empty?
          summary.errors.each { |e| s << "\nError [#{e[:id]}]: #{e[:message]}" }
        end
        msg
      when "mcp"
        handle_plugins_mcp(plugin_manager, rest)
      else
        # Try matching a plugin id for info
        if plugin_manager.installed?(sub)
          render_plugin_info(plugin_manager, sub)
        else
          "Unknown subcommand: #{sub}\n" \
          "Usage: /plugins [list|install|info|enable|disable|remove|reload|mcp]"
        end
      end
    end

    private def self.handle_plugins_mcp(plugin_manager : Plugin::Manager, rest : String) : String
      parts = rest.split(/\s+/)
      action = parts[0]? || ""
      plugin_id = parts[1]? || ""
      server = parts[2]? || ""

      case action
      when "enable", "disable"
        return "Usage: /plugins mcp #{action} <plugin-id> <server>" if plugin_id.empty? || server.empty?
        begin
          plugin_manager.set_mcp_server_enabled(plugin_id, server, action == "enable")
          "MCP server \"#{server}\" #{action}d for plugin \"#{plugin_id}\". Run /reload or /new to apply."
        rescue ex
          ex.message.to_s
        end
      else
        "Usage: /plugins mcp <enable|disable> <plugin-id> <server>"
      end
    end

    private def self.render_plugins_list(plugin_manager : Plugin::Manager) : String
      plugins = plugin_manager.list
      return "No plugins installed." if plugins.empty?

      String.build do |s|
        s << "Installed plugins (#{plugins.size}):\n"
        plugins.each do |r|
          status = r.enabled? ? (r.ok? ? "enabled" : "error") : "disabled"
          s << "  #{r.id} (#{r.display_name}"
          s << " v#{r.version}" if r.version
          s << ") [#{status}]"
          s << " — #{r.skill_count} skill(s), #{r.mcp_server_count} MCP, #{r.hook_count} hook(s), #{r.command_count} cmd(s)"
          s << '\n'
          if r.has_errors?
            r.diagnostics.select(&.severity.error?).each { |d| s << "    ! #{d.message}\n" }
          end
        end
        s << "\nUsage: /plugins install <path-or-url> | /plugins info <id> | /plugins enable|disable <id>"
      end
    end

    private def self.render_plugin_info(plugin_manager : Plugin::Manager, id : String) : String
      record = plugin_manager.get(id)
      return "Plugin \"#{id}\" is not installed." unless record

      String.build do |s|
        s << "Plugin: #{record.display_name} (#{record.id})\n"
        s << "Version: #{record.version || "unknown"}\n"
        s << "Source: #{record.source}\n"
        s << "State: #{record.ok? ? "ok" : "error"} (#{record.enabled? ? "enabled" : "disabled"})\n"
        s << "Root: #{record.root}\n"
        s << "Installed: #{record.installed_at}\n"
        s << "Updated: #{record.updated_at}\n" if record.updated_at

        if m = record.manifest
          s << "\nSkills (#{m.skills.size}):\n"
          m.skills.each { |path| s << "  #{path}\n" }

          unless m.mcp_servers.empty?
            s << "\nMCP servers (#{m.mcp_servers.size}):\n"
            m.mcp_servers.each do |srv_name, cfg|
              caps = record.capabilities
              enabled = caps.try(&.mcp_servers[srv_name]?).try(&.enabled?) || cfg.enabled?
              s << "  #{srv_name} [#{enabled ? "enabled" : "disabled"}] — #{cfg.stdio? ? cfg.command : cfg.url}\n"
            end
          end

          unless m.hooks.empty?
            s << "\nHooks (#{m.hooks.size}):\n"
            m.hooks.each { |h| s << "  #{h.event}: #{h.command}\n" }
          end

          unless m.commands.empty?
            s << "\nCommands (#{m.commands.size}):\n"
            m.commands.each { |c| s << "  /#{record.id}:#{c.name}\n" }
          end

          if ss = m.session_start
            s << "\nSession start skill: #{ss.skill}\n"
          end
        end

        unless record.diagnostics.empty?
          s << "\nDiagnostics:\n"
          record.diagnostics.each { |d| s << "  [#{d.severity}] #{d.message}\n" }
        end
      end
    end

    private def self.render_tool_block(name : String, args : String, output : String, is_error : Bool) : Nil
      display = output
      exit_code = -1
      # Bash embeds a non-zero exit as "[exit code: N]"; lift it out so we can
      # render it as a dedicated red footer instead of raw text.
      if m = display.match(/(?:\n)?\[exit code: (\d+)\]\s*\z/)
        exit_code = m[1]?.try(&.to_i?) || -1
        display = display.sub(/(?:\n)?\[exit code: \d+\]\s*\z/, "")
      end
      failed = is_error || exit_code > 0

      marker = failed ? "✗".colorize.fore(C_ERROR) : "●".colorize.fore(C_SUCCESS)
      label_c = failed ? C_ERROR : C_PRIMARY
      header = name == Tools::Names::BASH ? "Ran a command" : name
      puts " #{marker} #{header.colorize.fore(label_c).bold}"

      parsed = args.empty? ? nil : begin
        JSON.parse(args)
      rescue JSON::ParseException
        nil
      end
      echo_tool_args(name, parsed)

      trimmed = display.strip
      unless trimmed.empty?
        out_c = failed ? C_ERROR : C_MUTED
        trimmed.each_line do |line|
          puts "   #{line.colorize.fore(out_c)}"
        end
      end

      if failed
        msg = exit_code > 0 ? "   Command failed with exit code: #{exit_code}." : "   Command failed."
        puts msg.colorize.fore(C_ERROR)
      end
      puts
    end

    private def self.render_debug_transcript(store) : Nil
      events = store.read_events
      puts "=== Debug transcript: #{store.session_dir} ==="
      puts

      pending_calls = {} of String => {String, String}

      events.each do |event|
        case event[:type]
        when "turn.prompt", "turn.steer"
          if prompt = event[:data]["prompt"]?.try(&.as_s?)
            puts "User: #{prompt}"
            puts
          end
        when "assistant.text"
          if content = event[:data]["content"]?.try(&.as_s?)
            puts content
            puts
          end
        when "tool.call"
          id = event[:data]["tool_call_id"]?.try(&.as_s?) || ""
          name = event[:data]["tool_name"]?.try(&.as_s?) || "Tool"
          args = event[:data]["arguments"]?.try(&.as_s?) || "{}"
          pending_calls[id] = {name, args}
        when "tool.result"
          id = event[:data]["tool_call_id"]?.try(&.as_s?) || ""
          content = event[:data]["content"]?.try(&.as_s?) || ""
          name, args = pending_calls.delete(id) || {"Tool", ""}
          render_tool_block(name, args, content, false)
        end
      end
    end

    private def self.echo_tool_args(name : String, parsed : JSON::Any?) : Nil
      return if parsed.nil?
      case name
      when Tools::Names::BASH
        if cmd = parsed["command"]?.try(&.as_s?)
          puts "   #{"$ ".colorize.fore(C_SHELL)}#{cmd.colorize.fore(C_DIM).dim}"
        end
      when Tools::Names::READ, Tools::Names::WRITE, Tools::Names::EDIT
        if path = (parsed["path"]? || parsed["filePath"]?).try(&.as_s?)
          puts "   file: #{path}".colorize.fore(C_DIM).dim
        end
      when Tools::Names::GLOB
        if pat = parsed["pattern"]?.try(&.as_s?)
          puts "   pattern: #{pat}".colorize.fore(C_DIM).dim
        end
      when Tools::Names::GREP
        if pat = parsed["pattern"]?.try(&.as_s?)
          puts "   search: #{pat}".colorize.fore(C_DIM).dim
        end
      end
    end

    private def self.print_usage : Nil
      puts <<-USAGE
        H2Code #{VERSION} — lighter than air AI agent

        Usage:
          h2code -p "your prompt here" [options]

        Options:
          -p, --prompt <text>     Prompt to send to the agent
          -d, --work-dir <path>   Working directory (default: current)
          -c, --continue          Resume the most recent session
          -m, --model <name>      Model name (default: kimi-for-coding)
          -s, --session <id>      Resume session by ID
          --permission <mode>     manual | auto | yolo
          --yolo                  Auto-approve all tool calls
          --auto                  Auto-approve safe operations
          --hi                    Smoke test: send "hi" to the API and report
          --ram                   Print RSS after every tool call (debug memory growth)
          -v, --version           Show version
          -h, --help              Show this help

          (no -p flag)            Interactive TUI mode
                                  Type / for slash commands

        Commands:
          h2code sync [on|off|code|resync|status]   Cloud sync management
              sync                     Show current pairing QR (same as `sync code`)
              sync on                  Enable sync, connect daemon to relay, show pairing QR
              sync off                 Disable sync, drop daemon's relay connection
              sync code                Show current pairing QR
              sync resync [relay-url]  New pairing code + QR (e.g. for a new relay)
              sync status              Show sync status
          h2code resync [relay-url]                Shortcut for `h2code sync resync`
          h2code acp                                ACP server for IDE integration

        Environment:
          MOONSHOT_API_KEY        API key for Moonshot
          MOONSHOT_ENDPOINT       API endpoint (default: https://api.kimi.com/coding/v1)
          MOONSHOT_MODEL          Default model name
          H2CODE_PROVIDER          Provider: #{LLM::Provider.providers.map(&.name).join(" | ")}
          H2CODE_HOME              Config directory (default: ~/.h2code)
          HTTP_PROXY              HTTP/HTTPS proxy URL
          ALL_PROXY               SOCKS proxy URL
          H2CODE_DEBUG             Show backtraces on error
        USAGE
    end
  end

  # Bridge AskUserQuestion tool → TUI QuestionDialog. When the tool calls
  # `QuestionService#request`, this spawns a fiber that pushes the questions
  # into the App's dialog, waits for the user's answer on a channel, and
  # returns it. Mirrors TS `reverse-rpc/question-adapter.ts`.
  class AppQuestionService < Tools::QuestionService
    def initialize(@app : TUI::App)
    end

    def request(req : Tools::QuestionRequest, signal : ::H2code::Loop::AbortController?) : Tools::QuestionResult?
      # Capacity 1: the dialog's callback runs synchronously inside
      # handle_input, so a rendezvous channel would deadlock (send waits
      # for receive, receive can't start until handle_input returns).
      result_chan = Channel(Tools::QuestionResult).new(1)

      spawn do
        answers = @app.request_questions(req.questions)
        result_chan.send(answers)
      end

      # Block this turn fiber until the user answers. The agent loop's abort
      # signal is handled separately by the tool layer; here we just wait.
      result_chan.receive
    end
  end

  # Bridge ExitPlanMode tool → TUI PlanReviewDialog. When the tool calls
  # `PlanReviewService#request` in manual / yolo permission mode, this pushes
  # the finalized plan into the App's review dialog and blocks until the user
  # decides (Approve / Revise / Reject & Exit / Cancel).
  class AppPlanReviewService < Tools::PlanReviewService
    def initialize(@app : TUI::App)
    end

    def request(plan : String, path : String?,
                options : Array(Tools::PlanOption)?) : Tools::PlanReviewResult?
      @app.request_plan_review(plan, path, options)
    end
  end

  # Bridge Bash tool → real terminal for sudo commands. Switches to alt
  # screen + cooked termios so the child process (and sudo's /dev/tty
  # password read) works naturally, while relaying piped output to the
  # terminal in real time AND capturing it for the ToolResult.
  class AppTerminalExecService < Tools::TerminalExecService
    def initialize(@app : TUI::App)
    end

    def run(command : String, cwd : String?,
            env : Hash(String, String?), timeout_s : Int32?,
            aborted? : -> Bool) : Tools::TerminalExecResult
      terminal = @app.terminal

      # Headless fallback: no alt screen / termios dance. Just pipe + capture
      # (same as the normal Bash path — sudo will fail without /dev/tty).
      unless terminal.tty?
        return run_headless(command, cwd, env, timeout_s, aborted?)
      end

      # Terminal path: alt screen + cooked termios + pipe + relay + capture.
      @app.terminal_exec_active = true
      print TUI::ANSI.alt_screen_on
      print "\e[H"  # cursor to row 1, col 1
      print "\e[2J" # clear the alt screen
      terminal.restore!

      # Print a header so the user sees what's running before output starts.
      warning = @app.theme.colors.warning
      dim = @app.theme.colors.dim
      STDOUT.puts "#{TUI::ANSI.color(warning, nil)}#{TUI::ANSI.bold}● Running command#{TUI::ANSI.reset}"
      STDOUT.puts "#{TUI::ANSI.color(dim, nil)}  $ #{command}#{TUI::ANSI.reset}"
      STDOUT.puts
      STDOUT.flush

      output = ""
      begin
        process = Process.new(
          command,
          shell: true,
          env: env,
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe,
          chdir: cwd,
        )
        process.input.close

        # Tee fibers: relay pipe → real terminal (STDOUT/STDERR) AND capture
        # into IO::Memory for the ToolResult.
        stdout_mem = IO::Memory.new
        stderr_mem = IO::Memory.new
        done_out = Channel(Nil).new
        done_err = Channel(Nil).new

        spawn do
          tee_capture(process.output, STDOUT, stdout_mem)
          done_out.send(nil)
        end

        spawn do
          tee_capture(process.error, STDERR, stderr_mem)
          done_err.send(nil)
        end

        status, timed_out, was_aborted = Tools::Tool.wait_for_exit(process, timeout_s, aborted?)

        # Wait for tee fibers to finish draining the pipes.
        done_out.receive
        done_err.receive

        output = combine_output(stdout_mem.to_s, stderr_mem.to_s)

        Tools::TerminalExecResult.new(output, status.exit_code, timed_out, was_aborted)
      rescue ex : File::NotFoundError
        Tools::TerminalExecResult.new("Failed to execute command: shell not found", 127)
      rescue ex : IO::Error
        Tools::TerminalExecResult.new("Failed to execute command: #{ex.message}", 1)
      rescue ex
        Tools::TerminalExecResult.new("Unexpected error: #{ex.message}", 1)
      ensure
        terminal.raw!
        print TUI::ANSI.alt_screen_off
        @app.terminal_exec_active = false
        @app.force_redraw!
      end
    end

    private def run_headless(command : String, cwd : String?,
                             env : Hash(String, String?), timeout_s : Int32?,
                             aborted? : -> Bool) : Tools::TerminalExecResult
      process = Process.new(
        command,
        shell: true,
        env: env,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe,
        chdir: cwd,
      )
      process.input.close

      stdout_ch = Channel(String).new
      stderr_ch = Channel(String).new

      spawn { stdout_ch.send(capture_only(process.output)) }
      spawn { stderr_ch.send(capture_only(process.error)) }

      status, timed_out, was_aborted = Tools::Tool.wait_for_exit(process, timeout_s, aborted?)

      out_str = stdout_ch.receive
      err_str = stderr_ch.receive
      output = combine_output(out_str, err_str)

      Tools::TerminalExecResult.new(output, status.exit_code, timed_out, was_aborted)
    end

    # Read from src, write to both dest (real terminal) and mem (capture).
    # Caps at MAX_OUTPUT_BYTES in the capture; excess is relayed but discarded.
    private def tee_capture(src : IO, dest : IO, mem : IO::Memory) : Nil
      buf = Bytes.new(8192)
      total = 0
      begin
        loop do
          read = src.read(buf)
          break if read == 0
          dest.write(buf[0, read])
          dest.flush
          remaining = Tools::Bash::MAX_OUTPUT_BYTES - total
          if read > remaining
            mem.write(buf[0, remaining]) if remaining > 0
            # Drain the rest so the child does not block on a full pipe.
            loop { break if src.read(buf) == 0 }
            break
          end
          mem.write(buf[0, read])
          total += read
        end
      rescue IO::Error
        # Process killed or stream closed — return what we have.
      end
    end

    private def capture_only(io : IO) : String
      mem = IO::Memory.new
      buf = Bytes.new(8192)
      total = 0
      begin
        loop do
          read = io.read(buf)
          break if read == 0
          remaining = Tools::Bash::MAX_OUTPUT_BYTES - total
          if read > remaining
            mem.write(buf[0, remaining]) if remaining > 0
            loop { break if io.read(buf) == 0 }
            break
          end
          mem.write(buf[0, read])
          total += read
        end
      rescue IO::Error
      end
      mem.to_s
    end

    private def combine_output(out_str : String, err_str : String) : String
      String.build do |s|
        s << out_str unless out_str.empty?
        unless err_str.empty?
          s << "\n" unless out_str.empty?
          s << err_str
        end
      end
    end
  end
end

H2code::CLI.run(ARGV) unless ARGV.includes?("--no-cli-run")
