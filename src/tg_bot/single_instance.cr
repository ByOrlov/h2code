require "digest/sha256"

module TgBot
  # Port: single-instance guard for the daemon.
  #
  # Telegram allows exactly one concurrent getUpdates call per bot token, so
  # a second daemon copy for the same token fights the first one over
  # updates — an endless stream of "409 Conflict: terminated by other
  # getUpdates request" that starves both copies. The guard is therefore
  # keyed by the bot token: two daemons for two different bots may coexist,
  # two daemons for the same token may not.
  #
  # OS locking primitives are inherently platform-specific (flock on POSIX,
  # a named mutex on Windows). Both are held for the whole process lifetime
  # and released by the kernel on exit, crashed or not — a stale lock file
  # never blocks the next start. The adapter for the compile target is
  # selected in exactly one place - the composition root `default` below -
  # so no platform branching leaks into the rest of the codebase (same
  # pattern as ServicePort / ProcessPort).
  abstract class SingleInstancePort
    # Another daemon for this bot token is already running.
    class AlreadyRunning < Exception
    end

    # Try to become the only daemon for *key* (the bot token). Raises
    # AlreadyRunning when a live instance holds the lock. The lock is kept
    # until process exit; there is no release call.
    abstract def acquire(key : String) : Nil

    # Composition root: instantiate the adapter matching the compile target.
    # This is the single point where the platform is decided.
    def self.default : SingleInstancePort
      {% if flag?(:win32) %}
        Win32SingleInstancePort.new
      {% else %}
        UnixSingleInstancePort.new
      {% end %}
    end
  end
end

require "./single_instance/unix"
require "./single_instance/win32"
