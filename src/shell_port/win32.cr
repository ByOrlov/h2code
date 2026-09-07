{% skip_file unless flag?(:win32) %}

module H2code
  # Windows adapter: resolve the best available command-line interpreter.
  #
  # Resolution order, decided once at construction:
  #   1. bash.exe from Git for Windows — preferred because the Bash tool's
  #      schema and guidance assume POSIX shell semantics. Searched on PATH
  #      (the installer can add Git\bin there) and in the standard install
  #      locations (Program Files, Program Files (x86), per-user
  #      LocalAppData\Programs\Git). Every candidate is *probed* by actually
  #      running it: a bash.exe can exist yet be broken (partial install,
  #      missing DLLs) or be a stub that launches foreign machinery (see
  #      `stub?`) — existence alone is not evidence of a working shell.
  #   2. powershell.exe — ships with every supported Windows release, so it is
  #      taken without an existence probe. `-NoProfile`/`-NonInteractive`
  #      keep the run deterministic; note that Windows PowerShell 5.1 lacks
  #      `&&`/`||`.
  #   3. cmd.exe — always-present last resort; picked implicitly when
  #      PowerShell cannot be spawned (File::NotFoundError surfaces as the
  #      tool's "shell not found" error in that degenerate case).
  class Win32ShellPort < ShellPort
    @bash : String?

    def initialize
      @bash = detect_bash
    end

    def program : String
      bash = @bash
      bash || "powershell.exe"
    end

    def shell_args(command : String) : Array(String)
      if @bash
        ["-c", command]
      else
        ["-NoProfile", "-NonInteractive", "-Command", command]
      end
    end

    def env_shell : String
      program
    end

    def name : String
      @bash ? "bash" : "powershell"
    end

    def guidance : String
      if bash = @bash
        "The interpreter is bash from Git for Windows (`#{bash}`); full bash syntax is available. Windows-native shells are also directly invocable when a task needs them: `powershell -NoProfile -Command \"...\"` and `cmd /c \"...\"`."
      else
        "This system has no bash — commands run through Windows PowerShell (`powershell.exe -NoProfile -NonInteractive`). Use PowerShell syntax; `&&`/`||` chaining is unavailable in Windows PowerShell 5.1 — use `;` separators or separate tool calls. `cmd /c \"...\"` is also invocable for cmd built-ins."
      end
    end

    # Best-effort Git Bash lookup; nil when no working bash is installed.
    private def detect_bash : String?
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

      candidates.each do |candidate|
        next if stub?(candidate)
        return candidate if bash_works?(candidate)
      end
      nil
    end

    # True for bash.exe look-alikes that are not Git Bash:
    #   - `C:\Windows\System32\bash.exe` is the WSL launcher — even when it
    #     runs, it enters the Linux/WSL world (different filesystem roots,
    #     not the user's Windows system).
    #   - `...\WindowsApps\bash.exe` is a Microsoft Store app-execution alias;
    #     executing it with the app absent opens the Store page.
    private def stub?(path : String) : Bool
      down = path.downcase
      down.includes?("\\windows\\") || down.includes?("\\windowsapps\\")
    end

    # Probe *path* by running a trivial script. Existence is not enough: a
    # broken install (missing DLLs) fails with a non-zero exit, and stubs
    # can block waiting for interactive setup — hence the timeout.
    private def bash_works?(path : String) : Bool
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
