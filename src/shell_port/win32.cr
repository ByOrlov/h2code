{% skip_file unless flag?(:win32) %}

module H2code
  # Windows adapter: cmd.exe is the native interpreter, everything else is
  # explicitly invocable.
  #
  # Design (the hard-won way): *no* interpreter selection and *no* execution
  # probes at startup. An earlier revision preferred bash when a bash.exe
  # merely existed — on machines where that binary was a WSL launcher or a
  # broken Git install, every command routed through a dead interpreter while
  # the description kept promising bash. Probing candidates at boot only
  # traded that for multi-second UI freezes. Instead:
  #
  #   - cmd.exe always executes commands (`cmd /d /c`). It ships with every
  #     Windows, starts instantly, and its syntax is what "Windows command
  #     line" means to the model.
  #   - PowerShell is invocable from any command:
  #     `powershell -NoProfile -Command "..."`.
  #   - bash (Git for Windows) is the exotic fallback for POSIX-only tasks:
  #     `"<path>" -c '...'`. The path is *reported* in the guidance, never
  #     used to route commands — a broken bash fails that one explicit
  #     invocation, never the tool. Resolution: the `bash_path` override
  #     (set via /bash patch) or a fast existence scan that skips the WSL
  #     launcher and Store aliases. Deep verification (actually running the
  #     candidate) is opt-in via `/bash detect`, which also persists the
  #     result into config as `bash_available`.
  class Win32ShellPort < ShellPort
    def program : String
      "cmd.exe"
    end

    def shell_args(command : String) : Array(String)
      # /d skips AutoRun registry hooks for a deterministic run.
      ["/d", "/c", command]
    end

    def env_shell : String
      "cmd.exe"
    end

    def name : String
      "cmd"
    end

    def guidance : String
      String.build do |s|
        s << "Commands run through cmd.exe (`cmd /d /c`). PowerShell is directly invocable: `powershell -NoProfile -Command \"...\"`."
        if bash = bash_reference
          s << " For POSIX-only tasks bash from Git for Windows is available: `\"#{bash}\" -c '...'`."
        else
          s << " No bash is installed — use PowerShell or cmd equivalents for POSIX-style tasks."
        end
      end
    end

    # The bash location advertised to the model: explicit override first,
    # then a fast existence scan. Execution-free by design (see class doc).
    def bash_reference : String?
      ShellPort.bash_path || self.class.scan_bash_candidates.first?
    end

    # Collect existing bash.exe candidates in resolution order. Fast:
    # filesystem checks only, no process execution. Class-level — used both
    # by the instance guidance and by the deep `/bash detect` probe.
    def self.scan_bash_candidates : Array(String)
      candidates = [] of String
      (ENV["PATH"]? || "").split(';').each do |dir|
        next if dir.empty?
        candidate = File.join(dir, "bash.exe")
        candidates << candidate if File.file?(candidate)
      end
      roots = [
        ENV["ProgramFiles"]?,
        ENV["ProgramFiles(x86)"]?,
        ENV["ProgramW6432"]?,
        ENV["LOCALAPPDATA"]?.try { |la| File.join(la, "Programs") },
      ].compact
      roots.each do |root|
        candidate = File.join(root, "Git", "bin", "bash.exe")
        candidates << candidate if File.file?(candidate)
      end
      candidates.reject { |c| stub?(c) }
    end

    # True for bash.exe look-alikes that are not Git Bash:
    #   - `C:\Windows\System32\bash.exe` is the WSL launcher — even when it
    #     runs, it enters the Linux/WSL world (different filesystem roots,
    #     not the user's Windows system).
    #   - `...\WindowsApps\bash.exe` is a Microsoft Store app-execution alias;
    #     executing it with the app absent opens the Store page.
    def self.stub?(path : String) : Bool
      down = path.downcase
      down.includes?("\\windows\\") || down.includes?("\\windowsapps\\")
    end

    # ------------------------------------------------------------------
    # Deep detection (`/bash detect`) — user-initiated, may block.
    # ------------------------------------------------------------------

    # Probe every existing candidate by actually running it; returns the
    # first working bash path, or nil. Not called from the startup path.
    def self.detect_bash : String?
      scan_bash_candidates.each do |candidate|
        return candidate if bash_works?(candidate)
      end
      nil
    end

    # Run a trivial script through *path*. Existence is not enough: a broken
    # install (missing DLLs) fails with a non-zero exit, and stubs can block
    # waiting for interactive setup — hence the timeout.
    private def self.bash_works?(path : String) : Bool
      process = Process.new(path, {"-c", "exit 0"},
        input: Process::Redirect::Close,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe,
      )
      status_ch = Channel(Process::Status).new(1)
      spawn { status_ch.send(process.wait) }

      status = select
        when s = status_ch.receive
          s
        when timeout(3.seconds)
          # On win32 both graceful and forceful termination map to
          # TerminateProcess, so no port indirection is needed here.
          process.terminate(graceful: false) rescue nil
          nil
      end

      process.output.close rescue nil
      process.error.close rescue nil

      return false if status.nil?
      status.normal_exit? && status.exit_code == 0
    rescue ex : File::NotFoundError | IO::Error
      # Broken executable / missing runtime — treat as non-working.
      false
    rescue ex
      false
    end
  end
end
