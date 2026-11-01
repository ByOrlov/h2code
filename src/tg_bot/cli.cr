module TgBot
  # CLI surface of the daemon target: usage text and argv validation.
  # Kept separate from `main.cr` (the shard target entry, which invokes
  # `TgBot.main(ARGV)` on require) so specs can exercise parsing directly.
  module Cli
    FLAGS = {"--setup", "--pair", "--install-service", "--help", "-h"}

    def self.help?(argv : Array(String)) : Bool
      argv.includes?("--help") || argv.includes?("-h")
    end

    # First argument that isn't a known flag, nil when argv is valid.
    def self.unknown_argument(argv : Array(String)) : String?
      argv.reject { |arg| FLAGS.includes?(arg) }.first?
    end

    def self.usage(io : IO) : Nil
      io.puts <<-USAGE
      Usage: h2code-tg-bot [--setup] [--pair] [--install-service]

        --setup           interactive wizard: token, allowlist, dirs, binary → tg.json
        --pair            learn your Telegram id from your first message and exit
        --install-service install a user service unit (systemd on Linux) for
                          this daemon; enabling/starting stays with the user
        --help, -h        show this help and exit
      USAGE
    end
  end
end
