require "socket"
require "json"

module TgBot
  # Client side of the h2code control-socket protocol v2: newline-delimited
  # JSON over the resident session's `<session_dir>/control.sock`. Ops go
  # out under a lock and their `{"ok":…}` reply comes back on a channel;
  # pushed event frames (`{"ev":…}`) are dispatched in order to a
  # dispatcher fiber so a slow consumer never stalls the socket reader.
  class SessionLink
    getter sid : String           # short id (session dir basename prefix)
    getter session_dir : String

    @sock : UNIXSocket
    @send_lock = Mutex.new
    @replies = Channel(JSON::Any).new(16)
    @events = Channel(JSON::Any).new(256)
    @closed = false

    def initialize(@sid : String, @session_dir : String, @sock : UNIXSocket,
                   &on_event : (String, JSON::Any -> Nil))
      @on_event = on_event
      spawn(name: "link-reader-#{@sid}") { read_loop }
      spawn(name: "link-dispatch-#{@sid}") { dispatch_loop }
    end

    # Wait for the socket file to appear (the resident process binds it at
    # startup), then connect. Raises on timeout.
    def self.connect(sock_path : String, timeout : Time::Span = 60.seconds,
                     &on_event : (String, JSON::Any -> Nil)) : SessionLink
      deadline = Time.instant + timeout
      until File.exists?(sock_path)
        raise "control socket did not appear: #{sock_path}" if Time.instant > deadline
        sleep 100.milliseconds
      end
      sock = UNIXSocket.new(sock_path)
      sid = File.basename(File.dirname(sock_path))
      new(sid, File.dirname(sock_path), sock) { |s, f| on_event.call(s, f) }
    end

    def prompt(text : String) : Nil
      op("prompt", {"text" => JSON::Any.new(text)})
    end

    def interrupt : Nil
      op("interrupt")
    end

    def status : JSON::Any
      op("status")
    end

    # Values may be strings (single-select) or arrays of strings
    # (multi-select) — the resident side joins arrays with ", ".
    def answer(qid : String, answers : Hash(String, JSON::Any)) : Nil
      op("answer", {
        "qid"     => JSON::Any.new(qid),
        "answers" => JSON::Any.new(answers),
      })
    end

    def approve(qid : String, decision : String) : Nil
      op("approve", {"qid" => JSON::Any.new(qid), "decision" => JSON::Any.new(decision)})
    end

    def request_exit : Nil
      op("exit")
    end

    # Context wipe (op:clear) — refused by the resident while a turn runs.
    def clear_context : Nil
      op("clear")
    end

    # History → summary (op:compact); the compaction itself runs as a turn
    # afterwards (turn/assistant frames arrive as usual).
    def compact : Nil
      op("compact")
    end

    # Available model ids (op:models). Network-backed on most providers, so
    # the caller-side timeout is wider than the default op timeout.
    def models : Array(String)
      op("models", timeout: 30.seconds)["models"]?.try(&.as_a?).try(&.map(&.to_s)) || [] of String
    end

    def set_model(name : String) : Nil
      op("model", {"name" => JSON::Any.new(name)})
    end

    def mode : String?
      op("mode")["mode"]?.try(&.to_s)
    end

    def set_mode(value : String) : String?
      op("mode", {"value" => JSON::Any.new(value)})["mode"]?.try(&.to_s)
    end

    def closed? : Bool
      @closed
    end

    def close : Nil
      @closed = true
      begin
        @sock.close
      rescue
      end
      begin
        @replies.close
      rescue
      end
      begin
        @events.close
      rescue
      end
    end

    private def op(op : String, extra : Hash(String, JSON::Any) = {} of String => JSON::Any,
                   timeout : Time::Span = 10.seconds) : JSON::Any
      payload = {"op" => JSON::Any.new(op)} of String => JSON::Any
      extra.each { |k, v| payload[k] = v }
      @send_lock.synchronize do
        raise "link closed" if @closed
        @sock << payload.to_json << '\n'
        @sock.flush
        select
        when reply = @replies.receive
          unless reply["ok"]?.try(&.as_bool?)
            raise "op #{op} failed: #{reply["error"]?.try(&.to_s) || "unknown error"}"
          end
          reply
        when timeout(timeout)
          raise "op #{op} timed out"
        end
      end
    end

    private def read_loop : Nil
      @sock.each_line do |line|
        next if line.strip.empty?
        frame = JSON.parse(line)
        if frame["ev"]?
          @events.send(frame)
        else
          select
          when @replies.send(frame)
          when timeout(10.seconds)
            # Nobody is waiting for a reply — drop it.
          end
        end
      end
    rescue ex : IO::Error | Socket::Error
      @closed = true
    ensure
      @closed = true
    end

    private def dispatch_loop : Nil
      loop do
        frame = @events.receive?
        break if frame.nil?
        @on_event.call(@sid, frame)
      end
    rescue
      # Reader died — the manager notices via the process watcher.
    end
  end
end
