require "json"
require "random/secure"
require "./control_socket"
require "../tools/ask_user_question"

module H2code
  module Remote
    # Resident headless session — the process behind `h2code --resident` and
    # the `h2code-tg-bot` daemon. Mirrors the TUI's control-socket wiring
    # (`src/h2code.cr`) and ACP's session loop (`src/acp/session.cr`): a
    # headless agent that stays alive, serves prompts from its control
    # socket (protocol v2), pushes turn/assistant/question/approval frames
    # to connected clients and persists everything to the wire log exactly
    # like `run_headless` does.
    class ResidentSession
      QUESTION_TIMEOUT = 30.minutes # same budget as the ACP question handler
      APPROVAL_TIMEOUT = 5.minutes  # remote user unreachable → deny once
      APPROVAL_ARGS_PREVIEW = 2000  # args can be megabytes (Edit/Write)

      getter question_timeout : Time::Span
      getter approval_timeout : Time::Span

      # Built by `#wire` (called by the CLI before `#run`): the control
      # socket and the question service reference each other's owner, so
      # they cannot be constructed in `initialize` — Crystal forbids `self`
      # usage before every instance variable has a value.
      @socket : ControlSocket? = nil
      @question_service : SocketQuestionService? = nil

      @busy = false
      @exit_requested = false
      @external_queue = [] of String
      @queue_lock = Mutex.new
      @turn_mutex = Mutex.new
      @pending_questions = {} of String => Channel(Tools::QuestionResult?)
      @pending_approvals = {} of String => Channel(Permission::ApprovalChoice?)
      @pending_lock = Mutex.new

      def initialize(@agent : Loop::Agent,
                     @store : Session::Store,
                     @system_prompt : String,
                     @model_name : String,
                     question_timeout : Time::Span = QUESTION_TIMEOUT,
                     approval_timeout : Time::Span = APPROVAL_TIMEOUT)
        @question_timeout = question_timeout
        @approval_timeout = approval_timeout
        @done = Channel(Nil).new
      end

      def socket : ControlSocket
        (@socket || raise "ResidentSession not wired").as(ControlSocket)
      end

      def question_service : SocketQuestionService
        (@question_service || raise "ResidentSession not wired").as(SocketQuestionService)
      end

      # Build the control socket and the question service. Idempotent;
      # must run before `#run` (and before the socket is used at all).
      def wire : Nil
        return if @socket
        @socket = ControlSocket.new(
          ->(text : String) { deliver(text) },
          -> { @agent.cancel },
          -> { @busy },
          on_answer: ->(qid : String, answers : JSON::Any) { resolve_question(qid, answers); nil },
          on_approve: ->(qid : String, decision : String) { resolve_approval(qid, decision); nil },
          on_exit: -> { request_exit },
          status_extras: -> { status_extras },
        )
        # clear/compact are served natively (the resident owns the agent);
        # models/model/mode are wired from `h2code --resident`'s wiring,
        # which has the config and the permission manager at hand.
        socket.on_clear = -> { @agent.context.clear }
        socket.on_compact = -> do
          spawn(name: "resident-compact") do
            @agent.trigger_compaction_tui(@system_prompt) { |event| handle_event(event) }
          end
          nil
        end
        @question_service = SocketQuestionService.new(self)
      end

      # Block the main fiber until an exit is requested (op:exit / signal).
      def run(initial_prompt : String? = nil) : Nil
        socket.rebind(@store.session_dir)
        deliver(initial_prompt) if initial_prompt && !initial_prompt.strip.empty?
        @done.receive
      end

      # --- Prompt intake (mirror of Acp::Session#deliver_external_prompt) ---

      def deliver(text : String) : Nil
        return if text.strip.empty?
        @queue_lock.synchronize { @external_queue << text }
        return if @busy
        spawn(name: "resident-turn") { turn_loop }
      end

      private def turn_loop : Nil
        @turn_mutex.synchronize do
          @busy = true
          begin
            loop do
              break if @exit_requested
              text = @queue_lock.synchronize { @external_queue.shift? }
              break if text.nil?
              begin
                run_turn(text)
                socket.emit("turn", {"phase" => JSON::Any.new("ended"), "ok" => JSON::Any.new(true)})
              rescue ex : Loop::UserCancellationError
                # Mirror run_headless: leave a marker in the context so the
                # next turn's model sees why the previous one went silent —
                # an interrupt without a trace reads as the user being ignored.
                @agent.context.add_user(H2code.t("status.interrupted"))
                socket.emit("turn", {"phase" => JSON::Any.new("ended"), "ok" => JSON::Any.new(false)})
                break if @exit_requested
              rescue ex : Loop::NetworkFailureError
                socket.emit("error", {"text" => JSON::Any.new(ex.message.to_s)})
                socket.emit("turn", {"phase" => JSON::Any.new("ended"), "ok" => JSON::Any.new(false)})
              rescue ex
                socket.emit("error", {"text" => JSON::Any.new("#{ex.class}: #{ex.message}")})
                socket.emit("turn", {"phase" => JSON::Any.new("ended"), "ok" => JSON::Any.new(false)})
              end
            end
          ensure
            @busy = false
          end
        end
        finish if @exit_requested
      end

      private def run_turn(text : String) : Nil
        @store.append_simple("turn.prompt", "prompt", text)
        socket.emit("turn", {"phase" => JSON::Any.new("started")})
        @agent.run_goal_turn(text, @system_prompt) do |event|
          handle_event(event)
        end
      end

      # Wire-log persistence mirrors run_headless; pushes mirror the v2
      # protocol (see control_socket.cr).
      private def handle_event(event : Loop::Event) : Nil
        case event.type
        when .assistant_text?
          data = {"content" => JSON::Any.new(event.text)} of String => JSON::Any
          if (t = event.thinking) && !t.empty?
            data["thinking"] = JSON::Any.new(t)
          end
          @store.append("assistant.text", data)
          socket.emit("assistant", {"text" => JSON::Any.new(event.text)})
        when .tool_call_start?
          @store.append("tool.call", {
            "tool_call_id" => JSON::Any.new(event.tool_call_id),
            "tool_name"    => JSON::Any.new(event.tool_name),
            "arguments"    => JSON::Any.new(event.tool_args),
          })
        when .tool_result?
          @store.append("tool.result", {
            "tool_call_id" => JSON::Any.new(event.tool_call_id),
            "content"      => JSON::Any.new(event.text),
          })
        when .step_end?
          socket.emit("usage", usage_fields)
        when .error?
          socket.emit("error", {"text" => JSON::Any.new(event.text)})
        end
      end

      private def usage_fields : Hash(String, JSON::Any)
        pct = @agent.context.token_usage_percent
        {
          "model"          => JSON::Any.new(@model_name),
          "context_pct"    => JSON::Any.new(pct.round(1)),
          "context_tokens" => JSON::Any.new(@agent.context.token_count),
        } of String => JSON::Any
      end

      private def status_extras : Hash(String, JSON::Any)
        fields = {
          "model"          => JSON::Any.new(@model_name),
          "context_pct"    => JSON::Any.new(@agent.context.token_usage_percent.round(1)),
          "context_tokens" => JSON::Any.new(@agent.context.token_count),
        } of String => JSON::Any
        if reporter = @mode_reporter
          fields["mode"] = JSON::Any.new(reporter.call)
        end
        fields
      end

      # Permission-mode name for op:status ("auto" / "manual" / "yolo"),
      # set by the resident wiring (the permission manager lives outside).
      property mode_reporter : (-> String)? = nil

      # Keeps op:status truthful after op:model swaps the provider.
      def model_name=(name : String) : Nil
        @model_name = name
      end

      # --- Exit (graceful: a running turn is cancelled and finishes first) ---

      def request_exit : Nil
        @exit_requested = true
        if @busy
          @agent.cancel
        else
          finish
        end
      end

      def exit_requested? : Bool
        @exit_requested
      end

      private def finish : Nil
        socket.close
        @done.close
      end

      # --- AskUserQuestion bridge (mirror of Acp::QuestionHandler) ---

      def register_question(qid : String, channel : Channel(Tools::QuestionResult?)) : Nil
        @pending_lock.synchronize { @pending_questions[qid] = channel }
      end

      def resolve_question(qid : String, answers : JSON::Any) : Bool
        channel = @pending_lock.synchronize { @pending_questions.delete(qid) }
        return false unless channel
        channel.send(self.class.map_answers(answers))
        true
      end

      # Response shape matches Acp::QuestionHandler.map_response:
      # `{answers: {question => label(s)}}`, comma-joined for arrays.
      # A missing/invalid answers object means dismissed → empty result.
      def self.map_answers(answers : JSON::Any) : Tools::QuestionResult
        result = Tools::QuestionResult.new
        return result unless answers.raw.is_a?(Hash)
        answers.as_h.each do |question, answer|
          result[question] = if (arr = answer.as_a?)
                              arr.join(", ") { |v| v.to_s }
                            else
                              answer.to_s
                            end
        end
        result
      end

      # --- Permission approval bridge ---

      def approval_callback(tool_name : String, args : String, danger : String?) : Permission::ApprovalChoice
        qid = Random::Secure.hex(8)
        channel = Channel(Permission::ApprovalChoice?).new(1)
        @pending_lock.synchronize { @pending_approvals[qid] = channel }
        preview = args.size > APPROVAL_ARGS_PREVIEW ? "#{args[0, APPROVAL_ARGS_PREVIEW]}…" : args
        socket.emit("approval", {
          "qid"    => JSON::Any.new(qid),
          "tool"   => JSON::Any.new(tool_name),
          "args"   => JSON::Any.new(preview),
          "danger" => JSON::Any.new(danger || ""),
        })
        select
        when choice = channel.receive
          choice || Permission::ApprovalChoice::Deny
        when timeout(@approval_timeout)
          Permission::ApprovalChoice::Deny
        end
      end

      def resolve_approval(qid : String, decision : String) : Bool
        channel = @pending_lock.synchronize { @pending_approvals.delete(qid) }
        return false unless channel
        channel.send(self.class.parse_decision(decision))
        true
      end

      def self.parse_decision(decision : String) : Permission::ApprovalChoice
        case decision
        when "allow"         then Permission::ApprovalChoice::ApproveOnce
        when "allow_session" then Permission::ApprovalChoice::ApproveSession
        else                      Permission::ApprovalChoice::Deny
        end
      end

      # QuestionService wired into AskUserQuestion by the CLI: pushes the
      # question frame over the control socket and blocks the tool fiber
      # until op:answer arrives (or the timeout lapses → dismissed).
      class SocketQuestionService < Tools::QuestionService
        def initialize(@session : ResidentSession)
        end

        def request(req : Tools::QuestionRequest,
                    signal : ::H2code::Loop::AbortController?) : Tools::QuestionResult?
          qid = Random::Secure.hex(8)
          channel = Channel(Tools::QuestionResult?).new(1)
          @session.register_question(qid, channel)
          @session.socket.emit("question", {
            "qid"       => JSON::Any.new(qid),
            "questions" => build_questions(req),
          })
          select
          when result = channel.receive
            result
          when timeout(@session.question_timeout)
            Tools::QuestionResult.new # dismissed branch
          end
        end

        # Same shape as Acp::QuestionHandler#build_params.
        private def build_questions(req : Tools::QuestionRequest) : JSON::Any
          questions = req.questions.map do |q|
            h = {"question" => JSON::Any.new(q.question)} of String => JSON::Any
            h["header"] = JSON::Any.new(q.header) unless q.header.empty?
            h["multiSelect"] = JSON::Any.new(q.multi_select?) if q.multi_select?
            h["options"] = JSON::Any.new(q.options.map do |o|
              oh = {"label" => JSON::Any.new(o.label)} of String => JSON::Any
              oh["description"] = JSON::Any.new(o.description) unless o.description.empty?
              JSON::Any.new(oh)
            end)
            JSON::Any.new(h)
          end
          JSON::Any.new(questions)
        end
      end
    end
  end
end
