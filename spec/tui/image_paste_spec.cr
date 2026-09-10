require "../spec_helper"
require "../../src/tui/input"
require "../../src/tui/image_paste_port"
require "../../src/tui/media_attachment_store"

# Minimal PNG payload: magic + IHDR with 800x600 dimensions.
def make_png_bytes : Bytes
  header = Bytes.new(33, 0)
  header[0] = 0x89
  header[1] = 0x50
  header[2] = 0x4E
  header[3] = 0x47
  header[4] = 0x0D
  header[5] = 0x0A
  header[6] = 0x1A
  header[7] = 0x0A
  # IHDR chunk length + type.
  header[12] = 0x49
  header[13] = 0x48
  header[14] = 0x44
  header[15] = 0x52
  # Width 800, height 600.
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

describe H2code::TUI::ImagePastePort do
  it "reads an image via xclip TARGETS + image/png" do
    png = make_png_bytes
    responses = {
      {"xclip", ["-selection", "clipboard", "-t", "TARGETS", "-o"]}   => {true, "image/png\ntext/plain".to_slice},
      {"xclip", ["-selection", "clipboard", "-t", "image/png", "-o"]} => {true, png},
    }
    runner = ->(cmd : String, args : Array(String), _t : Int32) : {Bool, Bytes} do
      responses[{cmd, args}]? || {false, Bytes.empty}
    end

    # No Wayland session → the X11 xclip path is taken.
    old_wayland = ENV.delete("WAYLAND_DISPLAY")
    old_session = ENV.delete("XDG_SESSION_TYPE")

    media = H2code::TUI::ImagePastePort.new(runner).read_clipboard_media
    media.should_not be_nil
    if m = media
      m.image?.should be_true
      m.mime.should eq("image/png")
      m.bytes.should eq(png)
    end
  ensure
    ENV["WAYLAND_DISPLAY"] = old_wayland if old_wayland
    ENV["XDG_SESSION_TYPE"] = old_session if old_session
  end

  it "resolves a uri-list file path to image bytes" do
    png = make_png_bytes
    path = File.tempname("paste-spec", ".png")
    File.write(path, png)

    responses = {
      {"xclip", ["-selection", "clipboard", "-t", "TARGETS", "-o"]}       => {true, "text/uri-list".to_slice},
      {"xclip", ["-selection", "clipboard", "-t", "text/uri-list", "-o"]} => {true, "file://#{path}\n".to_slice},
    }
    runner = ->(cmd : String, args : Array(String), _t : Int32) : {Bool, Bytes} do
      responses[{cmd, args}]? || {false, Bytes.empty}
    end

    old_wayland = ENV.delete("WAYLAND_DISPLAY")
    old_session = ENV.delete("XDG_SESSION_TYPE")

    media = H2code::TUI::ImagePastePort.new(runner).read_clipboard_media
    media.should_not be_nil
    if m = media
      m.image?.should be_true
      m.mime.should eq("image/png")
      m.bytes.should eq(png)
    end
  ensure
    File.delete?(path) if path
    ENV["WAYLAND_DISPLAY"] = old_wayland if old_wayland
    ENV["XDG_SESSION_TYPE"] = old_session if old_session
  end

  it "reads an image file via H2CODE_CLIPBOARD_FILE override" do
    png = make_png_bytes
    path = File.tempname("paste-spec", ".png")
    File.write(path, png)

    old = ENV["H2CODE_CLIPBOARD_FILE"]?
    ENV["H2CODE_CLIPBOARD_FILE"] = path

    # Runner that fails everything — the override must not need the clipboard.
    runner = ->(_cmd : String, _args : Array(String), _t : Int32) : {Bool, Bytes} { {false, Bytes.empty} }

    media = H2code::TUI::ImagePastePort.new(runner).read_clipboard_media
    media.should_not be_nil
    if m = media
      m.image?.should be_true
      m.mime.should eq("image/png")
    end
  ensure
    File.delete?(path) if path
    if old
      ENV["H2CODE_CLIPBOARD_FILE"] = old
    else
      ENV.delete("H2CODE_CLIPBOARD_FILE")
    end
  end

  it "returns nil when no image is available" do
    runner = ->(_cmd : String, _args : Array(String), _t : Int32) : {Bool, Bytes} { {false, Bytes.empty} }

    old_wayland = ENV.delete("WAYLAND_DISPLAY")
    old_session = ENV.delete("XDG_SESSION_TYPE")
    old_clip = ENV.delete("H2CODE_CLIPBOARD_FILE")

    H2code::TUI::ImagePastePort.new(runner).read_clipboard_media.should be_nil
  ensure
    ENV["WAYLAND_DISPLAY"] = old_wayland if old_wayland
    ENV["XDG_SESSION_TYPE"] = old_session if old_session
    ENV["H2CODE_CLIPBOARD_FILE"] = old_clip if old_clip
  end
end

