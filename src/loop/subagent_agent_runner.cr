require "./subagent_registry"
require "./abort"
require "../tools/agent"
require "../tools/task"

module H2code
  module Loop
    # `Tools::AgentRunner` implementation: drives one turn on a child agent
    # (spawned or resumed) and returns the distilled result. Foreground runs
    # block the caller; background runs detach into a `TaskService`-tracked
    # fiber and deliver their result by injecting a `<notification>` into the
    # parent agent's context when they finish.
    #
    # Mirrors the JS split: `runAgentTurn` (drive the turn) + `SubagentTask`
    # (register with the task manager) + the Agent tool's foreground/background
    # formatting. The surface kept identical to JS: foreground returns
    # completed/failed/aborted; background returns detached with a task_id.
    class SubagentAgentRunner < Tools::AgentRunner
      DEFAULT_TIMEOUT_MS = Tools::Agent::DEFAULT_SUBAGENT_TIMEOUT_MS
      PARENT_AGENT_ID    = "main"

      # Retargeted by `/fork` / `/merge` at the idle boundary between turns.
      setter work_dir

      def initialize(@registry : SubagentRegistry,
                     @parent_agent : Loop::Agent,
                     @task_service : Tools::TaskService,
                     @system_prompt : String,
                     @work_dir : String,
                     @permission_mode : Permission::Mode,
                     @subagent_timeout_ms : Int32? = nil)
      end

      def launch(spec : Tools::AgentLaunchSpec,
                 signal : H2code::Tools::AbortController?) : Tools::AgentRunOutcome
        if resume_id = spec[:resume_agent_id]
          launch_resume(resume_id, spec, signal)
        else
          launch_spawn(spec, signal)
        end
      end

      # ----------------------------------------------------------------
      # Spawn
      # ----------------------------------------------------------------

      private def launch_spawn(spec : Tools::AgentLaunchSpec,
                               signal : H2code::Tools::AbortController?) : Tools::AgentRunOutcome
        profile_name = spec[:subagent_type] || Tools::Agent::DEFAULT_PROFILE_NAME

        entry = @registry.create(
          parent_agent: @parent_agent,
          profile_name: profile_name,
          work_dir: @work_dir,
          system_prompt: @system_prompt,
          permission_mode: @permission_mode,
          max_context_tokens: @parent_agent.context.max_context_tokens,
          parent_agent_id: PARENT_AGENT_ID,
        )

        if spec[:run_in_background]
          launch_background(entry, spec)
        else
          run_foreground(entry, spec[:prompt], signal)
        end
      end

      # ----------------------------------------------------------------
      # Resume
      # ----------------------------------------------------------------

      private def launch_resume(agent_id : String,
                                spec : Tools::AgentLaunchSpec,
                                signal : H2code::Tools::AbortController?) : Tools::AgentRunOutcome
        entry = @registry.get(agent_id)
        unless entry
          return failure_outcome(agent_id, "subagent",
            "Agent instance \"#{agent_id}\" does not exist", spec[:description])
        end
        entry = entry || raise "entry should not be nil"

        unless @registry.owned_by?(agent_id, PARENT_AGENT_ID)
          return failure_outcome(agent_id, "subagent",
            "Agent instance \"#{agent_id}\" does not belong to this parent agent",
            spec[:description])
        end

        if entry.running?
          return failure_outcome(agent_id, entry.profile_name,
            "Agent instance \"#{agent_id}\" is already running and cannot run concurrently",
            spec[:description])
        end

        if spec[:run_in_background]
          launch_background(entry, spec)
        else
          run_foreground(entry, spec[:prompt], signal)
        end
      end

      # ----------------------------------------------------------------
      # Foreground
      # ----------------------------------------------------------------

      private def run_foreground(entry : SubagentEntry, prompt : String,
                                 signal : H2code::Tools::AbortController?) : Tools::AgentRunOutcome
        entry.running = true
        # Link the parent's abort to the child: if the parent is cancelled
        # mid-turn, propagate the cancel to the child agent so its run_turn
        # unwinds. The child's own abort_controller is reset at the top of
        # run_turn, so a pre-aborted parent must also be re-checked there.
        link_abort(@parent_agent.abort_controller, entry.agent)
        begin
          outcome = drive_turn(entry, prompt, signal)
          outcome
        ensure
          entry.running = false
        end
      end

      # Poll the parent's `Loop::AbortController` and cancel the child when it
      # fires. Crystal has no event-driven abort, so a lightweight polling
      # fiber is the cheapest correct bridge. The poll stops as soon as either
      # side fires.
      private def link_abort(parent_abort : Loop::AbortController, child : Loop::Agent) : Nil
        spawn do
          until parent_abort.aborted?
            sleep 50.milliseconds
            Fiber.yield
          end
          child.cancel
        end
      end

      # Run one turn on the child agent and translate the result into an
      # `AgentRunOutcome`. The abort controller (if any) is linked so a parent
      # cancel propagates: we poll it around the turn.
      private def drive_turn(entry : SubagentEntry, prompt : String,
                             signal : H2code::Tools::AbortController?) : Tools::AgentRunOutcome
        agent = entry.agent

        # If the parent was cancelled before or during the run, surface it as
        # an abort rather than starting a doomed turn.
        if @parent_agent.abort_controller.aborted?
          return Tools::AgentRunOutcome.new(
            agent_id: entry.agent_id,
            profile_name: entry.profile_name,
            status: Tools::AgentRunStatus::Aborted,
            description: "",
            error: @parent_agent.abort_controller.reason || "parent cancelled",
          )
        end

        tool_call_id = @tool_call_id
        emit(Event.subagent_started(tool_call_id, entry.agent_id))
        ticks = 0
        text_buf = ""

        begin
          agent.run_turn(prompt, @system_prompt) do |event|
            case event.type
            when .tool_call_start?, .tool_call_delta?, .step_begin?
              ticks += 1
              emit(Event.subagent_progress(tool_call_id, entry.agent_id, ticks))
            when .text_delta?
              text_buf += event.text
              text_buf = text_buf[-2000..] if text_buf.size > 2000
              emit(Event.subagent_text(tool_call_id, entry.agent_id, text_buf))
            end
          end

          summary = latest_assistant_text(entry.context)
          emit(Event.subagent_completed(tool_call_id, entry.agent_id))
          Tools::AgentRunOutcome.new(
            agent_id: entry.agent_id,
            profile_name: entry.profile_name,
            status: Tools::AgentRunStatus::Completed,
            description: "",
            summary: summary,
          )
        rescue ex : Loop::UserCancellationError
          emit(Event.subagent_failed(tool_call_id, entry.agent_id, "Aborted"))
          Tools::AgentRunOutcome.new(
            agent_id: entry.agent_id,
            profile_name: entry.profile_name,
            status: Tools::AgentRunStatus::Aborted,
            description: "",
            error: ex.reason,
          )
        rescue ex
          emit(Event.subagent_failed(tool_call_id, entry.agent_id, "Failed"))
          Tools::AgentRunOutcome.new(
            agent_id: entry.agent_id,
            profile_name: entry.profile_name,
            status: Tools::AgentRunStatus::Failed,
            description: "",
            error: ex.message || ex.to_s,
          )
        end
      end

      # ----------------------------------------------------------------
      # Background
      # ----------------------------------------------------------------

      private def launch_background(entry : SubagentEntry,
                                    spec : Tools::AgentLaunchSpec) : Tools::AgentRunOutcome
        task_id = next_task_id
        prompt = spec[:prompt]
        description = spec[:description]

        # Register the task as running in the task service so TaskList /
        # TaskOutput / TaskStop can observe it.
        info = Tools::AgentTaskInfo.new(
          task_id: task_id,
          description: description,
          status: Tools::AgentTaskStatus::Running,
          started_at: Time.utc.to_unix_ms,
          detached: true,
          timeout_ms: timeout_ms.to_i64,
        )
        @task_service.as(Tools::InMemoryTaskService).register(info)

        entry.running = true
        spawn do
          begin
            entry.agent.run_turn(prompt, @system_prompt) { |_| }
            summary = latest_assistant_text(entry.context)
            info.status = Tools::AgentTaskStatus::Completed
            info.ended_at = Time.utc.to_unix_ms
            @task_service.as(Tools::InMemoryTaskService).set_output(
              task_id, summary, full_output_available: true)
            inject_completion_notification(entry, task_id, summary, nil)
          rescue ex : Loop::UserCancellationError
            info.status = Tools::AgentTaskStatus::Killed
            info.stop_reason = ex.reason
            info.ended_at = Time.utc.to_unix_ms
            inject_completion_notification(entry, task_id, nil, "killed")
          rescue ex
            info.status = Tools::AgentTaskStatus::Failed
            info.stop_reason = ex.message || ex.to_s
            info.ended_at = Time.utc.to_unix_ms
            @task_service.as(Tools::InMemoryTaskService).set_output(
              task_id, info.stop_reason.to_s, full_output_available: true)
            inject_completion_notification(entry, task_id, nil, "failed")
          ensure
            entry.running = false
          end
        end

        Tools::AgentRunOutcome.new(
          agent_id: entry.agent_id,
          profile_name: entry.profile_name,
          status: Tools::AgentRunStatus::Detached,
          description: description,
          task_id: task_id,
        )
      end

      # Inject a `<notification>` XML block into the parent agent's context so
      # the model sees the background result as a synthetic message on its
      # next step — mirrors the JS task-completion delivery path. Uses the
      # `Notification` origin (not `Injection`) so the per-step
      # `prune_injections` sweep keeps it in the context.
      private def inject_completion_notification(entry : SubagentEntry, task_id : String,
                                                 summary : String?, type : String?) : Nil
        status_str = case type
                     when nil      then "completed"
                     when "killed" then "killed"
                     when "failed" then "failed"
                     else               type.to_s
                     end
        body = summary || ""

        data = {
          "id"          => JSON::Any.new("task.#{task_id}.#{status_str}"),
          "category"    => JSON::Any.new("task_completion"),
          "type"        => JSON::Any.new(status_str),
          "source_kind" => JSON::Any.new("task"),
          "source_id"   => JSON::Any.new(task_id),
          "agent_id"    => JSON::Any.new(entry.agent_id),
          "title"       => JSON::Any.new("Background agent #{status_str}: #{entry.profile_name}"),
          "severity"    => JSON::Any.new(type == "completed" ? "info" : "warning"),
          "body"        => JSON::Any.new(body),
        } of String => JSON::Any

        xml = Tools.render_notification_xml(data)
        @parent_agent.context.add_notification(xml)
      end

      # ----------------------------------------------------------------
      # Helpers
      # ----------------------------------------------------------------

      private def latest_assistant_text(context : Context::Memory) : String
        context.history.reverse_each do |cm|
          next unless cm.message.role == "assistant"
          text = cm.message.text
          return text unless text.empty?
        end
        ""
      end

      private def timeout_ms : Int32
        if (t = @subagent_timeout_ms) && t >= 1
          return t
        end
        DEFAULT_TIMEOUT_MS
      end

      @task_counter = 0

      private def next_task_id : String
        @task_counter += 1
        "agent-#{@task_counter}"
      end

      private def failure_outcome(agent_id : String, profile_name : String,
                                  error : String, description : String = "") : Tools::AgentRunOutcome
        Tools::AgentRunOutcome.new(
          agent_id: agent_id,
          profile_name: profile_name,
          status: Tools::AgentRunStatus::Failed,
          description: description,
          error: error,
        )
      end
    end
  end
end
