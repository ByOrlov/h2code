module H2code
  module Tools
    # Agent — запуск одного дочернего субагента (foreground или background).
    #
    # Контракт перенесён 1:1 из
    # `packages/agent-core-v2/src/session/subagent/tools/agent.ts`.
    # Тул отвечает за парсинг, валидацию и рендер результата; фактический
    # запуск субагента делегирован инжекченному `AgentRunner`, чтобы тул
    # оставался чистым и тестопригодным без session-coordinator'а.
    #
    # См. детальный план портирования в `md-tools/agent.md`.
    class Agent < Tool
      DEFAULT_PROFILE_NAME         = "coder"
      RESUMED_LABEL                = "subagent"
      BACKGROUND_AGENT_UNAVAILABLE =
        "Background agent execution is not available for this agent because TaskList, TaskOutput, and TaskStop are not enabled."
      RESUME_WITH_TYPE_UNAVAILABLE =
        "Cannot set subagent_type when resuming an existing agent. Resume by agent id only."
      USER_INTERRUPTED_SUBAGENT_MESSAGE =
        "The subagent was stopped before it finished by user."
      SUBAGENT_STOPPED_MESSAGE =
        "The subagent was stopped before it finished."
      USER_CANCELLATION_MESSAGE   = "Aborted by the user"
      DEFAULT_SUBAGENT_TIMEOUT_MS = 7_200_000
      TASK_ID_PREFIX              = "agent"
      NO_RUNNER_ERROR             =
        "Agent is not available: no subagent runtime is registered in this build."

      DESCRIPTION_BASE = <<-TEXT
        Launch a subagent to handle a task. The subagent runs as a same-process loop instance with its own context and wire file. Delegating also keeps the bulk of intermediate file contents out of your own context — you get a conclusion back instead of a pile of dumps.

        Writing the prompt:
        - The subagent starts with zero context — it has not seen this conversation. Brief it like a colleague who just walked into the room: state the goal, list what you already know, hand over the specifics.
        - Lookups (read this file, run that test): put the exact path or command in the prompt. The subagent should not have to search for things you already know.
        - Investigations (figure out X, find why Y): give the question, not prescribed steps — fixed steps become dead weight when the premise is wrong.
        - Do not delegate understanding. If the task hinges on a file path or line number, find it yourself first and write it into the prompt.

        Usage notes:
        - When the task continues earlier work a subagent already did, prefer resuming that agent (pass its `resume` id) over spawning a fresh instance — the resumed agent keeps its prior context.
        - A subagent's result is only visible to you, not to the user. When the user needs to see what a subagent produced, summarize the relevant parts yourself in your own reply.
        - Subagents use a fixed 2-hour timeout. If one times out, resume the same agent instead of starting over.

        When NOT to use Agent: skip delegation for trivial work you can do directly — reading a file whose path you already know, searching a small known set of files, or any task that takes only a step or two. Delegation has a context-handoff cost; it pays off only when the task is substantial enough to outweigh it.

        Once a subagent is running, leave that scope to it: do not redo its searches or reads in parallel, and do not abandon it midway and finish the job manually. Both undo the context savings the delegation was meant to buy.
      TEXT

      AGENT_BACKGROUND_ENABLED = <<-TEXT
        When `run_in_background=true`, the subagent runs detached from this turn. The completion arrives in a later turn as a synthetic user-role message containing its result — you do not need to poll, sleep, or check on its progress. Continue with other work or respond to the user. Never fabricate or predict what the result will say.

        Default to a foreground subagent (omit `run_in_background`) when your next step needs its result — foreground hands the result straight back. Reach for `run_in_background=true` only when you have other work to do while it runs and do not need its result to proceed. Never launch in the background and then immediately wait on it (with `TaskOutput block=true`, sleeping, or otherwise): that just blocks the turn for no benefit — run it in the foreground instead.
      TEXT

      AGENT_BACKGROUND_DISABLED = <<-TEXT
        Background agent execution is disabled for this agent. Do not set `run_in_background=true` — any call that sets it is rejected before the subagent launches. Run every subagent in the foreground and wait for its result.
      TEXT

      # В JS список формируется динамически из IAgentProfileCatalogService.
      # Здесь фиксируем 4 профиля (см. md-tools/agent.md §1.2.4).
      PROFILES = [
        Profile.new(
          name: "agent",
          description: "Default H2Code agent",
          when_to_use: nil,
          tools: "Read, Write, Edit, ApplyPatch, Grep, Glob, Bash, TaskList, TaskOutput, TaskStop, CronCreate, CronList, CronDelete, ReadMediaFile, TodoList, Skill, WebSearch, Agent, AgentSwarm, FetchURL, AskUserQuestion, EnterPlanMode, ExitPlanMode, CreateGoal, GetGoal, SetGoalBudget, UpdateGoal, mcp__*",
        ),
        Profile.new(
          name: "coder",
          description: "General software engineering agent",
          when_to_use: "the only subagent type with file-editing tools; use it for any delegated task that must modify code. Use this agent for non-trivial software engineering work that may require reading files, editing code, running commands, and returning a compact but technically complete summary to the parent agent.",
          tools: "Agent, AgentSwarm, ApplyPatch, Bash, CronCreate, CronDelete, CronList, Edit, EnterPlanMode, ExitPlanMode, Glob, Grep, Read, ReadMediaFile, Skill, TaskList, TaskOutput, TaskStop, TodoList, WebSearch, FetchURL, Write, mcp__*",
        ),
        Profile.new(
          name: "explore",
          description: nil,
          when_to_use: "Fast codebase exploration with prompt-enforced read-only behavior. Fast agent specialized for exploring codebases. Use this when you need to quickly find files by patterns (e.g. \"src/**/*.yaml\"), search code for keywords (e.g. \"database connection\"), or answer questions about the codebase (e.g. \"how does the auth module work?\"). When calling this agent, specify the desired thoroughness level: \"quick\" for basic searches, \"medium\" for moderate exploration, or \"thorough\" for comprehensive analysis across multiple locations and naming conventions. Use this agent for any read-only exploration that will clearly require more than 3 search queries. Prefer launching multiple explore agents concurrently when investigating independent questions.",
          tools: "Bash, Read, ReadMediaFile, Glob, Grep, WebSearch, FetchURL",
        ),
        Profile.new(
          name: "plan",
          description: nil,
          when_to_use: "Read-only implementation planning and architecture design. Use this agent when the parent agent needs a step-by-step implementation plan, key file identification, and architectural trade-off analysis before code changes are made.",
          tools: "Read, ReadMediaFile, Glob, Grep, WebSearch, FetchURL",
        ),
      ]

      # Глобальный инжекченный runner. `nil` по умолчанию — тул честно
      # отказывается работать, пока session coordinator не подключит
      # реальную реализацию.
      @@runner : AgentRunner?

      # Включает поддержку `run_in_background=true`. Session/Loop
      # устанавливает true через `Agent.background_enabled = true` когда
      # реестр содержит TaskList/TaskOutput/TaskStop.
      @@background_enabled : Bool = false

      def self.runner=(r : AgentRunner?) : Nil
        @@runner = r
      end

      def self.runner : AgentRunner?
        @@runner
      end

      def self.background_enabled=(v : Bool) : Nil
        @@background_enabled = v
      end

      def self.background_enabled? : Bool
        @@background_enabled
      end

      def name : String
        Names::AGENT
      end

      def description : String
        background_block =
          @@background_enabled ? AGENT_BACKGROUND_ENABLED : AGENT_BACKGROUND_DISABLED

        String.build do |io|
          io << DESCRIPTION_BASE
          io << "\n\n"
          io << background_block
          io << "\n\nAvailable agent types (pass via subagent_type):\n"
          io << build_profile_descriptions
        end
      end

      def self.can_run_in_background? : Bool
        @@background_enabled
      end

      private def build_profile_descriptions : String
        PROFILES.map { |p| render_profile(p) }.join("\n")
      end

      private def render_profile(p : Profile) : String
        lines = [] of String
        head = String.build do |s|
          s << "- "
          s << p.name
          s << ":"
          if desc = p.description
            s << " "
            s << desc
          end
          if when_to_use = p.when_to_use
            s << " "
            s << when_to_use
          end
        end
        lines << head
        lines << "  Tools: #{p.tools}"
        lines.join("\n")
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "prompt": {
              "type": "string",
              "description": "Full task prompt for the subagent"
            },
            "description": {
              "type": "string",
              "description": "Short task description (3-5 words) for UI display"
            },
            "subagent_type": {
              "type": "string",
              "description": "One of the available agent types (see \"Available agent types\" in this tool description). Defaults to \"coder\" when omitted."
            },
            "resume": {
              "type": "string",
              "description": "Optional agent ID to resume instead of creating a new instance. When set, do not also pass subagent_type — the resumed agent keeps its own type, and supplying both is rejected."
            },
            "run_in_background": {
              "type": "boolean",
              "description": "If true, return immediately without waiting for completion. Prefer false unless the task can run independently and there is a clear benefit to not waiting."
            }
          },
          "required": ["prompt", "description"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        args = parse_input(input)

        begin
          processed = preprocess(args)
        rescue ex : ArgumentError
          return ToolResult.error(ex.message || "Invalid Agent input")
        end

        begin
          validate(processed)
        rescue ex : ValidationError
          return ToolResult.error(ex.message || "Invalid Agent input")
        end

        runner = @@runner
        return ToolResult.error(NO_RUNNER_ERROR) if runner.nil?

        runner.tool_call_id = @tool_call_id

        spec = AgentLaunchSpec.new(
          prompt: processed.prompt,
          description: processed.description,
          subagent_type: processed.subagent_type,
          resume_agent_id: processed.resume,
          run_in_background: processed.run_in_background?,
        )

        begin
          outcome = runner.launch(spec, nil)
        rescue ex
          return ToolResult.error("subagent error: #{launch_error_message(ex, nil)}")
        end

        case outcome.status
        when .detached?
          ToolResult.success(format_background_agent_result(outcome))
        when .completed?
          ToolResult.success(format_foreground_agent_success(outcome))
        when .failed?
          res = ToolResult.error(format_foreground_agent_failure(outcome))
          res
        else
          ToolResult.error("subagent error: unexpected status #{outcome.status}")
        end
      end

      # ------------------------------------------------------------------
      # Парсинг / препроцессор
      # ------------------------------------------------------------------

      private def parse_input(raw : JSON::Any) : AgentInput
        prompt = required_string(raw, "prompt")
        description = required_string(raw, "description")
        subagent_type = optional_trimmed(raw, "subagent_type")
        resume = optional_trimmed(raw, "resume")
        run_in_background = optional_bool(raw, "run_in_background")
        AgentInput.new(
          prompt: prompt,
          description: description,
          subagent_type: subagent_type,
          resume: resume,
          run_in_background: run_in_background,
        )
      end

      private def preprocess(args : AgentInput) : AgentInput
        resume_present = args.resume.try(&.empty?) == false
        type_present = args.subagent_type.try(&.empty?) == false

        # 1. Ни resume, ни subagent_type → default coder.
        unless resume_present || type_present
          return AgentInput.new(
            prompt: args.prompt,
            description: args.description,
            subagent_type: DEFAULT_PROFILE_NAME,
            resume: args.resume,
            run_in_background: args.run_in_background?,
          )
        end

        # 2. resume задан, subagent_type пуст → убрать subagent_type.
        if resume_present && !type_present
          return AgentInput.new(
            prompt: args.prompt,
            description: args.description,
            subagent_type: nil,
            resume: args.resume,
            run_in_background: args.run_in_background?,
          )
        end

        args
      end

      private def validate(args : AgentInput) : Nil
        if !args.resume.nil? && !args.subagent_type.nil?
          raise ValidationError.new(RESUME_WITH_TYPE_UNAVAILABLE)
        end

        if args.run_in_background? && !@@background_enabled
          raise ValidationError.new(BACKGROUND_AGENT_UNAVAILABLE)
        end

        if (type = args.subagent_type) && !PROFILES.any? { |p| p.name == type }
          raise ValidationError.new("Unknown agent type: \"#{type}\"")
        end
      end

      private def required_string(raw : JSON::Any, key : String) : String
        v = raw[key]?
        s = v.try(&.to_s) || ""
        s = s.strip
        raise ArgumentError.new("Agent requires `#{key}` to be a non-empty string.") if s.empty?
        s
      end

      private def optional_trimmed(raw : JSON::Any, key : String) : String?
        v = raw[key]?
        return nil if v.nil?
        s = v.to_s.strip
        s.empty? ? nil : s
      end

      private def optional_bool(raw : JSON::Any, key : String) : Bool
        v = raw[key]?
        return false if v.nil?
        v.as_bool? || false
      rescue Exception
        false
      end

      # ------------------------------------------------------------------
      # Рендер результата
      # ------------------------------------------------------------------

      def format_background_agent_result(outcome : AgentRunOutcome) : String
        %(task_id: #{outcome.task_id}\n) \
        %(status: running\n) \
        %(agent_id: #{outcome.agent_id}\n) \
        %(actual_subagent_type: #{outcome.profile_name}\n) \
        %(automatic_notification: true\n) \
        %(\n) \
        %(description: #{outcome.description}\n) \
        %(\n) \
        %(next_step: The completion arrives automatically in a later turn — do NOT wait, poll, or call TaskOutput on it; continue with other work or hand back to the user. (If you have nothing to do until it finishes, run such tasks in the foreground next time.)\n) \
        %(resume_hint: To continue or recover this same subagent later, call Agent(resume="#{outcome.agent_id}", prompt="..."). The parameter is agent_id ("#{outcome.agent_id}"), NOT task_id ("#{outcome.task_id}") or source_id from a later <notification>. Recovery cases: a later <notification type="task.lost" | "task.failed" | "task.killed"> for this subagent — its conversation history is preserved across session restarts and resume will pick it up.)
      end

      def format_foreground_agent_success(outcome : AgentRunOutcome) : String
        summary = outcome.summary || ""
        %(agent_id: #{outcome.agent_id}\n) \
        %(actual_subagent_type: #{outcome.profile_name}\n) \
        %(status: completed\n) \
        %(\n) \
        %(#{summary})
      end

      def format_foreground_agent_failure(outcome : AgentRunOutcome) : String
        msg = outcome.error || "unknown error"
        lines = [] of String
        lines << "agent_id: #{outcome.agent_id}"
        lines << "actual_subagent_type: #{outcome.profile_name}"
        lines << "status: failed"
        lines << ""
        lines << "subagent error: #{msg}"
        if outcome.timed_out?
          lines << "resume_hint: Continue with Agent(resume=\"#{outcome.agent_id}\", prompt=\"continue\"). Use agent_id only; do not set subagent_type. The subagent retains its prior context; redo any unfinished tool call if its result was lost."
        end
        lines.join("\n")
      end

      def format_subagent_timeout_description(ms : Int32) : String
        if ms % 3_600_000 == 0
          h = ms // 3_600_000
          "#{h} hour#{h == 1 ? "" : "s"}"
        elsif ms % 60_000 == 0
          m = ms // 60_000
          "#{m} minute#{m == 1 ? "" : "s"}"
        elsif ms % 1000 == 0
          s = ms // 1000
          "#{s} second#{s == 1 ? "" : "s"}"
        else
          "#{ms} ms"
        end
      end

      def launch_error_message(ex : Exception, signal : AbortController?) : String
        # signal.reason path сейчас не реализован (signal nil).
        if ex.is_a?(AbortError)
          format_subagent_stopped_message(nil)
        else
          ex.message || ex.to_s
        end
      end

      def format_subagent_stopped_message(reason : String?) : String
        if reason.nil? || reason.empty?
          SUBAGENT_STOPPED_MESSAGE
        elsif reason == USER_CANCELLATION_MESSAGE
          USER_INTERRUPTED_SUBAGENT_MESSAGE
        else
          "#{SUBAGENT_STOPPED_MESSAGE} Reason: #{reason}"
        end
      end
    end

    # --------------------------------------------------------------------
    # Контрактные типы
    # --------------------------------------------------------------------

    struct AgentInput
      getter prompt : String
      getter description : String
      getter subagent_type : String?
      getter resume : String?
      getter? run_in_background : Bool

      def initialize(@prompt : String,
                     @description : String,
                     @subagent_type : String? = nil,
                     @resume : String? = nil,
                     @run_in_background : Bool = false)
      end
    end

    struct Profile
      getter name : String
      getter description : String?
      getter when_to_use : String?
      getter tools : String

      def initialize(@name : String,
                     @description : String?,
                     @when_to_use : String?,
                     @tools : String)
      end
    end

    class ValidationError < Exception
    end

    class AbortError < Exception
    end

    # AbortController — заглушка для совместимости с контрактом runner'а.
    # Реальный signal пробрасывается через ToolBatch.
    class AbortController
      @aborted : Bool = false
      property reason : String?

      def aborted? : Bool
        @aborted
      end

      def abort(reason : String? = nil) : Nil
        @aborted = true
        @reason = reason
      end
    end

    alias AgentLaunchSpec = NamedTuple(
      prompt: String,
      description: String,
      subagent_type: String?,
      resume_agent_id: String?,
      run_in_background: Bool,
    )

    enum AgentRunStatus
      Completed
      Failed
      Aborted
      Detached

      def completed? : Bool
        self == Completed
      end

      def failed? : Bool
        self == Failed
      end

      def aborted? : Bool
        self == Aborted
      end

      def detached? : Bool
        self == Detached
      end
    end

    struct AgentRunOutcome
      getter agent_id : String
      getter profile_name : String
      getter status : AgentRunStatus
      getter description : String
      getter summary : String?
      getter error : String?
      getter? timed_out : Bool
      getter task_id : String?

      def initialize(@agent_id : String,
                     @profile_name : String,
                     @status : AgentRunStatus,
                     @description : String = "",
                     @summary : String? = nil,
                     @error : String? = nil,
                     @timed_out : Bool = false,
                     @task_id : String? = nil)
      end
    end

    # Контракт инжекченного runner'а. Эквивалент JS-связки
    # `ISessionSubagentService.launch` + `SubagentRunner.run`.
    #
    # Реализация отвечает за:
    #   * запуск субагента по spec;
    #   * обработку timeout/abort внутри себя;
    #   * возврат `AgentRunOutcome` с нужной веткой (detached/completed/failed).
    abstract class AgentRunner
      # Optional callback to emit subagent lifecycle events to the parent's
      # event loop. Set by the session before the tool runs so the TUI can
      # render live per-agent progress.
      property event_sink : (Loop::Event ->)?
      # Set by the Agent tool before each launch so lifecycle events carry
      # the parent tool_call_id.
      property tool_call_id : String = ""

      def emit(event : Loop::Event) : Nil
        @event_sink.try(&.call(event))
      end

      abstract def launch(spec : AgentLaunchSpec, signal : AbortController?) : AgentRunOutcome
    end
  end
end
