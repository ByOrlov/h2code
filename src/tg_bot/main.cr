require "./config"
require "./api"
require "./link"
require "./manager"
require "./callbacks"
require "./bot"
require "./wizard"
require "./service_port"

# h2code-tg-bot — Telegram front-end and session supervisor.
# Usage: h2code-tg-bot [--setup] [--pair] [--install-service]
#   --setup           interactive wizard: token, allowlist, dirs, binary → tg.json
#   --pair            learn your Telegram id from your first message and exit
#   --install-service install a user service unit (systemd on Linux) for
#                     this daemon; enabling/starting stays with the user
module TgBot
  def self.main(argv : Array(String)) : Nil
    if argv.includes?("--setup")
      config = Config.load
      start = Wizard.interactive(config_path: Config.path,
        input: STDIN, output: STDOUT).run
      if start
        config = Config.load
        config.validate!
        Bot.new(config).run
      end
      return
    end

    if argv.includes?("--install-service")
      install_service
      return
    end

    pair = argv.includes?("--pair")
    config = Config.load
    config.validate!(pair_mode: pair)
    Bot.new(config, pair_mode: pair).run
  rescue ex : ApiError
    STDERR.puts "error: #{ex.message}"
    exit 1
  rescue ex : ServicePort::Error
    STDERR.puts "error: #{ex.message}"
    exit 1
  rescue ex : Wizard::Aborted
    STDERR.puts "setup aborted: #{ex.message}"
    exit 3
  end

  private def self.install_service : Nil
    binary = Process.executable_path.try(&.to_s)
    raise ServicePort::Error.new("cannot resolve the running binary path") unless binary
    unless File.exists?(Config.path)
      STDERR.puts "note: #{Config.path} not found — run `h2code-tg-bot --setup` first,"
      STDERR.puts "      otherwise the service will just restart-loop on an empty config"
    end
    ServicePort.default.install(binary, STDOUT)
  end
end

TgBot.main(ARGV)
