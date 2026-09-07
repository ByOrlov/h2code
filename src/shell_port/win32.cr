{% skip_file unless flag?(:win32) %}

module H2code
  # Windows adapter: resolve the best available command-line interpreter.
  #
  # Resolution order, decided once at construction:
  #   1. bash.exe from Git for Windows — preferred because the Bash tool's
  #      schema and guidance assume POSIX shell semantics. Searched on PATH
  #      (the installer can add Git\bin there) and in the standard install
  #      locations (Program Files, Program Files (x86), per-user
  #      LocalAppData\Programs\Git).
  #   2. powershell.exe — ships with every supported Windows release, so it is
  #      taken without an existence probe. Pipes, redirections and `;`
  #      sequences work; note that Windows PowerShell 5.1 lacks `&&`/`||`.
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
        # -NoProfile/-NonInteractive keep the run deterministic (no profile
        # scripts, no prompt) and make non-zero exits propagate cleanly.
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
        "The interpreter is bash from Git for Windows (`#{bash}`); full bash syntax is available."
      else
        "This system has no bash — commands run through Windows PowerShell (`powershell.exe -NoProfile -NonInteractive`). Use PowerShell syntax; `&&`/`||` chaining is unavailable in Windows PowerShell 5.1 — use `;` separators or separate tool calls."
      end
    end

    # Best-effort Git Bash lookup; nil when Git for Windows is not installed.
    private def detect_bash : String?
      path_env = ENV["PATH"]? || ""
      path_env.split(';').each do |dir|
        next if dir.empty?
        candidate = File.join(dir, "bash.exe")
        return candidate if File.file?(candidate)
      end

      roots = [
        ENV["ProgramFiles"]?,
        ENV["ProgramFiles(x86)"]?,
        ENV["ProgramW6432"]?,
        ENV["LOCALAPPDATA"]?.try { |la| File.join(la, "Programs") },
      ].compact
      roots.each do |root|
        candidate = File.join(root, "Git", "bin", "bash.exe")
        return candidate if File.file?(candidate)
      end

      nil
    end
  end
end
