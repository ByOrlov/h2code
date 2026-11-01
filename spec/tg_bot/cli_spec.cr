require "spec"
require "../../src/tg_bot/cli"

describe TgBot::Cli do
  it "lists every accepted flag in usage" do
    io = IO::Memory.new
    TgBot::Cli.usage(io)
    {"--setup", "--pair", "--install-service", "--help", "-h"}.each do |flag|
      io.to_s.should contain(flag)
    end
  end

  it "accepts empty argv and known flags" do
    TgBot::Cli.unknown_argument([] of String).should be_nil
    TgBot::Cli.unknown_argument(["--setup", "--pair", "--install-service"]).should be_nil
  end

  it "recognizes both help spellings" do
    TgBot::Cli.help?(["--help"]).should be_true
    TgBot::Cli.help?(["-h"]).should be_true
    TgBot::Cli.help?(["--pair"]).should be_false
  end

  it "reports the first unknown argument" do
    TgBot::Cli.unknown_argument(["--pair", "--bogus", "--wat"]).should eq("--bogus")
  end
end
