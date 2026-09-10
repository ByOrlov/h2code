module H2code
  module Context
    struct ContextMessage
      property message : LLM::Message
      property origin : MessageOrigin = MessageOrigin::Normal

      def initialize(@message : LLM::Message, @origin : MessageOrigin = MessageOrigin::Normal)
      end

      def profiled_bytes : Int64
        @message.profiled_bytes
      end
    end

    enum MessageOrigin
      Normal
      Injection
      # Background-result notifications (e.g. a detached subagent finishing).
      # Unlike `Injection` (per-step protocol state pruned at the start of
      # every step), notification content is conversation: it must survive
      # `prune_injections` so the model actually sees it on a later step.
      Notification
      CompactionSummary
    end

    class Memory
      getter history : Array(ContextMessage) = [] of ContextMessage
      getter token_count : Int32 = 0
      property max_context_tokens : Int32 = 262144

      def add_user(content : String) : Nil
        @history << ContextMessage.new(LLM::Message.user(content))
        update_token_count
      end

      # User message with explicit content parts — the pasted-media path
      # (interleaved text + image parts resolved from editor placeholders).
      def add_user_parts(parts : Array(LLM::ContentPart)) : Nil
        @history << ContextMessage.new(LLM::Message.user(parts))
        update_token_count
      end

      def add_assistant(text : String, tool_calls : Array(LLM::ToolCall)? = nil) : Nil
        msg = LLM::Message.assistant(text, tool_calls)
        @history << ContextMessage.new(msg)
        update_token_count
      end

      def add_assistant_parts(parts : Array(LLM::ContentPart), tool_calls : Array(LLM::ToolCall)? = nil) : Nil
        msg = LLM::Message.assistant_parts(parts, tool_calls)
        @history << ContextMessage.new(msg)
        update_token_count
      end

      def add_tool_result(tool_call_id : String, content : String) : Nil
        msg = LLM::Message.tool(content, tool_call_id)
        @history << ContextMessage.new(msg)
        update_token_count
      end

      # Multi-part tool result (text + media content parts). Stores the same
      # parts structure the loop sends on the wire.
      def add_tool_result_parts(tool_call_id : String, parts : Array(LLM::ContentPart)) : Nil
        msg = LLM::Message.tool_parts(parts, tool_call_id)
        @history << ContextMessage.new(msg)
        update_token_count
      end

      def add_injection(content : String) : Nil
        msg = LLM::Message.system(content)
        @history << ContextMessage.new(msg, MessageOrigin::Injection)
        update_token_count
      end

      # Background-result notification (e.g. a detached subagent's completion).
      # Stored like an injection but with `Notification` origin so the
      # per-step `prune_injections` sweep — which removes transient step
      # reminders — does not drop it before the model has seen it.
      def add_notification(content : String) : Nil
        msg = LLM::Message.system(content)
        @history << ContextMessage.new(msg, MessageOrigin::Notification)
        update_token_count
      end

      def apply_compaction(summary : String, kept_messages : Array(ContextMessage)) : Nil
        @history.clear
        @history << ContextMessage.new(
          LLM::Message.system(summary),
          MessageOrigin::CompactionSummary
        )
        @history.concat(kept_messages)
        update_token_count
      end

      def undo(count : Int32 = 1) : Nil
        Undo.undo!(self, count)
      end

      # Force a token-count recalculation after external mutation of
      # `@history` (e.g. by `Context::Undo`). The normal add/remove paths
      # call `update_token_count` themselves; this is the escape hatch for
      # code that rewrites the array in place.
      def recalculate_token_count : Nil
        update_token_count
      end

      # Overwrite the token count with the authoritative figure reported by
      # the provider's usage object (prompt + completion tokens). The local
      # estimator used by `update_token_count` is only a stopgap between
      # round-trips; once the API returns the real number it supersedes the
      # estimate. A zero/non-positive value is ignored so a provider that
      # reports no usage does not clobber the estimate.
      def update_token_count_from_usage(prompt_tokens : Int32, completion_tokens : Int32) : Nil
        total = prompt_tokens + completion_tokens
        @token_count = total if total > 0
      end

      def clear : Nil
        @history.clear
        @token_count = 0
      end

      def prune_injections : Nil
        @history.reject!(&.origin.injection?)
        update_token_count
      end

      def messages : Array(LLM::Message)
        @history.map(&.message)
      end

      def token_usage_percent : Float64
        return 0.0 if @max_context_tokens == 0
        (@token_count.to_f64 / @max_context_tokens.to_f64) * 100.0
      end

      def near_limit? : Bool
        @token_count >= (@max_context_tokens * 0.9).to_i32
      end

      def last_user_message_index : Int32?
        @history.rindex { |cm| cm.message.role == "user" && cm.origin.normal? }
      end

      private def update_token_count : Nil
        msgs = @history.map(&.message)
        @token_count = LLM::TokenCounter.estimate(msgs)
      end

      # Deep byte size of the conversation history — the main memory consumer.
      # Used by the `/memory` profiler (`ProfiledMemory`). Sums the profiled
      # bytes of every retained message; array overhead itself is negligible
      # relative to the string payloads.
      def profiled_bytes : Int64
        @history.sum(&.profiled_bytes)
      end

      def profiled_count : Int32
        @history.size
      end
    end
  end
end
