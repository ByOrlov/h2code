require "./sensitive"

module H2code
  module Tools
    # Shared ripgrep subprocess plumbing for Glob and Grep.
    #
    # Single place that knows how to spawn `rg`: timeout / cap'd stdout+stderr
    # draining, two-phase kill, and the standard exclusion globs (VCS metadata
    # + sensitive files). Ported (in spirit) from
    # `packages/agent-core/src/tools/support/run-rg.ts`.
    module RunRg
      DEFAULT_TIMEOUT_S = 20
      SIGTERM_GRACE_S   =  5
      MAX_OUTPUT_BYTES  = 10 * 1024 * 1024 # 10 MiB
      MAX_STDERR_BYTES  = 1 * 1024 * 1024  # 1 MiB

      @@rg_binary : String?

      # Hardcoded fallback locations checked when `rg` is not on PATH —
      # common on macOS when the parent process has a minimal environment
      # (IDE plugin, launchd) that misses the Homebrew/cargo dirs the user's
      # interactive shell sets up. Windows lists its own package-manager
      # layouts; `~` expands via HomePort (USERPROFILE on Windows).
      FALLBACK_RG_PATHS = {% if flag?(:win32) %}
                            ["~/.cargo/bin/rg.exe", "~/scoop/shims/rg.exe"]
                          {% else %}
                            ["/opt/homebrew/bin/rg", "/usr/local/bin/rg",
                             "~/.cargo/bin/rg", "~/.local/bin/rg"]
                          {% end %}

      # VCS metadata directories excluded from search. Mirrors
      # `VCS_DIRECTORIES_TO_EXCLUDE` in `support/run-rg.ts`.
      VCS_DIRECTORIES_TO_EXCLUDE = [".git", ".svn", ".hg", ".bzr", ".jj", ".sl"]

      # Prefilter globs: VCS metadata + sensitive files. Mirrors
      # `SENSITIVE_GLOBS_TO_EXCLUDE` + `VCS_DIRECTORIES_TO_EXCLUDE` in
      # `support/run-rg.ts`. The authoritative check still runs on parsed
      # records via `PathAccess.sensitive?`.
      def self.exclude_globs : Array(String)
        globs = [] of String
        VCS_DIRECTORIES_TO_EXCLUDE.each { |d| globs << "!#{d}"; globs << "!#{d}/**" }
        Sensitive.globs_to_exclude.each { |g| globs << "!#{g}" }
        globs
      end

      record Result,
        exit_code : Int32,
        stdout_text : String,
        stderr_text : String,
        buffer_truncated : Bool,
        timed_out : Bool

      # Resolve the rg binary: PATH entries first, then hardcoded fallback
      # locations. Returns plain "rg" when nothing is found so that
      # `Process.new` raises `File::NotFoundError` and the caller reports
      # the recognizable "install ripgrep" message.
      def self.resolve_rg_binary(path_env : String?,
                                 fallbacks : Array(String) = FALLBACK_RG_PATHS) : String
        # On Windows the binary is rg.exe — a bare "rg" never matches
        # File.file?, so ripgrep installed via winget/scoop/choco went
        # undetected and the tool silently degraded to a bare "rg" program.
        names = {% if flag?(:win32) %} ["rg.exe", "rg"] {% else %} ["rg"] {% end %}
        unless path_env.nil? || path_env.empty?
          sep = {{ flag?(:win32) ? ";" : ":" }}
          path_env.split(sep).each do |dir|
            next if dir.empty?
            names.each do |name|
              candidate = File.join(dir, name)
              return candidate if usable_binary?(candidate)
            end
          end
        end
        fallbacks.each do |candidate|
          expanded = candidate.starts_with?('~') ? File.expand_path(candidate, home: HomePort.home) : candidate
          return expanded if usable_binary?(expanded)
        end
        "rg"
      end

      # Like File.file? && File.executable?, but tolerant of Windows Store
      # app-execution aliases in ...\WindowsApps\: stat-ing those reparse
      # points raises File::Error (access denied) instead of returning false.
      private def self.usable_binary?(path : String) : Bool
        File.file?(path) && File.executable?(path)
      rescue File::Error
        false
      end

      # Memoized binary used by `run`. `ENV["PATH"]` is read once — fine,
      # PATH doesn't change mid-process in practice.
      def self.rg_binary : String
        @@rg_binary ||= resolve_rg_binary(ENV["PATH"]?)
      end

      # Type names ripgrep knows about (`rg --type-list`), memoized. Lets
      # Grep distinguish a real type (e.g. `crystal`) from an extension
      # shorthand (e.g. `cr`) that rg would reject with
      # "unrecognized file type". Empty when rg can't be queried — callers
      # should then fall back to their own handling.
      @@type_names : Set(String)?

      def self.type_names : Set(String)
        @@type_names ||= begin
          process = Process.new(rg_binary, {"--type-list"},
            input: Process::Redirect::Close,
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Close)
          names = Set(String).new
          process.output.each_line do |line|
            # Format: `<name>: <glob>, <glob>, ...`
            name = line.split(':').first?.to_s.strip
            names << name unless name.empty?
          end
          process.wait
          names
        rescue
          Set(String).new
        end
      end

      # Run `rg` with `args`. Returns the captured stdout/stderr (capped at
      # MAX_OUTPUT_BYTES / MAX_STDERR_BYTES) and an `exit_code`. On timeout the
      # process is SIGTERM'd, then SIGKILL'd after `SIGTERM_GRACE_S`. When
      # `aborted?` fires the process is killed the same way so an ESC
      # interrupt tears the search down immediately.
      def self.run(args : Array(String), *, chdir : String? = nil,
                   timeout_s : Int32 = DEFAULT_TIMEOUT_S,
                   aborted? : -> Bool = -> { false }) : Result
        process = Process.new(
          rg_binary,
          args,
          shell: false,
          chdir: chdir,
          input: Process::Redirect::Close,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe,
        )

        # Close stdin immediately so interactive rg prompts (none by default,
        # but defensive) never hang.
        process.input?.try(&.close)

        stdout_buf = IO::Memory.new
        stderr_buf = IO::Memory.new
        stdout_done = Channel(Nil).new
        stderr_done = Channel(Nil).new

        spawn do
          copy_capped(process.output, stdout_buf, MAX_OUTPUT_BYTES)
          stdout_done.send(nil)
        end

        spawn do
          copy_capped(process.error, stderr_buf, MAX_STDERR_BYTES)
          stderr_done.send(nil)
        end

        status, timed_out, _aborted = Tool.wait_for_exit(
          process, timeout_s, aborted?, kill_grace_s: SIGTERM_GRACE_S)

        # Drain remaining streams before reading buffers.
        select
        when stdout_done.receive
        when timeout(2.seconds)
          # best-effort drain; move on
        end
        select
        when stderr_done.receive
        when timeout(2.seconds)
          # best-effort drain; move on
        end

        stdout_text = stdout_buf.to_s
        stderr_text = stderr_buf.to_s
        # If we hit the byte cap mid-stream, `copy_capped` stopped reading and
        # the process may still be writing; treat as truncated.
        buffer_truncated = stdout_text.bytesize >= MAX_OUTPUT_BYTES

        Result.new(
          exit_code: status.exit_code || -1,
          stdout_text: stdout_text,
          stderr_text: stderr_text,
          buffer_truncated: buffer_truncated,
          timed_out: timed_out,
        )
      rescue ex : File::NotFoundError
        # rg binary not present — surface as a recognizable error so tools can
        # produce the JS-style "install ripgrep" message.
        raise RgUnavailableError.new(ex.message || "rg not found")
      end

      class RgUnavailableError < Exception
      end

      private def self.copy_capped(src : IO, dst : IO, max_bytes : Int32) : Nil
        buf = uninitialized UInt8[8192]
        written = 0
        loop do
          n = src.read(buf.to_slice).to_i32
          break if n <= 0
          remaining = max_bytes - written
          break if remaining <= 0
          take = {n, remaining}.min
          dst.write(buf.to_slice[0, take])
          written += take
          break if written >= max_bytes
        end
      rescue IO::Error
        # Best-effort drain — process closed or EPIPE.
      end
    end
  end
end