describe H2code::TUI::MediaAttachmentStore do
  it "assigns sequential ids and formats placeholders" do
    store = H2code::TUI::MediaAttachmentStore.new
    a = store.add_image(make_png_bytes, "image/png", 800, 600)
    b = store.add_video("/tmp/demo/sample.mp4", "video/mp4")

    a.placeholder.should eq("[image #1 (800×600)]")
    b.placeholder.should eq("[video #2 sample.mp4]")

    store.get(1).should_not be_nil
    store.get(2).should eq(b)
    store.size.should eq(2)

    store.clear
    store.get(1).should be_nil
    store.size.should eq(0)

    # Ids restart after clear (matches the JS store).
    c = store.add_image(Bytes.empty, "image/png", 1, 1)
    c.id.should eq(1)
  end

  it "sanitizes video labels with placeholder-breaking chars" do
    store = H2code::TUI::MediaAttachmentStore.new
    v = store.add_video("/tmp/x/a[b].mp4", "video/mp4")
    v.placeholder.should_not contain("[b]")
    v.label.should eq("a_b_.mp4")
  end

  it "extracts image placeholders into interleaved parts" do
    store = H2code::TUI::MediaAttachmentStore.new
    store.add_image(make_png_bytes, "image/png", 800, 600)

    parts, ids = store.extract_parts("look at this [image #1 (800×600)] please")
    ids.should eq([1])
    parts.should_not be_nil
    if p = parts
      p.size.should eq(3)
      p[0].should be_a(H2code::LLM::TextContent)
      # Trailing whitespace is preserved verbatim (JS drops only
      # whitespace-only segments).
      p[0].as(H2code::LLM::TextContent).text.should eq("look at this ")
      p[1].should be_a(H2code::LLM::ImageContent)
      url = p[1].as(H2code::LLM::ImageContent).image_url.url
      url.should start_with("data:image/png;base64,")
      p[2].as(H2code::LLM::TextContent).text.should eq(" please")
    end
  end

  it "extracts video placeholders into file-path tags" do
    store = H2code::TUI::MediaAttachmentStore.new
    store.add_video("/tmp/demo/sample.mp4", "video/mp4")

    parts, ids = store.extract_parts("check [video #1 sample.mp4]")
    ids.should eq([1])
    parts.should_not be_nil
    if p = parts
      # Video tags are text, so adjacent text segments merge into one part.
      p.size.should eq(1)
      text = p[0].as(H2code::LLM::TextContent).text
      text.should contain("check")
      text.should contain(%(<video path="/tmp/demo/sample.mp4">))
    end
  end

  it "leaves stale and user-typed placeholders as literal text" do
    store = H2code::TUI::MediaAttachmentStore.new
    parts, ids = store.extract_parts("typed [image #999 (1×1)] by hand")
    ids.should be_empty
    parts.should be_nil
  end

  it "returns nil parts for plain text" do
    store = H2code::TUI::MediaAttachmentStore.new
    store.add_image(make_png_bytes, "image/png", 800, 600)
    parts, ids = store.extract_parts("no media here")
    ids.should be_empty
    parts.should be_nil
  end
end

describe "Ctrl+V key parsing" do
  it "maps byte 0x16 to Key::CtrlV" do
    parser = H2code::TUI::Input.new
    key, consumed = parser.parse_one([22_u8])
    consumed.should eq(1)
    key.should_not be_nil
    key.not_nil!.key.should eq(H2code::TUI::Key::CtrlV)
  end

  it "maps kitty CSI-u ESC[118;5u to Key::CtrlV" do
    parser = H2code::TUI::Input.new
    seq = "\e[118;5u".bytes
    key, consumed = parser.parse_one(seq)
    consumed.should eq(seq.size)
    key.should_not be_nil
    key.not_nil!.key.should eq(H2code::TUI::Key::CtrlV)
  end

  it "maps xterm modifyOtherKeys ESC[27;5;118~ to Key::CtrlV" do
    parser = H2code::TUI::Input.new
    seq = "\e[27;5;118~".bytes
    key, consumed = parser.parse_one(seq)
    consumed.should eq(seq.size)
    key.should_not be_nil
    key.not_nil!.key.should eq(H2code::TUI::Key::CtrlV)
  end

  it "maps kitty CSI-u alt combos to a flagged char event" do
    parser = H2code::TUI::Input.new
    seq = "\e[118;3u".bytes # alt+v (mods 3-1=2 → alt)
    key, consumed = parser.parse_one(seq)
    consumed.should eq(seq.size)
    key.should_not be_nil
    ev = key.not_nil!
    ev.char.should eq('v')
    ev.alt?.should be_true
  end

  it "drops kitty key-release events (mods:event-type 3)" do
    parser = H2code::TUI::Input.new
    seq = "\e[118;5:3u".bytes # Ctrl+V release
    key, consumed = parser.parse_one(seq)
    consumed.should eq(seq.size)
    key.should be_nil
  end

  it "maps disambiguated control keys from kitty CSI-u" do
    parser = H2code::TUI::Input.new
    {"\e[27u"   => H2code::TUI::Key::Escape,
     "\e[13u"   => H2code::TUI::Key::Enter,
     "\e[9u"    => H2code::TUI::Key::Tab,
     "\e[127u"  => H2code::TUI::Key::Backspace,
     "\e[13;2u" => H2code::TUI::Key::ShiftEnter}.each do |seq_str, expected|
      key, consumed = parser.parse_one(seq_str.bytes)
      consumed.should eq(seq_str.bytes.size)
      key.should_not be_nil
      key.not_nil!.key.should eq(expected)
    end
  end
end
