module H2code
  module Context
    # Context summarization when the conversation nears the context window.
    #
    # Ported from the TS `packages/agent-core/src/agent/compaction/full.ts`:
    #
    #   - the summarizer request is the projected history as a normal message
    #     list plus a separate instruction user message appended at the end —
    #     never one giant concatenated user message;
    #   - the projection closes still-open tool calls (synthesized results)
    #     and drops stray tool results with no call anywhere, so a strict
    #     provider cannot reject the request on structural grounds;
    #   - injection-origin messages (step reminders, hook notes) are protocol
    #     state, not conversation — excluded from the summarizer input;
    #   - when the summarizer request itself cannot fit (HTTP 413, or a 400
    #     whose body blames the input size — Z.AI/GLM reports oversized input
    #     as "The messages parameter is illegal"), the history is shrunk to
    #     the most recent messages within a token budget (70% → 50% → 35%)
    #     and retried; messages trimmed this way are not covered by the
    #     summary, reported via `CompactionResult#dropped_count`. On the
    #     first attempt the provider's usage figure backs up the local
    #     estimate, which can badly undercount a near-full history;
    #   - if the input rejection persists past the shrink budget, the
    #     history is hard-truncated to the most recent messages within a
    #     fraction of the context window — keeping the full history would
    #     guarantee the next regular request fails the same way;
    #   - a 413 first retries with media parts replaced by text markers;
    #   - an empty or truncated summary drops the oldest message and retries;
    #   - transient provider failures (429/5xx/network) back off and retry.
    #
    # On cancellation or terminal provider failure the full history is
    # retained and the returned status reflects that.
    class Compaction
      # Number of recent messages kept verbatim after compaction. Older
      # history is folded into the summary. Matches the TS default.
      DEFAULT_KEPT_COUNT = 6

      # Total retry budget for transient errors / empty-summary shrinks,
      # mirroring `MAX_COMPACTION_RETRY_ATTEMPTS` in full.ts.
      MAX_RETRIES = 5
      # Consecutive overflow shrinks before giving up, mirroring
      # `MAX_COMPACTION_OVERFLOW_SHRINK_ATTEMPTS` in full.ts.
      MAX_OVERFLOW_SHRINK_ATTEMPTS = 3
      # Fraction of the current history token estimate kept by each overflow
      # shrink attempt, mirroring `COMPACTION_OVERFLOW_SHRINK_RATIOS`.
      OVERFLOW_SHRINK_RATIOS = [0.7, 0.5, 0.35]
      # An overflow/413 is only recoverable-by-shrink when the estimated
      # request occupies at least this fraction of the context window —
      # otherwise the body size problem is not the history. Mirrors
      # `OVERFLOW_STATUS_RECOVERY_RATIO` in full.ts.
      OVERFLOW_RECOVERY_RATIO = 0.5
      # Backoff cap for transient-error retries, in seconds.
      MAX_RETRY_DELAY = 8

      # The summarizer instruction, adapted from the TS
      # `compaction-instruction.md`: a first-person handoff note, because the
      # next turn sees only the kept tail of the history plus this note.
      INSTRUCTION = <<-TEXT
        You are about to run out of context. Write a first-person handoff note to yourself so you can seamlessly continue this task after the earlier conversation is cleared.

        --- This message is a direct task, not part of the above conversation ---

        Write the note as your own continuing train of thought — first person, present tense, the way you would reason through the next move. Do not write a third-party report about someone else's work, and do not impose rigid section headings; let the shape follow the task. Write the note in the same language the conversation has been using — do not switch to English just because these instructions happen to be in English.

        Make the note self-sufficient: the next turn will see only your most recent messages and this note — every assistant message, tool call, and tool result above will be gone. In your own words, preserve what you genuinely need to continue:

        - What the latest request is actually asking for: your reading of its intent and any ambiguity you have already resolved — not a re-transcription, since what fits is kept verbatim in your most recent messages. But those kept messages are size-capped, so a long request is truncated there: if the latest request is large (a big paste or file), preserve the parts at risk of being dropped — above all the actual ask. If several requests are in play, say which one governs the next move, and re-quote any still-relevant earlier request that may have scrolled out of the kept messages.
        - The instructions and constraints currently in force (user preferences, project rules, environment and tooling limits) — condensed to what still matters, keeping decisions you have already settled (what you chose and why) separate from questions still open.
        - What has actually been done, at high fidelity: keep the exact commands that were run, the exact file paths touched, and whether each succeeded or failed — and the results themselves, not just the commands: the concrete values returned, the key lines or error text, the schema or signature a lookup revealed, since re-running to recover them may be slow or impossible. Keep only the final working version of any code; drop intermediate attempts and already-resolved errors.
        - What you still don't know: context the next step depends on that this conversation never established — files or paths referenced but not yet read, schemas or APIs assumed but unseen, questions the user has not answered. Name these gaps so the next turn goes and checks them instead of assuming.
        - The forward plan — and this is the moment to invest in it. Right now you hold more context on this task than you ever will again; the next turn resumes with less, so the plan you commit here is the one it will follow. Give the exact next command or tool call, but don't stop at the next step: set out the remaining sequence to finish, the decisions you have already made for those upcoming steps, the obstacles or edge cases you can already foresee, and any work you can commit to now — the exact patch, query, or shape of the final answer you already know you will produce.

        Be honest about uncertainty. If an earlier step claimed something was done but was never verified (tests "passing", a fix "working", a file "created"), say so plainly and treat it as unverified rather than fact — re-check before relying on it.

        Be concise, and keep the note proportional to the task: a long multi-step task warrants detail, but a trivial or nearly finished exchange needs only a sentence or two — do not pad it out. Include the critical data, identifiers, and references needed to continue, and omit anything that does not change the next move.

        Respond with text only. Do not call any tools — you already have everything you need in the conversation history.
        TEXT

      # The summarizer response was cut off before a complete summary.
      class TruncatedSummaryError < Exception
        def initialize
          super("Compaction response was truncated before producing a complete summary.")
        end
      end

      # The summarizer returned no usable summary text.
      class EmptySummaryError < Exception
        def initialize
          super("The compaction response did not contain a non-empty summary.")
        end
      end

      getter provider : LLM::Provider
      getter context : Context::Memory
      getter kept_count : Int32

      def initialize(@provider : LLM::Provider,
                     @context : Context::Memory,
                     @kept_count : Int32 = DEFAULT_KEPT_COUNT)
      end

      # Summarize the current history and replace it with the summary +
      # `kept_count` recent messages. Returns the summary text (useful for
      # the caller's event payload and persistence).
      #
      # On cancellation or provider failure the full history is retained and
      # the returned summary reflects that.
      def compact(&on_part : LLM::MessagePart ->) : CompactionResult
        old_messages = @context.history
        tokens_before = @context.token_count

        kept_n = Math.min(@kept_count, old_messages.size)
        kept = kept_n > 0 ? old_messages[-kept_n..] : [] of ContextMessage

        # Compaction summarises a near-full context, so the live window is
        # almost exhausted. Reset the budget clamp so the summary request is
        # not starved into a tiny output cap by the large used-context value.
        @provider.used_context_tokens = 0
        summary = ""
        dropped_count = 0
        status : CompactionStatus = CompactionStatus::Completed

        begin
          summary, dropped_count = summarize(old_messages, &on_part)
        rescue ex : Loop::UserCancellationError
          status = CompactionStatus::Cancelled
          summary = "[Compaction cancelled — keeping full history]"
          kept = old_messages
        rescue ex : LLM::ApiError
          # Last resort when the summarizer request keeps being rejected as
          # oversized input (Z.AI/GLM reports it as a 400 "The messages
          # parameter is illegal"): keeping the full history would guarantee
          # the next regular request fails the same way, so hard-truncate to
          # the most recent messages within a fraction of the window and
          # insert an explicit no-summary marker.
          truncated = nil
          if old_messages.size > 1 && Compaction.input_rejection?(ex)
            truncated = hard_truncate(old_messages, tokens_before)
          end
          if truncated && truncated.size < old_messages.size
            status = CompactionStatus::Completed
            summary = "[Context truncated without a summary — the summarizer request was rejected by the provider (#{ex.message}). Only the most recent messages remain; re-read key files or re-ask about anything that was dropped.]"
            kept = truncated
            dropped_count = old_messages.size - truncated.size
          else
            status = CompactionStatus::Failed
            summary = "[Compaction failed — keeping full history]"
            kept = old_messages
          end
        rescue
          status = CompactionStatus::Failed
          summary = "[Compaction failed — keeping full history]"
          kept = old_messages
        end

        @context.apply_compaction(summary, kept)
        tokens_after = @context.token_count

        CompactionResult.new(
          status: status,
          summary: summary,
          tokens_before: tokens_before,
          tokens_after: tokens_after,
          messages_before: old_messages.size,
          messages_after: kept.size,
          dropped_count: dropped_count,
        )
      end

      # Run the summarizer request loop: build the request from the current
      # history slice, call the provider, and shrink the slice when the
      # request cannot fit or the response comes back unusable. Returns the
      # summary text plus the number of messages trimmed from the input
      # (uncovered by the summary).
      private def summarize(history : Array(ContextMessage),
                            &on_part : LLM::MessagePart ->) : {String, Int32}
        # Injections are protocol state (step reminders, hook notes), not
        # conversation — summarizing them wastes tokens. Mirrors the TS
        # `stripDynamicToolContext` boundary.
        messages = history.reject(&.origin.injection?)
        full_size = messages.size
        dropped = 0
        media_stripped = false
        overflow_shrinks = 0
        empty_shrinks = 0
        retries = 0

        loop do
          request = Compaction.project(messages.map(&.message))
          request << LLM::Message.user(INSTRUCTION)
          estimated = LLM::TokenCounter.estimate(request)
          # Overflow evidence for the ratio gate in `overflow_error?`. On the
          # first attempt the request is (nearly) the whole live history, so
          # the provider's usage figure — authoritative, and often far above
          # the local estimate for a near-full window — counts too. Once the
          # slice has been shrunk, only the local estimate of what is
          # actually being sent is meaningful.
          gate_tokens = messages.size == full_size ? Math.max(estimated, @context.token_count) : estimated

          begin
            result = @provider.chat(request, nil, nil) do |part|
              on_part.call(part)
            end
            raise TruncatedSummaryError.new if result.stop_reason == "length"
            raise EmptySummaryError.new if result.text.strip.empty?
            return {result.text, dropped}
          rescue ex : Loop::UserCancellationError
            raise ex
          rescue ex : TruncatedSummaryError | EmptySummaryError
            empty_shrinks += 1
            if empty_shrinks > MAX_RETRIES || messages.size <= 1
              raise ex
            end
            retries = 0
            before = messages.size
            messages = Compaction.drop_oldest(messages)
            dropped += before - messages.size
            next
          rescue ex : LLM::ApiError
            # A request-body-size rejection (HTTP 413) is first retried with
            # media parts replaced by text markers: accumulated base64
            # payloads are the usual culprit, and a text summary needs
            # neither. Only the summarizer input is rewritten; the real
            # history keeps its media.
            if ex.status_code == 413 && !media_stripped
              media_stripped = true
              stripped = Compaction.replace_media_with_markers(messages)
              unless stripped.same?(messages)
                messages = stripped
                retries = 0
                next
              end
            end

            # Overflow: the summarizer request itself does not fit. Shrink to
            # the most recent messages within a token budget and retry.
            if Compaction.overflow_error?(ex, gate_tokens, @context.max_context_tokens) && messages.size > 1
              if overflow_shrinks >= MAX_OVERFLOW_SHRINK_ATTEMPTS
                raise ex
              end
              overflow_shrinks += 1
              retries = 0
              ratio = OVERFLOW_SHRINK_RATIOS[Math.min(overflow_shrinks - 1, OVERFLOW_SHRINK_RATIOS.size - 1)]
              budget = (LLM::TokenCounter.estimate(messages.map(&.message)) * ratio).to_i
              before = messages.size
              messages = Compaction.take_recent_within_token_budget(messages, budget)
              dropped += before - messages.size
              next
            end

            unless ex.retryable? && retries + 1 < MAX_RETRIES
              raise ex
            end
            retries += 1
            sleep Math.min(2 ** retries, MAX_RETRY_DELAY).seconds
          rescue ex : IO::Error
            # Network failures / timeouts — transient, back off and retry.
            unless retries + 1 < MAX_RETRIES
              raise ex
            end
            retries += 1
            sleep Math.min(2 ** retries, MAX_RETRY_DELAY).seconds
          end
        end
      end

      # Keep the most recent messages within 35% of the context window,
      # scaled down when the local estimator undercounts the provider's
      # usage figure (`usage_tokens`): the budget is expressed in local
      # tokens, so the same undercount must be applied to it. Used by the
      # last-resort truncation in `#compact`.
      private def hard_truncate(messages : Array(ContextMessage), usage_tokens : Int32) : Array(ContextMessage)
        history_est = LLM::TokenCounter.estimate(messages.map(&.message))
        budget = (@context.max_context_tokens * 0.35).to_i
        if usage_tokens > history_est && history_est > 0
          budget = (budget.to_f64 * history_est.to_f64 / usage_tokens.to_f64).to_i
        end
        budget = 1 if budget < 1
        Compaction.take_recent_within_token_budget(messages, budget)
      end

      # --- Request-building helpers, unit-testable in isolation ---

      # Project a message list into a wire-valid summarizer prefix: drop tool
      # results whose call appears nowhere in the slice (orphans), and
      # synthesize a placeholder result for every assistant tool call that
      # has no matching result after it (dangling calls — strict providers
      # reject them). Mirrors the TS `project({synthesizeMissing: true,
      # dropOrphanResults: true})` boundary in full.ts.
      def self.project(messages : Array(LLM::Message)) : Array(LLM::Message)
        called = Set(String).new
        messages.each do |msg|
          msg.tool_calls.try &.each { |tc| called << tc.id }
        end

        projected = messages.reject do |msg|
          id = msg.tool_call_id
          msg.role == "tool" && id && !called.includes?(id)
        end

        answered = Set(String).new
        projected.each do |msg|
          if msg.role == "tool" && (id = msg.tool_call_id)
            answered << id
          end
        end

        out = [] of LLM::Message
        projected.each do |msg|
          out << msg
          next unless msg.role == "assistant"
          msg.tool_calls.try &.each do |tc|
            next if answered.includes?(tc.id)
            out << LLM::Message.tool("[tool result unavailable after context truncation]", tc.id)
            answered << tc.id
          end
        end
        out
      end

      # Replace media parts (image/audio/video) with text markers in the
      # summarizer input, for the 413 strip-and-retry above. Returns the
      # input unchanged (same object) when there was no media to strip.
      def self.replace_media_with_markers(messages : Array(ContextMessage)) : Array(ContextMessage)
        changed = false
        out = messages.map do |cm|
          has_media = cm.message.content.any? do |part|
            part.is_a?(LLM::ImageContent) || part.is_a?(LLM::AudioContent) || part.is_a?(LLM::VideoContent)
          end
          next cm unless has_media
          changed = true
          parts = cm.message.content.map do |part|
            case part
            when LLM::ImageContent then LLM::TextContent.new("[image]")
            when LLM::AudioContent then LLM::TextContent.new("[audio]")
            when LLM::VideoContent then LLM::TextContent.new("[video]")
            else                        part
            end
          end
          msg = LLM::Message.new(cm.message.role, parts, cm.message.tool_calls, cm.message.tool_call_id)
          ContextMessage.new(msg, cm.origin)
        end
        changed ? out : messages
      end

      # The most recent messages whose cumulative token estimate fits the
      # budget, taken from the end. Always keeps at least one message, and
      # drops leading tool results so the slice starts on a conversation
      # boundary. Mirrors `takeRecentMessagesWithinTokenBudget` in full.ts.
      def self.take_recent_within_token_budget(messages : Array(ContextMessage),
                                               token_budget : Int32) : Array(ContextMessage)
        start = messages.size
        tokens = 0
        (messages.size - 1).step(to: 0, by: -1) do |i|
          msg_tokens = LLM::TokenCounter.estimate([messages[i].message])
          break if tokens + msg_tokens > token_budget
          tokens += msg_tokens
          start = i
        end
        start = 1 if start == 0
        drop_leading_tool_results(messages[start..])
      end

      # Drop the oldest message, then any tool results that now lead the
      # slice (their call is gone).
      def self.drop_oldest(messages : Array(ContextMessage)) : Array(ContextMessage)
        return messages if messages.size <= 1
        drop_leading_tool_results(messages[1..])
      end

      def self.drop_leading_tool_results(messages : Array(ContextMessage)) : Array(ContextMessage)
        start = 0
        while start < messages.size && messages[start].message.role == "tool"
          start += 1
        end
        messages[start..]
      end

      # Does the provider blame the request input itself — either a plain
      # "too large" (HTTP 413) or a 400 whose body points at the input
      # (Z.AI/GLM reports oversized input as "The messages parameter is
      # illegal")? No size assumption is made; callers that can shrink the
      # input should combine this with their own evidence via
      # `overflow_error?`.
      def self.input_rejection?(error : LLM::ApiError) : Bool
        return true if error.status_code == 413
        error.status_code == 400 &&
          error.message.to_s.matches?(/context|token|message|length|too (large|long)|exceed|maximum|illegal/i)
      end

      # Does this provider failure mean "the summarizer request itself does
      # not fit"? An input rejection qualifies when the estimated request
      # occupies at least `OVERFLOW_RECOVERY_RATIO` of the context window
      # (mirrors `shouldRecoverFromContextOverflow` in full.ts) — with a
      # small request, shrinking cannot be the fix, so the error is left to
      # propagate.
      def self.overflow_error?(error : LLM::ApiError, estimated_tokens : Int32,
                               max_context_tokens : Int32) : Bool
        return false if max_context_tokens <= 0
        return false unless estimated_tokens >= (max_context_tokens * OVERFLOW_RECOVERY_RATIO).to_i32
        input_rejection?(error)
      end
    end

    enum CompactionStatus
      Completed
      Cancelled
      Failed
    end

    struct CompactionResult
      getter status : CompactionStatus
      getter summary : String
      getter tokens_before : Int32
      getter tokens_after : Int32
      getter messages_before : Int32
      getter messages_after : Int32
      # Messages trimmed from the summarizer input by the overflow/empty
      # shrink loops — they are not covered by the produced summary.
      getter dropped_count : Int32

      def initialize(@status : CompactionStatus,
                     @summary : String,
                     @tokens_before : Int32,
                     @tokens_after : Int32,
                     @messages_before : Int32,
                     @messages_after : Int32,
                     @dropped_count : Int32 = 0)
      end

      def cancelled? : Bool
        @status == CompactionStatus::Cancelled
      end

      def failed? : Bool
        @status == CompactionStatus::Failed
      end

      def completed? : Bool
        @status == CompactionStatus::Completed
      end
    end
  end
end
