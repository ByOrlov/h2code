module H2code
  module TUI
    module EventController
      # Rebuild the visible TUI transcript from a replayed context memory.
      # Called after session resume/fork so the on-screen conversation matches
      # the agent's internal state. Streaming-only metadata (thinking blocks,
      # step summaries) is not recoverable from the wire log and is omitted.
      def load_transcript_from(memory : Context::Memory) : Nil
        @messages.clear
        @streaming_text = ""
        @streaming_thinking = ""
        @streaming_tool = nil
        @streaming_hwm = 0
        @current_step = 0
        # History was rebuilt from scratch — reset the log emission cursor
        # and force a full repaint.
        @log_zone.reset
        @previous_viewport_top = 0
        @first_render = true
        invalidate_log_cache!

        memory.history.each do |cm|
          msg = cm.message
          case cm.origin
          when .injection?
            next
          when .compaction_summary?
            emit_to_log(Message.new("system", "[compacted] #{msg.text}"))
            next
          end

          case msg.role
          when "user"
            emit_to_log(Message.new("user", msg.text))
          when "assistant"
            if tcs = msg.tool_calls
              tcs.each do |tc|
                m = Message.new("tool", "")
                m.tool_call_id = tc.id
                m.tool_name = tc.name
                m.tool_args = tc.arguments
                m.step = @current_step
                emit_to_log(m)
              end
            end
            unless (text = msg.text).empty?
              emit_to_log(Message.new("assistant", text))
            end
          when "tool"
            attach_tool_result(msg.tool_call_id.to_s, msg.text)
          when "system"
            emit_to_log(Message.new("system", msg.text)) unless msg.text.empty?
          end
        end

        @dirty = true
      end

      private def attach_tool_result(tool_call_id : String, result : String) : Nil
        i = @messages.size - 1
        while i >= 0
          m = @messages[i]
          if m.role == "tool" && m.tool_call_id == tool_call_id
            m.tool_result = result
            @messages[i] = m
            return
          end
          i -= 1
        end
      end

      def show_interrupted(message : String = H2code.t("status.interrupted")) : Nil
        finalize_streaming_thinking
        # Flush any in-flight streaming text into a permanent assistant message
        # so it doesn't disappear when we reset the streaming buffer.
        flush_streaming_text!
        stop_spinner
        # The log zone already shows this message (emit_to_log below); setting
        # Error here would duplicate it in the status bar (┃ ✗ <message>).
        # Hello renders as a blank status line, leaving only the log entry.
        @agent_status = AgentStatus::Hello
        @status = message
        emit_to_log(Message.new("status", message))
        invalidate_log_cache!
        @dirty = true
      end

      def on_event(event : Loop::Event) : Nil
        @render_pending &+= 1
        case event.type
        when .step_begin?
          @current_step = event.step
          start_spinner
          @agent_status = AgentStatus::Busy
          @status = thinking_status
        when .text_delta?
          finalize_streaming_thinking
          @streaming_text += event.text
          @agent_status = AgentStatus::Busy
          @status = thinking_status
        when .thinking_delta?
          declare_active(:thinking) if @streaming_thinking.empty?
          @streaming_thinking += event.text
          @status = "thinking..."
        when .assistant_text?
          finalize_streaming_thinking
          if @streaming_text.empty?
            # Finalized text delivered without preceding deltas (e.g. a plan
            # block emitted straight into the Log zone). Add it as a complete
            # assistant message so it never inflates the Active zone.
            unless event.text.empty?
              emit_to_log(Message.new("assistant", event.text))
              invalidate_log_cache!
            end
          else
            flush_streaming_text!
            invalidate_log_cache!
          end
          stop_spinner
          @status = ""
        when .tool_call_start?
          finalize_streaming_thinking
          flush_streaming_text!
          @step_tool_count += 1
          @turn_tool_count += 1

          if event.tool_name == Tools::Names::READ && (group = @pending_read_group) && group.step == @current_step
            reads = (group.read_group ||= [] of ReadGroupEntry)
            reads << ReadGroupEntry.new(event.tool_call_id, event.tool_args)
          else
            msg = Message.new("tool", "")
            msg.tool_call_id = event.tool_call_id
            msg.tool_name = event.tool_name
            msg.tool_args = tool_args_preview(event.tool_name, event.tool_args)
            msg.step = @current_step
            emit_to_log(msg)
            @pending_read_group = event.tool_name == Tools::Names::READ ? msg : nil
          end

          @streaming_tool = event.tool_name
          @agent_status = AgentStatus::Busy
          @status = thinking_status
        when .tool_result?
          # Results for parallel tool calls can arrive out of order, so scan
          # backward for the matching tool message instead of assuming the last
          # one is the target. Message is a struct, so updated values must be
          # reassigned into the array.
          i = @messages.size - 1
          while i >= 0
            msg = @messages[i]
            if msg.role == "tool"
              if group = msg.read_group
                if eidx = group.index { |e| e.tool_call_id == event.tool_call_id }
                  entry = group[eidx]
                  entry.tool_result = tool_preview_text(event.text)
                  entry.is_error = event.is_error?
                  group[eidx] = entry
                  msg.read_group = group
                  @messages[i] = msg
                  break
                end
              elsif msg.tool_call_id == event.tool_call_id
                msg.tool_result = tool_preview_text(event.text)
                msg.is_error = event.is_error?
                # The full structured display (e.g. Edit diff) can be large.
                # /debug has the full output; the TUI renders from the preview.
                msg.tool_display = nil
                # RAM-usage line attached by --ram; rendered inside this
                # block, right under the result preview.
                msg.ram_line = event.ram_line
                @messages[i] = msg
                break
              end
            end
            i -= 1
          end
          @streaming_tool = nil
          @agent_status = AgentStatus::Busy
          @status = thinking_status
          inject_plan_if_any(event.text)
          # A completed TodoList (all items done) is snapshotted into the log
          # and cleared, so the finished plan migrates out of the active zone
          # and a fresh list can be started. Idempotent: clearing happens right
          # after the snapshot, so subsequent tool results see an empty list.
          snapshot_todo_if_complete!
        when .info?
          @agent_status = AgentStatus::Busy
          @status = event.text
          # Compaction start message ("Context near limit, triggering compaction...")
          # sets the compacting flag; the completion message
          # ("Context compacted (N → M messages)") clears it.
          if event.text.includes?("compacting") || event.text.includes?("compaction")
            @is_compacting = true
          elsif event.text.includes?("compacted")
            @is_compacting = false
            stop_spinner
          end
        when .compaction_started?
          @is_compacting = true
          @defer_user_messages = true
          @agent_status = AgentStatus::Busy
          @status = "Compacting context..."
          msg = Message.new("compaction", "")
          msg.compaction_state = "running"
          msg.tip = event.tip || ""
          msg.tokens_before = event.tokens_before
          @compaction_msg = msg
          emit_to_log(msg)
        when .compaction_completed?
          @is_compacting = false
          @defer_user_messages = false
          @agent_status = AgentStatus::Busy if @agent_busy
          stop_spinner
          @status = thinking_status
          # Update the most recent running compaction block in place.
          if cmsg = @compaction_msg
            cmsg.compaction_state = "done"
            cmsg.tokens_before = event.tokens_before
            cmsg.tokens_after = event.tokens_after
            cmsg.summary = event.summary || ""
          else
            i = @messages.size - 1
            while i >= 0
              m = @messages[i]
              if m.role == "compaction" && m.compaction_state == "running"
                m.compaction_state = "done"
                m.tokens_before = event.tokens_before
                m.tokens_after = event.tokens_after
                m.summary = event.summary || ""
                @messages[i] = m
                break
              end
              i -= 1
            end
          end
          @compaction_msg = nil
        when .compaction_cancelled?
          @is_compacting = false
          @defer_user_messages = false
          @agent_status = AgentStatus::Busy if @agent_busy
          stop_spinner
          @status = thinking_status
          if cmsg = @compaction_msg
            cmsg.compaction_state = "cancelled"
          else
            i = @messages.size - 1
            while i >= 0
              m = @messages[i]
              if m.role == "compaction" && m.compaction_state == "running"
                m.compaction_state = "cancelled"
                @messages[i] = m
                break
              end
              i -= 1
            end
          end
          @compaction_msg = nil
        when .subagent_started?
          handle_subagent_started(event)
        when .subagent_progress?
          handle_subagent_progress(event)
        when .subagent_text?
          handle_subagent_text(event)
        when .subagent_completed?
          handle_subagent_terminal(event, "Completed")
        when .subagent_failed?
          handle_subagent_terminal(event, event.phase.empty? ? "Failed" : event.phase)
        when .error?
          emit_to_log(Message.new("error", event.text))
          stop_spinner
          @agent_status = AgentStatus::Error
          @status = event.text
        when .exception?
          msg = Message.new("exception", event.text)
          emit_to_log(msg)
          stop_spinner
          @agent_status = AgentStatus::Error
          @status = event.text
        when .turn_end?
          # Turn finished (normal, errored, or cancelled). Reset busy state
          # and drain the next queued message if any. The TUI is the single
          # owner of the busy/idle phase so this is the only place busy flips
          # back to false — run_turn itself runs in a detached fiber and
          # cannot safely touch @agent_busy on completion.
          @agent_busy = false
          @is_compacting = false
          @defer_user_messages = false
          stop_spinner
          if event.is_error?
            @agent_status = AgentStatus::Error
            @status = H2code.t("status.interrupted")
          else
            @agent_status = AgentStatus::Done
            step_word = @current_step == 1 ? "step" : "steps"
            tool_word = @turn_tool_count == 1 ? "tool" : "tools"
            @status = "Done · #{@current_step} #{step_word}, #{@turn_tool_count} #{tool_word}"
          end
          @status_tracker.try(&.transition!(Notify::AgentStatus::Done, H2code.t("status.turn_complete")))
          @status_tracker.try(&.transition!(Notify::AgentStatus::Idle))

          # A cancelled turn ends the dispatch chain: drop queued messages
          # so they don't leak into the next prompt the user types fresh.
          if event.is_error?
            unless @queue.empty?
              @queue.clear
              emit_to_log(Message.new("system", "[Queue cleared on interrupt]"))
            end
          end

          # Drain the next queued message if the user queued one during the
          # finished turn. Skipped during the dispatch-pending gap.
          if !@run_turn_cb.nil? && !@dispatch_pending
            drain_next_queued
          end
        end

        # Invalidate the log-zone line cache for any event that may modify
        # @messages. Streaming events (step_begin, text_delta, thinking_delta,
        # info) don't touch @messages, so the cache stays valid and those
        # frames remain O(1).
        case event.type
        when .step_begin?, .text_delta?, .thinking_delta?, .info?
          # No @messages change
        else
          invalidate_log_cache!
        end

        @dirty = true
        render_now

        # Post-render telemetry: only after tool results, since the user wants
        # metric changes attributed to the tool that caused them. Must run
        # AFTER render_now because SyncBugsCount is incremented during render.
        if event.type.tool_result?
          check_post_render_telemetry!
        end
      end

      # Find the tool-call Message that owns the parent AgentSwarm/Agent
      # tool_call_id and return its index, or nil if it was already trimmed.
      private def find_swarm_message(tool_call_id : String) : Int32?
        i = @messages.size - 1
        while i >= 0
          m = @messages[i]
          if m.role == "tool" && m.tool_call_id == tool_call_id
            return i
          end
          i -= 1
        end
        nil
      end

      private def recompute_swarm_active : Nil
        active = false
        @messages.each do |m|
          next if m.swarm_members.empty?
          m.swarm_members.each { |sm| active = true if sm.running? }
        end
        @swarm_active = active
      end

      # CI observer state change, called cross-fiber from the LiveCiService
      # poll fiber (same pattern as on_event). While any observer is pending,
      # declares the `:ci` active-zone key so the per-commit animated wait
      # lines keep the zone balance. When THIS observer reached a terminal
      # state its outcome is emitted into the log zone first — even when
      # other observers are still pending, so an intermediate commit's
      # result is never silently dropped (each settled line also satisfies
      # the release invariant). The `:ci` key is released only when no
      # observer is pending anymore. The agent-facing notification / turn
      # wake-up is handled by the service's delivery callback, not here.
      def on_ci_update(obs : Tools::Ci::Observer) : Nil
        if obs.terminal?
          line = case obs.status
                 when .success?
                   H2code.t("ui.ci_passed", sha: obs.short_sha, detail: obs.detail)
                 when .failure?
                   H2code.t("ui.ci_failed", sha: obs.short_sha, detail: obs.detail)
                 when .error?
                   H2code.t("ui.ci_error", sha: obs.short_sha, detail: obs.detail)
                 else
                   H2code.t("ui.ci_timeout", sha: obs.short_sha, detail: obs.detail)
                 end
          emit_to_log(Message.new("system", line))
          invalidate_log_cache!
        end
        if obs.pending? || Tools::Ci.service.try(&.pending?) || false
          @ci_active = true
          declare_active(:ci)
        else
          @ci_active = false
          release_active(:ci)
        end
        @dirty = true
      end

      private def handle_subagent_started(event : Loop::Event) : Nil
        idx = find_swarm_message(event.tool_call_id)
        return unless idx
        msg = @messages[idx]
        member = SwarmMember.new(event.agent_id)
        member.swarm_index = event.swarm_index
        member.item_text = event.item_text
        member.phase = event.phase.empty? ? "Running" : event.phase
        msg.swarm_members << member
        @messages[idx] = msg
        @swarm_active = true
        @dirty = true
      end

      private def handle_subagent_progress(event : Loop::Event) : Nil
        idx = find_swarm_message(event.tool_call_id)
        return unless idx
        msg = @messages[idx]
        changed = false
        # SwarmMember is a struct, so each yields a copy; mutate via index and
        # write the element back, otherwise the phase/ticks update is lost and
        # members stay "Running" forever (keeps @swarm_active true → endless
        # redraws that lock terminal scroll).
        msg.swarm_members.each_with_index do |sm, i|
          next unless sm.agent_id == event.agent_id
          if event.subagent_ticks > sm.ticks
            sm.ticks = event.subagent_ticks
            msg.swarm_members[i] = sm
            changed = true
          end
        end
        @messages[idx] = msg if changed
        @dirty = true if changed
      end

      private def handle_subagent_text(event : Loop::Event) : Nil
        idx = find_swarm_message(event.tool_call_id)
        return unless idx
        msg = @messages[idx]
        changed = false
        # SwarmMember is a struct — see handle_subagent_progress for the
        # mutate-via-index pattern.
        msg.swarm_members.each_with_index do |sm, i|
          next unless sm.agent_id == event.agent_id
          sm.latest_text = event.text
          msg.swarm_members[i] = sm
          changed = true
        end
        @messages[idx] = msg if changed
        @dirty = true if changed
      end

      private def handle_subagent_terminal(event : Loop::Event, phase : String) : Nil
        idx = find_swarm_message(event.tool_call_id)
        return unless idx
        msg = @messages[idx]
        # See handle_subagent_progress: SwarmMember is a struct, so each yields
        # a copy. Mutate via index and write back, or the phase never updates.
        msg.swarm_members.each_with_index do |sm, i|
          next unless sm.agent_id == event.agent_id
          sm.phase = phase
          msg.swarm_members[i] = sm
        end
        @messages[idx] = msg
        recompute_swarm_active
        @dirty = true
      end

      def request_approval(tool_name : String, args : String, danger : String?) : Permission::ApprovalChoice
        @approval_pending = ApprovalRequest.new(tool_name, args, danger)
        @agent_status = AgentStatus::Waiting
        @status = "Waiting for approval: #{tool_name}"
        @dirty = true
        @status_tracker.try(&.transition!(Notify::AgentStatus::InputRequired,
          H2code.t("ui.approval_required"), tool_name))
        select
        when choice = @approval_channel.receive
          @approval_pending = nil
          @agent_status = AgentStatus::Busy
          @status = thinking_status
          @dirty = true
          @status_tracker.try(&.transition!(Notify::AgentStatus::Working))
          choice
        end
      end

      SUDO_APPROVAL_OPTIONS = ["Allow once", "Always allow", "Deny"]

      def request_sudo_approval(command : String) : Tools::Bash::SudoApprovalChoice
        @sudo_approval_pending = command
        @sudo_approval_list.show("Sudo command requires approval", SUDO_APPROVAL_OPTIONS)
        @sudo_approval_list.selected = 0
        @agent_status = AgentStatus::Waiting
        @status = "Waiting for sudo approval"
        @dirty = true
        @status_tracker.try(&.transition!(Notify::AgentStatus::InputRequired,
          H2code.t("ui.approval_required"), "Bash (sudo)"))
        choice = @sudo_approval_channel.receive
        @sudo_approval_list.hide
        @sudo_approval_pending = nil
        @agent_status = AgentStatus::Busy
        @status = thinking_status
        @dirty = true
        @status_tracker.try(&.transition!(Notify::AgentStatus::Working))
        choice
      end

      # Launch a structured multi-question prompt. Mirrors TS
      # `reverse-rpc/question-adapter.ts` mounting a QuestionDialogComponent
      # and awaiting the user's answers. Returns the answers map
      # (question text → answer), empty when the user dismissed the dialog.
      def request_questions(questions : Array(Tools::QuestionItem),
                            on_toggle_tool_output : (-> Nil)? = nil) : Hash(String, String)
        # Capacity 1 so the dialog's callback can `send` without rendezvous
        # — otherwise `send` inside `handle_input` would deadlock waiting for
        # the `receive` that can only run after handle_input returns.
        received = Channel(Hash(String, String)).new(1)
        @question_dialog.show(questions, ->(answers : Hash(String, String)) do
          received.send(answers)
          nil
        end, on_toggle_tool_output)
        @agent_status = AgentStatus::Waiting
        @status = "Waiting for your response"
        @dirty = true
        result = received.receive
        @agent_status = AgentStatus::Busy
        @status = thinking_status
        result
      end

      # Surface a finalized plan for interactive approval. Mirrors
      # `request_questions`: shows the PlanReviewDialog and blocks until the
      # user decides. Returns the review result (never nil — dismissal is
      # encoded as `PlanReviewDecision::Dismissed`).
      def request_plan_review(plan : String, path : String?,
                              options : Array(Tools::PlanOption)?) : Tools::PlanReviewResult
        received = Channel(Tools::PlanReviewResult).new(1)
        @plan_review_dialog.show(plan, path, options, ->(result : Tools::PlanReviewResult) do
          received.send(result)
          nil
        end)
        @agent_status = AgentStatus::Waiting
        @status = "Waiting for plan review"
        @dirty = true
        result = received.receive
        @agent_status = AgentStatus::Busy
        @status = thinking_status
        result
      end

      private def inject_plan_if_any(tool_output : String) : Nil
        return unless tool_output.includes?("Plan")
        plan_body, kind = extract_plan_body(tool_output)
        return if plan_body.empty?
        msg = Message.new("plan_box", plan_body)
        msg.plan_kind = kind
        msg.plan_path = extract_plan_path(tool_output)
        emit_to_log(msg)
      end

      # Returns the plan body (stripped) and its kind. Body is empty when the
      # output is not a recognised ExitPlanMode outcome.
      private def extract_plan_body(output : String) : {String, String}
        auto_marker = "## Plan (auto-approved, not user-reviewed):"
        approved_marker = "## Approved Plan:"
        if idx = output.index(auto_marker)
          body = output[(idx + auto_marker.size)..].strip
          return {body, "auto_approved"}
        end
        if idx = output.index(approved_marker)
          body = output[(idx + approved_marker.size)..].strip
          return {body, "approved"}
        end
        return {"", "approved"} if output.includes?("Plan rejected by user.")
        {"", ""}
      end

      # Extract the "Plan saved to: <path>" line if present, mirroring the
      # TS `PLAN_SAVED_TO_RE` regex.
      private def extract_plan_path(output : String) : String?
        if m = output.match(/\nPlan saved to: ([^\n]+)\n/)
          p = m[1]?.try(&.strip)
          p unless p.try(&.empty?)
        end
      end

      # Bordered box around a markdown-rendered plan, mirroring TS
      # `PlanBoxComponent`: "  ┌── plan: name ──┐", "  │ body │", "  └──┘".
      # The title embeds the plan filename (when known) and a Rejected
      # badge in error colour for rejected plans.
      # Compaction block — port of TS `CompactionComponent`. While running,
      # the bullet blinks (white ↔ blank); once done the bullet turns solid
      # green with "(N → M tokens)"; cancelled turns it warning-yellow. The
      # summary can be toggled with Ctrl-O via the generic `expanded` flag.
      private def snapshot_todo_if_complete! : Nil
        todos = current_todos
        return if todos.nil? || todos.empty?
        return unless todos.all? { |(_, status)| status == "done" }

        msg = Message.new("todo_snapshot", "")
        # Dup: `on_clear_todos` below mutates the tool's array in place, and the
        # snapshot must be an immutable frozen copy.
        msg.todo_items = todos.dup
        emit_to_log(msg)
        invalidate_log_cache!
        @on_clear_todos.try(&.call)
      end

      # Todo panel: mirrors TS `components/chrome/todo-panel.ts`. Shows the
      # agent's structured TODO list (title + status) above the editor so
      # the user sees progress without scrolling through the transcript.
      # Post-render telemetry check. Called AFTER render_now so that any
      # sync_bugs_count increment caused by rendering this tool's result is
      # already reflected. If a tracked counter went up, the delta line is
      # attached to the last completed tool message and a second render shows
      # it. This must run after the render (not during event handling) because
      # SyncBugsCount is incremented inside build_rendered_lines_split.
      #
      # No infinite-loop risk: @telemetry.sample consumes the delta (updates
      # prev_values), so the second render_now produces delta=0 and the method
      # returns early.
      private def check_post_render_telemetry! : Nil
        parts = [] of String
        @telemetry.counter_names.each do |name|
          case name
          when "SyncBugsCount"
            if (delta = @telemetry.sample(name, @sync_bugs_count)) > 0
              parts << "SyncBugsCount +#{delta}"
            end
          end
        end
        return if parts.empty?

        line = parts.join(" · ")
        # Attach to the last tool message that has a result (the one whose
        # render just completed).
        i = @messages.size - 1
        while i >= 0
          msg = @messages[i]
          if msg.role == "tool" && !msg.tool_result.nil?
            msg.telemetry_line = line
            @messages[i] = msg
            break
          end
          i -= 1
        end
        invalidate_log_cache!
        @dirty = true
        render_now
      end
    end
  end
end
