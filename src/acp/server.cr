require "json"
require "../config/config"
require "../llm/provider"
require "../llm/types"
require "../context/memory"
require "../tools/registry"
require "../tools/names"
require "../permission/manager"
require "../session/store"
require "../session/index"
require "../session/lifecycle"
require "../loop/agent"
require "../loop/subagent_registry"
require "../loop/subagent_agent_runner"
require "../loop/subagent_swarm_runner"
require "../tools/task"
require "../hooks/engine"
require "../prompt/system_prompt"
require "../mcp/manager"
require "../mcp/config"
require "./json_rpc"
require "./session"
require "./approval"
require "./plan_review"
require "./question"
require "./event_translator"

module H2code
  module Acp
    # ACP protocol version information.
    PROTOCOL_VERSION = 1
    SPEC_TAG         = "v0.10.x"
    AGENT_NAME       = "H2Code"
    AGENT_VERSION    = H2code::VERSION

    # Main ACP server orchestrator. Owns the JSON-RPC frame, dispatches ACP
    # methods, and manages per-session state.
    class Server
      getter rpc : JsonRpc
      getter config : Config::Config
      getter home : String
      getter oauth : LLM::OAuthCredentials?

      @sessions = {} of String => Acp::Session
      @sessions_lock = Mutex.new
      @negotiated = false

      def initialize(@config : Config::Config, @home : String,
                     @oauth : LLM::OAuthCredentials?)
        @rpc = JsonRpc.new
      end

      def run : Nil
        {% if flag?(:unix) %}
          Signal::INT.trap { @rpc.close }
          Signal::TERM.trap { @rpc.close }
        {% end %}

        @rpc.run do |msg|
          spawn(name: "acp-dispatch") { dispatch(msg) }
        end

        # Shutdown: close all sessions
        @sessions_lock.synchronize do
          @sessions.each_value(&.cancel)
        end
      rescue ex
        STDERR.puts "[acp] server error: #{ex}"
        exit(1)
      end

      # --- Dispatch ---

      private def dispatch(msg : JSON::Any) : Nil
        method = msg["method"]?.try(&.to_s)
        return unless method

        id = msg["id"]?
        id_int = id.try(&.as_i?) || id.try(&.as_i64?).try(&.to_i)

        params = msg["params"]? || JSON.parse("{}")

        case method
        when "initialize"
          handle_initialize(id_int, params)
        when "authenticate"
          handle_authenticate(id_int, params)
        when "session/new"
          handle_session_new(id_int, params)
        when "session/load"
          handle_session_load(id_int, params)
        when "session/resume"
          handle_session_resume(id_int, params)
        when "session/prompt"
          handle_session_prompt(id_int, params)
        when "session/cancel"
          handle_session_cancel(id_int, params)
        when "session/list"
          handle_session_list(id_int, params)
        when "session/set_mode"
          handle_set_mode(id_int, params)
        when "session/set_config_option"
          handle_set_config_option(id_int, params)
        when "session/set_model", "unstable_setSessionModel"
          handle_set_model(id_int, params)
        else
          if id_int
            @rpc.send_error(id_int, ErrorCodes::METHOD_NOT_FOUND,
              "Method not found: #{method}")
          else
            @rpc.log_notification_error(method, "unknown method")
          end
        end
      rescue ex
        STDERR.puts "[acp] dispatch error for '#{method}': #{ex}"
        if id_int
          @rpc.send_error(id_int, ErrorCodes::INTERNAL_ERROR,
            "Internal error", JSON::Any.new(ex.message.to_s))
        end
      end

      # --- initialize ---

      private def handle_initialize(id : Int32?, params : JSON::Any) : Nil
        @negotiated = true

        response = {
          "protocolVersion"   => JSON::Any.new(PROTOCOL_VERSION.to_i64),
          "agentCapabilities" => JSON.parse(%({
            "loadSession": true,
            "promptCapabilities": {
              "image": true,
              "audio": false,
              "embeddedContext": true
            },
            "mcpCapabilities": {
              "http": true,
              "sse": true
            },
            "sessionCapabilities": {
              "list": {}
            }
          })),
          "authMethods" => JSON.parse(%([
            {"id":"login","type":"terminal","name":"Login with H2Code account","args":["--login"]}
          ])),
          "agentInfo" => JSON.parse(%({
            "name": #{AGENT_NAME.to_json},
            "version": #{AGENT_VERSION.to_json}
          })),
        } of String => JSON::Any

        @rpc.send_response(id, response) if id
      end

      # --- authenticate ---

      private def handle_authenticate(id : Int32?, params : JSON::Any) : Nil
        method_id = params["methodId"]?.try(&.to_s) || ""

        unless method_id == "login"
          @rpc.send_error(id, ErrorCodes::INVALID_PARAMS,
            "Unknown auth method: #{method_id}") if id
          return
        end

        unless authed?
          @rpc.send_error(id, ErrorCodes::AUTH_REQUIRED,
            "Authentication required") if id
          return
        end

        @rpc.send_response(id, JSON.parse("{}")) if id
      end

      # --- session/new ---

      private def handle_session_new(id : Int32?, params : JSON::Any) : Nil
        unless authed?
          @rpc.send_error(id, ErrorCodes::AUTH_REQUIRED,
            "Authentication required") if id
          return
        end

        cwd = params["cwd"]?.try(&.to_s) || Dir.current

        # Convert ACP mcpServers (from IDE config) to H2Code format
        mcp_servers = convert_mcp_servers(params["mcpServers"]?)

        # Build per-session infrastructure — the store generates its own ID,
        # which we use as the ACP session ID so session/load can find it.
        acp_session, session_id = build_session_with_id(cwd, mcp_servers)

        @sessions_lock.synchronize { @sessions[session_id] = acp_session }

        config_options = build_config_options(acp_session)
        response = %({"sessionId":#{session_id.to_json},"configOptions":#{config_options.to_json}})

        @rpc.send_response(id, JSON.parse(response)) if id

        # Push slash-command palette to the IDE
        push_available_commands(session_id)
      end

      # --- session/load ---

      private def handle_session_load(id : Int32?, params : JSON::Any) : Nil
        unless authed?
          @rpc.send_error(id, ErrorCodes::AUTH_REQUIRED,
            "Authentication required") if id
          return
        end

        session_id = params["sessionId"]?.try(&.to_s) || ""

        lifecycle = H2code::Session::Lifecycle.new(@home)
        entry = lifecycle.index.get(session_id)

        unless entry
          @rpc.send_error(id, ErrorCodes::INVALID_PARAMS,
            "Unknown sessionId: #{session_id}") if id
          return
        end

        cwd = entry.cwd.empty? ? Dir.current : entry.cwd
        # Already loaded in this child: reuse it. Rebuilding would try to
        # take a session lock this process already holds (SessionBusyError
        # — flock conflicts even within one process) and would leak the
        # previous session's runtime.
        if existing = lookup_session(session_id)
          config_options = build_config_options(existing)
          response = {"configOptions" => config_options} of String => JSON::Any
          @rpc.send_response(id, response) if id
          push_available_commands(session_id)
          return
        end
        # The index scan above found the entry, but the files can be gone
        # by the time we open them; report instead of resurrecting an
        # empty session that would lose everything on the next save.
        acp_session = begin
          build_session_from_existing(session_id, entry.path, cwd)
        rescue H2code::Session::FileDeletedError
          @rpc.send_error(id, ErrorCodes::INVALID_PARAMS,
            "Session files were deleted: #{session_id}") if id
          return
        rescue ex : H2code::Session::SessionBusyError
          # Session owned by another live process (e.g. a TUI) — a second
          # writer would interleave two conversations into one wire log.
          @rpc.send_error(id, ErrorCodes::SESSION_BUSY, ex.message.to_s) if id
          return
        end
        @sessions_lock.synchronize { @sessions[session_id] = acp_session }

        # Replay history
        acp_session.replay_history

        config_options = build_config_options(acp_session)
        response = {"configOptions" => config_options} of String => JSON::Any

        @rpc.send_response(id, response) if id
        push_available_commands(session_id)
      end

      # --- session/resume ---

      private def handle_session_resume(id : Int32?, params : JSON::Any) : Nil
        unless authed?
          @rpc.send_error(id, ErrorCodes::AUTH_REQUIRED,
            "Authentication required") if id
          return
        end

        session_id = params["sessionId"]?.try(&.to_s) || ""

        lifecycle = H2code::Session::Lifecycle.new(@home)
        entry = lifecycle.index.get(session_id)

        unless entry
          @rpc.send_error(id, ErrorCodes::INVALID_PARAMS,
            "Unknown sessionId: #{session_id}") if id
          return
        end

        cwd = entry.cwd.empty? ? Dir.current : entry.cwd
        # Already loaded in this child: reuse it (rebuilding would try to
        # take a session lock this process already holds — see
        # handle_session_load).
        if existing = lookup_session(session_id)
          config_options = build_config_options(existing)
          response = {"configOptions" => config_options} of String => JSON::Any
          @rpc.send_response(id, response) if id
          push_available_commands(session_id)
          return
        end
        # The index scan above found the entry, but the files can be gone
        # by the time we open them; report instead of resurrecting an
        # empty session that would lose everything on the next save.
        acp_session = begin
          build_session_from_existing(session_id, entry.path, cwd)
        rescue H2code::Session::FileDeletedError
          @rpc.send_error(id, ErrorCodes::INVALID_PARAMS,
            "Session files were deleted: #{session_id}") if id
          return
        rescue ex : H2code::Session::SessionBusyError
          # Session owned by another live process (e.g. a TUI) — a second
          # writer would interleave two conversations into one wire log.
          @rpc.send_error(id, ErrorCodes::SESSION_BUSY, ex.message.to_s) if id
          return
        end

        @sessions_lock.synchronize { @sessions[session_id] = acp_session }

        config_options = build_config_options(acp_session)
        response = {"configOptions" => config_options} of String => JSON::Any

        @rpc.send_response(id, response) if id
        push_available_commands(session_id)
      end

      # --- session/prompt ---

      private def handle_session_prompt(id : Int32?, params : JSON::Any) : Nil
        session_id = params["sessionId"]?.try(&.to_s) || ""
        acp_session = lookup_session(session_id)

        unless acp_session
          @rpc.send_error(id, ErrorCodes::INVALID_PARAMS,
            "Unknown sessionId: #{session_id}") if id
          return
        end

        # Convert ACP content blocks to prompt text
        prompt_text = convert_prompt(params["prompt"]?)

        # Run the prompt (blocks until turn completes)
        result = acp_session.prompt(prompt_text)

        @rpc.send_response(id, result) if id
      end

      # --- session/cancel ---

      private def handle_session_cancel(id : Int32?, params : JSON::Any) : Nil
        session_id = params["sessionId"]?.try(&.to_s) || ""
        acp_session = lookup_session(session_id)

        unless acp_session
          # Notifications can't return errors — log only
          @rpc.log_notification_error("session/cancel",
            "Unknown sessionId: #{session_id}")
          return
        end

        acp_session.cancel
      end

      # --- session/list ---

      private def handle_session_list(id : Int32?, params : JSON::Any) : Nil
        # `cwd` is an optional filter per the ACP spec: without it every
        # workspace is listed (remote clients use this to populate their
        # workspace/folder picker from the full session history).
        cwd = params["cwd"]?.try(&.to_s).presence
        lifecycle = H2code::Session::Lifecycle.new(@home)

        entries = cwd ? lifecycle.index.list(H2code::Session::Index.workspace_id(cwd)) : lifecycle.index.list

        sessions = [] of JSON::Any
        entries.each do |entry|
          # state.json title is rarely set (the TUI does not write one) —
          # fall back to the first user prompt (preview, sanitized) so
          # remote clients (hibechat) get a meaningful session name.
          title = entry.title.presence || entry.preview.presence
          updated_str = nil
          begin
            updated_str = entry.updated_at.to_rfc3339
          rescue
            nil
          end

          info = JSON.parse(%({
            "id": #{entry.id.to_json},
            "cwd": #{entry.cwd.to_json},
            "title": #{title ? title.to_json : "null"},
            "updatedAt": #{updated_str ? updated_str.to_json : "null"}
          }))
          sessions << info
        end

        response = %({"sessions":#{sessions.to_json},"nextCursor":null})
        @rpc.send_response(id, JSON.parse(response)) if id
      end

      # --- session/set_mode ---

      private def handle_set_mode(id : Int32?, params : JSON::Any) : Nil
        session_id = params["sessionId"]?.try(&.to_s) || ""
        mode_id = params["modeId"]?.try(&.to_s) || "default"
        acp_session = lookup_session(session_id)

        unless acp_session
          @rpc.send_error(id, ErrorCodes::INVALID_PARAMS,
            "Unknown sessionId: #{session_id}") if id
          return
        end

        unless Modes.valid?(mode_id)
          @rpc.send_error(id, ErrorCodes::INVALID_PARAMS,
            "Unknown modeId: #{mode_id}") if id
          return
        end

        _, perm = Modes.to_toggles(mode_id)
        acp_session.agent.permission.mode = perm

        # Push config option update
        push_config_update(acp_session)

        @rpc.send_response(id, JSON.parse("{}")) if id
      end

      # --- session/set_config_option ---

      private def handle_set_config_option(id : Int32?, params : JSON::Any) : Nil
        session_id = params["sessionId"]?.try(&.to_s) || ""
        config_id = params["configId"]?.try(&.to_s) || ""
        value = params["value"]?
        acp_session = lookup_session(session_id)

        unless acp_session
          @rpc.send_error(id, ErrorCodes::INVALID_PARAMS,
            "Unknown sessionId: #{session_id}") if id
          return
        end

        case config_id
        when "mode"
          mode_id = value.try(&.to_s) || "default"
          unless Modes.valid?(mode_id)
            @rpc.send_error(id, ErrorCodes::INVALID_PARAMS,
              "Unknown modeId: #{mode_id}") if id
            return
          end
          _, perm = Modes.to_toggles(mode_id)
          acp_session.agent.permission.mode = perm
        when "model"
          # Model swap per session — deferred (provider swap requires rebuild)
          STDERR.puts "[acp] model swap not yet implemented"
        when "thinking"
          # Thinking toggle — deferred (requires provider effort mapping)
          STDERR.puts "[acp] thinking toggle not yet implemented"
        else
          @rpc.send_error(id, ErrorCodes::INVALID_PARAMS,
            "Unknown configId: #{config_id}") if id
          return
        end

        push_config_update(acp_session)
        config_options = build_config_options(acp_session)
        @rpc.send_response(id, {"configOptions" => config_options} of String => JSON::Any) if id
      end

      # --- session/set_model ---

      private def handle_set_model(id : Int32?, params : JSON::Any) : Nil
        session_id = params["sessionId"]?.try(&.to_s) || ""
        model_id = params["modelId"]?.try(&.to_s) || ""
        acp_session = lookup_session(session_id)

        unless acp_session
          @rpc.send_error(id, ErrorCodes::INVALID_PARAMS,
            "Unknown sessionId: #{session_id}") if id
          return
        end

        STDERR.puts "[acp] model swap not yet implemented (requested: #{model_id})"

        push_config_update(acp_session)
        @rpc.send_response(id, JSON.parse("{}")) if id
      end

      # --- Session builders ---

      private def build_session_with_id(cwd : String,
                                        mcp_servers : Array(Mcp::McpServerConfig) = [] of Mcp::McpServerConfig) : {Acp::Session, String}
        lifecycle = H2code::Session::Lifecycle.new(@home)
        store = lifecycle.create(cwd)
        session_id = store.read_state.try(&.id) || store.meta_id? || Random::Secure.hex(12)
        {build_session_common(session_id, store, cwd, mcp_servers), session_id}
      end

      private def build_session_from_existing(session_id : String,
                                              session_dir : String,
                                              cwd : String,
                                              mcp_servers : Array(Mcp::McpServerConfig) = [] of Mcp::McpServerConfig) : Acp::Session
        # open_existing! takes the session lock: a session owned by
        # another live process (e.g. an interactive TUI) must not be
        # resumed here — two writers on one wire.jsonl corrupt it.
        store = H2code::Session::Store.open_existing!(session_dir)
        build_session_common(session_id, store, cwd, mcp_servers)
      end

      private def build_session_common(session_id : String, store : H2code::Session::Store,
                                       cwd : String,
                                       mcp_servers : Array(Mcp::McpServerConfig) = [] of Mcp::McpServerConfig) : Acp::Session
        # Build provider for this session
        provider = CLI.build_named_provider(@config.provider_name, @config, @oauth)
        sid = store.read_state.try(&.id) || store.meta_id? || session_id
        CLI.configure_provider(provider, @config, sid)

        # Build memory
        memory = Context::Memory.new
        memory.max_context_tokens = @config.max_context_tokens

        # Build tools
        tools = build_tools(cwd, memory)

        # Connect configured MCP servers (config + IDE-provided via ACP)
        all_mcp = @config.mcp_servers + mcp_servers
        unless all_mcp.empty?
          mcp_manager = Mcp::Manager.new(@home)
          mcp_manager.register_from_cache(all_mcp, tools,
            active_provider: @config.provider_name, blocking: false)
        end

        # Build permission with ACP approval callback
        permission = Permission::Manager.new(
          Permission::Mode.parse(@config.permission_mode))

        # Build agent
        agent = Loop::Agent.new(provider, memory, tools, permission)

        # Build system prompt
        system_prompt = Prompt::SystemPrompt.build(cwd,
          additional_dirs: [] of String,
          skills_listing: "",
          shell: @config.shell)

        # Create the ACP session wrapper
        acp_session = Acp::Session.new(session_id, agent, store, @rpc, system_prompt)

        # Wire subagent runtimes (mirrors wire_subagent_runners in h2code.cr):
        # without this Agent/AgentSwarm fail with "no subagent runtime is
        # registered" and TaskList/TaskOutput/TaskStop have no backing
        # service. Same globals caveat as PlanMode above: with several
        # concurrent ACP sessions the last one created wins.
        task_service = Tools::InMemoryTaskService.new(store)
        Tools::Task.service = task_service
        registry = Loop::SubagentRegistry.new
        permission_mode = Permission::Mode.parse(@config.permission_mode)
        Tools::Agent.runner = Loop::SubagentAgentRunner.new(
          registry: registry,
          parent_agent: agent,
          task_service: task_service,
          system_prompt: system_prompt,
          work_dir: cwd,
          permission_mode: permission_mode,
          subagent_timeout_ms: @config.subagent_timeout_ms,
        )
        Tools::AgentSwarm.runner = Loop::SubagentSwarmRunner.new(
          registry: registry,
          parent_agent: agent,
          system_prompt: system_prompt,
          work_dir: cwd,
          permission_mode: permission_mode,
          subagent_timeout_ms: @config.subagent_timeout_ms,
        )
        Tools::Agent.background_enabled = true

        # Wire the permission callback to use reverse-RPC
        handler = ApprovalHandler.new(@rpc, session_id)
        permission.approval_callback = handler.callback

        # Plan-mode wiring (mirrors the TUI path in h2code.cr): per-session
        # plan service + interactive review over reverse-RPC to the client.
        # NOTE: Tools::PlanMode holds GLOBAL class properties — with several
        # concurrent ACP sessions the last one created wins. Acceptable for
        # the daemon's one-chat-at-a-time usage; same simplification as the
        # TUI's AskUserQuestion.service.
        H2code::Tools::PlanMode.plan_service = H2code::Tools::AgentPlanService.new(store.session_dir, "main")
        H2code::Tools::PlanMode.permission_mode = H2code::Tools::PermissionModeRef.new(
          auto: permission.mode.auto?)
        H2code::Tools::PlanMode.plan_review_service = PlanReviewHandler.new(@rpc, session_id)
        # AskUserQuestion over the same reverse-RPC channel (`session/
        # request_question`): without a QuestionService the tool fails with
        # "connected client does not support interactive questions".
        H2code::Tools::AskUserQuestion.service = QuestionHandler.new(@rpc, session_id)

        acp_session
      end

      private def build_tools(work_dir : String, memory : Context::Memory) : Tools::Registry
        tools = Tools::Registry.new
        # App-wide sudo mode from config (mirrors the TUI `/sudo` setting).
        Tools::Bash.default_sudo_mode = Tools::Bash::SudoMode.parse?(@config.sudo_mode) || Tools::Bash::SudoMode::Off
        tools.register(Tools::Bash.new(work_dir))
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
        tools.register(Tools::WebSearch.new)
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
        tools.register(Tools::ReadMediaFile.new)
        tools.register(Tools::SelectTools.new)
        tools.register(Tools::CurrentTime.new)
        tools.register(Tools::GetContextRemaining.new(memory))
        tools
      end

      # --- Helpers ---

      private def lookup_session(session_id : String) : Acp::Session?
        @sessions_lock.synchronize { @sessions[session_id]? }
      end

      private def authed? : Bool
        !!(@config.provider_name && @config.provider_configured?)
      end

      # Convert ACP mcpServers (from IDE config) to H2Code McpServerConfig entries.
      # ACP format: { name: { type?, command?, args?, env?, url?, headers? } }
      # type absent → stdio; "http" → http; "sse" → sse; "acp" → dropped.
      private def convert_mcp_servers(servers : JSON::Any?) : Array(Mcp::McpServerConfig)
        return [] of Mcp::McpServerConfig unless servers
        return [] of Mcp::McpServerConfig unless servers.as_h?

        result = [] of Mcp::McpServerConfig
        servers.as_h.each do |name, config|
          type = config["type"]?.try(&.to_s) || "stdio"

          case type
          when "stdio"
            command = config["command"]?.try(&.to_s) || ""
            args = config["args"]?.try(&.as_a?).try(&.map(&.to_s)) || [] of String
            env = parse_string_map(config["env"]?)
            result << Mcp::McpServerConfig.new(name: name.to_s, command: command,
              args: args, env: env, type: "stdio")
          when "http"
            url = config["url"]?.try(&.to_s) || ""
            headers = parse_string_map(config["headers"]?)
            result << Mcp::McpServerConfig.new(name: name.to_s, type: "http",
              url: url, headers: headers)
          when "sse"
            url = config["url"]?.try(&.to_s) || ""
            headers = parse_string_map(config["headers"]?)
            result << Mcp::McpServerConfig.new(name: name.to_s, type: "sse",
              url: url, headers: headers)
          else
            STDERR.puts "[acp] dropping unsupported MCP server transport: #{name} (#{type})"
          end
        end
        result
      end

      # Parse Array({name, value}) or Hash(String, String) → Hash(String, String)
      private def parse_string_map(val : JSON::Any?) : Hash(String, String)
        return {} of String => String unless val
        if h = val.as_h?
          result = {} of String => String
          h.each { |k, v| result[k] = v.to_s }
          return result
        end
        if a = val.as_a?
          result = {} of String => String
          a.each do |entry|
            name = entry["name"]?.try(&.to_s)
            value = entry["value"]?.try(&.to_s)
            result[name] = value if name && value
          end
          return result
        end
        {} of String => String
      end

      private def convert_prompt(prompt : JSON::Any?) : String
        return "" unless prompt
        return prompt.to_s if prompt.as_s?

        # Array of content blocks
        parts = [] of String
        if arr = prompt.as_a?
          arr.each do |block|
            case block["type"]?.try(&.to_s)
            when "text"
              parts << block["text"]?.try(&.to_s).to_s
            when "image"
              # Image support deferred — note for future
              nil
            when "resource"
              if text = block["text"]?
                uri = block["uri"]?.try(&.to_s) || ""
                parts << "<resource uri=\"#{uri}\">#{text}</resource>"
              end
            when "resource_link"
              uri = block["uri"]?.try(&.to_s) || ""
              if uri.starts_with?("file:")
                parts << "[file: #{uri}]"
              else
                parts << "<resource_link uri=\"#{uri}\"/>"
              end
            end
          end
        end
        parts.join("\n")
      end

      private def build_config_options(session : Acp::Session) : JSON::Any
        current_model = session.agent.provider.model_name
        current_mode = Modes.from_permission(session.agent.permission.mode)

        model_values = [JSON.parse(%({"value":#{current_model.to_json},"label":#{current_model.to_json}}))]
        mode_values = Modes::ACP_MODES.map do |m|
          JSON.parse(%({"value":#{m.to_json},"label":#{m.capitalize.to_json}}))
        end

        options = [
          JSON.parse(%({
            "configId": "model",
            "label": "Model",
            "type": "select",
            "currentValue": #{current_model.to_json},
            "values": #{model_values.to_json}
          })),
          JSON.parse(%({
            "configId": "mode",
            "label": "Mode",
            "type": "select",
            "currentValue": #{current_mode.to_json},
            "values": #{mode_values.to_json}
          })),
        ]

        JSON::Any.new(options)
      end

      private def push_config_update(session : Acp::Session) : Nil
        options = build_config_options(session)
        update = JSON.parse(%({"kind":"config_option_update","configOptions":#{options.to_json}}))
        @rpc.send_notification("session/update",
          EventTranslator.session_update(session.id, update))
      rescue ex
        STDERR.puts "[acp] config update error: #{ex}"
      end

      # Push the slash-command palette to the IDE after session creation.
      private def push_available_commands(session_id : String) : Nil
        commands = JSON.parse(%([
          {"name":"/compact","description":"Compact context"},
          {"name":"/status","description":"Show session status"},
          {"name":"/usage","description":"Show token usage"},
          {"name":"/mcp","description":"Show MCP server status"},
          {"name":"/tasks","description":"Show background tasks"},
          {"name":"/help","description":"Show available commands"}
        ]))

        update = JSON.parse(%({"kind":"available_commands_update","commands":#{commands.to_json}}))
        @rpc.send_notification("session/update",
          EventTranslator.session_update(session_id, update))
      rescue ex
        STDERR.puts "[acp] available_commands error: #{ex}"
      end
    end

    # ACP permission mode taxonomy.
    module Modes
      ACP_MODES = ["default", "plan", "auto", "yolo"]

      def self.valid?(mode_id : String) : Bool
        ACP_MODES.includes?(mode_id)
      end

      # Map ACP mode → {plan, permission}
      def self.to_toggles(mode_id : String) : {Bool, Permission::Mode}
        case mode_id
        when "default" then {false, Permission::Mode::Manual}
        when "plan"    then {true, Permission::Mode::Manual}
        when "auto"    then {false, Permission::Mode::Auto}
        when "yolo"    then {false, Permission::Mode::Yolo}
        else                {false, Permission::Mode::Manual}
        end
      end

      # Reverse map: permission mode → ACP mode id
      def self.from_permission(mode : Permission::Mode) : String
        case mode
        in Permission::Mode::Manual then "default"
        in Permission::Mode::Auto   then "auto"
        in Permission::Mode::Yolo   then "yolo"
        end
      end
    end
  end
end
