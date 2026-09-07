require "json"

module H2code
  module Tools
    # GetContextRemaining — context-window budget introspection for the model.
    #
    # The agent's context memory tracks an estimate of tokens used against
    # the provider's context window. Exposing that figure as a read-only
    # tool lets the model pace itself: trim tool outputs, avoid re-reading
    # large files, and warn the user before an automatic compaction fires.
    #
    # Codex exposes the same capability as `get_context_remaining`.
    class GetContextRemaining < Tool
      DESCRIPTION = <<-TEXT
        Get the remaining context-window budget for this session.

        Returns tokens used, the window size, tokens remaining, and percent used. Use this to pace long tasks: when the budget runs low, prefer targeted reads over whole files, trim tool outputs, and tell the user the session is close to automatic compaction. Takes no arguments.
      TEXT

      def initialize(@memory : Context::Memory)
      end

      def name : String
        Names::GET_CONTEXT_REMAINING
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
        used = @memory.token_count
        max = @memory.max_context_tokens
        remaining = {max - used, 0}.max
        percent = @memory.token_usage_percent.round(1)

        lines = [] of String
        lines << "tokens_used: #{used}"
        lines << "context_window: #{max}"
        lines << "tokens_remaining: #{remaining}"
        lines << "percent_used: #{percent}"
        if @memory.near_limit?
          lines << "near_limit: true"
          lines << "note: the session is close to automatic compaction — avoid large tool outputs and warn the user if this persists."
        else
          lines << "near_limit: false"
        end
        ToolResult.success(lines.join('\n'))
      end
    end
  end
end
