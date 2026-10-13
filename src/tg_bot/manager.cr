require "process"
require "json"

module TgBot
  # Spawns and supervises `h2code --resident` child processes, one per
  # session. A new session is discovered by diffing `<sessions>/**/control.sock`
  # before/after the spawn (the daemon is the only creator, so the diff is
  # race-free in practice). Child stdout/stderr go to a per-session log.
  class Manager
    getter links = {} of String => SessionLink

    def initialize(@config : Config,
                   @on_event : Proc(String, JSON::Any, Nil),
                   @on_died : Proc(String, Nil))
      @processes = {} of String => Process
      @lock = Mutex.new
    end

    def self.sessions_root : String
      home = ENV["H2CODE_HOME"]? || File.join(ENV["HOME"]? || Dir.current, ".h2code")
      File.join(home, "sessions")
    end

    def logs_dir : String
      home = ENV["H2CODE_HOME"]? || File.join(ENV["HOME"]? || Dir.current, ".h2code")
      dir = File.join(home, "tg", "logs")
      Dir.mkdir_p(dir)
      dir
    end

    def start_session(dir : String) : SessionLink
      before = existing_sockets
      log = File.open(File.join(logs_dir, "spawn.log"), "a")

      process = Process.new(@config.h2code_bin,
        ["--resident", "-d", dir],
        output: log, error: log)

      sock_path = wait_for_new_socket(before, process)
      link = SessionLink.connect(sock_path) do |sid, frame|
        @on_event.call(sid, frame)
      end
      @lock.synchronize { @processes[link.sid] = process }
      spawn(name: "watch-#{link.sid}") do
        process.wait
        @lock.synchronize do
          @processes.delete(link.sid)
          @links.delete(link.sid)
        end
        link.close
        @on_died.call(link.sid)
      end
      @lock.synchronize { @links[link.sid] = link }
      link
    end

    def link(sid : String) : SessionLink?
      @lock.synchronize { @links[sid]? }
    end

    # Thread-safe list of live links — the bot iterates it for /sessions.
    def snapshot : Array(SessionLink)
      @lock.synchronize { @links.values.dup }
    end

    def stop(sid : String) : Nil
      @lock.synchronize { @links[sid]?.try(&.request_exit) }
    end

    def busy?(sid : String) : Bool?
      link = link(sid)
      return nil unless link
      return nil if link.closed?
      link.status["busy"]?.try(&.as_bool?)
    rescue
      nil
    end

    private def existing_sockets : Set(String)
      Set.new(Dir.glob(File.join(Manager.sessions_root, "**", "control.sock")))
    end

    private def wait_for_new_socket(before : Set(String), process : Process) : String
      deadline = Time.instant + 60.seconds
      loop do
        socks = Dir.glob(File.join(Manager.sessions_root, "**", "control.sock"))
        fresh = socks.reject { |p| before.includes?(p) }
        return fresh.first if fresh.size > 0
        unless process.exists?
          raise "h2code exited during startup — see #{File.join(logs_dir, "spawn.log")}"
        end
        raise "timed out waiting for the session control socket" if Time.instant > deadline
        sleep 100.milliseconds
      end
    end
  end
end
