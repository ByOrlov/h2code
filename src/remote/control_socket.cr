require "socket"
require "json"

module H2code
  module Remote
    # Per-process control socket for external input (h2code-remote).
    #
    # A running TUI listens on `<session_dir>/control.sock`; the h2code-remote
    # daemon connects as a client and injects prompts/interrupts as synthetic
    # user input via `App#deliver_external_prompt` (the same path cron uses).
    # One listener per process — remote multiplexes by connecting to each
    # session's socket separately.
    #
    # Protocol: newline-delimited UTF-8 JSON, one object per line.
    #   client → {"op":"prompt","text":"..."}
    #   client → {"op":"interrupt"}
    #   client → {"op":"status"}
    #   server ← {"ok":true} | {"ok":false,"error":"..."}
    #             | {"ok":true,"busy":true|false}   (op: status)
    #
    # v2 (resident mode, h2code-tg-bot): the server also *pushes* event
    # frames to connected clients and accepts answer/approve/exit ops:
    #   client → {"op":"answer","qid":"...","answers":{...}}
    #   client → {"op":"approve","qid":"...","decision":"allow|allow_session|deny"}
    #   client → {"op":"exit"}
    #   client → {"op":"clear"}                     (context wipe; refused while busy)
    #   client → {"op":"compact"}                   (history → summary; refused while busy)
    #   client → {"op":"models"}                    → {"ok":true,"models":[...]}
    #   client → {"op":"model","name":"..."}        (refused while busy)
    #   client → {"op":"mode"}                      → {"ok":true,"mode":"auto"}
    #   client → {"op":"mode","value":"auto|manual|yolo"}
    #   server ← {"ev":"turn","phase":"started|ended",...}
    #   server ← {"ev":"assistant","text":"..."}
    #   server ← {"ev":"question","qid":"...","questions":[...]}
    #   server ← {"ev":"approval","qid":"...","tool":"...","args":"..."}
    #   server ← {"ev":"usage","model":"...","context_pct":...}
    #   server ← {"ev":"error","text":"..."}
    # Pushes only happen while something calls `#emit` — the TUI never
    # does, so one-way clients like h2code-remote (write-only) are never
    # written to and cannot stall on a full socket buffer.
    #
    # Unknown ops answer ok:false; malformed lines are skipped. The socket
    # file is unlinked on close/rebind and on exit (best-effort).
    class ControlSocket
      @server : UNIXServer? = nil
      @path : String? = nil
      @clients : Array(UNIXSocket) = [] of UNIXSocket
      @clients_lock = Mutex.new

      def initialize(@on_prompt : String -> Nil,
                     @on_interrupt : -> Nil,
                     @on_status : -> Bool = -> { false },
                     @on_answer : ((String, JSON::Any) -> Nil)? = nil,
                     @on_approve : ((String, String) -> Nil)? = nil,
                     @on_exit : (-> Nil)? = nil,
                     @status_extras : (() -> Hash(String, JSON::Any))? = nil)
      end

      # Session-control ops (v2, Telegram bot surface). Optional and set after
      # construction (the TUI socket leaves them nil → "unsupported op"); the
      # resident wires what it can serve itself and gets the rest from
      # `h2code --resident`'s wiring.
      property on_clear : (-> Nil)? = nil
      property on_compact : (-> Nil)? = nil
      property on_models : (() -> Array(String))? = nil
      property on_model_change : (String -> Bool)? = nil
      property on_mode_get : (-> String)? = nil
      # Returns the normalized mode name, or nil when the value is not a mode.
      property on_mode_set : (String -> String?)? = nil

      # (Re)bind to a session directory. Safe to call repeatedly — the old
      # listener is closed first (TUI switches session dirs on /new, /resume
      # and /fork).
      def rebind(session_dir : String) : Nil
        close
        path = File.join(session_dir, "control.sock")
        begin
          File.delete(path) if File.exists?(path)
          server = UNIXServer.new(path)
        rescue ex
          # Non-fatal: remote sync for this session is simply unavailable.
          STDERR.puts "[control-socket] cannot listen on #{path}: #{ex.message}"
          return
        end
        @server = server
        @path = path
        spawn { accept_loop(server) }
      end

      def close : Nil
        server = @server
        path = @path
        @server = nil
        @path = nil
        begin
          server.close if server
        rescue
        end
        @clients_lock.synchronize do
          @clients.each do |c|
            begin
              c.close
            rescue
            end
          end
          @clients.clear
        end
        begin
          File.delete(path) if path && File.exists?(path)
        rescue
        end
      end

      # Push one event frame to every connected client (v2). Frames are
      # serialized to a single JSON line under the clients lock so they can
      # never interleave with a reply written from another fiber.
      def emit(ev : String, fields : Hash(String, JSON::Any) = {} of String => JSON::Any) : Nil
        frame = {"ev" => JSON::Any.new(ev)} of String => JSON::Any
        fields.each { |k, v| frame[k] = v }
        line = frame.to_json
        @clients_lock.synchronize do
          @clients.dup.each do |c|
            begin
              c << line << '\n'
              c.flush
            rescue
              # Dead client — serve()'s ensure removes it from the list.
            end
          end
        end
      end

      private def accept_loop(server : UNIXServer) : Nil
        loop do
          client = begin
            server.accept
          rescue
            # Listener closed (rebind/exit).
            break
          end
          spawn { serve(client.as UNIXSocket) }
        end
      end

      private def serve(client : UNIXSocket) : Nil
        @clients_lock.synchronize { @clients << client }
        client.each_line do |line|
          next if line.strip.empty?
          handle_line(client, line)
        end
      rescue
        # Client disconnected mid-line.
      ensure
        @clients_lock.synchronize { @clients.delete(client) }
        begin
          client.close
        rescue
        end
      end

      private def handle_line(client : UNIXSocket, line : String) : Nil
        msg = begin
          JSON.parse(line)
        rescue JSON::ParseException
          reply(client, ok: false, error: "malformed JSON")
          return
        end
        op = msg["op"]?.try(&.to_s)
        text = msg["text"]?.try(&.to_s)

        case op
        when "prompt"
          if text.nil? || text.strip.empty?
            reply(client, ok: false, error: "empty prompt")
            return
          end
          @on_prompt.call(text || raise "text checked above")
          reply(client, ok: true)
        when "interrupt"
          @on_interrupt.call
          reply(client, ok: true)
        when "status"
          # Authoritative busy flag for h2code-remote's session listing: the
          # wire log has no end-of-turn record (an interrupted turn writes
          # nothing), so the TUI process itself is the source of truth.
          fields = {"busy" => JSON::Any.new(@on_status.call)} of String => JSON::Any
          if extras = @status_extras
            extras.call.each { |k, v| fields[k] = v }
          end
          reply(client, ok: true, fields: fields)
        when "answer"
          qid = msg["qid"]?.try(&.to_s).to_s
          answers = msg["answers"]?
          if cb = @on_answer
            if qid.empty? || answers.nil?
              reply(client, ok: false, error: "answer requires qid and answers")
            else
              cb.call(qid, answers)
              reply(client, ok: true)
            end
          else
            reply(client, ok: false, error: "unsupported op")
          end
        when "approve"
          qid = msg["qid"]?.try(&.to_s).to_s
          decision = msg["decision"]?.try(&.to_s).to_s
          if cb = @on_approve
            if qid.empty? || !{"allow", "allow_session", "deny"}.includes?(decision)
              reply(client, ok: false, error: "approve requires qid and decision allow|allow_session|deny")
            else
              cb.call(qid, decision)
              reply(client, ok: true)
            end
          else
            reply(client, ok: false, error: "unsupported op")
          end
        when "exit"
          if cb = @on_exit
            cb.call
            reply(client, ok: true)
          else
            reply(client, ok: false, error: "unsupported op")
          end
        when "clear"
          # Wiping the context mid-turn would race the running agent; the
          # client is told to interrupt first (the /esc-vs-/clear distinction
          # the Telegram surface keeps).
          if (cb = @on_clear).nil?
            reply(client, ok: false, error: "unsupported op")
          elsif @on_status.call
            reply(client, ok: false, error: "busy — interrupt the session first")
          else
            cb.call
            reply(client, ok: true)
          end
        when "compact"
          if (cb = @on_compact).nil?
            reply(client, ok: false, error: "unsupported op")
          elsif @on_status.call
            reply(client, ok: false, error: "busy — interrupt the session first")
          else
            cb.call
            reply(client, ok: true)
          end
        when "models"
          if cb = @on_models
            models = cb.call
            reply(client, ok: true, fields: {
              "models" => JSON::Any.new(models.map { |m| JSON::Any.new(m) }),
            })
          else
            reply(client, ok: false, error: "unsupported op")
          end
        when "model"
          name = msg["name"]?.try(&.to_s)
          if (cb = @on_model_change).nil?
            reply(client, ok: false, error: "unsupported op")
          elsif name.nil? || name.empty?
            reply(client, ok: false, error: "model requires name")
          elsif @on_status.call
            reply(client, ok: false, error: "busy — interrupt the session first")
          else
            changed = cb.call(name)
            reply(client, ok: changed, error: changed ? nil : "model switch failed")
          end
        when "mode"
          value = msg["value"]?.try(&.to_s)
          if value && !value.empty?
            if cb = @on_mode_set
              if (normalized = cb.call(value))
                reply(client, ok: true, fields: {"mode" => JSON::Any.new(normalized)})
              else
                reply(client, ok: false, error: "unknown mode: #{value}")
              end
            else
              reply(client, ok: false, error: "unsupported op")
            end
          elsif (getter = @on_mode_get)
            reply(client, ok: true, fields: {"mode" => JSON::Any.new(getter.call)})
          else
            reply(client, ok: false, error: "unsupported op")
          end
        else
          reply(client, ok: false, error: "unknown op")
        end
      rescue ex
        reply(client, ok: false, error: ex.message || "error")
      end

      private def reply(client : UNIXSocket, ok : Bool, error : String? = nil,
                        fields : Hash(String, JSON::Any)? = nil) : Nil
        payload = {"ok" => JSON::Any.new(ok)} of String => JSON::Any
        payload["error"] = JSON::Any.new(error) if error
        fields.try { |f| f.each { |k, v| payload[k] = v } }
        @clients_lock.synchronize do
          begin
            client << payload.to_json << '\n'
            client.flush
          rescue
          end
        end
      end
    end
  end
end
