{% skip_file if flag?(:win32) %}

module H2code
  # POSIX adapter: the home directory comes from the HOME environment
  # variable, which login shells (login(1), sshd, systemd --user, …) always
  # set. "/tmp" is a degenerate fallback for environments where HOME is
  # stripped (some CI sandboxes, cron without a login shell); it preserves the
  # behaviour previously hardcoded at every call site.
  class UnixHomePort < HomePort
    def home : String
      ENV["HOME"]? || "/tmp"
    end
  end
end
