require "../spec_helper"
require "../../src/tg_bot/wizard"

describe TgBot::Wizard do
  it "walks the happy path, writes the config and declines autostart" do
    with_tmpdir do |dir|
      config_path = File.join(dir, "tg.json")
      # one line per prompt: token, allowlist choice [default 2],
      # confirm learned id [default y], dirs [default cwd],
      # bin [default h2code], save [default y], start now [default n]
      input = IO::Memory.new("111:abc\n\n\n\n\n\n\n")
      wizard = TgBot::Wizard.new(input, IO::Memory.new,
        ->(t : String) { t == "111:abc" ? "mybot" : raise "bad token" },
        ->(t : String) { 42_i64 },
        config_path, cwd: dir)

      with_path_entry(dir) do
        # a fake h2code executable so the binary step resolves
        File.write(File.join(dir, "h2code"), "#!/bin/sh\n")
        File.chmod(File.join(dir, "h2code"), 0o755)
        wizard.run.should be_false
      end

      saved = TgBot::Config.load(config_path)
      saved.token.should eq("111:abc")
      saved.allowed_user_ids.should eq([42_i64])
      saved.dirs.should eq([dir])
      saved.h2code_bin.should eq("h2code")
    end
  end

  it "retries a rejected token before accepting a valid one" do
    with_tmpdir do |dir|
      config_path = File.join(dir, "tg.json")
      input = IO::Memory.new("nope\n111:abc\n1\n42, 100500\n/srv/app\n/bin/ls\n\nn\n")
      wizard = TgBot::Wizard.new(input, IO::Memory.new,
        ->(t : String) { t == "111:abc" ? "mybot" : raise "Telegram API 401: Unauthorized" },
        ->(t : String) { 42_i64 },
        config_path, cwd: dir)

      with_path_entry("/bin") { wizard.run.should be_false }

      saved = TgBot::Config.load(config_path)
      saved.token.should eq("111:abc")
      saved.allowed_user_ids.should eq([42_i64, 100500_i64])
      saved.dirs.should eq(["/srv/app"])
      saved.h2code_bin.should eq("/bin/ls")
    end
  end

  it "rejects non-numeric ids and keeps asking" do
    with_tmpdir do |dir|
      input = IO::Memory.new("111:abc\n1\n@me\n7\n\n/bin/ls\n\nn\n")
      wizard = TgBot::Wizard.new(input, IO::Memory.new,
        ->(t : String) { "mybot" },
        ->(t : String) { 42_i64 },
        File.join(dir, "tg.json"), cwd: dir)

      wizard.run

      saved = TgBot::Config.load(File.join(dir, "tg.json"))
      saved.allowed_user_ids.should eq([7_i64])
    end
  end

  it "aborts cleanly when the input closes" do
    with_tmpdir do |dir|
      wizard = TgBot::Wizard.new(IO::Memory.new(""), IO::Memory.new,
        ->(t : String) { "mybot" },
        ->(t : String) { 42_i64 },
        File.join(dir, "tg.json"), cwd: dir)
      expect_raises(TgBot::Wizard::Aborted) { wizard.run }
      File.exists?(File.join(dir, "tg.json")).should be_false
    end
  end

  describe "pure helpers" do
    wizard = TgBot::Wizard.new(IO::Memory.new, IO::Memory.new,
      ->(t : String) { "b" },
      ->(t : String) { 1_i64 },
      "/dev/null")

    it "parses ids with mixed separators" do
      wizard.parse_ids("42, 100500 7").should eq([42_i64, 100500_i64, 7_i64])
      wizard.parse_ids("").should eq([] of Int64)
      wizard.parse_ids("42, @me").should be_nil
      wizard.parse_ids("12.5").should be_nil
    end

    it "parses dirs, normalizing trailing slashes" do
      wizard.parse_dirs("/srv/app/, /srv/other").should eq(["/srv/app", "/srv/other"])
      wizard.parse_dirs("").should eq([] of String)
      wizard.parse_dirs("srv/app").should be_nil
    end

    it "resolves the binary from PATH" do
      wizard.resolve_bin("/bin/ls").should eq("/bin/ls")
      wizard.resolve_bin("ls").should eq("/bin/ls")
      wizard.resolve_bin("definitely-not-a-real-binary-xyz").should be_nil
    end

    it "masks the token in the summary" do
      wizard.mask("1234567890:ABCDEF").should eq("123456…CDEF")
      wizard.mask("short").should eq("short")
    end
  end

end

private def with_path_entry(dir : String, &)
  saved = ENV["PATH"]?
  ENV["PATH"] = "#{dir}:#{ENV["PATH"]?}"
  begin
    yield
  ensure
    saved.nil? ? ENV.delete("PATH") : (ENV["PATH"] = saved)
  end
end
