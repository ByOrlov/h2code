require "./subagent_registry"
require "./abort"
require "../tools/agent_swarm"
require "../tools/task"

module H2code
  module Loop
    # `Tools::SwarmRunner` implementation. The `AgentSwarm` tool already fans
    # specs out into parallel fibers and collects results in order; this class
    # only owns the single-spec run: spawn (or resume) one child agent, drive a
    # turn, return the `SwarmRunResult`. Concurrency, ordering, and XML render
    # all live in the tool.
    class SubagentSwarmRunner
      include Tools::SwarmRunner

      PARENT_AGENT_ID = "main"

      # Retargeted by `/fork` / `/merge` at the idle boundary between turns.
      setter work_dir

      def initialize(@registry : SubagentRegistry,
                     @parent_agent : Loop::Agent,
                     @system_prompt : String,
                     @work_dir : String,
                     @permission_mode : Permission::Mode,
                     @subagent_timeout_ms : Int32? = nil)
      end

      def call(spec : Tools::AgentSwarmSpec,
               ctx : Tools::SwarmRunContext) : Tools::SwarmRunResult
        if spec.is_a?(Tools::ResumeSpec)
          run_resume(spec.as(Tools::ResumeSpec), ctx)
        else
          run_spawn(spec, ctx)
        end
      end

      def resume_item?(agent_id : String) : String?
        @registry.swarm_item(agent_id)
      end

      def timeout_ms : Int32?
        t = @subagent_timeout_ms
        return nil unless t
        t >= 1 ? t : nil
      end

      # ----------------------------------------------------------------

      private def run_spawn(spec : Tools::AgentSwarmSpec,
                            ctx : Tools::SwarmRunContext) : Tools::SwarmRunResult
        entry = @registry.create(
          parent_agent: @parent_agent,
          profile_name: ctx.profile_name,
          work_dir: @work_dir,
          system_prompt: @system_prompt,
          permission_mode: @permission_mode,
          max_context_tokens: @parent_agent.context.max_context_tokens,
          parent_agent_id: PARENT_AGENT_ID,
          swarm_item: spec.item,
        )

        drive(entry, spec, ctx)
      end

      private def run_resume(spec : Tools::ResumeSpec,
                             ctx : Tools::SwarmRunContext) : Tools::SwarmRunResult
        entry = @registry.get(spec.agent_id)
        unless entry
          return Tools::SwarmRunResult.new(
            spec: spec, agent_id: spec.agent_id,
            status: Tools::SwarmStatus::Failed,
            error: "Agent instance \"#{spec.agent_id}\" does not exist",
          )
        end
        entry = entry || raise "entry should not be nil"

        if entry.running?
          return Tools::SwarmRunResult.new(
            spec: spec, agent_id: spec.agent_id,
            status: Tools::SwarmStatus::Failed,
            error: "Agent instance \"#{spec.agent_id}\" is already running",
          )
        end

        drive(entry, spec, ctx)
      end

      private def drive(entry : SubagentEntry,
                        spec : Tools::AgentSwarmSpec,
                        ctx : Tools::SwarmRunContext) : Tools::SwarmRunResult
        tool_call_id = ctx.tool_call_id
        emit(Event.subagent_started(tool_call_id, entry.agent_id, ctx.swarm_index, spec.item || ""))

        entry.running = true
        ticks = 0
        text_buf = ""
        begin
          entry.agent.run_turn(spec.prompt, @system_prompt) do |event|
            case event.type
            when .tool_call_start?, .tool_call_delta?, .step_begin?
              ticks += 1
              emit(Event.subagent_progress(tool_call_id, entry.agent_id, ticks))
            when .text_delta?
              text_buf += event.text
              # Cap the buffer so a very long response doesn't grow unbounded.
              text_buf = text_buf[-2000..] if text_buf.size > 2000
              emit(Event.subagent_text(tool_call_id, entry.agent_id, text_buf))
            end
          end
          summary = latest_assistant_text(entry.context)
          emit(Event.subagent_completed(tool_call_id, entry.agent_id))
          Tools::SwarmRunResult.new(
            spec: spec,
            agent_id: entry.agent_id,
            status: Tools::SwarmStatus::Completed,
            state: "started",
            result: summary,
          )
        rescue ex : Loop::UserCancellationError
          emit(Event.subagent_failed(tool_call_id, entry.agent_id, "Aborted"))
          Tools::SwarmRunResult.new(
            spec: spec,
            agent_id: entry.agent_id,
            status: Tools::SwarmStatus::Aborted,
            error: ex.reason,
          )
        rescue ex
          emit(Event.subagent_failed(tool_call_id, entry.agent_id, "Failed"))
          Tools::SwarmRunResult.new(
            spec: spec,
            agent_id: entry.agent_id,
            status: Tools::SwarmStatus::Failed,
            error: ex.message || ex.to_s,
          )
        ensure
          entry.running = false
        end
      end

      private def latest_assistant_text(context : Context::Memory) : String
        context.history.reverse_each do |cm|
          next unless cm.message.role == "assistant"
          text = cm.message.text
          return text unless text.empty?
        end
        ""
      end
    end
  end
end
