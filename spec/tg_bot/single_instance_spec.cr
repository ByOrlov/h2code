require "spec"
require "../../src/tg_bot/single_instance"

describe TgBot::SingleInstancePort do
  old_home = ENV["H2CODE_HOME"]?

  around_each do |example|
    ENV["H2CODE_HOME"] = File.join(Dir.tempdir, "tg-single-instance-spec-#{Random::Secure.hex(8)}")
    begin
      example.run
    ensure
      ENV["H2CODE_HOME"] = old_home
    end
  end

  it "rejects a second acquisition of the same token" do
    first = TgBot::SingleInstancePort.default
    first.acquire("111:AAA")
    second = TgBot::SingleInstancePort.default
    expect_raises(TgBot::SingleInstancePort::AlreadyRunning) do
      second.acquire("111:AAA")
    end
  end

  it "allows different tokens side by side" do
    TgBot::SingleInstancePort.default.acquire("111:AAA")
    TgBot::SingleInstancePort.default.acquire("222:BBB")
  end

  it "names the holder pid in the error" do
    TgBot::SingleInstancePort.default.acquire("333:CCC")
    ex = expect_raises(TgBot::SingleInstancePort::AlreadyRunning) do
      TgBot::SingleInstancePort.default.acquire("333:CCC")
    end
    ex.message.to_s.should contain("pid #{Process.pid}")
  end

  # flock conflicts between two descriptors of one process, so the specs
  # above exercise the real cross-process mechanics; the path layout below
  # is unix-only detail.
  {% unless flag?(:win32) %}
    it "keys lock files by token hash under the h2code home" do
      a = TgBot::UnixSingleInstancePort.lock_path("111:AAA")
      b = TgBot::UnixSingleInstancePort.lock_path("222:BBB")
      a.should start_with(File.join(ENV["H2CODE_HOME"], "locks"))
      a.should_not eq(b)
      # stable across calls, so a restart finds the same lock
      TgBot::UnixSingleInstancePort.lock_path("111:AAA").should eq(a)
    end
  {% end %}
end
