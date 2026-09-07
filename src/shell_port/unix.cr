{% skip_file if flag?(:win32) %}

module H2code
  # POSIX adapter: prefer a real bash when one is installed (it almost always
  # is — /bin/bash on Linux, /bin/bash or Homebrew's on macOS), because the
  # Bash tool's schema and guidance assume bash semantics and some distros
  # ship /bin/sh as dash, which rejects common bashisms (`[[ ]]`, arrays,
  # process substitution). Falls back to plain `/bin/sh` for bash-less systems
  # (Alpine, minimal containers) and reports itself honestly as "sh" so the
  # model is not misled about the available syntax.
  class UnixShellPort < ShellPort
    @bash : String?

    def initialize
      @bash = detect_bash
    end

    def program : String
      @bash || "/bin/sh"
    end

    def shell_args(command : String) : Array(String)
      ["-c", command]
    end

    def env_shell : String
      program
    end

    def name : String
      @bash ? "bash" : "sh"
    end

    def guidance : String
      if bash = @bash
        "The interpreter is bash (`#{bash}`); full bash syntax is available."
      else
        "No bash is installed — commands run through POSIX `sh` (`/bin/sh`). Avoid bash-only constructs (arrays, `[[ ]]`, process substitution, brace expansion)."
      end
    end

    # First executable `bash` on PATH, nil when the system has none.
    private def detect_bash : String?
      (ENV["PATH"]? || "").split(':').each do |dir|
        next if dir.empty?
        candidate = File.join(dir, "bash")
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end
  end
end
