module H2code
  module TUI
    struct ReadGroupEntry
      property tool_call_id : String
      property tool_args : String
      property tool_result : String?
      property? is_error : Bool = false

      def initialize(@tool_call_id : String, @tool_args : String)
      end

      def profiled_bytes : Int64
        total = @tool_call_id.profiled_bytes + @tool_args.profiled_bytes
        total += @tool_result.try(&.profiled_bytes) || 0_i64
        total
      end
    end

    # Live state of one subagent inside a swarm/agent tool call. Updated by
    # SubagentStarted/Progress/Completed/Failed events and rendered as an
    # animated grid cell by `render_swarm_progress`.
    struct SwarmMember
      property agent_id : String
      property phase : String # "Running" | "Completed" | "Failed" | "Aborted"
      property ticks : Int32 = 0
      property item_text : String = ""
      property swarm_index : Int32 = 0
      # Streaming assistant text from the child agent, capped to avoid unbounded
      # growth. The TUI renders the last 1–3 non-empty lines of this buffer as a
      # live preview in the active zone (mirrors kimi-code's latestModelText).
      property latest_text : String = ""

      def initialize(@agent_id : String, @phase : String = "Running")
      end

      def completed? : Bool
        @phase == "Completed"
      end

      def failed? : Bool
        # A failed member carries either the canonical "Failed"/"Aborted"
        # phase or the raw error text (set by subagent_failed). Anything that
        # isn't the running start phase and isn't Completed is a terminal
        # failure — matching on exact strings would leave custom error text
        # misclassified as still-running and lock the swarm grid forever.
        !running? && !completed?
      end

      def done? : Bool
        !running?
      end

      def running? : Bool
        @phase == "Running" || @phase.empty?
      end
    end

    MCP_HELP_TEXT = <<-TEXT
      MCP (Model Context Protocol) lets you connect external tool servers to h2code.
      Here is how to set one up.

      Step 1 — Create the config file

        Open (or create) ~/.h2code/mcp.json. This is the global config.
        Project-local overrides are also supported (see the note at the bottom).

      Step 2 — Add a server entry

        Every file has the same top-level shape: a "mcpServers" object where
        each key is a server name you choose. Two server types are supported.

        a) Local server (stdio) — h2code launches a child process:

             {
               "mcpServers": {
                 "github": {
                   "command": "npx",
                   "args": ["-y", "@modelcontextprotocol/server-github"],
                   "env": { "GITHUB_TOKEN": "ghp_xxx" }
                 }
               }
             }

        b) Remote server (HTTP/SSE) — h2code connects to a URL:

             {
               "mcpServers": {
                 "remote": {
                   "type": "http",
                   "url": "https://mcp.example.com/sse",
                   "bearerTokenEnvVar": "MCP_REMOTE_TOKEN"
                 }
               }
             }

           For remote servers, put the token in an environment variable
           (export MCP_REMOTE_TOKEN=... in your shell). It is never written
           to the config file.

      Step 3 — Apply the changes

        Run /mcp update to (re)connect. Use /mcp status to check that the
        server is connected and see its tools.

      Tips

        - Tools from MCP servers appear as mcp__<server>__<tool>.
        - Config file locations (later overrides earlier, by server name):
            ~/.h2code/mcp.json            (global)
            <project-root>/.mcp.json     (nearest parent with .git)
            <cwd>/.h2code/mcp.json        (project-local)
        - Optional fields per server:
            "enabled": false              skip this server
            "enabledTools": ["foo"]       register only these tools
            "disabledTools": ["bar"]      hide these tools
            "startupTimeoutMs": 30000     connection timeout
            "toolTimeoutMs": 60000        per tool-call timeout
            "providers": ["moonshot"]     load only for these providers
      TEXT

    struct Message
      property role : String
      property content : String
      property tool_call_id : String = ""
      property tool_name : String?
      property tool_args : String?
      property tool_result : String?
      property tool_display : Tools::ToolDisplay? = nil
      property? is_error : Bool = false
      property? expanded : Bool = false
      property step : Int32 = 0
      property read_group : Array(ReadGroupEntry)?
      # Plan-box: when a tool result carries an ExitPlanMode plan (approved,
      # auto-approved, or rejected), the plan body is lifted out of the raw
      # result text and rendered as a bordered box — mirrors TS PlanBoxComponent.
      property plan_path : String?
      property plan_kind : String = "" # "approved" | "auto_approved" | "rejected"
      # Compaction block: a transcript entry that blinks while compaction is
      # in flight, then settles into a "complete (N → M tokens)" summary.
      # Mirrors TS `CompactionComponent`. Ctrl-O expands/collapses the
      # summary inline (reuses the generic `expanded` flag).
      property compaction_state : String = "" # "" | "running" | "done" | "cancelled"
      property tokens_before : Int32? = nil
      property tokens_after : Int32? = nil
      property summary : String = ""
      property tip : String = ""
      # Optional RAM-usage line (set by --ram). Rendered inside the tool
      # block right under the result preview, dim+italic so it visually
      # separates from the actual tool output.
      property ram_line : String? = nil
      # Optional telemetry line (set when `/telemetry` is on and a tracked
      # counter increased during this tool call's render). Rendered in yellow
      # right under the result preview, mirroring `ram_line`.
      property telemetry_line : String? = nil
      # Swarm/Agent live progress: when non-empty, the tool block renders an
      # animated grid of per-subagent cells instead of the static header.
      property swarm_members : Array(SwarmMember) = [] of SwarmMember
      # Todo snapshot: when a TodoList reaches all-done, the live panel is
      # frozen into the transcript (role "todo_snapshot") so it migrates from
      # the active zone into the append-only log. Carries `{title, status}`
      # pairs rendered identically to the active-zone panel. See TUI_ZONES.md.
      property todo_items : Array({String, String})? = nil

      def initialize(@role : String, @content : String = "")
      end

      # Deep byte size of this transcript entry — the strings it carries.
      # `tool_display` (diff before/after) is included when present.
      def profiled_bytes : Int64
        total = @role.profiled_bytes + @content.profiled_bytes
        total += @tool_call_id.profiled_bytes unless @tool_call_id.empty?
        total += @tool_name.try(&.profiled_bytes) || 0_i64
        total += @tool_args.try(&.profiled_bytes) || 0_i64
        total += @tool_result.try(&.profiled_bytes) || 0_i64
        total += @summary.profiled_bytes unless @summary.empty?
        total += @tip.profiled_bytes unless @tip.empty?
        total += @ram_line.try(&.profiled_bytes) || 0_i64
        total += @telemetry_line.try(&.profiled_bytes) || 0_i64
        if d = @tool_display
          total += d.before.try(&.profiled_bytes) || 0_i64
          total += d.after.try(&.profiled_bytes) || 0_i64
        end
        if group = @read_group
          total += group.sum(&.profiled_bytes)
        end
        total
      end
    end

    struct ApprovalRequest
      property tool_name : String
      property args : String
      property danger : String?

      def initialize(@tool_name : String, @args : String, @danger : String?)
      end
    end

    # A message typed while the agent is mid-turn. Mirrors the TS
    # `QueuedMessage` (mode 'prompt' = normal message, 'bash' = queued shell
    # command — not yet used). Drained FIFO on turn end; `Ctrl+S` (steer)
    # injects it into the *current* turn instead, via `Agent#steer`.
    struct QueuedMessage
      property text : String
      property mode : String # "prompt" | "bash"
      # Media content parts resolved from pasted placeholders at submit time
      # (nil for plain-text messages). Delivered to the turn with the text.
      property parts : Array(LLM::ContentPart)? = nil

      def initialize(@text : String, @mode : String = "prompt",
                     @parts : Array(LLM::ContentPart)? = nil)
      end
    end
  end
end
