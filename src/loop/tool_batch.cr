module H2code
  module Loop
    # Result produced by one fiber in a parallel tool batch.
    struct ToolBatchResult
      property index : Int32
      property tool_call_id : String
      property content : String
      property? is_error : Bool
      property display : Tools::ToolDisplay? = nil
      # An unexpected exception raised inside the fiber. When non-nil, the
      # caller must re-raise it on the main fiber so the loop-level interceptor
      # can surface it to the UI. UserCancellationError is NOT carried here —
      # it is reported as a normal cancelled result below.
      property exception : Exception? = nil

      def initialize(@index : Int32, @tool_call_id : String,
                     @content : String, @is_error : Bool, @display : Tools::ToolDisplay? = nil)
      end
    end

    enum PlannedCallStatus
      Approved
      Skipped
      Stopped
    end

    # Pre-flight plan for a single tool call in a batch.
    struct PlannedCall
      property index : Int32
      property tool_call : LLM::ToolCall
      property status : PlannedCallStatus
      property content : String?
      property is_error : Bool?

      def initialize(@index : Int32, @tool_call : LLM::ToolCall,
                     @status : PlannedCallStatus,
                     @content : String? = nil, @is_error : Bool? = nil)
      end
    end

    # Executes a batch of tool calls in parallel using Crystal fibers.
    #
    # Pre-flight checks (tool resolution, deduplication, permission approval)
    # run sequentially because approval callbacks may block on user input.
    # Approved calls are then spawned into fibers; results are collected as
    # they finish but returned (and appended to context) in the original
    # tool_calls order.
    class ToolBatch
      def initialize(
        @registry : Tools::Registry,
        @permission : Permission::Manager,
        @dedup : DedupTracker,
        @abort_controller : AbortController,
        @context : Context::Memory,
        @hooks : Hooks::Engine? = nil,
      )
      end

      def run(tool_calls : Array(LLM::ToolCall),
              &on_event : Event ->) : Array(LLM::Message)
        planned = plan_calls(tool_calls, &on_event)

        approved = planned.select(&.status.approved?)
        channel = Channel(ToolBatchResult).new

        approved.each do |pc|
          spawn do
            execute_approved(pc, channel)
          end
        end

        results_by_index = {} of Int32 => ToolBatchResult
        approved.size.times do
          result = channel.receive
          results_by_index[result.index] = result
          on_event.call(Event.tool_result(result.tool_call_id, result.content, result.is_error?, result.display))
        end

        # Re-raise the first unexpected exception on the main fiber so the
        # loop-level interceptor surfaces it to the UI. Fibers swallow
        # unhandled exceptions, so we capture and propagate explicitly.
        results_by_index.each_value do |r|
          if exc = r.exception
            raise exc
          end
        end

        assemble_results(tool_calls, planned, results_by_index)
      end

      private def plan_calls(tool_calls : Array(LLM::ToolCall),
                             &on_event : Event ->) : Array(PlannedCall)
        planned = [] of PlannedCall
        seen = [] of {String, String}

        tool_calls.each_with_index do |tc, idx|
          on_event.call(Event.tool_call_start(tc.id, tc.name, tc.arguments))

          tool = @registry.get(tc.name)
          unless tool
            content = "Unknown tool: #{tc.name}"
            on_event.call(Event.tool_result(tc.id, content, true))
            planned << PlannedCall.new(idx, tc, PlannedCallStatus::Skipped, content, true)
            next
          end

          canonical_args = canonicalize(tc.arguments)
          if @dedup.same_step_dedup?(tc.name, canonical_args, seen)
            on_event.call(Event.info("Skipping duplicate tool call: #{tc.name}"))
            content = "[Duplicate of previous call — same result]"
            on_event.call(Event.tool_result(tc.id, content, false))
            planned << PlannedCall.new(idx, tc, PlannedCallStatus::Skipped, content, false)
            next
          end
          seen << {tc.name, canonical_args}

          dedup_action = @dedup.check_and_track(tc.name, canonical_args)
          case dedup_action
          when DedupTracker::DedupAction::ForceStop
            msg = "Tool #{tc.name} called repeatedly. Forcing stop."
            on_event.call(Event.info(msg))
            on_event.call(Event.tool_result(tc.id, msg, false))
            planned << PlannedCall.new(idx, tc, PlannedCallStatus::Stopped, msg, false)
            break
          when DedupTracker::DedupAction::Reminder
            on_event.call(Event.info("Repeated call to #{tc.name} (streak 3). Reminder injected."))
          when DedupTracker::DedupAction::DecisionMenu
            on_event.call(Event.info("Repeated call to #{tc.name} (streak 5). Decision needed."))
          when DedupTracker::DedupAction::FinalWarning
            on_event.call(Event.info("Repeated call to #{tc.name} (streak 8). Final warning."))
          end

          approved = @permission.check(tc.name, tc.arguments, on_event)
          unless approved
            # Surface the specific deny reason (plan-mode guard, auto-mode
            # deny, rule deny) when one is available.
            msg = @permission.last_deny_message || "Permission denied for #{tc.name}"
            on_event.call(Event.tool_result(tc.id, msg, true))
            planned << PlannedCall.new(idx, tc, PlannedCallStatus::Skipped, msg, true)
            next
          end

          # PreToolUse hook: a block decision denies the call with the hook's
          # reason visible to the model. Runs after permission (which may
          # itself block) so the hook sees only user-approved calls.
          if engine = @hooks
            if block = engine.trigger_block("PreToolUse", tc.name,
                 {"tool_name"  => JSON::Any.new(tc.name),
                  "tool_input" => JSON.parse(tc.arguments)})
              msg = "Blocked by PreToolUse hook: #{block.reason}"
              on_event.call(Event.tool_result(tc.id, msg, true))
              planned << PlannedCall.new(idx, tc, PlannedCallStatus::Skipped, msg, true)
              next
            end
          end

          planned << PlannedCall.new(idx, tc, PlannedCallStatus::Approved)
        end

        planned
      end

      private def execute_approved(pc : PlannedCall,
                                   channel : Channel(ToolBatchResult)) : Nil
        tc = pc.tool_call

        begin
          @abort_controller.throw_if_aborted!

          tool = @registry.get(tc.name)
          unless tool
            channel.send(ToolBatchResult.new(pc.index, tc.id, "Unknown tool: #{tc.name}", true))
            return
          end

          input = parse_args(tc.arguments)
          tool.tool_call_id = tc.id
          tool.abort_check = -> { @abort_controller.aborted? }
          result = Loop.execute_tool(@abort_controller) do
            tool.execute(input)
          end

          @abort_controller.throw_if_aborted!

          # Scrub binary / invalid-UTF-8 bytes at the tool boundary so the
          # content that reaches the context, transcript, hooks and the wire
          # is always valid UTF-8. See Tools::Tool.sanitize_output.
          result.content = Tools::Tool.sanitize_output(result.content)

          budgeted_content, _truncated = Context::Budget.budget(tc.name, tc.id, result.content)

          # PostToolUse hook: fire-and-forget (not blocking). Lets external
          # tooling observe completed tool calls.
          if engine = @hooks
            event_type = result.is_error? ? "PostToolUseFailure" : "PostToolUse"
            spawn do
              engine.trigger(event_type, tc.name,
                {"tool_name"   => JSON::Any.new(tc.name),
                 "tool_input"  => JSON.parse(tc.arguments),
                 "tool_result" => JSON::Any.new(budgeted_content)})
            end
          end

          channel.send(ToolBatchResult.new(pc.index, tc.id, budgeted_content, result.is_error?, result.display))
        rescue ex : UserCancellationError
          channel.send(ToolBatchResult.new(pc.index, tc.id, "Cancelled: #{ex.reason}", true))
        rescue ex
          # Capture the exception so the caller re-raises it on the main fiber
          # — the loop-level interceptor surfaces it as a red exception message
          # instead of silently swallowing it as an error tool result.
          r = ToolBatchResult.new(pc.index, tc.id, "Execution failed: #{ex.message}", true)
          r.exception = ex
          channel.send(r)
        end
      end

      private def assemble_results(tool_calls : Array(LLM::ToolCall),
                                   planned : Array(PlannedCall),
                                   results_by_index : Hash(Int32, ToolBatchResult)) : Array(LLM::Message)
        messages = [] of LLM::Message

        tool_calls.each_with_index do |tc, idx|
          plan = planned.find { |p| p.index == idx }
          next unless plan

          case plan.status
          when PlannedCallStatus::Approved
            result = results_by_index[idx]
            @context.add_tool_result(result.tool_call_id, result.content)
            messages << LLM::Message.tool(result.content, result.tool_call_id)
          when PlannedCallStatus::Skipped, PlannedCallStatus::Stopped
            content = plan.content || ""
            @context.add_tool_result(tc.id, content)
            messages << LLM::Message.tool(content, tc.id)
          end
        end

        messages
      end

      private def canonicalize(args : String) : String
        return "" if args.empty?
        begin
          parsed = JSON.parse(args)
          canonical_hash(parsed).to_json
        rescue
          args
        end
      end

      private def canonical_hash(value : JSON::Any) : JSON::Any
        case value.raw
        when Hash
          sorted = {} of String => JSON::Any
          value.as_h.keys.sort!.each do |k|
            sorted[k] = canonical_hash(value[k])
          end
          JSON::Any.new(sorted)
        when Array
          JSON::Any.new(value.as_a.map { |v| canonical_hash(v) })
        else
          value
        end
      end

      private def parse_args(args : String) : JSON::Any
        return JSON::Any.new({} of String => JSON::Any) if args.empty?
        JSON.parse(args)
      rescue JSON::ParseException
        JSON::Any.new({} of String => JSON::Any)
      end
    end
  end
end
