module H2code
  module Tools
    # EnterPlanMode + ExitPlanMode — перевод агента в/из режим планирования.
    #
    # Контракты перенесены 1:1 из
    # `packages/agent-core-v2/src/agent/plan/tools/enter-plan-mode.ts`
    # и `exit-plan-mode.ts`. Plan-mode guard, review service и runtime wiring
    # описаны в `plans/WIRE-PLAN-MODE.md`.
    class EnterPlanMode < Tool
      DESCRIPTION = <<-TEXT
        Use this tool proactively when you're about to start a non-trivial implementation task.
        Getting user sign-off on your approach via ExitPlanMode before writing code prevents wasted effort.

        Use it when ANY of these conditions apply:

        1. New Feature Implementation - e.g. "Add a caching layer to the API"
        2. Multiple Valid Approaches - e.g. "Optimize database queries" (indexing vs rewrite vs caching)
        3. Code Modifications - e.g. "Refactor auth module to support OAuth"
        4. Architectural Decisions - e.g. "Add WebSocket support"
        5. Multi-File Changes - involves more than 2-3 files
        6. Unclear Requirements - need exploration to understand scope
        7. User Preferences Matter - if user input would materially change the implementation approach, use EnterPlanMode to structure the decision

        Permission mode notes:
        - EnterPlanMode enters plan mode automatically without an approval prompt in all permission modes.
        - In yolo and manual modes, ExitPlanMode still presents the plan to the user for approval.
        - In auto permission mode, do not use AskUserQuestion; make the best decision from available context.
        - In auto permission mode, ExitPlanMode exits plan mode without asking the user.
        - Use EnterPlanMode only when planning itself adds value.

        When NOT to use:
        - Single-line or few-line fixes (typos, obvious bugs, small tweaks)
        - User gave very specific, detailed instructions
        - Pure research/exploration tasks

        Once you are in plan mode, a reminder walks you through the workflow (explore → design → write the plan file → `ExitPlanMode`) and enforces read-only access. For non-trivial tasks where you are unsure of the codebase structure or relevant code paths, use `Agent(subagent_type="explore")` to investigate first when the `Agent` tool is available.
      TEXT

      def name : String
        Names::ENTER_PLAN_MODE
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        service = PlanMode.plan_service

        before = service.try(&.status)
        if before
          return ToolResult.error("Plan mode is already active. Use ExitPlanMode when the plan is ready.")
        end

        svc = service
        return ToolResult.error("Plan service is not initialized.") if svc.nil?

        begin
          svc.enter
        rescue ex
          return ToolResult.error("Failed to enter plan mode: #{ex.message || "Failed to enter plan mode."}")
        end

        after = svc.status
        ToolResult.success(entered_plan_mode_message(after.try(&.path)))
      end

      # ------------------------------------------------------------------

      def entered_plan_mode_message(plan_path : String?) : String
        if plan_path.nil?
          return <<-TEXT
            Plan mode is now active. Your workflow:

            1. Use read-only tools (Read, Grep, Glob) to investigate the codebase. Use Bash only when needed.
            2. Design a concrete, step-by-step plan.
            3. Wait for the host to provide a plan file path before calling ExitPlanMode.

            Do NOT use Write or Edit while plan mode is active in this host; no plan file path is available.
            Use Bash only when needed; Bash follows the normal permission mode and rules.
          TEXT
        end

        <<-TEXT
          Plan mode is now active. Your workflow:

          Plan file: #{plan_path}

          1. Use read-only tools (Read, Grep, Glob) to investigate the codebase. Use Bash only when needed.
          2. Design a concrete, step-by-step plan.
          3. Write the plan to the plan file with Write or Edit.
          4. When the plan is ready, call ExitPlanMode for user approval.

          Do NOT edit files other than the plan file while plan mode is active.
          Use Bash only when needed; Bash follows the normal permission mode and rules.
        TEXT
      end
    end

    class ExitPlanMode < Tool
      RESERVED_OPTION_LABELS = Set{"approve", "reject", "reject and exit", "revise"}

      DESCRIPTION = <<-TEXT
        Use this tool when you are in plan mode and have finished writing your plan to the plan file and are ready for user approval.

        ## How This Tool Works
        - You should have already written your plan to the plan file specified in the plan mode reminder.
        - This tool does NOT take the plan content as a parameter - it reads the plan from the file you wrote.
        - The user will see the contents of your plan file when they review it. In auto permission mode, the tool reads the file and exits plan mode without asking the user.

        ## When to Use
        Only use this tool for tasks that require planning implementation steps. For research tasks (searching files, reading code, understanding the codebase), do NOT use this tool.

        ## What a good plan contains
        List specific, verifiable steps grounded in the actual codebase — real files, functions, and commands, in a sensible order. Each step should be concrete enough to act on and to check. Avoid vague filler like "improve performance" or "add tests"; say what to change and where.

        ## Multiple Approaches
        If your plan offers multiple alternative approaches, pass them via the `options` parameter so the user can choose which one to execute — see the `options` parameter for the format, count, and reserved labels. In yolo and manual modes the user sees all options alongside the host's Reject and Revise controls.

        ## Before Using
        - In auto permission mode, do NOT use AskUserQuestion; make the best decision from available context.
        - In auto permission mode, this tool exits plan mode without asking the user.
        - In yolo and manual modes, this tool still presents the plan to the user for approval.
        - If auto permission mode is not active and you have unresolved questions, use AskUserQuestion first.
        - If auto permission mode is not active and you have multiple approaches and haven't narrowed down yet, consider using AskUserQuestion first to let the user choose, then write a plan for the chosen approach only.
        - Once your plan is finalized, use THIS tool to request approval.
        - Do NOT use AskUserQuestion to ask "Is this plan OK?" or "Should I proceed?" - that is exactly what ExitPlanMode does.
        - If rejected, revise based on feedback and call ExitPlanMode again.
      TEXT

      def name : String
        Names::EXIT_PLAN_MODE
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "options": {
              "type": "array",
              "description": "When the plan contains multiple alternative approaches, list them here so the user can choose which one to execute. Provide up to 3 options; 2-3 distinct approaches work best when the plan offers a real choice. Passing a single option is allowed and is equivalent to a plain plan approval. Each option represents a distinct approach from the plan. Do not use \"Reject\", \"Revise\", \"Approve\", or \"Reject and Exit\" as labels.",
              "minItems": 1,
              "maxItems": 3,
              "items": {
                "type": "object",
                "properties": {
                  "label": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 80,
                    "description": "Short name for this option (1-8 words). Append \"(Recommended)\" if you recommend this option."
                  },
                  "description": {
                    "type": "string",
                    "default": "",
                    "description": "Brief summary of this approach and its trade-offs."
                  }
                },
                "required": ["label"],
                "additionalProperties": false
              }
            }
          },
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        service = PlanMode.plan_service
        return ToolResult.error("Plan service is not initialized.") if service.nil?

        status = service.status
        if status.nil?
          # Принудительно входим в plan mode, если агент не вызвал EnterPlanMode,
          # чтобы ExitPlanMode был самодостаточным и не падал с без recover-ошибкой.
          begin
            service.enter
          rescue ex
            return ToolResult.error("Failed to enter plan mode: #{ex.message || "Failed to enter plan mode."}")
          end
          status = service.status
          return ToolResult.error("Failed to activate plan mode. Use EnterPlanMode (or /plan) first.") if status.nil?
        end

        # Parse options if provided.
        options = parse_options(input)
        return options if options.is_a?(ToolResult) # validation error

        resolved = resolve_plan(status)
        return resolved if resolved.is_error?

        mode = PlanMode.permission_mode
        if mode && mode.auto?
          service.exit
          return ToolResult.success(format_auto_approved(resolved.content, status.path))
        end

        # Interactive review (manual / yolo). Falls back to auto-approve when no
        # review service is registered (e.g. headless / scripted runs).
        reviewer = PlanMode.plan_review_service
        if reviewer.nil?
          service.exit
          return ToolResult.success(format_user_approved(resolved.content, status.path))
        end

        result = reviewer.request(resolved.content, status.path, options)
        handle_review_result(result, service, resolved.content, status.path, options)
      end

      # Branches mirror the JS `exitPlanModeApprovalResult` outcomes.
      private def handle_review_result(result : PlanReviewResult?, service : PlanService,
                                       plan : String, path : String?,
                                       options : Array(PlanOption)?) : ToolResult
        case result.try(&.decision) || PlanReviewDecision::Dismissed
        in .approve?
          service.exit
          res = result || raise "result should not be nil for approve"
          sel = options.try { |opts| opts.find { |o| o.label == res.selected_label } }
          prefix = sel ? "Selected approach: #{sel.label}\nExecute ONLY the selected approach. Do not execute any unselected alternatives.\n\n" : ""
          ToolResult.success(prefix + format_user_approved(plan, path))
        in .revise?
          fb = (result || raise "result should not be nil for revise").feedback
          msg = fb.empty? ? "User requested revisions. Plan mode remains active." : "User rejected the plan. Feedback:\n\n#{fb}"
          ToolResult.success(msg)
        in .reject_and_exit?
          service.exit
          ToolResult.error("Plan rejected by user. Plan mode deactivated.")
        in .dismissed?
          ToolResult.success("Plan approval dismissed. Plan mode remains active.")
        end
      end

      # ------------------------------------------------------------------

      def resolve_plan(status : PlanData)
        if status.content.strip.empty?
          if status.path.nil?
            return ToolResult.error("No plan file found. Write the plan to the current plan file first, then call ExitPlanMode.")
          else
            return ToolResult.error("No plan file found. Write your plan to #{status.path} first, then call ExitPlanMode.")
          end
        end

        # Хак: упаковываем план в ToolResult.success, переиспользуя content.
        ToolResult.success(status.content)
      end

      def format_auto_approved(plan : String, path : String?) : String
        saved_to = path ? "Plan saved to: #{path}\n\n" : ""
        <<-TEXT
          Exited plan mode. Plan mode deactivated. All tools are now available.
          Note: this plan was auto-approved without user review — the user has NOT explicitly approved it. Follow the user's original instructions on whether to proceed with execution; if they asked you to stop, wait, or only summarize after planning, do not start executing.
          #{saved_to}## Plan (auto-approved, not user-reviewed):
          #{plan}
        TEXT
      end

      def format_user_approved(plan : String, path : String?) : String
        saved_to = path ? "Plan saved to: #{path}\n\n" : ""
        <<-TEXT
          Exited plan mode. Plan mode deactivated. All tools are now available.
          #{saved_to}## Approved Plan:
          #{plan}
        TEXT
      end

      # ------------------------------------------------------------------

      private def parse_options(input : JSON::Any) : Array(PlanOption)? | ToolResult
        raw = input["options"]?
        return nil if raw.nil?

        arr = raw.as_a?
        return ToolResult.error("`options` must be an array.") unless arr

        if arr.size < 1 || arr.size > 3
          return ToolResult.error("`options` must contain between 1 and 3 entries.")
        end

        opts = [] of PlanOption
        arr.each do |o|
          label = o["label"]?.try(&.to_s) || ""
          return ToolResult.error("`options[].label` must be a non-empty string.") if label.empty?
          if label.size > 80
            return ToolResult.error("`options[].label` must not exceed 80 characters.")
          end
          description = o["description"]?.try(&.to_s) || ""
          opts << PlanOption.new(label: label, description: description)
        end

        if err = unique_option_labels_error(opts)
          return ToolResult.error(err)
        end

        if err = reserved_option_labels_error(opts)
          return ToolResult.error(err)
        end

        opts
      end

      def normalize_option_label(label : String) : String
        label.strip.downcase
      end

      def unique_option_labels_error(options : Array(PlanOption)) : String?
        seen = {} of String => Nil
        options.each do |o|
          norm = normalize_option_label(o.label)
          if seen.has_key?(norm)
            return "Option labels must be unique."
          end
          seen[norm] = nil
        end
        nil
      end

      def reserved_option_labels_error(options : Array(PlanOption)) : String?
        options.each do |o|
          norm = normalize_option_label(o.label)
          return "Option labels must not use reserved approval labels." if RESERVED_OPTION_LABELS.includes?(norm)
        end
        nil
      end
    end

    # --------------------------------------------------------------------
    # Plan-mode service contract
    # --------------------------------------------------------------------

    struct PlanData
      getter id : String
      getter content : String
      getter path : String?

      def initialize(@id : String, @content : String, @path : String? = nil)
      end
    end

    abstract class PlanService
      abstract def status : PlanData?
      abstract def enter(id : String? = nil, create_file : Bool = false) : Nil
      abstract def cancel(id : String? = nil) : Nil
      abstract def clear : Nil
      abstract def exit(id : String? = nil) : Nil
    end

    struct PlanOption
      getter label : String
      getter description : String

      def initialize(@label : String, @description : String = "")
      end
    end

    # Outcome of an interactive plan review (Approve / Revise / Reject & Exit /
    # Dismissed). Mirrors the JS `ApprovalResponse.decision` branches in
    # `exit-plan-mode-review-ask.ts`.
    enum PlanReviewDecision
      Approve
      Revise
      RejectAndExit
      Dismissed
    end

    struct PlanReviewResult
      getter decision : PlanReviewDecision
      getter selected_label : String?
      getter feedback : String

      def initialize(@decision : PlanReviewDecision,
                     @selected_label : String? = nil,
                     @feedback : String = "")
      end
    end

    # Service the ExitPlanMode tool calls to surface a finalized plan to the
    # user for interactive approval. The host (TUI) registers an implementation
    # that blocks until the user decides; headless / scripted runs leave it nil
    # and ExitPlanMode falls back to auto-approve.
    abstract class PlanReviewService
      abstract def request(plan : String, path : String?,
                           options : Array(PlanOption)?) : PlanReviewResult?
    end

    # Контейнер глобального состояния plan mode: service + permission mode.
    module PlanMode
      class_property plan_service : PlanService? = nil
      class_property permission_mode : PermissionModeRef? = nil
      class_property plan_review_service : PlanReviewService? = nil

      # Plan-mode read-only enforcement. Returns a deny message when the tool
      # must be blocked while plan mode is active, or nil to allow it. Mirrors
      # JS `plan-mode-guard-deny.ts`: Write/Edit may only target the current
      # plan file; TaskStop / CronCreate / CronDelete are blocked outright.
      def self.guard_check(tool_name : String, args : String) : String?
        svc = plan_service
        return nil unless svc && (status = svc.status)
        plan_path = status.path

        if tool_name == Names::WRITE || tool_name == Names::EDIT
          target = extract_path(tool_name, args)
          if target && plan_path &&
             File.expand_path(target) == File.expand_path(plan_path)
            return nil
          end
          return "Plan mode is active. You may only write to the current plan file: #{plan_path || "(no plan file selected yet)"}. Call ExitPlanMode to exit plan mode before editing other files."
        end

        if PlanMode::MUTATING_TOOLS.includes?(tool_name)
          return "#{tool_name} is not available in plan mode. Call ExitPlanMode first."
        end

        nil
      end

      MUTATING_TOOLS = Set{Names::TASK_STOP, Names::CRON_CREATE, Names::CRON_DELETE, Names::APPLY_PATCH}

      # Whether this call is a Write/Edit targeting the current plan file —
      # such calls are always approved without a prompt (the plan-mode guard
      # allows only them through while plan mode is active).
      def self.plan_file_write?(tool_name : String, args : String) : Bool
        return false unless tool_name == Names::WRITE || tool_name == Names::EDIT
        svc = plan_service
        return false unless svc && (status = svc.status) && (plan_path = status.path)
        target = extract_path(tool_name, args)
        !target.nil? && File.expand_path(target) == File.expand_path(plan_path)
      end

      private def self.extract_path(tool_name : String, args : String) : String?
        return nil if args.empty?
        parsed = JSON.parse(args)
        (parsed["path"]? || parsed["filePath"]?).try(&.to_s)
      rescue JSON::ParseException
        nil
      end
    end

    # Lightweight permission-mode reference — ввёл, чтобы не тянуть тяжёлый
    # `Permission::Manager` в чистый tool. Auto-mode → true.
    struct PermissionModeRef
      property? auto : Bool = false

      def initialize(@auto : Bool = false)
      end
    end

    # Простейшая реализация PlanService: состояние в памяти, путь к файлу
    # плана опциональный.
    class AgentPlanService < PlanService
      @active : Bool = false
      @plan_id : String? = nil
      @plan_path : String?
      @session_dir : String
      @agent_id : String

      def initialize(@session_dir : String, @agent_id : String, @plan_path : String? = nil)
      end

      def status : PlanData?
        return nil unless @active && (id = @plan_id)
        content = ""
        if (path = @plan_path) && File.exists?(path)
          content = File.read(path)
        end
        PlanData.new(id: id, content: content, path: @plan_path)
      end

      def enter(id : String? = nil, create_file : Bool = false) : Nil
        raise "Already in plan mode" if @active
        @plan_id = id || generate_id
        @plan_path ||= File.join(@session_dir, "agents", @agent_id, "plans", "#{@plan_id}.md")
        plan_path = @plan_path || raise "plan_path should not be nil"
        Dir.mkdir_p(File.dirname(plan_path))
        @active = true
        File.write(plan_path, "") if create_file && !File.exists?(plan_path)
      end

      def cancel(id : String? = nil) : Nil
        @active = false
        @plan_id = nil
      end

      def clear : Nil
        cancel
      end

      def exit(id : String? = nil) : Nil
        @active = false
        @plan_id = nil
      end

      private def generate_id : String
        Random::Secure.hex(8)
      end
    end
  end
end
