require "json"

module H2code
  module Tools
    # CurrentTime — read-only clock access for the model.
    #
    # The system prompt's "current date and time" is captured once at session
    # start and goes stale in long sessions; every time-sensitive decision
    # (cache freshness, expiry checks, cron schedules, "is it a weekday")
    # should come from this tool instead of the prompt snapshot.
    #
    # Codex exposes the same capability as `curr_time` in its `clock`
    # namespace.
    class CurrentTime < Tool
      DESCRIPTION = <<-TEXT
        Get the current date and time.

        Returns local time (ISO 8601 with UTC offset), UTC time, and Unix epoch milliseconds. Use this whenever the real current time matters — the timestamp in the system prompt was captured when the session started and may be hours or days stale. Takes no arguments.
      TEXT

      def name : String
        Names::CURRENT_TIME
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
        now = Time.local
        lines = [] of String
        lines << "local: #{now.to_rfc3339}"
        lines << "utc: #{now.to_utc.to_rfc3339}"
        lines << "unix_ms: #{now.to_unix_ms}"
        ToolResult.success(lines.join('\n'))
      end
    end
  end
end
