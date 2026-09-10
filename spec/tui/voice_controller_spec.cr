require "../spec_helper"
require "../../src/tui/diff"
require "../../src/tui/app"

# Interactive h2voice mock: the /v1/record/start SSE stream stays open after
# `started`; /v1/record/stop finishes the session by writing the
# transcribing + result events onto that stream, /v1/record/cancel by
# writing a single `cancelled` event — mirroring the real server.
class VoiceSessionMock
  property stop_requests : Int32 = 0
  property cancel_requests : Int32 = 0
  # When true the SSE stream is closed right after `started` — the server
  # dying mid-session, no result or error event ever arrives.
  property? drop_stream : Bool = false
  @sse : UNIXSocket? = nil
  @server : UNIXServer
  @path : String

  def initialize
    @path = File.join(Dir.tempdir, "h2voice-session-#{Random::Secure.hex(6)}.sock")
    @server = UNIXServer.new(@path)
    spawn do
      while client = @server.accept?
        spawn { handle(client) }
      end
    end
  end

  def socket_path : String
    @path
  end

  def close : Nil
    @sse.try(&.close)
    @server.close rescue nil
    File.delete(@path) rescue nil
  end

  private def handle(client : UNIXSocket) : Nil
    path = read_head(client).split(' ')[1]?
    case path
    when "/v1/record/start"
      client << "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
      client << sse(%({"type":"started","sample_rate":16000}))
      client.flush
      if drop_stream?
        client.close
      else
        @sse = client
      end
    when "/v1/record/stop"
      @stop_requests += 1
      body = %({"status":"stopped","duration_ms":4200})
      client << "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
      client.flush
      client.close
      if sse = @sse
        sse << sse(%({"type":"transcribing","engine":"gigaam","language":"ru"}))
        sse << sse(%({"type":"result","text":"привет из теста","duration_ms":4200,"engine":"gigaam","language":"ru"}))
        sse.flush
        sse.close
      end
    when "/v1/record/cancel"
      @cancel_requests += 1
      body = %({"status":"cancelled","duration_ms":4200})
      client << "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
      client.flush
      client.close
      if sse = @sse
        sse << sse(%({"type":"cancelled","duration_ms":4200}))
        sse.flush
        sse.close
      end
    end
  rescue IO::Error
  end

  private def read_head(client : UNIXSocket) : String
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

  private def sse(json : String) : String
    "data: #{json}\n\n"
  end
end

def voice_wait_until(timeout_ms = 5000, & : -> Bool) : Bool
  deadline = Time.monotonic + timeout_ms.milliseconds
  until yield
    return false if Time.monotonic > deadline
    sleep 5.milliseconds
    Fiber.yield
  end
  true
end

# Scriptable stand-in for the presence port so specs never probe the real
# filesystem (the OS adapters scan $PATH and ~/.h2voice).
class FakeVoicePresence < H2code::Transcription::VoicePresencePort
  def initialize(@installed : Bool)
  end

  def installed? : Bool
    @installed
  end
end

