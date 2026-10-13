require "../spec_helper"
require "../../src/transcription/client"

# Minimal HTTP-over-unix-socket mock for the h2voice server (see
# VOICE_PROTOCOL.md). Each connection is answered from the scripted `routes`
# hash: path → response body/status. SSE responses are written raw and the
# socket closed (Connection: close), which the real server's chunked stream
# reduces to from the client's perspective.
class VoiceMockServer
  getter requests : Array(String) = [] of String
  @routes : Hash(String, Tuple(Int32, Array(String), String)) = {} of String => Tuple(Int32, Array(String), String)
  @path : String

  def initialize(path : String)
    @server = UNIXServer.new(path)
    @path = path
  end

  def self.start(& : self -> Nil) : Nil
    path = File.join(Dir.tempdir, "h2voice-mock-#{Random::Secure.hex(6)}.sock")
    mock = new(path)
    mock.run
    yield mock
  ensure
    mock.try(&.close)
  end

  def socket_path : String
    @path
  end

  # Script a response for a request path. `body` is written verbatim after
  # the status line; for SSE pass "event-stream" headers + data lines.
  def route(path : String, status : Int32, headers : Array(String), body : String) : Nil
    @routes[path] = {status, headers, body}
  end

  def run : Nil
    spawn do
      while client = @server.accept?
        handle(client)
      end
    end
  end

  def close : Nil
    @server.close rescue nil
    File.delete(@path) rescue nil
  end

  private def handle(client : UNIXSocket)
    spawn do
      begin
        request = read_request(client)
        @requests << request
        path = request.split(' ')[1]?.to_s
        status, headers, body = @routes[path]? || {404, ["Content-Type: application/json"], %({"error":"not found"})}
        sse = headers.includes?("Content-Type: text/event-stream")
        client << "HTTP/1.1 #{status} #{status == 200 ? "OK" : "Status"}\r\n"
        headers.each { |h| client << h << "\r\n" }
        client << "Content-Length: #{body.bytesize}\r\n" unless sse
        client << "\r\n"
        client << body
        client.flush
        client.close
      rescue IO::Error
      end
    end
  end

  # Read the request head only (method + path + headers). Bodies are left
  # unread — routing needs nothing from them and the socket is closed right
  # after the response anyway.
  private def read_request(client : UNIXSocket) : String
    String.build do |s|
      loop do
        line = client.read_line
        break if line == "\r\n" || line.empty?
        s << line << "\n"
      end
    end
  rescue IO::Error
    ""
  end
end

def sse(*events : String) : {Int32, Array(String), String}
  body = events.map { |e| "data: #{e}\n\n" }.join
  {200, ["Content-Type: text/event-stream", "Cache-Control: no-cache", "Connection: close"], body}
end

