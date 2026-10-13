require "json"

module TgBot
  # Daemon configuration: `~/.h2code/tg.json` (H2CODE_HOME honoured).
  #
  #   {
  #     "token": "123456:ABC...",        // from @BotFather
  #     "allowed_user_ids": [12345678],  // numeric Telegram ids; REQUIRED
  #     "dirs": ["/srv/app"],            // offered by /new (optional)
  #     "h2code_bin": "h2code"           // how to spawn sessions
  #   }
  #
  # An empty `allowed_user_ids` refuses to start (unless --pair): a bot
  # without an allowlist would run agent sessions for anyone who finds it.
  class Config
    property token : String = ""
    property allowed_user_ids : Array(Int64) = [] of Int64
    property dirs : Array(String) = [] of String
    property h2code_bin : String = "h2code"

    def self.path : String
      home = ENV["H2CODE_HOME"]? || File.join(ENV["HOME"]? || Dir.current, ".h2code")
      File.join(home, "tg.json")
    end

    def self.load(path : String = self.path) : self
      config = new
      return config unless File.exists?(path)
      root = JSON.parse(File.read(path))
      config.token = root["token"]?.try(&.to_s) || ""
      if ids = root["allowed_user_ids"]?.try(&.as_a?)
        config.allowed_user_ids = ids.map(&.to_s.to_i64)
      end
      if dirs = root["dirs"]?.try(&.as_a?)
        config.dirs = dirs.map(&.to_s)
      end
      config.h2code_bin = root["h2code_bin"]?.try(&.to_s) || config.h2code_bin
      config
    end

    def validate!(pair_mode : Bool = false) : Nil
      if token.empty?
        STDERR.puts "config: 'token' is empty — run `h2code-tg-bot --setup`"
        STDERR.puts "  (or register a bot with @BotFather and put its token"
        STDERR.puts "  into #{Config.path})"
        exit 2
      end
      return if pair_mode
      if allowed_user_ids.empty?
        STDERR.puts "config: 'allowed_user_ids' is empty — refusing to start."
        STDERR.puts "  A bot without an allowlist would run agent sessions for"
        STDERR.puts "  anyone who finds it. Run `h2code-tg-bot --setup` to fill"
        STDERR.puts "  it in (or add your numeric Telegram id, shown by"
        STDERR.puts "  @userinfobot, to #{Config.path}; or run with --pair once"
        STDERR.puts "  to learn the id from a message)."
        exit 2
      end
    end

    def allows?(user_id : Int64) : Bool
      allowed_user_ids.includes?(user_id)
    end

    # Round-trips the config (token/ids/dirs/binary); /dirs add/remove edits
    # the live list and persists it through here.
    def save(path : String = Config.path) : Nil
      Dir.mkdir_p(File.dirname(path))
      File.open(path, "w") do |file|
        JSON.build(file, indent: "  ") do |j|
          j.object do
            j.field "token", token
            j.field "allowed_user_ids" do
              j.array { allowed_user_ids.each { |id| j.number id } }
            end
            j.field "dirs" do
              j.array { dirs.each { |d| j.string d } }
            end
            j.field "h2code_bin", h2code_bin
          end
        end
      end
    end
  end
end
