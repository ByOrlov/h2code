module H2code
  module Session
    # Raised when opening a session whose exclusive lock is held by another
    # live process. Two conversation writers on one wire.jsonl interleave
    # their events and — worse — full-file repairs (`Store#recover_wire`)
    # rebuild the log from the writer's own journal, silently dropping the
    # other writer's lines. A session directory may therefore have exactly
    # one owning process at a time.
    class SessionBusyError < Exception
      getter session_dir : String
      getter holder_pid : Int32?

      def initialize(@session_dir : String, @holder_pid : Int32?)
        pid = @holder_pid ? " (pid #{@holder_pid})" : ""
        super("Session is already open in another h2code process#{pid}: #{@session_dir}")
      end
    end

    # Exclusive per-session lock over `<session_dir>/lock`.
    #
    # Implemented with `File#flock_exclusive` — flock(2) on POSIX,
    # LockFileEx on Windows — so the OS releases the lock when the holding
    # process dies: no stale lock files to clean up after a crash. The pid
    # written into the file is diagnostics only; the kernel lock is the
    # source of truth (a recorded pid means nothing by itself, and the OS
    # may reuse pids).
    #
    # Read-only consumers (Index scans, session pickers, the remote
    # daemon's wire tail) never lock — readers cannot corrupt the log.
    # Metadata writers (rename / archive, which touch only state.json via
    # atomic writes) stay lock-free too: a racing rename loses at most a
    # title update, never conversation history.
    class Lock
      getter path : String
      @file : File?

      # Acquire the exclusive lock for `session_dir` or raise
      # `SessionBusyError`. The directory is created on demand (fresh
      # sessions lock before their first write).
      def self.acquire!(session_dir : String) : Lock
        path = File.join(session_dir, "lock")
        Dir.mkdir_p(session_dir) unless Dir.exists?(session_dir)
        # "a+": create when missing, never truncate — truncating would
        # erase the previous holder's pid before we could read it for the
        # error message.
        file = File.open(path, "a+")
        begin
          file.flock_exclusive(blocking: false)
        rescue IO::Error
          holder = read_holder_pid(file)
          file.close
          raise SessionBusyError.new(session_dir, holder)
        end
        write_holder_pid(file)
        new(path, file)
      end

      def initialize(@path : String, @file : File)
      end

      # Whether *session_dir*'s exclusive lock is currently held by a live
      # process (the session is open in some h2code instance). Probed with a
      # non-blocking flock on a separate handle: when the attempt fails the
      # kernel lock is taken. The probe lock is released immediately, so this
      # never blocks and never disturbs the holder. Sessions without a lock
      # file on disk are never locked. Read-only — this is how the session
      # picker hides open sessions.
      def self.locked?(session_dir : String) : Bool
        path = File.join(session_dir, "lock")
        return false unless File.exists?(path)
        file = File.open(path, "r")
        locked = begin
          file.flock_exclusive(blocking: false)
          file.flock_unlock
          false
        rescue IO::Error
          true
        end
        file.close
        locked
      rescue File::Error
        false
      end

      # Release the lock and close the handle. Idempotent. The OS also
      # releases the lock on process exit, so an omitted release leaks
      # nothing past the owning process's lifetime.
      def release : Nil
        if file = @file
          @file = nil
          begin
            file.flock_unlock
          rescue IO::Error
          end
          file.close
        end
      end

      private def self.read_holder_pid(file : File) : Int32?
        file.rewind
        content = file.gets_to_end
        file.rewind
        content.strip.to_i32?
      rescue IO::Error
        nil
      end

      private def self.write_holder_pid(file : File) : Nil
        file.truncate(0)
        file.write(Process.pid.to_s.to_slice)
        file.flush
      rescue IO::Error
        # Diagnostics only — the kernel lock stands regardless.
      end
    end
  end
end
