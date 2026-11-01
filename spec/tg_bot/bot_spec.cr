require "../spec_helper"
require "../../src/tg_bot/callbacks"
require "../../src/tg_bot/config"
require "../../src/tg_bot/bot"

describe TgBot::Callback do
  it "round-trips every shape" do
    shapes = {
      {TgBot::Callback::Kind::Answer,   "s1", "q1", 0, 2, -1},
      {TgBot::Callback::Kind::Toggle,   "s1", "q1", 1, 0, -1},
      {TgBot::Callback::Kind::Submit,   "s1", "q1", 2, -1, -1},
      {TgBot::Callback::Kind::Dismiss,  "s1", "q1", -1, -1, -1},
      {TgBot::Callback::Kind::Approve,  "s1", "q1", -1, -1, 0},
      {TgBot::Callback::Kind::Approve,  "s1", "q1", -1, -1, 2},
    }
    shapes.each do |(kind, sid, qid, qi, oi, decision)|
      data = TgBot::Callback.build(kind, sid, qid, qi, oi, decision)
      parsed = TgBot::Callback.parse(data).should_not be_nil
      parsed.kind.should eq(kind)
      parsed.sid.should eq(sid)
      parsed.qid.should eq(qid)
      parsed.qi.should eq(qi)
      parsed.oi.should eq(oi)
      parsed.decision.should eq(decision)
    end
  end

  it "keeps callback_data within Telegram's 64-byte cap" do
    worst = TgBot::Callback.build(TgBot::Callback::Kind::Answer,
      "0123456789abcdef", "0123456789abcdef", 99, 99)
    worst.size.should be <= 64
  end

  it "round-trips command buttons" do
    {"st", "in", "sp"}.each do |action|
      parsed = TgBot::Callback.parse(
        TgBot::Callback.build(TgBot::Callback::Kind::Command, "s1", action)
      ).should_not be_nil
      parsed.kind.should eq(TgBot::Callback::Kind::Command)
      parsed.sid.should eq("s1")
      parsed.qid.should eq(action)
    end
    TgBot::Callback.parse("c:s1:").should be_nil
    TgBot::Callback.parse("c:s1:st:extra").should be_nil
  end

  it "round-trips dir-picker buttons" do
    data = TgBot::Callback.build(TgBot::Callback::Kind::NewDir, "", "", qi: 2)
    data.should eq("n:2")
    parsed = TgBot::Callback.parse(data).should_not be_nil
    parsed.kind.should eq(TgBot::Callback::Kind::NewDir)
    parsed.qi.should eq(2)
    TgBot::Callback.parse("n:x").should be_nil
    TgBot::Callback.parse("n:").should be_nil
  end

  it "rejects foreign, truncated and nil payloads" do
    TgBot::Callback.parse(nil).should be_nil
    TgBot::Callback.parse("").should be_nil
    TgBot::Callback.parse("a:s1:q1").should be_nil          # missing indices
    TgBot::Callback.parse("a:s1:q1:x:y").should be_nil      # non-numeric
    TgBot::Callback.parse("z:s1:q1").should be_nil          # unknown kind
    TgBot::Callback.parse(":q1:0:0").should be_nil          # empty sid
    TgBot::Callback.parse("x:s1:").should be_nil            # empty qid
  end
end

describe TgBot::Config do
  it "loads token, allowlist, dirs and h2code_bin" do
    with_tmpdir do |dir|
      path = File.join(dir, "tg.json")
      File.write(path, <<-JSON)
        {
          "token": "123:abc",
          "allowed_user_ids": [42, "100500"],
          "dirs": ["/srv/app"],
          "h2code_bin": "/usr/local/bin/h2code"
        }
        JSON
      config = TgBot::Config.load(path)
      config.token.should eq("123:abc")
      config.allowed_user_ids.should eq([42_i64, 100500_i64])
      config.dirs.should eq(["/srv/app"])
      config.h2code_bin.should eq("/usr/local/bin/h2code")
      config.allows?(42_i64).should be_true
      config.allows?(43_i64).should be_false
    end
  end

  it "defaults to sane values for a missing config" do
    with_tmpdir do |dir|
      config = TgBot::Config.load(File.join(dir, "missing.json"))
      config.token.should eq("")
      config.allowed_user_ids.empty?.should be_true
      config.h2code_bin.should eq("h2code")
      config.allows?(1_i64).should be_false
    end
  end
