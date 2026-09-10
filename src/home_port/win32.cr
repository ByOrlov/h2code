{% skip_file unless flag?(:win32) %}

module H2code
  # Windows adapter: USERPROFILE is the canonical per-user directory set by
  # the OS for every process (roughly `C:\Users\<name>`). HOME is consulted
  # second for processes launched from POSIX-ish environments (Git Bash, MSYS2,
  # Cygwin) that export it — when both are present USERPROFILE wins because it
  # is the value Windows itself and native applications expect. "." is the
  # degenerate fallback (no /tmp exists on Windows).
  class Win32HomePort < HomePort
    def home : String
      ENV["USERPROFILE"]? || ENV["HOME"]? || "."
    end
  end
end