describe H2code::TUI::App do
  it "runs a full voice recording session via the h2voice server" do
    mock = VoiceSessionMock.new
    begin
      app = H2code::TUI::App.new
      config = H2code::Config::Config.new
      config.transcription = H2code::Config::TranscriptionConfig.new(
        enabled: true, socket: mock.socket_path, engine: "auto", language: "ru")
      app.app_config = config
      submitted = [] of String
      app.run_turn_cb = ->(text : String, _persisted : Bool, _parts : Array(H2code::LLM::ContentPart)?) do
        submitted << text
        nil
      end

      # Ctrl+R #1: session starts, pending RECORDING tool appears in the
      # active zone with the REC timer and the stop hint.
      app.toggle_voice_recording
      voice_wait_until { app.voice_recording? }.should be_true
      msg = app.@messages.find { |m| m.role == "tool" && m.tool_name == "RECORDING" }
      msg.should_not be_nil
      if m = msg
        m.tool_result.should be_nil
      end
      lines, _editor_line, log_size = app.build_rendered_lines(80)
      active = lines[log_size..].map { |l| l.gsub(/\e\[[0-9;]*m/, "") }
      active.join('\n').should contain("REC")
      active.join('\n').should contain("Ctrl+R / Space — stop and transcribe · Esc — cancel")

      # Ctrl+R #2: stop → transcribing → result. The transcription is fed
      # into the normal message path (agent idle → immediate turn), and the
      # finished entry migrates to the log zone with duration + engine.
      app.toggle_voice_recording
      voice_wait_until { !app.voice_active? }.should be_true
      mock.stop_requests.should eq(1)

      done = app.@messages.find { |t| t.role == "tool" && t.tool_name == "RECORDING" }
      done.should_not be_nil
      if m = done
        m.tool_result.should eq("привет из теста")
        m.is_error?.should be_false
        meta = JSON.parse(m.tool_args.to_s)
        meta["engine"].to_s.should eq("gigaam")
        meta["duration_ms"].as_i64.should eq(4200)
      end

      lines2, _editor2, log_size2 = app.build_rendered_lines(80)
      log = lines2[0...log_size2].map { |l| l.gsub(/\e\[[0-9;]*m/, "") }
      log.join('\n').should contain("Voice message · 00:04 · gigaam")
      log.join('\n').should contain("привет из теста")

      submitted.should eq(["привет из теста"])
    ensure
      mock.close
    end
  end

  it "cancels a recording via Esc without transcribing (protocol 0.3.0)" do
    mock = VoiceSessionMock.new
    begin
      app = H2code::TUI::App.new
      config = H2code::Config::Config.new
      config.transcription = H2code::Config::TranscriptionConfig.new(
        enabled: true, socket: mock.socket_path, engine: "auto", language: "ru")
      app.app_config = config
      submitted = [] of String
      app.run_turn_cb = ->(text : String, _persisted : Bool, _parts : Array(H2code::LLM::ContentPart)?) do
        submitted << text
        nil
      end

      app.toggle_voice_recording
      voice_wait_until { app.voice_recording? }.should be_true

      # Escape: cancel instead of stop — no stop request, no transcription.
      app.cancel_voice_recording
      voice_wait_until { !app.voice_active? }.should be_true
      mock.cancel_requests.should eq(1)
      mock.stop_requests.should eq(0)

      done = app.@messages.find { |t| t.role == "tool" && t.tool_name == "RECORDING" }
      done.should_not be_nil
      if m = done
        m.is_error?.should be_false
        m.tool_result.should eq("")
        meta = JSON.parse(m.tool_args.to_s)
        meta["cancelled"].as_bool.should be_true
        meta["duration_ms"].as_i64.should eq(4200)
      end

      lines, _editor_line, log_size = app.build_rendered_lines(80)
      log = lines[0...log_size].map { |l| l.gsub(/\e\[[0-9;]*m/, "") }
      log.join('\n').should contain("Cancelled · 00:04")

      submitted.should be_empty
    ensure
      mock.close
    end
  end

  it "keeps the recording working while the agent is busy (queued transcription)" do
    mock = VoiceSessionMock.new
    begin
      app = H2code::TUI::App.new
      config = H2code::Config::Config.new
      config.transcription = H2code::Config::TranscriptionConfig.new(
        enabled: true, socket: mock.socket_path, engine: "auto", language: "ru")
      app.app_config = config
      app.run_turn_cb = ->(_text : String, _persisted : Bool, _parts : Array(H2code::LLM::ContentPart)?) { nil }

      # Simulate a busy agent: the transcription must land in the queue.
      # compaction_started flips @is_compacting + @defer_user_messages — the
      # same gates submit_message checks to decide queue-vs-immediate.
      app.on_event(H2code::Loop::Event.compaction_started)
      app.toggle_voice_recording
      voice_wait_until { app.voice_recording? }.should be_true
      app.toggle_voice_recording
      voice_wait_until { !app.voice_active? }.should be_true

      app.@queue.size.should eq(1)
      app.@queue[0].text.should eq("привет из теста")
      app.agent_busy?.should be_true
    ensure
      mock.close
    end
  end

  it "does not start a session when transcription is explicitly disabled" do
    app = H2code::TUI::App.new
    config = H2code::Config::Config.new
    config.transcription.enabled = false
    app.app_config = config
    app.voice_presence = FakeVoicePresence.new(true)
    app.toggle_voice_recording
    app.voice_active?.should be_false
    app.@messages.last.role.should eq("error")
    app.@messages.last.content.should contain("[transcription]")
  end

  it "advises installing H2 Voice when transcription is off and H2 Voice is absent" do
    app = H2code::TUI::App.new
    config = H2code::Config::Config.new
    config.transcription.enabled = false
    app.app_config = config
    app.voice_presence = FakeVoicePresence.new(false)
    app.toggle_voice_recording
    app.voice_active?.should be_false
    app.@messages.last.role.should eq("error")
    app.@messages.last.content.should contain("Install H2 Voice")
    app.@messages.last.content.should contain(H2code::Transcription::VoicePresencePort::INSTALL_URL)
  end

  it "advises installing H2 Voice when the socket is dead and H2 Voice is absent" do
    app = H2code::TUI::App.new
    config = H2code::Config::Config.new
    config.transcription = H2code::Config::TranscriptionConfig.new(
      enabled: true, socket: "/nonexistent/h2voice.sock")
    app.app_config = config
    app.voice_presence = FakeVoicePresence.new(false)
    app.toggle_voice_recording
    voice_wait_until { !app.voice_active? }.should be_true
    done = app.@messages.find { |t| t.role == "tool" && t.tool_name == "RECORDING" }
    done.should_not be_nil
    if m = done
      m.is_error?.should be_true
      (m.tool_result || "").should contain("Install H2 Voice")
      (m.tool_result || "").should contain(H2code::Transcription::VoicePresencePort::INSTALL_URL)
    end
  end

  it "fails the session with an error when the SSE stream dies before the result" do
    mock = VoiceSessionMock.new
    mock.drop_stream = true
    begin
      app = H2code::TUI::App.new
      config = H2code::Config::Config.new
      config.transcription = H2code::Config::TranscriptionConfig.new(
        enabled: true, socket: mock.socket_path, engine: "auto", language: "ru")
      app.app_config = config

      app.toggle_voice_recording

      # Server drops the connection mid-session (possibly before the wait
      # even observes the recording state): the entry must finish with an
      # error instead of hanging in the active zone forever.
      voice_wait_until { !app.voice_active? }.should be_true
      done = app.@messages.find { |t| t.role == "tool" && t.tool_name == "RECORDING" }
      done.should_not be_nil
      if m = done
        m.is_error?.should be_true
        (m.tool_result || "").should contain("closed before the transcription result")
      end
    ensure
      mock.close
    end
  end

  it "starts a recording on a double-Space tap (alternative to Ctrl+R)" do
    mock = VoiceSessionMock.new
    begin
      app = H2code::TUI::App.new
      config = H2code::Config::Config.new
      config.transcription = H2code::Config::TranscriptionConfig.new(
        enabled: true, socket: mock.socket_path, engine: "auto", language: "ru")
      app.app_config = config

      # First tap: not consumed (the space is typed normally), but armed. In
      # the real flow handle_key inserts the space into the editor after
      # handle_space_tap returns false — mirror that here.
      app.handle_space_tap(H2code::TUI::KeyEvent.char(' ')).should be_false
      app.@last_space_at.should_not be_nil
      app.@editor.handle_input(H2code::TUI::KeyEvent.char(' '))

      # Second tap within DOUBLE_SPACE_MS: consumed → recording starts and
      # the armed state resets.
      app.handle_space_tap(H2code::TUI::KeyEvent.char(' ')).should be_true
      app.@last_space_at.should be_nil
      voice_wait_until { app.voice_recording? }.should be_true

      # Stop so the mock's SSE fiber finishes cleanly.
      app.toggle_voice_recording
      voice_wait_until { !app.voice_active? }.should be_true
    ensure
      mock.close
    end
  end

  it "stops the recording on Space when the editor holds only whitespace" do
    mock = VoiceSessionMock.new
    begin
      app = H2code::TUI::App.new
      config = H2code::Config::Config.new
      config.transcription = H2code::Config::TranscriptionConfig.new(
        enabled: true, socket: mock.socket_path, engine: "auto", language: "ru")
      app.app_config = config

      app.toggle_voice_recording
      voice_wait_until { app.voice_recording? }.should be_true

      # Stray spaces (and tabs) in the input are not content: Space still
      # stops the capture instead of typing another character.
      app.@editor.set("   \t ")
      app.space_stops_recording?(H2code::TUI::KeyEvent.char(' ')).should be_true

      app.toggle_voice_recording
      voice_wait_until { !app.voice_active? }.should be_true
      mock.stop_requests.should eq(1)
    ensure
      mock.close
    end
  end

  it "types the Space normally mid-typing instead of stopping the recording" do
    mock = VoiceSessionMock.new
    begin
      app = H2code::TUI::App.new
      config = H2code::Config::Config.new
      config.transcription = H2code::Config::TranscriptionConfig.new(
        enabled: true, socket: mock.socket_path, engine: "auto", language: "ru")
      app.app_config = config

      app.toggle_voice_recording
      voice_wait_until { app.voice_recording? }.should be_true

      app.@editor.set("/tips")
      app.space_stops_recording?(H2code::TUI::KeyEvent.char(' ')).should be_false

      app.cancel_voice_recording
      voice_wait_until { !app.voice_active? }.should be_true
      mock.stop_requests.should eq(0)
    ensure
      mock.close
    end
  end

  it "does not start a recording when text is typed between the two Spaces" do
    mock = VoiceSessionMock.new
    begin
      app = H2code::TUI::App.new
      config = H2code::Config::Config.new
      config.transcription = H2code::Config::TranscriptionConfig.new(
        enabled: true, socket: mock.socket_path, engine: "auto", language: "ru")
      app.app_config = config

      app.handle_space_tap(H2code::TUI::KeyEvent.char(' ')).should be_false
      app.@editor.handle_input(H2code::TUI::KeyEvent.char(' '))

      # Characters typed between the presses (same path handle_key takes for
      # the editor; @last_space_at is reset by handle_key, but the trigger
      # must also hold without that reset — see the armed-state check below).
      app.@editor.handle_input(H2code::TUI::KeyEvent.char('т'))
      app.@editor.handle_input(H2code::TUI::KeyEvent.char('е'))
      app.@editor.handle_input(H2code::TUI::KeyEvent.char('к'))
      app.@editor.handle_input(H2code::TUI::KeyEvent.char('с'))
      app.@editor.handle_input(H2code::TUI::KeyEvent.char('т'))

      # Worst case: the armed timestamp survived (e.g. the intermediate keys
      # were consumed by a dialog before reaching the reset branch in
      # handle_key). The editor-content guard must still refuse to trigger,
      # and the press must be typed normally instead.
      app.handle_space_tap(H2code::TUI::KeyEvent.char(' ')).should be_false
      app.voice_active?.should be_false
      # handle_key types the refused press normally — mirror it.
      app.@editor.handle_input(H2code::TUI::KeyEvent.char(' '))
      app.@editor.text.should eq(" текст ")
    ensure
      mock.close
    end
  end

  it "shows an error on a double-Space tap when transcription is disabled" do
    app = H2code::TUI::App.new
    config = H2code::Config::Config.new
    config.transcription.enabled = false
    app.app_config = config
    app.voice_presence = FakeVoicePresence.new(true)

    # First tap: not consumed (the space is typed normally), but armed. In
    # the real flow handle_key inserts the space into the editor after
    # handle_space_tap returns false — mirror that here.
    app.handle_space_tap(H2code::TUI::KeyEvent.char(' ')).should be_false
    app.@last_space_at.should_not be_nil
    app.@editor.handle_input(H2code::TUI::KeyEvent.char(' '))

    # Second tap: consumed even though voice is disabled — start_voice_
    # recording emits the config error instead of silently doing nothing,
    # and the typed space is removed just like on the enabled path.
    app.handle_space_tap(H2code::TUI::KeyEvent.char(' ')).should be_true
    app.@last_space_at.should be_nil
    app.voice_active?.should be_false
    app.@editor.text.should eq("")
    app.@messages.last.role.should eq("error")
    app.@messages.last.content.should contain("[transcription]")
  end
end
