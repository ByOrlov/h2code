# Integration spec: ImagePastePort against the REAL system clipboard —
# real process spawning (xclip / wl-paste via XWayland), no injected runner.
# Mirrors spec/integration/bash_tool_spec.cr in that it verifies genuine
# system behaviour rather than unit-level fakes.
#
# NOTE: seeding the clipboard replaces its current content (there is no way
# to snapshot/restore a clipboard portably). CI runners are headless-ish but
# XWayland usually provides :0 — when no seeder/reader pair is available the
# examples skip instead of failing.
require "../spec_helper"
require "../../src/tui/image_paste_port"

# Minimal valid PNG (magic + IHDR 800x600) used as the clipboard payload.
def clip_png_bytes : Bytes
  header = Bytes.new(33, 0)
  header[0] = 0x89
  header[1] = 0x50
  header[2] = 0x4E
  header[3] = 0x47
  header[4] = 0x0D
  header[5] = 0x0A
  header[6] = 0x1A
  header[7] = 0x0A
  header[12] = 0x49
  header[13] = 0x48
  header[14] = 0x44
  header[15] = 0x52
  header[16] = 0
  header[17] = 0
  header[18] = 0x03
  header[19] = 0x20
  header[20] = 0
  header[21] = 0
  header[22] = 0x02
  header[23] = 0x58
  header
end

def clipboard_available? : Bool
  # A reader and a seeder must both exist, plus a display to talk to.
  reader = {"xclip", "wl-paste"}.any? { |b| Process.find_executable(b) }
  seeder = {"xclip", "wl-copy"}.any? { |b| Process.find_executable(b) }
  display = ENV["DISPLAY"]? || ENV["WAYLAND_DISPLAY"]?
  reader && seeder && !display.nil?
end

def seed_clipboard_png(png : Bytes) : Bool
  tmp = File.tempname("clip-it", ".png")
  File.write(tmp, png)
  # IMPORTANT: `xclip -i` daemonizes to serve the selection; the daemon
  # inherits stdout/stderr. With pipe-backed IOs Process.run then waits for
  # EOF that never comes — a classic deadlock. Route output to /dev/null so
  # the direct child's exit is all we wait for (exactly why the same command
  # works interactively in bash).
  ok = false
  devnull_w = File.open(File::NULL, "w")
  if Process.find_executable("xclip")
    status = Process.run("xclip", ["-selection", "clipboard", "-t", "image/png", "-i"],
      input: File.open(tmp), output: devnull_w, error: devnull_w)
    ok = status.success?
  elsif Process.find_executable("wl-copy")
    status = Process.run("wl-copy", ["--type", "image/png"],
      input: File.open(tmp), output: devnull_w, error: devnull_w)
    ok = status.success?
  end
  devnull_w.close
  File.delete?(tmp)
  ok
end

describe "ImagePastePort (integration, real clipboard)" do
  it "round-trips a seeded PNG through the live clipboard" do
    # Soft-skip when no clipboard backend exists (headless CI without
    # XWayland): `next` exits the example as passed, with a visible note.
    unless clipboard_available?
      puts "SKIP clipboard round-trip: no clipboard backend available"
      next
    end

    png = clip_png_bytes
    seed_clipboard_png(png).should be_true

    # No env override, default runner — the exact path the Ctrl+V handler
    # takes in a real session.
    ENV.delete("H2CODE_CLIPBOARD_FILE")
    media = H2code::TUI::ImagePastePort.new.read_clipboard_media

    media.should_not be_nil
    if m = media
      m.image?.should be_true
      m.mime.should eq("image/png")
      m.bytes.size.should eq(png.size)
      m.bytes.should eq(png)
    end
  end

  it "returns nil quickly when the clipboard holds plain text" do
    unless clipboard_available?
      puts "SKIP clipboard text-nil: no clipboard backend available"
      next
    end

    # Same /dev/null routing as seed_clipboard_png — see the deadlock note.
    devnull_w = File.open(File::NULL, "w")
    if Process.find_executable("xclip")
      Process.run("xclip", ["-selection", "clipboard"],
        input: IO::Memory.new("plain text"), output: devnull_w, error: devnull_w)
    elsif Process.find_executable("wl-copy")
      Process.run("wl-copy", [] of String, input: IO::Memory.new("plain text"),
        output: devnull_w, error: devnull_w)
    end
    devnull_w.close

    ENV.delete("H2CODE_CLIPBOARD_FILE")
    started = Time.monotonic
    media = H2code::TUI::ImagePastePort.new.read_clipboard_media
    elapsed = Time.monotonic - started

    media.should be_nil
    # A text clipboard must fail fast, not hang on any backend probe.
    elapsed.total_seconds.should be < 10
  end
end
