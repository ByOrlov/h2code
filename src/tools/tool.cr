# Pull in the tool-name constants so any file that loads `Tool` (directly
# or via the centralized require chain) can reference `Names::*` without a
# separate require. Idempotent with the explicit require in h2code.cr.
require "./names"
# Same for the shell port backing the Bash tool's SHELL_PORT constant.
require "../shell_port"

module H2code
  module Tools
    abstract class Tool
      # Composition roots for cross-platform process termination and command
      # interpretation. Tools that spawn subprocesses use these instead of
      # `LibC.kill` (POSIX-only) and hardcoded `/bin/sh`/`bash` assumptions.
      PROCESS_PORT = ::H2code::ProcessPort.default
      SHELL_PORT   = ::H2code::ShellPort.default

      abstract def name : String
      abstract def description : String
      abstract def parameters : JSON::Any
      abstract def execute(input : JSON::Any) : ToolResult

      # Set by ToolBatch before each execute call so tools that spawn
      # subagents (AgentSwarm, Agent) can emit lifecycle events tied to
      # the parent tool_call_id in the transcript.
      property tool_call_id : String = ""

      # Set by ToolBatch before each execute call to the agent's abort
      # controller. Tools that spawn long-running work (subprocesses, long
      # HTTP reads) poll this so an ESC/Ctrl+C interrupt tears their work
      # down immediately instead of waiting out `execute_tool`'s grace period
      # and leaving orphan processes behind.
      property abort_check : -> Bool = -> { false }

      def to_definition : LLM::ToolDefinition
        LLM::ToolDefinition.new(
          LLM::ToolFunction.new(name, description, parameters)
        )
      end

      # Sanitize tool output so it is always valid UTF-8 and free of the
      # control bytes that chat providers reject with HTTP 400. Tools can
      # capture arbitrary bytes (e.g. `cat` on an ELF binary, `/dev/urandom`,
      # a crashed process writing to stderr), and `String.new(Bytes)` does NOT
      # validate UTF-8 — a single invalid byte in the request body turns into
      # "Chat API error 400". This is the single boundary where untrusted
      # external bytes (subprocess output, file contents, HTTP bodies) enter
      # the agent's message stream, so it is the right place to scrub.
      SANITIZE_NOTICE = "\n[...output contained invalid UTF-8 / binary data and was sanitized]"

      def self.sanitize_output(content : String) : String
        scrubbed = content.scrub
        replaced = false
        # Replace C0 control bytes except the common whitespace (\t \n \r)
        # and the embedded NUL, which are valid UTF-8 but trip up providers
        # and render as garbage in the TUI.
        cleaned = scrubbed.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F]/) do
          replaced = true
          "\uFFFD"
        end
        # If anything actually changed, tell the model the output was binary so
        # it does not mistake a wall of replacement chars for real content.
        (scrubbed != content || replaced) ? cleaned + SANITIZE_NOTICE : cleaned
      end

      # Wait for `process` to exit, reacting to an abort request or a
      # `timeout_s` deadline. On either, the process is killed two-phase
      # (SIGTERM, then SIGKILL after `kill_grace_s`) and reaped. Returns the
      # exit status plus `timed_out` / `aborted` flags so callers can shape
      # the result message.
      #
      # This replaces the bare `select ... when status_ch.receive when
      # timeout(...)` wait that blocked tool fibers past an ESC interrupt:
      # the abort was invisible to the tool, so the child process ran to
      # completion (orphaned) and the tool only returned after
      # `Loop.execute_tool`'s 2s grace expired. Polling `aborted?` here kills
      # the process within one `poll_interval` of the interrupt.
      def self.wait_for_exit(process : Process, timeout_s : Int32?,
                             aborted? : -> Bool = -> { false },
                             poll_interval : Time::Span = 100.milliseconds,
                             kill_grace_s : Int32 = 2) : {Process::Status, Bool, Bool}
        status_ch = Channel(Process::Status).new
        spawn { status_ch.send(process.wait) }

        deadline = timeout_s ? Time.monotonic + timeout_s.seconds : nil
        timed_out = false
        aborted = false

        loop do
          select
          when status = status_ch.receive
            return {status, timed_out, aborted}
          when timeout(poll_interval)
            if aborted?.call
              aborted = true
              break
            end
            if deadline && Time.monotonic >= deadline
              timed_out = true
              break
            end
          end
        end

        # Abort or timeout fired: kill (two-phase) and reap.
        process.terminate rescue nil
        select
        when status = status_ch.receive
          {status, timed_out, aborted}
        when timeout(kill_grace_s.seconds)
          PROCESS_PORT.force_kill(process)
          {status_ch.receive, timed_out, aborted}
        end
      end
    end

    # Structured display metadata carried alongside a tool's textual result.
    # Mirrors the TS `ToolInputDisplay` `file_io` / `diff` kinds: decouples TUI
    # rendering (e.g. the Edit diff view) from re-parsing the raw `tool_args`
    # JSON, which is brittle when argument key names drift between the schema
    # and the renderer (see `App#render_edit_diff`).
    struct ToolDisplay
      property kind : String       # "file_io" | "diff" | ...
      property operation : String? # "read" | "write" | "edit"
      property path : String?
      property before : String?
      property after : String?

      def initialize(@kind : String, @operation : String? = nil, @path : String? = nil,
                     @before : String? = nil, @after : String? = nil)
      end
    end

    struct ToolResult
      property content : String
      property? is_error : Bool = false
      property? truncated : Bool = false
      property display : ToolDisplay? = nil

      def initialize(@content : String, @is_error : Bool = false, *, truncated : Bool = false)
        @truncated = truncated
      end

      def self.success(content : String) : ToolResult
        new(content, false)
      end

      def self.error(content : String) : ToolResult
        new(content, true)
      end
    end

    class ToolContext
      property work_dir : String
      property timeout_seconds : Int32 = 120

      def initialize(@work_dir : String)
      end
    end
  end
end