end

describe TgBot::Bot do
  it "only offers dirs listed in the config" do
    bot = test_bot(TgBot::Config.new)
    bot.pick_dir(nil).should eq(Dir.current)          # empty config → cwd
    bot.pick_dir("/etc").should be_nil                # and no arbitrary paths

    config = TgBot::Config.new
    config.dirs = ["/srv/app", "/srv/other"]
    bot = test_bot(config)
    bot.pick_dir(nil).should eq("/srv/app")
    bot.pick_dir("/srv/app").should eq("/srv/app")
    bot.pick_dir("/srv/app/").should eq("/srv/app")   # trailing slash normalizes
    bot.pick_dir("/etc").should be_nil
  end

  it "clips long texts to Telegram's message cap" do
    bot = test_bot(TgBot::Config.new)
    short = "x" * 100
    bot.clip(short).should eq(short)
    long = "x" * 5000
    bot.clip(long).size.should be <= TgBot::Bot::MAX_TEXT + 1
  end

  it "finds the highest update id in a batch" do
    TgBot::Bot.last_update_id([] of JSON::Any).should be_nil
    batch = [update(11), update(12)]
    TgBot::Bot.last_update_id(batch).should eq(12)
  end

  it "parses commands prefixed with reply-keyboard emoji" do
    config = TgBot::Config.new
    config.allowed_user_ids = [1_i64]
    api = RecordingApi.new
    bot = TgBot::Bot.new(config, api: api)

    # 📊 /status without a session → friendly hint (command was recognized)
    bot.handle_message(message(api, "📊 /status"))
    api.messages.last[1].should contain("no active session")

    # ⛔ /interrupt without a session → same recognition path
    bot.handle_message(message(api, "⛔ /interrupt"))
    api.messages.last[1].should contain("no active session")

    # /help attaches the persistent reply keyboard
    bot.handle_message(message(api, "/help"))
    api.keyboards.size.should eq(1)
    api.keyboards.last[2].should eq(TgBot::Bot::REPLY_BUTTONS)
  end

  it "offers a dir picker when /new has several configured dirs" do
    config = TgBot::Config.new
    config.allowed_user_ids = [1_i64]
    config.dirs = ["/srv/alpha", "/srv/beta"]
    api = RecordingApi.new
    bot = TgBot::Bot.new(config, api: api)

    bot.handle_message(message(api, "/new"))
    api.messages.last[1].should contain("start a session in")
    keyboard = api.messages.last[2].should_not be_nil
    keyboard = keyboard.not_nil!
    # Dir rows first, then the manual-path escape hatch and the way back.
    keyboard.size.should eq(4)
    keyboard[0][0][0].should contain("alpha")
    keyboard[1][0][0].should contain("beta")
    keyboard[0][0][1].should eq("n:0")
    keyboard[1][0][1].should eq("n:1")
    keyboard[2][0][1].should eq("ndm")
    keyboard[3][0][1].should eq("ls")

    bot.handle_message(message(api, "/dirs"))
    api.messages.last[1].should contain("/srv/alpha")
    api.messages.last[1].should contain("/srv/beta")
    # The dirs screen doubles as the manager: every dir is removable.
    dirs_kb = api.messages.last[2].should_not be_nil
    dirs_kb = dirs_kb.not_nil!
    dirs_kb[0][0][1].should eq("rd:0")
    dirs_kb[1][0][1].should eq("rd:1")
  end

  it "formats a voice transcription as a marked prompt" do
    bot = test_bot(TgBot::Config.new)
    bot.voice_prompt("привет мир").should eq("получено голосовое сообщение: привет мир")
    bot.voice_prompt("  ").should contain("получено голосовое сообщение")
  end

  it "downloads, transcribes and enqueues a voice message" do
    with_tmpdir do |dir|
      old_home = ENV["H2CODE_HOME"]?
      ENV["H2CODE_HOME"] = dir
      begin
        config = TgBot::Config.new
        config.allowed_user_ids = [1_i64]
        api = VoiceApi.new
        voice = StubVoiceClient.new("привет мир")
        bot = TgBot::Bot.new(config, api: api, voice_client: voice)

        msg = JSON.parse(%({"chat": {"id": 99}, "from": {"id": 1},
                            "voice": {"file_id": "v1", "duration": 2}}))
        bot.handle_voice(99, msg)

        # The clip landed in the h2voice-allowlisted dir (<home>/voice); the
        # transcription was echoed to the chat, and the prompt went through
        # the batching inbox and flushed with no session.
        voice.last_path.to_s.should start_with(File.join(dir, "voice"))
        api.messages.last[1].should eq("🎙 привет мир")
        sleep TgBot::Bot::BATCH_PAUSE + 0.7.seconds
        api.messages.last[1].should contain("no active session")
      ensure
        if old_home
          ENV["H2CODE_HOME"] = old_home
        else
          ENV.delete("H2CODE_HOME")
        end
      end
    end
  end

  it "names sessions automatically and honours renames in the journal" do
    with_tmpdir do |dir|
      old_home = ENV["H2CODE_HOME"]?
      ENV["H2CODE_HOME"] = dir
      begin
        bot = test_bot(TgBot::Config.new)
        bot.auto_name("/srv/app", "a3f2c1d4e5").should eq("app-a3f2")

        api = RecordingApi.new
        bot = TgBot::Bot.new(TgBot::Config.new, api: api)

        bot.state.record_start("a3f2c1d4e5", "/srv/app", "app-a3f2", custom: false)
        bot.session_name("a3f2c1d4e5").should eq("app-a3f2")

        bot.apply_rename(99, "a3f2c1d4e5", "Billing audit")
        bot.session_name("a3f2c1d4e5").should eq("Billing audit")
        bot.state.entry("a3f2c1d4e5").try(&.custom?).should be_true

        # '-' hands the automatic name back.
        bot.apply_rename(99, "a3f2c1d4e5", "-")
        bot.session_name("a3f2c1d4e5").should eq("app-a3f2")

        # The journal survives a daemon restart.
        reloaded = TgBot::State.new(TgBot::State.default_path)
        reloaded.entry("a3f2c1d4e5").try(&.dir).should eq("/srv/app")
      ensure
        if old_home
          ENV["H2CODE_HOME"] = old_home
        else
          ENV.delete("H2CODE_HOME")
        end
      end
    end
  end

  it "renders the sessions, recent and find screens from the journal" do
    with_tmpdir do |dir|
      old_home = ENV["H2CODE_HOME"]?
      ENV["H2CODE_HOME"] = dir
      begin
        config = TgBot::Config.new
        config.allowed_user_ids = [1_i64]
        api = RecordingApi.new
        bot = TgBot::Bot.new(config, api: api)

        bot.handle_message(message(api, "/sessions"))
        api.messages.last[1].should contain("0 sessions")
        kb = api.messages.last[2].should_not be_nil
        kb = kb.not_nil!
        kb.flatten.map(&.[1]).should contain("new")
        kb.flatten.map(&.[1]).should contain("hist")

        # Two closed sessions in the journal: one matches "billing".
        bot.state.record_start("s1", "/srv/app", "app-a3f2")
        bot.state.record_first_prompt("s1", "fix the billing webhook")
        bot.state.record_start("s2", "/srv/other", "other-b1c2")
        bot.state.record_first_prompt("s2", "refactor the parser")

        bot.handle_message(message(api, "/recent"))
        api.messages.last[1].should contain("2 in all")

        bot.render_find(99, nil, "billing", 0)
        api.messages.last[1].should contain("billing")
        api.messages.last[1].should contain("1 match")
        find_kb = api.messages.last[2].should_not be_nil
        find_kb = find_kb.not_nil!
        find_kb[0][0][1].should eq("cc:s1")
      ensure
        if old_home
          ENV["H2CODE_HOME"] = old_home
        else
          ENV.delete("H2CODE_HOME")
        end
      end
    end
  end

  it "routes a pending rename flow through plain text" do
    with_tmpdir do |dir|
      old_home = ENV["H2CODE_HOME"]?
      ENV["H2CODE_HOME"] = dir
      begin
        config = TgBot::Config.new
        config.allowed_user_ids = [1_i64]
        api = RecordingApi.new
        bot = TgBot::Bot.new(config, api: api)
        bot.state.record_start("s1", "/srv/app", "app-a3f2")

        bot.consume_input(99, TgBot::Bot::PendingInput.new(:rename, "s1"), "Deploy fix")
        bot.session_name("s1").should eq("Deploy fix")
        api.messages.last[1].should contain("renamed to Deploy fix")
      ensure
        if old_home
          ENV["H2CODE_HOME"] = old_home
        else
          ENV.delete("H2CODE_HOME")
        end
      end
    end
  end

