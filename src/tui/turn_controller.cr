module H2code
  module TUI
    module TurnController
      private def submit_message(text : String) : Nil
        text = text.strip
        return if text.empty?

        # Resolve pasted media placeholders into content parts (nil for a
        # plain-text message). The text with placeholders keeps serving the
        # transcript and persistence; the parts ride alongside to the model.
        parts, _matched = @media_store.extract_parts(text)

        # Gate mirrors the TS three-flag rule: defer the message (queue it)
        # when a turn is running, compaction is in flight, or a meta-command
        # asked us to defer. Idle + nothing-deferred → send immediately.
        if @agent_busy || @is_compacting || @defer_user_messages
          enqueue_message(text, parts: parts)
          return
        end

        start_turn(text, parts: parts)
      end

      # Append a message to the queue and persist it so drain survives a
      # resume. The hint shown in the queue pane depends on the current
      # phase (see `queue_hint`).
      private def enqueue_message(text : String, mode : String = "prompt", *,
                                  persist : Bool = true,
                                  parts : Array(LLM::ContentPart)? = nil) : Nil
        @queue << QueuedMessage.new(text, mode, parts)
        @on_persist_queued.try(&.call("turn.prompt", text)) if persist
        emit_to_log(Message.new("system", "[Queued: #{truncate_preview(text)}]"))
        invalidate_log_cache!
        @dirty = true
      end

      # Begin a turn for `text`: add to transcript, flip busy, spawn the
      # run_turn fiber. Called for the first message and for each drained
      # queued message.
      # Begin a turn for `text`: add to transcript, flip busy, spawn the
      # run_turn fiber. Called for the first message and for each drained
      # queued message.
      # `persisted` is false when the message was already written to the wire
      # log (e.g. it sat in the queue and `enqueue_message` persisted it); the
      # drain path sets it to avoid a duplicate `turn.prompt` record.
      private def start_turn(text : String, persisted : Bool = false,
                             parts : Array(LLM::ContentPart)? = nil) : Nil
        emit_to_log(Message.new("user", text))
        # The welcome box is part of the Log zone history; do NOT hide it when
        # the first user message arrives. Removing it shrinks the log and
        # forces an unnecessary full repaint, besides violating the idea that
        # the log is append-only.
        @current_step = 0
        @step_tool_count = 0
        @turn_tool_count = 0
        @agent_busy = true
        @agent_status = AgentStatus::Busy
        @status = "Thinking..."
        start_spinner
        invalidate_log_cache!
        @dirty = true
        @status_tracker.try(&.transition!(Notify::AgentStatus::Working))

        cb = @run_turn_cb || raise "run_turn_cb not initialized"
        spawn do
          begin
            cb.call(text, persisted, parts)
          rescue ex : Exception
            # The turn fiber died before emitting TurnEnd (e.g. a store
            # append failed before the agent loop's begin/ensure). Without
            # this net @agent_busy stays true forever and the UI locks in
            # Busy with no way to interrupt. Report, surface the error, and
            # run the standard turn-end cleanup so the app returns to idle.
            ExceptionHandler.report(ex, "turn fiber")
            emit_to_log(Message.new("error", ex.message.to_s))
            on_event(Loop::Event.turn_end(true))
          end
        end
      end

      # Shift one queued message (FIFO) and start a fresh turn for it.
      # Called from `on_event(TurnEnd)` once the previous turn finishes and
      # the queue is non-empty. Recursive via the drain in `on_event` — each
      # turn-end pulls the next item until the queue empties.
      private def drain_next_queued : Nil
        return if @queue.empty?

        next_msg = @queue.shift
        @dispatch_pending = true

        # The tiny async hop lets the TurnEnd handler finish flipping phase
        # back to idle before we start the next turn (otherwise start_turn
        # would see agent_busy=true and re-queue the message).
        spawn do
          @dispatch_pending = false
          # Already persisted when enqueued — skip the duplicate write.
          start_turn(next_msg.text, persisted: true, parts: next_msg.parts)
        end
      end

      private def truncate_preview(text : String) : String
        # Collapse newlines/tabs so the preview stays on a single line in the
        # queue pane (pasted text may contain embedded line breaks).
        flat = text.gsub(/[\r\n]+/, " ").strip
        return flat if flat.size <= 40
        "#{flat[0...40]}..."
      end

      # Public entry point for external systems (cron scheduler, background-task
      # completion) to deliver a prompt to the agent as a synthetic user message.
      # When busy, the message is queued (without a wire-log write — cron fires
      # are regenerated on resume from cron.json, and task notifications are
      # transient). When idle, a fresh turn is started (persisted: true so the
      # run_turn block skips writing a duplicate turn.prompt record).
      def deliver_external_prompt(text : String) : Nil
        return if text.strip.empty?
        if @agent_busy || @is_compacting || @defer_user_messages
          enqueue_message(text, "external", persist: false)
        else
          start_turn(text, persisted: true)
        end
      end

      # Authoritative busy flag for the remote control socket (`op: status`):
      # a turn is running or compaction is in flight.
      def agent_busy? : Bool
        @agent_busy || @is_compacting
      end

      TOOL_PREVIEW_LINES =   10
      TOOL_PREVIEW_CHARS = 1000

      # Normal TUI stores only a small preview of each tool result.
      # The full output is kept in the session JSONL and is viewable via /debug.
      private def tool_preview_text(text : String) : String
        return text if text.empty?
        return text if text.size <= TOOL_PREVIEW_CHARS && text.count('\n') <= TOOL_PREVIEW_LINES

        # Avoid scanning huge single-line outputs (e.g. a 50 MB file read).
        # Stop after the char budget or after the 11th newline.
        preview = String.build(capacity: TOOL_PREVIEW_CHARS + 64) do |s|
          line_count = 0
          chars = 0
          text.each_char do |c|
            if c == '\n'
              line_count += 1
              break if line_count > TOOL_PREVIEW_LINES
            end
            break if chars >= TOOL_PREVIEW_CHARS
            s << c
            chars += 1
          end
        end
        preview + "\n[... truncated; load session in /debug mode to expand ...]"
      end

      # Keep only a small preview of tool arguments in the TUI. The full args
      # are persisted in the session JSONL and viewable via /debug.
      private def tool_args_preview(name : String, args : String?) : String?
        return args if args.nil? || args.empty? || args.size <= TOOL_PREVIEW_CHARS

        begin
          parsed = JSON.parse(args)
          case name
          when Tools::Names::EDIT
            truncate_json_field(parsed, "old_string", "oldString")
            truncate_json_field(parsed, "new_string", "newString")
          when Tools::Names::WRITE
            truncate_json_field(parsed, "content")
          end
          parsed.to_json
        rescue
          args
        end
      end

      private def truncate_json_field(parsed : JSON::Any, *keys : String)
        keys.each do |key|
          value = parsed[key]?
          next unless value
          text = value.as_s? || value.to_s
          next if text.size <= TOOL_PREVIEW_CHARS
          parsed.as_h[key] = JSON::Any.new(tool_preview_text(text))
        end
      end

      # The user-visible hint above the queue pane, mirroring the TS
      # queue-pane copy. Context-sensitive to the current phase.
      private def queue_hint : String
        if @is_compacting
          "will send after compaction"
        elsif @agent_busy
          "Ctrl+S steers now · Enter queues for next turn"
        else
          "will send next"
        end
      end

      # Ctrl+S handler. Three branches (mirrors TS `steerMessage`):
      #   - compacting/deferred  → enqueue (can't steer mid-compaction)
      #   - idle                 → send immediately (no turn to steer)
      #   - busy                 → inject into running turn via Agent#steer
      private def steer_or_queue(text : String) : Nil
        text = text.strip
        return if text.empty?

        if @is_compacting || @defer_user_messages
          enqueue_message(text)
          return
        end

        unless @agent_busy
          start_turn(text)
          return
        end

        # Busy: inject into the live turn.
        @on_steer.try(&.call(text))
        @on_persist_queued.try(&.call("turn.steer", text))
        emit_to_log(Message.new("user", text))
        emit_to_log(Message.new("system", "[Steered into running turn]"))
        @dirty = true
      end

      # Ctrl+S with an empty editor but queued messages: the queue hint
      # ("Ctrl+S steers now") promises this drains the queue into the live
      # turn instead of waiting for turn-end drain. No-op unless a turn is
      # actually running; the queued entries were already persisted on
      # enqueue, so they are not re-persisted here.
      private def steer_queued : Nil
        return if @queue.empty?
        return unless @agent_busy
        return if @is_compacting || @defer_user_messages

        @queue.dup.each do |qm|
          @on_steer.try(&.call(qm.text))
          emit_to_log(Message.new("user", qm.text))
        end
        @queue.clear
        emit_to_log(Message.new("system", "[Queued messages steered into running turn]"))
        @dirty = true
      end

      TIPS = [
        "tips.ctrl_steer",
        "tips.scroll_debug",
        "tips.enter_queues",
        "tips.help_commands",
        "tips.usage_queue",
        "tips.ctrl_exit",
      ]

      private def current_tip : String
        key = TIPS[(Time.utc.to_unix // 5) % TIPS.size]
        H2code.t(key)
      end

      private def thinking_status : String
        step_word = @current_step == 1 ? "time" : "times"
        tool_word = @step_tool_count == 1 ? "tool" : "tools"
        "thinking #{@current_step} #{step_word}, call #{@step_tool_count} #{tool_word}"
      end

      private def finalize_streaming_thinking : Nil
        return if @streaming_thinking.empty?
        emit_to_log(Message.new("thinking", @streaming_thinking))
        @streaming_thinking = ""
        release_active(:thinking)
      end

      # Flush the in-flight streaming assistant text into a permanent assistant
      # message so it migrates from the Active zone to the Log zone, and reset
      # the streaming state.
      #
      # The active-zone block is padded to its high-water mark
      # (@streaming_hwm — see MessageRenderer#render_streaming_text), which can
      # be TALLER than the finalized message renders in the log (transient
      # inflation from raw inline markup, plus the streaming block renders
      # markdown 5 columns narrower and wraps earlier). The combined coverage
      # (log + active) must never shrink, so the deficit is compensated with
      # blank "spacer" log lines — the same mechanism release_active uses.
      private def flush_streaming_text! : Nil
        return if @streaming_text.empty?
        msg = Message.new("assistant", @streaming_text)
        emit_to_log(msg)
        deficit = @streaming_hwm - render_message(msg, @terminal.cols).size
        deficit.times { emit_to_log(Message.new("spacer", "")) } if deficit > 0
        @streaming_text = ""
        @streaming_hwm = 0
      end

      # Start the spinner. The status line is a permanent active-zone element
      # (always one row), so it does NOT participate in the zone-balance
      # declare/release contract — it never appears or disappears.
      private def start_spinner : Nil
        @spinner.start
      end

      # Stop the spinner animation. No release_active needed — the status line
      # stays visible regardless of spinner state.
      private def stop_spinner : Nil
        @spinner.stop
      end

      private def visible_len(s : String) : Int32
        CharWidth.visible_width(s)
      end

      # Cached branch shown in the status bar. The value is recomputed only
      # at cheap, bounded moments — `work_dir=` and turn end — never from
      # the render loop, so reactivity costs one small file read per turn.
      private def refresh_git_branch! : Nil
        branch = detect_git_branch
        return if branch == @git_branch
        @git_branch = branch
        @dirty = true
      end

      private def detect_git_branch : String
        dot_git = File.join(@work_dir, ".git")
        head_path =
          if File.file?(dot_git)
            # Linked worktree: `.git` is a `gitdir: <path>` pointer and HEAD
            # lives in that git dir, not below the checkout.
            pointer = File.read(dot_git).strip
            if pointer.starts_with?("gitdir:")
              File.join(pointer["gitdir:".size..].strip, "HEAD")
            else
              ""
            end
          else
            File.join(dot_git, "HEAD")
          end
        return "" if head_path.empty? || !File.exists?(head_path)
        head = File.read(head_path).strip
        if head.starts_with?("ref: refs/heads/")
          head["ref: refs/heads/".size..]
        else
          head[0...8]
        end
      rescue
        ""
      end
    end
  end
end
