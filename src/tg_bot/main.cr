require "./config"
require "./api"
require "./link"
require "./manager"
require "./callbacks"
require "./bot"
require "./wizard"
require "./service_port"
require "./single_instance"
require "./cli"

# h2code-tg-bot — Telegram front-end and session supervisor.
# Usage: h2code-tg-bot [--setup] [--pair] [--install-service]
#   --setup           interactive wizard: token, allowlist, dirs, binary → tg.json
#   --pair            learn your Telegram id from your first message and exit
#   --install-service install a user service unit (systemd on Linux) for
#                     this daemon; enabling/starting stays with the user
#   --help, -h        show usage and exit; unknown arguments are rejected
#                     with the same usage text (exit code 2)
module TgBot
  def self.main(argv : Array(String)) : Nil
    if Cli.help?(argv)
      Cli.usage(STDOUT)
      return
    end

    if unknown = Cli.unknown_argument(argv)
      STDERR.puts "error: unknown argument: #{unknown}"
      Cli.usage(STDERR)
      exit 2
    end

    if argv.includes?("--setup")
      config = Config.load
      start = Wizard.interactive(config_path: Config.path,
        input: STDIN, output: STDOUT).run
      if start
        config = Config.load
        config.validate!
        guard = SingleInstancePort.default
        guard.acquire(config.token)
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
    # Single-instance guard (also for --pair: pairing polls getUpdates too,
    # and Telegram serves only one poller per token). `guard` must stay
    # reachable for the process lifetime — it owns the lock file handle.
    guard = SingleInstancePort.default
    guard.acquire(config.token)
    Bot.new(config, pair_mode: pair).run
  rescue ex : ApiError
    STDERR.puts "error: #{ex.message}"
    exit 1
  rescue ex : SingleInstancePort::AlreadyRunning
    STDERR.puts "error: #{ex.message}"
    STDERR.puts "  Telegram serves only one getUpdates poller per bot token;"
    STDERR.puts "  stop the other instance (pgrep -af h2code-tg-bot) first."
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
