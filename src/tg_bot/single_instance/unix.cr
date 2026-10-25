{% skip_file if flag?(:win32) %}

module TgBot
  # POSIX adapter: a non-blocking exclusive flock on a per-token lock file
  # under the h2code home (`~/.h2code/locks/tg-<sha256(token)>.lock`,
  # H2CODE_HOME honoured). flock needs no cleanup — the kernel drops it when
  # the process exits, crashed or not; the lock file itself only carries the
  # holder's pid so the losing copy can name the culprit in its error.
  class UnixSingleInstancePort < SingleInstancePort
    @lock : File?

    def acquire(key : String) : Nil
      path = self.class.lock_path(key)
      Dir.mkdir_p(File.dirname(path))
      lock = File.new(path, "a+")
      # flock conflicts even between two descriptors of the same process,
      # so this also guards a double `acquire` within one run. With
      # blocking: false a busy lock raises instead of hanging (Crystal 1.21
      # stdlib contract for flock_exclusive).
      begin
        lock.flock_exclusive(blocking: false)
      rescue ex : IO::Error
        lock.seek(0)
        pid = lock.gets_to_end.strip
        lock.close
        detail = pid.empty? ? "" : " (pid #{pid})"
        raise AlreadyRunning.new(
          "another h2code-tg-bot is already running for this bot#{detail}")
      end
      lock.seek(0)
      lock.truncate
      lock.print(Process.pid)
      lock.flush
      # Keep the descriptor open for the process lifetime: closing it would
      # release the flock immediately.
      @lock = lock
    end

    # Lock files live next to tg.json, one per token hash: different tokens
    # are different bots and run side by side.
    def self.lock_path(key : String) : String
      home = ENV["H2CODE_HOME"]? || File.join(ENV["HOME"]? || Dir.current, ".h2code")
      File.join(home, "locks", "tg-#{Digest::SHA256.hexdigest(key)[0, 16]}.lock")
    end
  end
end
