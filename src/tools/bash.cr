module H2code
  module Tools
    class Bash < Tool
      DEFAULT_TIMEOUT_S =  60
      MAX_TIMEOUT_S     = 300

      # Background-specific timeouts.
      DEFAULT_BG_TIMEOUT_S =    600
      MAX_BG_TIMEOUT_S     = 86_400

      # In-tool output cap. The context budget (Context::Budget) separately
      # truncates at 50k chars for the model context; this cap mirrors the JS
      # BashTool's 10 MB foreground buffer so a runaway command (e.g. `yes`,
      # `cat /dev/urandom`) cannot exhaust memory before the budget runs.
      MAX_OUTPUT_BYTES           = 10 * 1024 * 1024
      OUTPUT_TRUNCATION_SENTINEL = "\n[...truncated]\nOutput is truncated to fit in the message."

      @work_dir : String
      @task_service : TaskService?
      @session_dir : String?
      @delivery : (String -> Nil)?

      # Sudo permission modes.
      #   Off     — sudo commands are always disallowed (default).
      #   Request — ask the user for approval each time a sudo command runs.
      #   Always  — sudo commands are allowed without asking.
      enum SudoMode
        Off
        Request
        Always
      end

      enum SudoApprovalChoice
        AllowOnce
        AlwaysAllow
        Deny
      end

      # App-wide sudo default, set once from Config at startup so every Bash
      # instance (main agent, subagents, ACP) starts with the same mode —
      # `/sudo` adjusts the main instance at runtime and persists the value
      # back to config.json. Defaults to Off — sudo commands are disallowed
      # until the user raises the mode.
      class_property default_sudo_mode : SudoMode = SudoMode::Off

      # Per-instance sudo permission state, initialized from the app-wide
      # default. Runtime changes (TUI `/sudo`, approval dialogs) affect only
      # the instance they are applied to.
      @sudo_mode : SudoMode = Bash.default_sudo_mode
      @sudo_approval : (String -> SudoApprovalChoice)?
      @terminal_exec : TerminalExecService?

      # Class-level OS-env proxies, set once from Config at startup so every
      # Bash instance (main agent, subagents, ACP server) shares the same value
      # without each one re-reading ENV. Defaults mirror the prior inline reads.
      class_property git_terminal_prompt : String? = nil
      class_property shell : String? = nil

      def sudo_mode=(mode : SudoMode) : Nil
        @sudo_mode = mode
      end

      def sudo_mode : SudoMode
        @sudo_mode
      end

      def sudo_approval=(cb : (String -> SudoApprovalChoice)?) : Nil
        @sudo_approval = cb
      end

      def sudo_approval : (String -> SudoApprovalChoice)?
        @sudo_approval
      end

      # Injected terminal-exec bridge. When set and a command is detected as
      # requiring elevated privileges (sudo), the command is routed through this
      # service instead of the normal piped execution path. nil → sudo commands
      # fall back to the normal path (stdin closed, sudo will fail with
      # "a terminal is required to read the password"). Wired only by the TUI.
      def terminal_exec=(svc : TerminalExecService?) : Nil
        @terminal_exec = svc
      end

      def terminal_exec : TerminalExecService?
        @terminal_exec
      end

      def initialize(@work_dir : String = Dir.current,
                     @task_service : TaskService? = nil,
                     @session_dir : String? = nil,
                     @delivery : (String -> Nil)? = nil)
        @sudo_approval = nil
        @terminal_exec = nil
      end

      # Late-injected delivery callback (TUI pumps background-completion
      # notifications into the active turn). Set after registration so the
      # same Bash instance serves both headless (nil) and interactive runs.
      def delivery=(callback : (String -> Nil)?) : Nil
        @delivery = callback
      end

      def name : String
        Names::BASH
      end

      def description : String
        # The tool's *name* is fixed platform-independent ("Bash" — it is
        # matched against in permission rules, dedup tracking, the TUI), but
        # the interpreter actually behind it is OS-specific (ShellPort). The
        # description is the only channel the model has to learn which syntax
        # is safe, so it names the resolved interpreter and carries the
        # port's guidance verbatim.
        %(Execute a `#{SHELL_PORT.name}` command. Use this for shell semantics — pipes, env, processes, git, package managers, build/test runners, anything genuinely interactive or multi-step.

Translate these to a dedicated tool instead:
- `cat` / `head` / `tail` (known path) → `Read`
- `sed` / `awk` (in-place edit) → `Edit`
- `echo > file` / `cat <<EOF` → `Write`
- `find` / recursive `ls` to locate files by name pattern → `Glob` (plain `ls <known-directory>` is fine for listing a directory)
- `grep` / `rg` (search file contents) → `Grep`

The dedicated tools keep raw stdout out of the conversation; that is why they are worth reaching for whenever one fits.

Output:
The stdout and stderr will be combined and returned as a string. The output may be truncated if it is too long. If the command exits non-zero, the output ends with a `Command failed with exit code: N` line; a command killed by its timeout ends with its own message instead.

Guidelines for safety and security:
- Each shell tool call will be executed in a fresh shell environment. The shell variables, current working directory changes, and the shell history is not preserved between calls. To run a command in a particular directory, pass the `cwd` argument (or use absolute paths) rather than relying on a `cd` from an earlier call.
- The tool call will return after the command is finished. You shall not use this tool to execute an interactive command or a command that may run forever. For possibly long-running commands, set the `timeout` argument in seconds. The default is #{DEFAULT_TIMEOUT_S}s; the maximum is #{MAX_TIMEOUT_S}s; a command that hits its timeout is killed.
- Avoid using `..` to access files or directories outside of the working directory.
- Avoid modifying files outside of the working directory unless explicitly instructed to do so.
- Never run commands that require superuser privileges unless explicitly instructed to do so.

Guidelines for efficiency:
- Use `&&` to chain commands that genuinely depend on each other, e.g. `npm install && npm test`. Independent read-only commands (separate `git show`, `ls`, or status checks) should be issued as separate parallel Bash calls in one response, not chained into a single call — chaining serializes their execution and mixes their output.
- Use `;` to run commands sequentially regardless of success/failure.
- Use `||` for conditional execution (run second command only if first fails).
- Use pipe operations (`|`) and redirections (`>`, `>>`) to chain input and output between commands.
- Always quote file paths containing spaces with double quotes (e.g. cd "/path with spaces/").
- Compose multi-step logic in a single call with `if` / `case` / `for` / `while` control flows.

For long-running commands, pass run_in_background: true. The tool returns immediately with a task_id, and the full output is streamed to a file. Use TaskList / TaskOutput / TaskStop to inspect or control the background task; you will be automatically notified when it completes.

#{SHELL_PORT.guidance})
      end

      def parameters : JSON::Any
        # Background-related params are advertised only when a TaskService is
        # wired, so the model never sees run_in_background for an agent that
        # cannot honour it (e.g. subagents). The runtime guard in `execute`
        # remains as a defence-in-depth check.
        bg_params = if @task_service
                      %(
            "run_in_background": {
              "type": "boolean",
              "default": false,
              "description": "Run the command in the background and return immediately with a task_id. The full output is streamed to a file; use TaskOutput to read it and TaskStop to cancel. Completion is delivered as a notification."
            },
            "disable_timeout": {
              "type": "boolean",
              "default": false,
              "description": "When true and run_in_background is true, the background process runs with no timeout. Only effective for background tasks."
            }
          )
                    else
                      ""
                    end
        JSON.parse(%({
          "type": "object",
          "properties": {
            "command": {
              "type": "string",
              "description": "The command to execute."
            },
            "cwd": {
              "type": "string",
              "description": "The working directory in which to run the command. When omitted, the command runs in the session's working directory."
            },
            "timeout": {
              "type": "integer",
              "description": "Optional timeout in seconds. The default is #{DEFAULT_TIMEOUT_S}s; the maximum is #{MAX_TIMEOUT_S}s for foreground and #{MAX_BG_TIMEOUT_S}s for background. A command that hits its timeout is killed (foreground) or timed_out (background).",
              "default": #{DEFAULT_TIMEOUT_S}
            },
            "description": {
              "type": "string",
              "description": "A short description of what this command does. Shown in the approval UI."
            }#{bg_params.empty? ? "" : ", #{bg_params}"}
          },
          "required": ["command"]
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        command = input["command"]?.try(&.to_s) || ""
        return ToolResult.error("Command cannot be empty.") if command.empty?

        run_in_background = input["run_in_background"]?.try(&.as_bool?) == true

        # Background execution requires a TaskService to track the process.
        if run_in_background
          if @task_service.nil?
            return ToolResult.error(
              "Background execution is not available for this agent. " \
              "Do not set run_in_background=true.",
            )
          end
          return execute_background(input, command)
        end

        execute_foreground(input, command)
      end

      # ------------------------------------------------------------------
      # Foreground execution
      # ------------------------------------------------------------------

      private def execute_foreground(input : JSON::Any, command : String) : ToolResult
        timeout_s = parse_timeout(input["timeout"]?)
        cwd = input["cwd"]?.try(&.to_s)
        effective_cwd = (cwd.nil? || cwd.empty?) ? @work_dir : cwd

        spawn_env = build_env

        # Sudo commands need a real terminal (sudo reads the password from
        # /dev/tty). Check sudo permission first, then route through
        # TerminalExecService if available.
        if sudo_command?(command)
          unless sudo_allowed?(command)
            return ToolResult.error("sudo disallowed for agent. Use /sudo always or /sudo request to enable.")
          end
          if svc = @terminal_exec
            return execute_in_terminal(svc, command, effective_cwd, spawn_env, timeout_s)
          end
        end

        process = SHELL_PORT.spawn(command, spawn_env, effective_cwd)
        # Close stdin immediately so interactive commands (`cat`, `read`,
        # `python -c 'input()'`) receive EOF instead of hanging the tool.
        process.input.close

        stdout_ch = Channel(Capture).new
        stderr_ch = Channel(Capture).new

        spawn { stdout_ch.send(capture(process.output)) }
        spawn { stderr_ch.send(capture(process.error)) }

        status, timed_out, aborted = Tool.wait_for_exit(process, timeout_s, abort_check)

        out_cap = stdout_ch.receive
        err_cap = stderr_ch.receive

        truncated = out_cap.truncated? || err_cap.truncated?
        result = combine_output(out_cap.text, err_cap.text)
        result += OUTPUT_TRUNCATION_SENTINEL if truncated

        if aborted
          ToolResult.error("#{result}\n[interrupted by user]")
        elsif timed_out
          ToolResult.error("#{result}\n[Command timed out after #{timeout_s}s and was killed]")
        elsif !status.normal_exit?
          ToolResult.error("#{result}\n[killed by signal]")
        elsif status.exit_code != 0
          # Keep the `[exit code: N]` trailer format: the TUI
          # (h2code.cr render_tool_block) parses it to render a red footer.
          ToolResult.error("#{result}\n[exit code: #{status.exit_code}]")
        else
          ToolResult.success(result.strip)
        end
      rescue ex : File::NotFoundError
        ToolResult.error("Failed to execute command: shell not found")
      rescue ex : IO::Error
        ToolResult.error("Failed to execute command: #{ex.message}")
      rescue ex
        ToolResult.error("Unexpected error: #{ex.message}")
      end

      # ------------------------------------------------------------------
      # Terminal execution (sudo)
      # ------------------------------------------------------------------

      private def sudo_command?(command : String) : Bool
        Permission::Danger.detect_command(command) == "elevated privileges"
      end

      private def sudo_allowed?(command : String) : Bool
        case @sudo_mode
        in SudoMode::Off
          false
        in SudoMode::Always
          true
        in SudoMode::Request
          if cb = @sudo_approval
            case cb.call(command)
            in SudoApprovalChoice::AllowOnce
              true
            in SudoApprovalChoice::AlwaysAllow
              @sudo_mode = SudoMode::Always
              true
            in SudoApprovalChoice::Deny
              false
            end
          else
            false
          end
        end
      end

      private def execute_in_terminal(svc : TerminalExecService, command : String,
                                      cwd : String, env : Hash(String, String?),
                                      timeout_s : Int32) : ToolResult
        result = svc.run(command, cwd, env, timeout_s, abort_check)

        output = result.output
        truncated = false
        if output.bytesize > MAX_OUTPUT_BYTES
          output = output[0, MAX_OUTPUT_BYTES]
          truncated = true
        end
        output += OUTPUT_TRUNCATION_SENTINEL if truncated

        if result.aborted?
          ToolResult.error("#{output}\n[interrupted by user]")
        elsif result.timed_out?
          ToolResult.error("#{output}\n[Command timed out after #{timeout_s}s and was killed]")
        elsif result.exit_code != 0
          ToolResult.error("#{output}\n[exit code: #{result.exit_code}]")
        else
          ToolResult.success(output.strip)
        end
      rescue ex : File::NotFoundError
        ToolResult.error("Failed to execute command: shell not found")
      rescue ex : IO::Error
        ToolResult.error("Failed to execute command: #{ex.message}")
      rescue ex
        ToolResult.error("Unexpected error: #{ex.message}")
      end

      # ------------------------------------------------------------------
      # Background execution
      # ------------------------------------------------------------------

      private def execute_background(input : JSON::Any, command : String) : ToolResult
        svc = @task_service
        session_dir = @session_dir
        if svc.nil? || session_dir.nil?
          return ToolResult.error("Background execution is not available.")
        end

        cwd = input["cwd"]?.try(&.to_s)
        effective_cwd = (cwd.nil? || cwd.empty?) ? @work_dir : cwd

        disable_timeout = input["disable_timeout"]?.try(&.as_bool?) == true
        timeout_s = disable_timeout ? nil : parse_bg_timeout(input["timeout"]?)

        # Generate task metadata + output path.
        task_id = svc.next_task_id("bash")
        output_path = File.join(session_dir, "tasks", "#{task_id}.log")
        Dir.mkdir_p(File.dirname(output_path))

        spawn_env = build_env

        # Spawn the process.
        process = SHELL_PORT.spawn(command, spawn_env, effective_cwd)
        process.input.close

        now_ms = Time.utc.to_unix_ms
        info = AgentTaskInfo.new(
          task_id: task_id,
          description: input["description"]?.try(&.to_s) || command,
          status: AgentTaskStatus::Running,
          started_at: now_ms,
          detached: true,
          timeout_ms: timeout_s.try(&.to_i64.*(1000)),
          command: command,
          pid: process.pid.to_i64,
        )
        svc.register(info)

        exit_ch = Channel(Process::Status).new
        svc.register_process(task_id, process, exit_ch)

        # Monitor fiber: capture output to file, wait for exit, update status,
        # and deliver the completion notification.
        spawn do
          monitor_background(svc, task_id, process, output_path, exit_ch, command)
        end

        # Arm a timeout (if configured) on a separate fiber.
        if t = timeout_s
          spawn do
            select
            when exit_ch.receive?
              # Process exited before the timeout; nothing to do.
            when timeout(t.seconds)
              # Timeout fired — the monitor is still waiting on process.wait;
              # kill the process, the monitor will observe the exit and settle
              # as TimedOut.
              unless info.status.terminal?
                kill_two_phase(process)
              end
            end
          end
        end

        ToolResult.success(background_started_result(task_id, output_path, command))
      rescue ex : File::NotFoundError
        ToolResult.error("Failed to execute command: shell not found")
      rescue ex : IO::Error
        ToolResult.error("Failed to execute command: #{ex.message}")
      rescue ex
        ToolResult.error("Unexpected error: #{ex.message}")
      end

      private def monitor_background(svc : TaskService, task_id : String,
                                     process : Process, output_path : String,
                                     exit_ch : Channel(Process::Status),
                                     command : String) : Nil
        # Capture stdout + stderr to the output file in real time. Each stream
        # is copied in its own fiber; their completion is awaited before the
        # exit status is read so no output is lost.
        done_out = Channel(Nil).new
        done_err = Channel(Nil).new
        file = File.open(output_path, "w")

        spawn do
          begin
            IO.copy(process.output, file)
          rescue IO::Error
            # Process closed the stream early — ignore.
          ensure
            done_out.send(nil)
          end
        end

        spawn do
          begin
            # Separate stderr from stdout with a marker line so the combined
            # output is readable. A simple newline separator is enough for the
            # agent to parse the tail preview.
            first = true
            buf = Bytes.new(8192)
            loop do
              read = process.error.read(buf)
              break if read == 0
              file.puts unless first
              first = false
              file.write(buf[0, read])
            end
          rescue IO::Error
            # Stream closed — ignore.
          ensure
            done_err.send(nil)
          end
        end

        # Wait for both stream copiers to finish, then close the file and
        # read the exit status.
        done_out.receive
        done_err.receive
        file.fsync
        file.close

        status = process.wait
        exit_ch.send(status)
        exit_ch.close

        info = svc.get_task(task_id) || raise "task not found: #{task_id}"
        now_ms = Time.utc.to_unix_ms
        info.ended_at = now_ms

        if !status.normal_exit?
          info.status = AgentTaskStatus::Failed
          info.stop_reason = "killed by signal"
        elsif info.status.terminal?
          # Already terminal (e.g. killed by TaskStop or timeout) — leave it.
        elsif status.exit_code != 0
          info.status = AgentTaskStatus::Failed
          info.exit_code = status.exit_code
        else
          info.status = AgentTaskStatus::Completed
          info.exit_code = 0
        end

        # Read a tail preview for TaskOutput.
        preview = read_tail(output_path, Task::OUTPUT_PREVIEW_BYTES)
        svc.set_output(task_id, preview,
          output_path: output_path,
          full_output_available: true,
          truncated: preview.bytesize >= Task::OUTPUT_PREVIEW_BYTES)

        svc.persist_task_meta(task_id) if svc.is_a?(InMemoryTaskService)

        # Deliver the completion notification unless suppressed.
        deliver_completion(svc, task_id, command, output_path) unless svc.notification_suppressed?(task_id)
      end

      # ------------------------------------------------------------------
      # Notification delivery
      # ------------------------------------------------------------------

      private def deliver_completion(svc : TaskService, task_id : String,
                                     command : String, output_path : String) : Nil
        info = svc.get_task(task_id)
        return if info.nil?
        delivery = @delivery
        return if delivery.nil?

        status_str = info.status.to_wire
        completed = info.status.completed?

        body = String.build do |s|
          s << "Command: #{command}\n"
          if ec = info.exit_code
            s << "Exit code: #{ec}\n"
          end
          if r = info.stop_reason
            s << "Reason: #{r}\n"
          end
          s << "Output: #{output_path}\n"
          s << "Use the Read tool with the output_path to read the full log."
        end

        data = {
          "id"          => JSON::Any.new("task.#{task_id}.#{status_str}"),
          "category"    => JSON::Any.new("task_completion"),
          "type"        => JSON::Any.new(status_str),
          "source_kind" => JSON::Any.new("bash"),
          "source_id"   => JSON::Any.new(task_id),
          "title"       => JSON::Any.new("Background process #{status_str}"),
          "severity"    => JSON::Any.new(completed ? "info" : "warning"),
          "body"        => JSON::Any.new(body),
        } of String => JSON::Any

        xml = Tools.render_notification_xml(data)
        delivery.call(xml)
      end

      # ------------------------------------------------------------------
      # Helpers
      # ------------------------------------------------------------------

      private def background_started_result(task_id : String, output_path : String,
                                            command : String) : String
        lines = [] of String
        lines << "Background task started."
        lines << "task_id: #{task_id}"
        lines << "output_path: #{output_path}"
        lines << "command: #{command}"
        lines << "Use TaskOutput to read the output (non-blocking by default) and TaskStop to cancel it."
        lines.join('\n')
      end

      private def read_tail(path : String, max_bytes : Int32) : String
        return "" unless File.exists?(path)
        size = File.size(path)
        return File.read(path) if size <= max_bytes
        File.open(path) do |f|
          f.seek(size - max_bytes)
          f.gets_to_end
        end
      rescue
        ""
      end

      # Two-phase kill: SIGTERM (port-routed: Windows tree-kills), then
      # SIGKILL after 5s.
      private def kill_two_phase(process : Process) : Nil
        PROCESS_PORT.terminate(process)
        spawn do
          sleep 5.seconds
          if process.exists?
            PROCESS_PORT.force_kill(process)
          end
        end
      end

      private def parse_timeout(raw : JSON::Any?) : Int32
        value = raw.try(&.as_i?) || raw.try(&.as_s?).try(&.to_i?) || DEFAULT_TIMEOUT_S
        return DEFAULT_TIMEOUT_S if value <= 0
        {value, MAX_TIMEOUT_S}.min
      end

      private def parse_bg_timeout(raw : JSON::Any?) : Int32
        value = raw.try(&.as_i?) || raw.try(&.as_s?).try(&.to_i?) || DEFAULT_BG_TIMEOUT_S
        return DEFAULT_BG_TIMEOUT_S if value <= 0
        {value, MAX_BG_TIMEOUT_S}.min
      end

      # Hardened child env. Crystal's `Process.new(env:)` merges with the
      # parent env (inheriting PATH, HOME, …), so this hash only overrides.
      private def build_env : Hash(String, String?)
        env = {} of String => String?
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        # Default to '0' so git fails fast on private remotes if a TTY happens
        # to be inherited; honour an explicit ambient value when set.
        env["GIT_TERMINAL_PROMPT"] = Bash.git_terminal_prompt || "0"
        env["SHELL"] = Bash.shell || SHELL_PORT.env_shell
        env
      end

      private def combine_output(out_str : String, err_str : String) : String
        String.build do |s|
          s << out_str unless out_str.empty?
          unless err_str.empty?
            s << "\n" unless out_str.empty?
            s << err_str
          end
        end
      end

      # Read up to MAX_OUTPUT_BYTES from an IO, then stop and mark truncated.
      # Never raises: a killed/errored process closes its pipe mid-read, and
      # the capture fiber must still hand back whatever it collected so the
      # main fiber's `Channel#receive` cannot deadlock.
      private def capture(io : IO) : Capture
        mem = IO::Memory.new
        buf = Bytes.new(8192)
        total = 0
        truncated = false
        begin
          loop do
            read = io.read(buf)
            break if read == 0
            remaining = MAX_OUTPUT_BYTES - total
            if read > remaining
              mem.write(buf[0, remaining])
              truncated = true
              # Drain the rest so the child does not block on a full pipe,
              # discarding everything past the cap.
              drain(io, buf)
              break
            end
            mem.write(buf[0, read])
            total += read
          end
        rescue IO::Error
          # Process killed or stream closed — return what we have so far.
        end
        Capture.new(mem.to_s, truncated)
      end

      private def drain(io : IO, buf : Bytes) : Nil
        loop do
          break if io.read(buf) == 0
        end
      rescue IO::Error
        # Best-effort drain; ignore a closed stream.
      end

      private struct Capture
        getter text : String
        getter? truncated : Bool

        def initialize(@text : String, @truncated : Bool)
        end
      end
    end

    # Result of running a command through a real terminal (alt screen).
    struct TerminalExecResult
      getter output : String
      getter exit_code : Int32
      getter? timed_out : Bool
      getter? aborted : Bool

      def initialize(@output : String, @exit_code : Int32,
                     @timed_out : Bool = false, @aborted : Bool = false)
      end
    end

    # Bridge for executing commands in a real terminal (alt screen + cooked
    # termios) so programs that read from /dev/tty (sudo, ssh, …) can prompt
    # for passwords naturally. The TUI provides a concrete implementation
    # wired via `Bash#terminal_exec=`. When nil, sudo commands fall back to
    # the normal piped path (which will fail for password prompts).
    abstract class TerminalExecService
      abstract def run(command : String, cwd : String?,
                       env : Hash(String, String?), timeout_s : Int32?,
                       aborted? : -> Bool) : TerminalExecResult
    end
  end
end
