require "http/client"
require "socket"

module H2code
  module Transcription
    # One event from the /v1/record/start SSE stream (see VOICE_PROTOCOL.md
    # in the h2voice repo). `type` is one of: started, level, stopped,
    # cancelled, transcribing, result, error.
    struct RecordEvent
      property kind : String
      property text : String = ""
      property rms : Float64 = 0.0
      property duration_ms : Int64 = 0_i64
      property engine : String = ""
      property language : String = ""
      # Error-only fields (`kind == "error"`).
      property code : String = ""
      property message : String = ""

      def initialize(@kind : String)
      end

      # SSE event type: started | level | stopped | cancelled | transcribing |
      # result | error.
      def type : String
        @kind
      end

      def self.parse(json : String) : RecordEvent?
        parsed = JSON.parse(json)
        evt = RecordEvent.new(parsed["type"]?.try(&.to_s) || "")
        evt.text = parsed["text"]?.try(&.to_s) || ""
        evt.rms = parsed["rms"]?.try(&.as_f?) || 0.0
        evt.duration_ms = parsed["duration_ms"]?.try(&.as_i64?) || 0_i64
        evt.engine = parsed["engine"]?.try(&.to_s) || ""
        evt.language = parsed["language"]?.try(&.to_s) || ""
        evt.code = parsed["code"]?.try(&.to_s) || ""
        evt.message = parsed["message"]?.try(&.to_s) || ""
        evt
      rescue JSON::ParseException
        nil
      end
    end

    # Thin client for the local h2voice server (HTTP/1.1 over a Unix domain
    # socket, chmod 0600). Recording is streamed as Server-Sent Events; the
    # stop endpoint returns immediately and the final transcribing/result
    # events arrive on the SSE stream opened by `record_start`.
    class Client
      class Error < Exception
      end

      @path : String

      def initialize(@path : String)
      end

      # Build a client from the `transcription` config section, honouring the
      # socket-path env overrides the server itself reads and expanding `~`.
      def self.from_config(cfg : Config::TranscriptionConfig) : Client
        path = cfg.socket
        {"H2VOICE_VOICE_SOCKET", "SOROKA_VOICE_SOCKET",
         "HCODE_VOICE_SOCKET", "H2CODE_VOICE_SOCKET"}.each do |env|
          if v = ENV[env]?
            path = v
            break
          end
        end
        home = HomePort.home
        path = path.sub(/^~(?=\/|$)/, home)
        new(path)
      end

      def socket_path : String
        @path
      end

      # GET /health. Returns the server protocol version, or nil when the
      # socket is absent or the server does not answer.
      def health? : String?
        with_client do |client|
          resp = client.get("/health")
          return nil unless resp.status.success?
          JSON.parse(resp.body)["version"]?.try(&.to_s)
        end
      rescue IO::Error | JSON::ParseException
        nil
      end

      # POST /v1/record/start and consume its SSE stream, invoking `on_event`
      # for every event until the stream closes (result/error delivered, or
      # the server dropped the connection). Runs in the calling fiber — spawn
      # one if the caller must not block (the stream lives for the whole
      # recording session).
      def record_start(language : String, stt_engine : String,
                       &on_event : RecordEvent -> Nil) : Nil
        body = {"language" => language, "stt_engine" => stt_engine}.to_json
        with_client do |client|
          # Block form: the response body is NOT buffered, so the SSE stream
          # can be consumed incrementally via body_io.
          client.post("/v1/record/start", body: body) do |resp|
            if resp.status.success?
              parse_sse(resp) { |evt| on_event.call(evt) }
            else
              # 409 already_recording and others arrive as JSON, not SSE.
              on_event.call(error_from_body(resp))
            end
          end
        end
      end

      # POST /v1/record/stop. Returns true when the server accepted the stop
      # (the final events still arrive on the start stream). False when no
      # session was active (409) or the server is unreachable.
      def record_stop : Bool
        with_client do |client|
          resp = client.post("/v1/record/stop")
          resp.status.success?
        end
      rescue IO::Error
        false
      end

      # POST /v1/record/cancel (protocol 0.3.0). Aborts the capture without
      # transcription: the server discards the audio and the terminal
      # `cancelled` event arrives on the start stream. Returns true when the
      # server accepted the cancel. False when no session was active (409),
      # the server predates the endpoint (404) or it is unreachable.
      def record_cancel : Bool
        with_client do |client|
          resp = client.post("/v1/record/cancel")
          resp.status.success?
        end
      rescue IO::Error
        false
      end

      private def with_client(& : HTTP::Client -> _)
        client = HTTP::Client.new(UNIXSocket.new(@path))
        begin
          yield client
        ensure
          client.close
        end
      end

      # Read `data:` lines off an SSE response body until EOF.
      private def parse_sse(resp : HTTP::Client::Response, &on_event : RecordEvent -> Nil) : Nil
        io = resp.body_io
        loop do
          line = io.read_line
          next unless line.starts_with?("data:")
          if evt = RecordEvent.parse(line[5..].strip)
            on_event.call(evt)
          end
        rescue IO::EOFError
          break
        end
      end

      private def error_from_body(resp : HTTP::Client::Response) : RecordEvent
        evt = RecordEvent.new("error")
        evt.code = "http_#{resp.status_code}"
        # Block-form responses stream their body — read it from body_io.
        body = resp.body_io.try(&.gets_to_end)
        begin
          parsed = JSON.parse(body.to_s)
          evt.message = parsed["status"]?.try(&.to_s) || parsed["error"]?.try(&.to_s) || resp.status_message.to_s
        rescue JSON::ParseException
          evt.message = resp.status_message.to_s
        end
        evt
      end
    end
  end
end