end

private def message(api : RecordingApi, text : String) : JSON::Any
  JSON.parse(%({"chat": {"id": 99}, "from": {"id": 1}, "text": "#{text}"}))
end

private def test_bot(config : TgBot::Config) : TgBot::Bot
  api = TgBot::Api.new("dummy-token")
  TgBot::Bot.new(config, api: api)
end

private def update(id : Int64) : JSON::Any
  JSON.parse(%({"update_id": #{id}}))
end

# Records outgoing traffic instead of calling Telegram; method signatures
# mirror TgBot::Api exactly so it can be injected into Bot.
class RecordingApi < TgBot::Api

  property messages = [] of Tuple(Int64, String, Array(Array({String, String}))?)
  property keyboards = [] of Tuple(Int64, String, Array(Array(String)))
  property callback_answers = [] of {String, String?}

  def initialize
    super("dummy-token")
  end

  def send_message(chat_id : Int64, text : String,
                   keyboard : Array(Array({String, String}))? = nil,
                   parse_mode : String? = nil) : JSON::Any?
    messages << {chat_id, text, keyboard}
    JSON.parse(%({"message_id": 42}))
  end

  def send_keyboard(chat_id : Int64, text : String,
                    buttons : Array(Array(String))) : JSON::Any?
    keyboards << {chat_id, text, buttons}
    JSON.parse(%({"message_id": 43}))
  end

  def answer_callback_query(id : String, text : String? = nil) : Nil
    callback_answers << {id, text}
  end
end

# RecordingApi plus the file-download half of the Telegram API: getFile and
# the download itself are answered locally so voice specs never touch the
# network.
class VoiceApi < RecordingApi
  def get_file_path(file_id : String) : String?
    "voice/#{file_id}.oga"
  end

  def download_file(file_path : String, dest : String) : Nil
    File.write(dest, "fake-ogg")
  end
end

# Stubbed h2voice client: verifies the clip was downloaded to disk (into the
# h2voice allowlisted dir) and returns a canned transcription without a
# socket.
class StubVoiceClient < H2code::Transcription::Client
  property last_path : String?

  def initialize(@text : String)
    super("/nonexistent/h2voice.sock")
  end

  def transcribe_file(path : String, mime : String = "",
                      language : String? = nil, stt_engine : String = "auto") : String
    File.exists?(path).should be_true
    @last_path = path
    @text
  end
end
