require "../spec_helper"
require "../../src/tui/diff"
require "../../src/tui/terminal_mock"
require "../../src/tui/app"

# Voice-recording shrink reproducers.
#
# A pending RECORDING tool call lives in the ACTIVE zone like any running
# tool. render_recording_tool draws TWO lines while capturing (the REC timer
# + the "Ctrl+R / Space / Esc" hint). The transition to transcribing used to
# drop the hint line, shrinking the active zone mid-flight: SyncBugsCount
# fired and, once the transcript is taller than the screen, the
# viewport-shrink full-repaint path rewrote rows that already sat in the
# immutable scrollback — duplicating transcript content. The transcribing
# frame now keeps the block at two lines (a frozen "NN:NN recorded" line in
# place of the hint), so the zone never shrinks.
#
# These specs use a gated h2voice mock (stop sends ONLY the "transcribing"
# event; the result is withheld until finish! is called) so the intermediate
# transcribing frame can be rendered deterministically.

# SSE mock whose stop path withholds the result, keeping the session in the
# "transcribing" state until the spec releases it.
class GatedVoiceMock
  @sse : UNIXSocket? = nil
  @server : UNIXServer
  @path : String
  property stop_requests : Int32 = 0

  def initialize
    @path = File.join(Dir.tempdir, "h2voice-gated-#{Random::Secure.hex(6)}.sock")
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

  # Release the session: deliver the transcription result and close.
  def finish(text : String) : Nil
    if sse = @sse
      sse << sse(%({"type":"result","text":#{text.to_json},"duration_ms":4200,"engine":"gigaam","language":"ru"}))
      sse.flush
      sse.close
    end
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
      @sse = client
    when "/v1/record/stop"
      @stop_requests += 1
      body = %({"status":"stopped","duration_ms":4200})
      client << "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
      client.flush
      client.close
      # ONLY the transcribing event — the result stays withheld until
      # finish! so the spec can render frames in this state.
      if sse = @sse
        sse << sse(%({"type":"transcribing","engine":"gigaam","language":"ru"}))
        sse.flush
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

private def voice_wait_until(timeout_ms = 5000, & : -> Bool) : Bool
  deadline = Time.monotonic + timeout_ms.milliseconds
  until yield
    return false if Time.monotonic > deadline
    sleep 5.milliseconds
    Fiber.yield
  end
  true
end

# App wired to the gated mock, with the sync render path silenced.
private def voice_app(mock : GatedVoiceMock) : H2code::TUI::App
  app = H2code::TUI::App.new
  app.stop
  config = H2code::Config::Config.new
  config.transcription = H2code::Config::TranscriptionConfig.new(
    enabled: true, socket: mock.socket_path, engine: "auto", language: "ru")
  app.app_config = config
  app.run_turn_cb = ->(_text : String, _persisted : Bool, _parts : Array(H2code::LLM::ContentPart)?) { nil }
  app
end

private def strip_ansi(str : String) : String
  str.gsub(/\e\[[0-9;]*m/, "")
end

describe "Voice recording — active zone must not shrink" do
  # ── REC → transcribing: the block drops its hint line ──
  it "the transcribing state must not shrink the recording block" do
    mock = GatedVoiceMock.new
    begin
      app = voice_app(mock)

      app.toggle_voice_recording
      voice_wait_until { app.voice_recording? }.should be_true
      _l, active_rec, _e = app.build_rendered_lines_split(80)

      # Stop: the server moves to transcribing (result withheld).
      app.toggle_voice_recording
      voice_wait_until { !app.voice_recording? && app.voice_active? }.should be_true
      _l2, active_tr, _e2 = app.build_rendered_lines_split(80)

      active_tr.size.should be >= active_rec.size
      app.@sync_bugs_count.should eq(0)
    ensure
      mock.finish("cleanup")
      mock.close
    end
  end

  # ── End-to-end: a mid-session shrink repaints rows that already sit in
  # the scrollback, duplicating transcript content ──
  it "REC → transcribing does not duplicate transcript content" do
    mock = GatedVoiceMock.new
    begin
      app = voice_app(mock)
      term = H2code::TUI::TerminalMock.new(rows: 24, cols: 80)

      # Pre-fill the log so the transcript is taller than the screen and the
      # viewport scrolls (scrollback holds immutable copies).
      30.times do |i|
        app.emit_to_log(H2code::TUI::Message.new("assistant", "MARKER line #{i} payload text"))
      end
      loop do
        app.render_to(term)
        break unless app.@log_zone.pending?
      end
      before = term.visible_rows.map { |l| strip_ansi(l) }.count { |l| l.includes?("MARKER line") }

      app.toggle_voice_recording
      voice_wait_until { app.voice_recording? }.should be_true
      app.render_to(term)

      # REC → transcribing: the shrink forces the full-repaint path.
      app.toggle_voice_recording
      voice_wait_until { !app.voice_recording? && app.voice_active? }.should be_true
      app.render_to(term)

      after = term.visible_rows.map { |l| strip_ansi(l) }.count { |l| l.includes?("MARKER line") }
      after.should eq(before)
    ensure
      mock.finish("cleanup")
      mock.close
    end
  end
end
