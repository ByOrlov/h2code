require "digest/sha256"
require "./danger"
require "./policies"

module H2code
  module Permission
    enum Mode
      Manual
      Auto
      Yolo

      def to_s : String
        case self
        in Manual then "manual"
        in Auto   then "auto"
        in Yolo   then "yolo"
        end
      end

      def self.parse(str : String) : Mode
        case str.downcase
        when "manual", "ask" then Manual
        when "auto"          then Auto
        when "yolo"          then Yolo
        else                      Manual
        end
      end
    end

    enum ApprovalChoice
      Deny
      ApproveOnce
      ApproveSession
    end

    class Manager
      property mode : Mode = Mode::Manual
      property approval_callback : ((String, String, String?) -> ApprovalChoice)?
      # User-configured rule set (allow / deny / ask). Evaluated before the
      # interactive approval prompt; a deny rule short-circuits to false,
      # an allow rule short-circuits to true (skipping the prompt), and an
      # ask rule forces the prompt even in auto mode.
      property rules : Policies::RuleSet = Policies::RuleSet.new
      # Deny reason from the last check() that returned false (plan-mode
      # guard, auto-mode AskUserQuestion deny, rule deny). The loop surfaces
      # it to the model instead of a generic "Permission denied" — mirrors
      # the JS deny policies carrying their message.
      property last_deny_message : String? = nil

      @session_approvals : Set(String) = Set(String).new

      def initialize(@mode : Mode = Mode::Manual)
      end

      # Deep byte size of the session-approval cache (SHA-256 hex keys, 64
      # bytes each). Used by the `/memory` profiler. There is no eviction, so
      # this set grows unbounded across a long session.
      def profiled_bytes : Int64
        @session_approvals.sum(&.profiled_bytes)
      end

      def profiled_count : Int32
        @session_approvals.size
      end

      def check(tool_name : String, args : String, on_event : Loop::Event ->) : Bool
        @last_deny_message = nil

        # Plan-mode read-only guard: while plan mode is active, mutating tools
        # are blocked (except writes to the current plan file). Evaluated first,
        # before user rules and permission modes — mirrors JS
        # `plan-mode-guard-deny.ts`.
        if plan_block = Tools::PlanMode.guard_check(tool_name, args)
          @last_deny_message = plan_block
          on_event.call(Loop::Event.info(plan_block))
          return false
        end

        # Auto-mode AskUserQuestion deny — mirrors JS
        # `auto-mode-ask-user-question-deny.ts`: the tool is disabled while
        # auto permission mode is active so the model decides on its own
        # instead of blocking on the user.
        if @mode.auto? && tool_name == Tools::Names::ASK_USER_QUESTION
          msg = Tools::AskUserQuestion::AUTO_MODE_DENY_MESSAGE
          @last_deny_message = msg
          on_event.call(Loop::Event.info(msg))
          return false
        end

        # User-configured rules take precedence over the mode default.
        # A deny rule always blocks, even in yolo. An allow rule bypasses
        # the prompt. An ask rule forces the prompt.
        if rule = @rules.evaluate(tool_name, args)
          case rule.decision
          in Policies::Decision::Deny
            @last_deny_message = "Denied by rule: #{rule.pattern}"
            on_event.call(Loop::Event.info("Denied by rule: #{rule.pattern}"))
            return false
          in Policies::Decision::Allow
            return true
          in Policies::Decision::Ask
            # fall through to the prompt below
          end
        end

        # EnterPlanMode enters plan mode without an approval prompt in all
        # permission modes (matches the shipped tool description). Writes to
        # the current plan file are likewise always approved — the plan-mode
        # guard above already narrowed Write/Edit down to that file.
        return true if tool_name == Tools::Names::ENTER_PLAN_MODE
        return true if Tools::PlanMode.plan_file_write?(tool_name, args)

        return true if @mode.yolo?

        if @mode.auto? && auto_approve?(tool_name)
          return true
        end

        # Cache approval by tool + SHA256(args): the full args JSON (which
        # for Edit/Write can be megabytes) is never retained on the Set.
        cache_key = "#{tool_name}:#{Digest::SHA256.hexdigest(args)}"
        return true if @session_approvals.includes?(cache_key)

        danger = Danger.detect(tool_name, args)
        if danger
          on_event.call(Loop::Event.info("WARNING: #{danger}"))
        end

        choice = if cb = @approval_callback
                   cb.call(tool_name, args, danger)
                 else
                   headless_prompt(tool_name, args, danger)
                 end

        case choice
        in ApprovalChoice::ApproveSession
          @session_approvals << cache_key
          true
        in ApprovalChoice::ApproveOnce
          true
        in ApprovalChoice::Deny
          false
        end
      end

      private def headless_prompt(tool_name, args, danger) : ApprovalChoice
        print_approval_prompt(tool_name, args, danger)
        response = gets.try(&.strip.downcase) || "n"
        case response
        when "y", "yes" then ApprovalChoice::ApproveOnce
        when "s"        then ApprovalChoice::ApproveSession
        else                 ApprovalChoice::Deny
        end
      end

      # Backwards-compatible danger accessor. New code should call
      # `Permission::Danger.detect` directly.
      def detect_danger(tool_name : String, args : String) : String?
        Danger.detect(tool_name, args)
      end

      private def auto_approve?(tool_name : String) : Bool
        case tool_name
        when Tools::Names::READ, Tools::Names::GLOB, Tools::Names::GREP, Tools::Names::TODO_LIST, Tools::Names::CURRENT_TIME, Tools::Names::GET_CONTEXT_REMAINING
          true
        else
          false
        end
      end

      private def print_approval_prompt(tool_name : String, args : String, danger : String?) : Nil
        puts ""
        if danger
          print "⚠ Dangerous: #{danger}\n"
        end
        print "▶ Run #{tool_name}?"

        parsed = parse_args(args)
        if command = parsed["command"]?
          print "  $ #{command}\n"
        elsif file = (parsed["path"]? || parsed["filePath"]?)
          print "  file: #{file}\n"
        end

        print "  [y] approve once  [s] approve for session  [n] reject\n"
        print "  > "
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
