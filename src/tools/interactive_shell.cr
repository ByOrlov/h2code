require "json"

module H2code
  module Tools
    # InteractiveShell — persistent shell sessions with writable stdin.
    #
    # The Bash tool runs one-shot commands; background tasks stream output
    # but cannot be fed input. This tool keeps a long-running process alive
    # (a REPL, a dev server, a debugger) and lets the model write to its
    # stdin, read new output incrementally, and eventually kill it — a
    # dialogue with the process instead of a single request/response.
    #
    # Codex exposes the same capability as `unified_exec` + `write_stdin`.
    #
    # Lifecycle: sessions live in a process-global service (the Cron
    # pattern), survive across tool calls within one h2code process, and
    # are killed by `stop_all` on agent exit. They are NOT background
    # tasks: TaskList/TaskStop do not see them; use the `list` / `kill`
    # actions instead.
    class ShellSession
      MAX_BUFFER_BYTES = 1_048_576 # 1 MiB ring per session

      getter id : String
      getter command : String
      getter started_at : Int64

      @process : Process
      @mutex = Mutex.new
      @chunks = [] of String
      @buffered = 0
      @read_index = 0
      @input_closed = false
      @exit_message : String? = nil

      def initialize(@id : String, @command : String, cwd : String?)
        @started_at = Time.utc.to_unix_ms
        env = {} of String => String?
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["SHELL"] = Bash.shell || Tool::SHELL_PORT.env_shell
        @process = Process.new(
          Tool::SHELL_PORT.program,
          Tool::SHELL_PORT.shell_args(@command),
          env: env,
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe,
          chdir: cwd,
        )

        spawn { pump(@process.output) }
        spawn { pump(@process.error) }
        spawn { watch_exit }
      end

      def alive? : Bool
        @mutex.synchronize { @exit_message.nil? }
      end

      def exit_message : String?
        @mutex.synchronize { @exit_message }
      end

      # Append raw bytes to the session buffer, enforcing the ring cap.
      private def append(text : String) : Nil
        @mutex.synchronize do
          @chunks << text
          @buffered += text.bytesize
          while @buffered > MAX_BUFFER_BYTES && @chunks.size > 1
            dropped = @chunks.shift
            @buffered -= dropped.bytesize
            @read_index -= 1 if @read_index > 0
          end
          @read_index = @chunks.size if @read_index > @chunks.size
        end
      end

      private def pump(io : IO) : Nil
        buf = Bytes.new(8192)
        loop do
          read = begin
            io.read(buf)
          rescue IO::Error
            break
          end
          break if read == 0
          append(String.new(buf[0, read]))
        end
      end

      private def watch_exit : Nil
        status = watch_exit_status
        message = if status.normal_exit?
                    "[process exited with code #{status.exit_status}]"
                  else
                    "[process terminated by signal #{status.exit_signal}]"
                  end
        @mutex.synchronize do
          @exit_message = message
          @chunks << message
          @buffered += message.bytesize
        end
        # Release the parent-side pipe descriptors; the child is gone.
        @process.close
      end

      # Reap the child without letting `Process#wait` close its stdin
      # while it is still running: the stdlib `wait` does `close_io
      # @input` first, which would EOF the session immediately and kill
      # any program reading stdin (cat, REPLs). Polling `terminated?`
      # first and calling `wait` only once the child is gone makes the
      # stdin close harmless — on Unix the runtime has already reaped the
      # exit status via its SIGCHLD loop, and on Windows the handle is
      # signaled, so `wait` just fetches the status without blocking.
      private def watch_exit_status : Process::Status
        until @process.terminated?
          sleep 50.milliseconds
        end
        @process.wait
      end

      # Write raw data to the session's stdin (flushed immediately).
      # Raises ShellSessionError when stdin is already closed or the
      # process has exited.
      def write(data : String) : Int32
        @mutex.synchronize do
          if @input_closed || !@exit_message.nil?
            raise ShellSessionError.new("stdin of #{@id} is no longer writable (#{@exit_message || "input closed"})")
          end
        end
        begin
          @process.input.write(data.to_slice)
          @process.input.flush
          data.bytesize
        rescue ex : IO::Error
          raise ShellSessionError.new("failed to write to #{@id}: #{ex.message}")
        end
      end

      # Close the session's stdin (EOF). Programs like `cat` or a REPL
      # reading until end-of-input will exit on their own afterwards.
      def close_input : Nil
        @mutex.synchronize { @input_closed = true }
        begin
          @process.input.close
        rescue IO::Error
        end
      end

      def input_closed? : Bool
        @mutex.synchronize { @input_closed }
      end

      # Return output produced since the previous read. Polls in small
      # increments until `wait_ms` elapses, new data arrives, or the
      # process exits — whichever comes first.
      def read_new_output(wait_ms : Int32) : String
        deadline = Time.monotonic + wait_ms.milliseconds
        loop do
          text, alive = @mutex.synchronize do
            pending = @chunks[@read_index..]
            @read_index = @chunks.size
            {pending.join, @exit_message.nil?}
          end
          return text unless text.empty?
          return "" if !alive || Time.monotonic >= deadline
          sleep 25.milliseconds
        end
      end

      def kill : Nil
        close_input
        unless @exit_message
          begin
            Tool::PROCESS_PORT.force_kill(@process)
          rescue Exception
          end
        end
      end

      def status_line : String
        state = alive? ? "running" : (@exit_message || "exited")
        "#{@id}\t#{state}\t#{@command}"
      end
    end

    class ShellSessionError < Exception
    end

    # Process-global registry of interactive shell sessions.
    class InteractiveShellService
      MAX_SESSIONS = 16

      getter sessions_dir : String?

      def initialize(@sessions_dir : String? = nil)
      end

      @mutex = Mutex.new
      @sessions = {} of String => ShellSession
      @next_id = 0

      def start(command : String, cwd : String?) : ShellSession
        @mutex.synchronize do
          if @sessions.size >= MAX_SESSIONS
            ids = @sessions.values.map(&.id).join(", ")
            raise ShellSessionError.new("Too many interactive sessions (#{MAX_SESSIONS}). Kill one first: #{ids}")
          end
          @next_id += 1
          session = ShellSession.new("shell-#{@next_id}", command, cwd)
          @sessions[session.id] = session
          session
        end
      end

      def get(id : String) : ShellSession?
        @mutex.synchronize { @sessions[id]? }
      end

      def list : Array(ShellSession)
        @mutex.synchronize { @sessions.values.sort_by!(&.id) }
      end

      def kill(id : String) : ShellSession?
        session = @mutex.synchronize { @sessions[id]? }
        return nil unless session
        session.kill
        # Drop the session from the registry once it is dead; its buffered
        # output is no longer reachable afterwards.
        @mutex.synchronize { @sessions.delete(id) }
        session
      end

      def stop_all : Nil
        @mutex.synchronize { @sessions.values.each(&.kill) }
        @mutex.synchronize { @sessions.clear }
      end
    end

    module InteractiveShell
      @@service : InteractiveShellService?

      def self.service=(s : InteractiveShellService?)
        @@service = s
      end

      def self.service : InteractiveShellService?
        @@service
      end
    end

    class InteractiveShellTool < Tool
      @work_dir : String

      # Retargeted by `/fork` / `/merge` at the idle boundary between turns.
      setter work_dir

      def initialize(@work_dir : String = Dir.current)
      end

      def name : String
        Names::INTERACTIVE_SHELL
      end

      def description : String
        "Manage interactive shell sessions: a persistent process whose stdin stays writable, so you can hold a dialogue with it (REPLs like python3/irb/node, debuggers like gdb/pdb, dev servers, psql, redis-cli). " \
        "Actions: 'start' (params: command, optional cwd) spawns the process and returns session_id; 'write' (session_id, data) sends raw bytes to its stdin — include a trailing \\n to submit a line; 'read' (session_id, optional wait_ms, default 250, max 10000) returns output produced since your last read, waiting up to wait_ms for new data; 'close_input' (session_id) sends EOF so programs reading to end-of-input exit on their own; 'kill' (session_id) terminates the session; 'list' shows live sessions. " \
        "Typical flow: start → read (banner) → write 'command\\n' → read result → ... → kill. Sessions are not background tasks: TaskList/TaskStop do not manage them."
      end

      def parameters : JSON::Any
        JSON.parse(%({
          "type": "object",
          "properties": {
            "action": {
              "type": "string",
              "enum": ["start", "write", "read", "close_input", "kill", "list"],
              "description": "The operation to perform on an interactive shell session."
            },
            "command": {
              "type": "string",
              "description": "start: shell command line that launches the interactive program, e.g. 'python3' or 'node'."
            },
            "cwd": {
              "type": "string",
              "description": "start: optional working directory for the session. Defaults to the session's working directory."
            },
            "session_id": {
              "type": "string",
              "description": "write / read / close_input / kill: the session id returned by start."
            },
            "data": {
              "type": "string",
              "description": "write: raw bytes to send to the session's stdin. Include a trailing newline to submit a line."
            },
            "wait_ms": {
              "type": "integer",
              "default": 250,
              "description": "read: how long to wait for new output, in milliseconds. Default 250, max 10000."
            }
          },
          "required": ["action"]
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        action = input["action"]?.try(&.to_s) || ""
        case action
        when "start"       then do_start(input)
        when "write"       then do_write(input)
        when "read"        then do_read(input)
        when "close_input" then do_close_input(input)
        when "kill"        then do_kill(input)
        when "list"        then do_list
        else
          ToolResult.error("Unknown action #{action.inspect}. Use one of: start, write, read, close_input, kill, list.")
        end
      end

      private def do_start(input : JSON::Any) : ToolResult
        svc = InteractiveShell.service
        return ToolResult.error("Interactive shell sessions are not available in this build.") unless svc

        command = input["command"]?.try(&.to_s) || ""
        return ToolResult.error("No command provided: pass the program to launch in 'command'.") if command.strip.empty?

        cwd = input["cwd"]?.try(&.to_s)
        cwd = nil if cwd && cwd.empty?

        # Fork-sandbox confinement: a REPL/debugger started in (or aimed
        # at) the original repository is as good as a Bash escape.
        if reason = Sandbox.shell_block_reason(command, cwd, @work_dir)
          return ToolResult.error(reason)
        end

        session = svc.start(command, cwd)
        # Give interactive programs a moment to print their banner.
        banner = session.read_new_output(300)
        lines = ["session_id: #{session.id}"]
        lines << "command: #{command}"
        lines << "status: running"
        lines << "banner: #{banner.inspect}" unless banner.empty?
        lines << "Next: write input with a trailing newline, then read new output."
        ToolResult.success(lines.join('\n'))
      rescue ex : ShellSessionError
        ToolResult.error(ex.message || "failed to start session")
      rescue ex : IO::Error | File::NotFoundError
        ToolResult.error("Failed to start command: #{ex.message}")
      end

      private def do_write(input : JSON::Any) : ToolResult
        session = lookup(input)
        return session unless session.is_a?(ShellSession)

        data = input["data"]?.try(&.to_s)
        return ToolResult.error("No data provided: pass the bytes to write in 'data'.") if data.nil?

        written = session.write(data)
        ToolResult.success("wrote #{written} bytes to #{session.id} (#{session.alive? ? "running" : "exited"}); use read to collect new output")
      rescue ex : ShellSessionError
        ToolResult.error(ex.message || "failed to write")
      end

      private def do_read(input : JSON::Any) : ToolResult
        result = lookup(input)
        return result unless result.is_a?(ShellSession)
        session = result

        wait_ms = input["wait_ms"]?.try(&.as_i?) || 250
        wait_ms = 10_000 if wait_ms > 10_000
        wait_ms = 0 if wait_ms < 0

        text = session.read_new_output(wait_ms)
        if text.empty?
          state = session.alive? ? "running" : (session.exit_message || "exited")
          ToolResult.success("(no new output; session #{state})")
        else
          ToolResult.success(text)
        end
      end

      private def do_close_input(input : JSON::Any) : ToolResult
        result = lookup(input)
        return result unless result.is_a?(ShellSession)

        result.close_input
        ToolResult.success("closed stdin of #{result.id} (EOF sent); programs reading to end-of-input will exit on their own — read to observe the exit.")
      end

      private def do_kill(input : JSON::Any) : ToolResult
        svc = InteractiveShell.service
        return ToolResult.error("Interactive shell sessions are not available in this build.") unless svc

        id = input["session_id"]?.try(&.to_s) || ""
        return ToolResult.error("No session_id provided.") if id.empty?

        session = svc.kill(id)
        return ToolResult.error("Session not found: #{id} (use action 'list' to see live sessions).") unless session

        # Give the exit watcher a moment to settle so the exit status is
        # included in the report.
        session.read_new_output(100)
        ToolResult.success("killed #{id} (#{session.exit_message || "terminating"})")
      end

      private def do_list : ToolResult
        svc = InteractiveShell.service
        return ToolResult.error("Interactive shell sessions are not available in this build.") unless svc

        sessions = svc.list
        return ToolResult.success("No interactive sessions.") if sessions.empty?
        ToolResult.success(sessions.map(&.status_line).join('\n'))
      end

      # Shared session lookup: returns the session or a ToolResult error.
      private def lookup(input : JSON::Any) : ShellSession | ToolResult
        svc = InteractiveShell.service
        unless svc
          return ToolResult.error("Interactive shell sessions are not available in this build.")
        end
        id = input["session_id"]?.try(&.to_s) || ""
        return ToolResult.error("No session_id provided.") if id.empty?
        session = svc.get(id)
        return ToolResult.error("Session not found: #{id} (use action 'list' to see live sessions).") unless session
        session
      end
    end
  end
end