describe H2code::Transcription::Client do
  it "reads /health" do
    VoiceMockServer.start do |mock|
      mock.route("/health", 200, ["Content-Type: application/json"], %({"status":"ok","version":"0.2.1"}))
      client = H2code::Transcription::Client.new(mock.socket_path)
      client.health?.should eq("0.2.1")
    end
  end

  it "returns nil health when the socket is missing" do
    client = H2code::Transcription::Client.new("/nonexistent/h2voice-mock.sock")
    client.health?.should be_nil
  end

  it "parses SSE events from /v1/record/start" do
    VoiceMockServer.start do |mock|
      mock.route("/v1/record/start", *sse(
        %({"type":"started","sample_rate":16000,"channels":1,"device":"default"}),
        %({"type":"level","rms":0.12}),
        %({"type":"transcribing","engine":"gigaam","language":"ru"}),
        %({"type":"result","text":"привет мир","duration_ms":2100,"engine":"gigaam","language":"ru"}),
      ))
      client = H2code::Transcription::Client.new(mock.socket_path)
      types = [] of String
      result = nil
      client.record_start("ru", "auto") do |evt|
        types << evt.type
        result = evt if evt.type == "result"
      end
      types.should eq(["started", "level", "transcribing", "result"])
      result.should_not be_nil
      if r = result
        r.text.should eq("привет мир")
        r.duration_ms.should eq(2100)
        r.engine.should eq("gigaam")
      end
    end
  end

  it "parses error events with code and message" do
    VoiceMockServer.start do |mock|
      mock.route("/v1/record/start", *sse(
        %({"type":"error","code":"audio_too_short","message":"recording too short: 100ms"}),
      ))
      client = H2code::Transcription::Client.new(mock.socket_path)
      errors = [] of H2code::Transcription::RecordEvent
      client.record_start("auto", "auto") { |evt| errors << evt if evt.type == "error" }
      errors.size.should eq(1)
      errors[0].code.should eq("audio_too_short")
      errors[0].message.should eq("recording too short: 100ms")
    end
  end

  it "delivers a JSON error body as an error event for non-200 responses" do
    VoiceMockServer.start do |mock|
      mock.route("/v1/record/start", 409, ["Content-Type: application/json"], %({"status":"already_recording"}))
      client = H2code::Transcription::Client.new(mock.socket_path)
      events = [] of H2code::Transcription::RecordEvent
      client.record_start("auto", "auto") { |evt| events << evt }
      events.size.should eq(1)
      events[0].type.should eq("error")
      events[0].message.should eq("already_recording")
    end
  end

  it "reports record_stop success and failure" do
    VoiceMockServer.start do |mock|
      mock.route("/v1/record/stop", 200, ["Content-Type: application/json"], %({"status":"stopped","duration_ms":2130}))
      client = H2code::Transcription::Client.new(mock.socket_path)
      client.record_stop.should be_true

      missing = H2code::Transcription::Client.new("/nonexistent/h2voice-mock.sock")
      missing.record_stop.should be_false
    end
  end

  it "reports record_cancel success, 409 and failure" do
    VoiceMockServer.start do |mock|
      mock.route("/v1/record/cancel", 200, ["Content-Type: application/json"], %({"status":"cancelled","duration_ms":2130}))
      client = H2code::Transcription::Client.new(mock.socket_path)
      client.record_cancel.should be_true

      missing = H2code::Transcription::Client.new("/nonexistent/h2voice-mock.sock")
      missing.record_cancel.should be_false
    end

    # 409 not_recording (and 404 from pre-0.3.0 servers) must read as false
    # so the caller can fall back to record_stop.
    VoiceMockServer.start do |mock|
      mock.route("/v1/record/cancel", 409, ["Content-Type: application/json"], %({"status":"not_recording"}))
      client = H2code::Transcription::Client.new(mock.socket_path)
      client.record_cancel.should be_false
    end
  end

  it "transcribes a local file via /v1/transcribe/file" do
    VoiceMockServer.start do |mock|
      mock.route("/v1/transcribe/file", 200, ["Content-Type: application/json"],
        %({"text":"привет мир","duration_sec":2.1,"engine":"gigaam","language":"ru"}))
      client = H2code::Transcription::Client.new(mock.socket_path)
      client.transcribe_file("/tmp/clip.ogg", mime: "audio/ogg",
        language: "ru", stt_engine: "auto").should eq("привет мир")
    end
  end

  it "raises with the server's error reason for a failed transcription" do
    VoiceMockServer.start do |mock|
      mock.route("/v1/transcribe/file", 422, ["Content-Type: application/json"],
        %({"error":"no_stt_engine_available"}))
      client = H2code::Transcription::Client.new(mock.socket_path)
      expect_raises(H2code::Transcription::Client::Error, "no_stt_engine_available") do
        client.transcribe_file("/tmp/clip.ogg")
      end
    end
  end

  it "expands ~ and honours env overrides in from_config" do
    home = ENV["HOME"]? || "/tmp"
    cfg = H2code::Config::TranscriptionConfig.new(enabled: true, socket: "~/../h2voice/voice.sock")
    H2code::Transcription::Client.from_config(cfg).socket_path.should eq("#{home}/../h2voice/voice.sock")

    ENV["H2VOICE_VOICE_SOCKET"] = "/tmp/custom.sock"
    H2code::Transcription::Client.from_config(cfg).socket_path.should eq("/tmp/custom.sock")
  ensure
    ENV.delete("H2VOICE_VOICE_SOCKET")
  end
end
