require "json"
require "../loop/agent"
require "../loop/events"
require "../session/store"
require "../permission/manager"
require "./json_rpc"
require "./event_translator"

module H2code
  module Acp
    # Per-session wrapper: owns a `Loop::Agent` + `Session::Store`, translates
    # streaming events into ACP `session/update` notifications, and bridges
    # permission approvals via reverse-RPC to the IDE.
    class Session
      getter id : String
      getter agent : Loop::Agent
      getter store : H2code::Session::Store
      getter rpc : JsonRpc
      getter system_prompt : String
      getter current_turn_id : Int32 = 0

      @turn_counter = Atomic(Int32).new(0)
      @prompt_result : Channel(JSON::Any)?
      @tool_args_accumulator = {} of String => String
      @started_tool_calls = Set(String).new
      @cancelled = false
      # Serializes agent turns: a client `session/prompt` and self-started
      # external-prompt turns (CI failure notifications) never interleave.
      @turn_mutex = Mutex.new
      # Advisory busy flag — true while a turn (plus its follow-up drain)
      # runs; external deliveries check it to decide between queueing and
      # self-starting a turn.
      @busy = false
      # External prompts queued while a turn runs (CI completion
      # notifications), drained as follow-up turns when it ends.
      @external_queue = [] of String
      @external_lock = Mutex.new
      # `<notification id="...">` payloads already delivered — a racing
      # source firing twice must notify exactly once.
      @delivered_notification_ids = Set(String).new

      def initialize(@id : String, @agent : Loop::Agent, @store : H2code::Session::Store,
                     @rpc : JsonRpc, @system_prompt : String)
      end

      # Run a prompt turn. Streams `session/update` notifications and returns
      # a `PromptResponse`-shaped JSON::Any when done.
      def prompt(text : String) : JSON::Any
        # Blank prompts are rejected by the chat API (400) — answer locally
        # instead of starting a turn that can only fail.
        if text.strip.empty?
          update = EventTranslator.assistant_delta(@id, "Silence — nothing recognized; message ignored.")
          emit_update(update)
          return build_prompt_response("end_turn")
        end

        # Check for slash commands
        if text.starts_with?('/')
          return handle_slash_command(text)
        end

        @cancelled = false

        result_channel = Channel(JSON::Any).new
        @prompt_result = result_channel

        spawn(name: "acp-prompt-#{@id}") do
          @turn_mutex.synchronize do
            @busy = true
            begin
              run_turn(text)
              drain_external_prompts
              # Turn completed normally
              stop = @cancelled ? "cancelled" : "end_turn"
              result_channel.send(build_prompt_response(stop)) unless result_channel.closed?
            rescue ex : Loop::UserCancellationError
              @cancelled = true
              result_channel.send(build_prompt_response("cancelled")) unless result_channel.closed?
            rescue ex : Loop::NetworkFailureError
              STDERR.puts "[acp] network error in session #{@id}: #{ex.message}"
              result_channel.send(build_prompt_response("end_turn")) unless result_channel.closed?
            rescue ex
              STDERR.puts "[acp] error in session #{@id}: #{ex}"
              ex.backtrace.each { |b| STDERR.puts "  #{b}" } if ENV["H2CODE_DEBUG"]?
              result_channel.send(build_prompt_response("end_turn")) unless result_channel.closed?
            ensure
              @busy = false
            end
          end
        end

        result_channel.receive
      end

      # External prompt injection (CI completion notifications; the ACP
      # mirror of the TUI's `App#deliver_external_prompt`). While a turn
      # runs, texts queue up and are drained as follow-up turns when it
      # ends — a build failing mid-turn delivers its failure-log excerpt to
      # the model right away, in the same response stream. While idle, a
      # fresh turn starts on its own so a failed build wakes the agent
      # without the client sending anything. Notification payloads carrying
      # an id (the `<notification id="...">` XML envelope or the plain-text
      # `[notification id="..."]` marker line) are deduplicated by id.
      def deliver_external_prompt(text : String) : Nil
        return if text.strip.empty?
        @external_lock.synchronize do
          if id = notification_id(text)
            return if @delivered_notification_ids.includes?(id)
            @delivered_notification_ids << id
          end
          @external_queue << text
        end
        return if @busy
        spawn(name: "acp-external-#{@id}") do
          @turn_mutex.synchronize do
            @busy = true
            begin
              drain_external_prompts
            rescue ex
              STDERR.puts "[acp] external prompt error in session #{@id}: #{ex}"
            ensure
              @busy = false
            end
          end
        end
      end

      # Id of a notification payload — the `<notification id="...">` XML
      # attribute or the plain-text `[notification id="..."]` marker line
      # (must stay in sync with the TUI's TurnController).
      private def notification_id(text : String) : String?
        text.match(/<notification\s+id="([^"]*)"/).try(&.[1]) ||
          text.match(/\[notification\s+id="([^"]*)"\]/).try(&.[1])
      end

      # One agent turn: persist the prompt, bump the turn id and stream the
      # agent's events as `session/update` notifications.
      private def run_turn(text : String) : Nil
        @store.append_simple("turn.prompt", "prompt", text)
        @current_turn_id = @turn_counter.add(1)
        @tool_args_accumulator.clear
        @started_tool_calls.clear
        @agent.run_goal_turn(text, @system_prompt) do |event|
          handle_event(event)
        end
      end

      # Follow-up turns for external prompts queued while a turn ran (CI
      # failure logs etc.): they run inside the caller's turn mutex before
      # the PromptResponse goes out, so the model receives them right after
      # the current turn instead of fetching the logs itself.
      private def drain_external_prompts : Nil
        loop do
          break if @cancelled
          text = @external_lock.synchronize { @external_queue.shift? }
          break if text.nil?
          run_turn(text)
        end
      end

      # Cancel the current turn.
      def cancel : Nil
        @cancelled = true
        @agent.cancel
      rescue ex
        STDERR.puts "[acp] cancel error: #{ex}"
      end

      # Replay conversation history from the wire log.
      # Emits `session/update` notifications for each historical message.
      def replay_history : Nil
        events = @store.read_events
        synthetic_turn = 0
        tool_turn_map = {} of String => Int32

        events.each do |evt|
          case evt[:type]
          when "turn.prompt"
            next if evt[:data]["prompt"]?.try(&.to_s).try(&.empty?)
            text = evt[:data]["prompt"]?.try(&.to_s) || ""
            update = EventTranslator.user_message(@id, text)
            emit_update(update)
          when "assistant.text"
            synthetic_turn += 1
            content = evt[:data]["content"]?.try(&.to_s) || ""
            unless content.empty?
              update = EventTranslator.assistant_delta(@id, content)
              emit_update(update)
            end
            # Replay thinking if present
            if thinking = evt[:data]["thinking"]?.try(&.to_s)
              unless thinking.empty?
                update = EventTranslator.thinking_delta(@id, thinking)
                emit_update(update)
              end
            end
          when "tool.call"
            synthetic_turn += 1
            tc_id = evt[:data]["tool_call_id"]?.try(&.to_s) || ""
            tc_name = evt[:data]["tool_name"]?.try(&.to_s) || "tool"
            args = evt[:data]["arguments"]?.try(&.to_s) || ""
            tool_turn_map[tc_id] = synthetic_turn
            update = EventTranslator.tool_call_start(@id, synthetic_turn, tc_id, tc_name, args)
            emit_update(update)
          when "tool.result"
            tc_id = evt[:data]["tool_call_id"]?.try(&.to_s) || ""
            content = evt[:data]["content"]?.try(&.to_s) || ""
            tid = tool_turn_map[tc_id]? || synthetic_turn
            update = EventTranslator.tool_result(@id, tid, tc_id, content, false)
            emit_update(update)
          end
        end
      rescue ex
        STDERR.puts "[acp] replay error: #{ex}"
      end

      # --- Event handling ---

      private def handle_event(event : Loop::Event) : Nil
        case event.type
        when .text_delta?
          update = EventTranslator.assistant_delta(@id, event.text)
          emit_update(update)
        when .thinking_delta?
          update = EventTranslator.thinking_delta(@id, event.text)
          emit_update(update)
        when .tool_call_start?
          @tool_args_accumulator[event.tool_call_id] = event.tool_args
          @started_tool_calls << event.tool_call_id

          update = EventTranslator.tool_call_start(@id, @current_turn_id,
            event.tool_call_id, event.tool_name, event.tool_args)
          emit_update(update)

          # Persist to wire log
          @store.append("tool.call", {
            "tool_call_id" => JSON::Any.new(event.tool_call_id),
            "tool_name"    => JSON::Any.new(event.tool_name),
            "arguments"    => JSON::Any.new(event.tool_args),
          })
        when .tool_call_delta?
          # Accumulate args
          prev = @tool_args_accumulator[event.tool_call_id]? || ""
          @tool_args_accumulator[event.tool_call_id] = prev + event.tool_args

          update = EventTranslator.tool_call_delta(@id, @current_turn_id,
            event.tool_call_id, @tool_args_accumulator[event.tool_call_id])
          emit_update(update)
        when .tool_result?
          update = EventTranslator.tool_result(@id, @current_turn_id,
            event.tool_call_id, event.text, event.is_error?)
          emit_update(update)

          # Persist to wire log
          @store.append("tool.result", {
            "tool_call_id" => JSON::Any.new(event.tool_call_id),
            "content"      => JSON::Any.new(event.text),
          })
        when .assistant_text?
          # This is the finalized checkpoint — persist to wire log
          data = {"content" => JSON::Any.new(event.text)} of String => JSON::Any
          if (t = event.thinking) && !t.empty?
            data["thinking"] = JSON::Any.new(t)
          end
          @store.append("assistant.text", data)
        when .info?
          # Info messages as lightweight agent_message_chunk
          update = EventTranslator.info_message(@id, event.text)
          emit_update(update)
        when .error?
          STDERR.puts "[acp] agent error: #{event.text}"
        when .exception?
          STDERR.puts "[acp] agent exception: #{event.text}"
        when .step_begin?, .step_end?
          # Internal step tracking — no ACP notification needed

        when .turn_end?
          # The prompt fiber will resolve based on this
          @cancelled = true if event.is_error?
        when .compaction_started?
          update = EventTranslator.info_message(@id, "[Compacting context...]")
          emit_update(update)
        when .compaction_completed?
          if event.summary && !event.summary.empty?
            @store.append("context.apply_compaction", {"summary" => JSON::Any.new(event.summary)})
          end
        when .compaction_cancelled?
          # No notification needed

        when .subagent_started?, .subagent_progress?, .subagent_text?,
             .subagent_completed?, .subagent_failed?
          # Subagent events are filtered — only main agent drives session/update
          nil
        when .user_message?
          # Already recorded by the prompt handler
          nil
        end
      end

      # --- Slash commands ---

      BUILTIN_SLASH = {"/compact", "/status", "/usage", "/mcp", "/tasks", "/help"}

      private def handle_slash_command(text : String) : JSON::Any
        # Parse: /command args
        parts = text.strip.split(/\s+/, 2)
        cmd = parts[0]

        if BUILTIN_SLASH.includes?(cmd)
          output = case cmd
                   when "/status"
                     "Mode: #{@agent.permission.mode}\nProvider: #{@agent.provider.name}\nModel: #{@agent.provider.model_name}"
                   when "/usage"
                     pct = @agent.context.token_usage_percent
                     tok = @agent.context.token_count
                     max_t = @agent.context.max_context_tokens
                     "Token usage: #{tok}/#{max_t} (#{pct.round(1)}%)"
                   when "/help"
                     "Available commands: /compact /status /usage /mcp /tasks /help"
                   when "/mcp"
                     "MCP status not available in ACP mode"
                   when "/tasks"
                     "Task browser not available in ACP mode"
                   when "/compact"
                     # Trigger compaction
                     "Context compaction not yet supported via ACP slash"
                   else
                     "Unknown command: #{cmd}"
                   end

          # Emit as agent_message_chunk
          update = EventTranslator.assistant_delta(@id, output)
          emit_update(update)
          build_prompt_response("end_turn")
        else
          # Unknown slash command — emit error, don't send to model
          update = EventTranslator.assistant_delta(@id, "Unknown command: #{cmd}. Available: /compact /status /usage /mcp /tasks /help")
          emit_update(update)
          build_prompt_response("end_turn")
        end
      end

      # --- Emit helpers ---

      private def emit_update(update : JSON::Any) : Nil
        @rpc.send_notification("session/update", update)
      rescue ex
        STDERR.puts "[acp] emit_update error: #{ex}"
      end

      private def build_prompt_response(stop_reason : String) : JSON::Any
        JSON.parse(%({"stopReason":"#{stop_reason}"}))
      end
    end
  end
end
