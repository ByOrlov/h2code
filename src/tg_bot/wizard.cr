require "json"
require "colorize"
require "./config"
require "./api"

module TgBot
  # Interactive setup wizard for `~/.h2code/tg.json` (`h2code-tg-bot --setup`).
  #
  # Terminal-driven: prompts over IO, every value validated before it is
  # accepted (the token is checked against getMe, ids must be numeric, the
  # h2code binary must resolve). Existing config values are offered as
  # defaults, so re-running the wizard edits rather than rewrites blind.
  #
  # Output is ANSI-styled — banner, numbered step headings, ✓/✗ markers and
  # an aligned summary — but only when stdout is a terminal; pipes and specs
  # get the same layout without escape codes.
  #
  # Network touchpoints are injected as procs so specs can drive the whole
  # flow over IO::Memory without Telegram.
  class Wizard
    # Total width the banner and step rules are padded to.
    WIDTH = 54

    def initialize(@input : IO,
                   @output : IO,
                   @token_checker : Proc(String, String),
                   @id_learner : Proc(String, Int64),
                   @config_path : String,
                   @cwd : String = Dir.current,
                   color : Bool? = nil)
      @color = color.nil? ? @output.tty? : color
    end

    # Real-network wiring: validate the token via getMe, learn the caller's
    # id by long-polling until their first message arrives.
    def self.interactive(config_path : String = Config.path,
                         input : IO = STDIN,
                         output : IO = STDOUT) : Wizard
      token_checker = ->(token : String) do
        me = Api.new(token).get_me
        me["username"]?.try(&.to_s) || me["id"].to_s
      end
      id_learner = ->(token : String) do
        api = Api.new(token)
        offset = 0_i64
        loop do
          api.get_updates(offset).each do |u|
            uid = u["update_id"]?.to_s.to_i64?
            offset = (uid || offset) + 1
            from = u["message"]?.try(&.["from"]?).try(&.["id"]?)
            id = from.try(&.to_s).try(&.to_i64?)
            if id
              # Confirm everything consumed so the daemon doesn't replay the
              # pairing message from the unconfirmed backlog on startup.
              api.get_updates(offset, timeout: 0)
              return id
            end
          end
        end
      end
      new(input, output, token_checker, id_learner, config_path)
    end

    # EOF on the input (Ctrl-D, closed pipe) aborts the wizard instead of
    # looping on prompts forever.
    class Aborted < Exception
    end

    # Runs the whole flow; returns true when the user asked to start the
    # bot right away.
    def run : Bool
      existing = Config.load(@config_path)
      banner

      token, bot_name = ask_token(existing)
      allowed = ask_allowlist(existing, token)
      dirs = ask_dirs(existing)
      bin = ask_bin(existing)

      print_summary(bot_name, token, allowed, dirs, bin)
      return false unless confirm("save this config?", default: true)

      Dir.mkdir_p(File.dirname(@config_path))
      File.write(@config_path, build_json(token, allowed, dirs, bin))
      ok("written to #{@config_path}")
      confirm("start the bot now?", default: false)
    end

    # --- Steps ---

    # Token is required; validated against getMe so a typo never survives
    # to runtime. Existing valid token is kept on empty input.
    def ask_token(existing : Config) : {String, String}
      heading("1/4 · token")
      loop do
        token = ask("bot token from @BotFather", existing.token)
        begin
          bot_name = @token_checker.call(token)
          ok("token works — bot @#{bot_name}")
          return {token, bot_name}
        rescue ex
          err("token rejected: #{ex.message}",
            "get a token from @BotFather (/newbot) and paste it here")
        end
      end
    end

    def ask_allowlist(existing : Config, token : String) : Array(Int64)
      heading("2/4 · allowlist")
      @output.puts "  who may use the bot? the allowlist is #{paint("REQUIRED", :yellow)} —"
      @output.puts "  an open bot would run agent sessions for anyone who finds it"
      @output.puts "    #{paint("1", :cyan)}) enter ids manually (@userinfobot shows your numeric id)"
      @output.puts "    #{paint("2", :cyan)}) learn my id from my first message to the bot"
      loop do
        choice = ask("choice", "2")
        case choice
        when "1"
          ids = loop do
            parsed = parse_ids(ask("ids (comma or space separated)", ""))
            break parsed if parsed && !parsed.empty?
            err("ids must be numbers (no @names — @userinfobot shows the number)")
          end
          return ids
        when "2"
          @output.puts "  #{paint("…", :yellow)} waiting — open Telegram and send any message to the bot"
          id = @id_learner.call(token)
          ok("your id: #{id}")
          return [id] if confirm("add it to the allowlist?", default: true)
        else
          err("enter 1 or 2")
        end
      end
    end

    def ask_dirs(existing : Config) : Array(String)
      heading("3/4 · directories")
      default = existing.dirs.empty? ? @cwd : existing.dirs.join(", ")
      loop do
        raw = ask("directories for /new (comma separated)", default)
        dirs = parse_dirs(raw)
        if dirs.nil?
          err("relative paths are not allowed here — use absolute paths")
          next
        end
        return dirs
      end
    end

    def ask_bin(existing : Config) : String
      heading("4/4 · h2code binary")
      default = existing.h2code_bin.empty? ? "h2code" : existing.h2code_bin
      loop do
        bin = ask("h2code binary", default)
        resolved = resolve_bin(bin)
        if resolved
          ok("found: #{resolved}") unless resolved == bin
          return bin
        end
        err("not found on PATH or disk: #{bin}", "absolute path is safest for systemd")
      end
    end

    # --- Pure helpers ---

    def parse_ids(raw : String) : Array(Int64)?
      parts = raw.split(/[\s,]+/).reject(&.empty?)
      return [] of Int64 if parts.empty?
      ids = parts.map(&.to_i64?)
      ids.all? ? ids.map(&.not_nil!) : nil
    end

    # Only absolute paths: the daemon may run from anywhere (systemd /),
    # so a relative dir would silently mean something else at runtime.
    def parse_dirs(raw : String) : Array(String)?
      parts = raw.split(/[\s,]+/).reject(&.empty?)
      return [] of String if parts.empty?
      return nil unless parts.all?(&.starts_with?('/'))
      parts.map { |p| File.expand_path(p.rstrip('/')) }
    end

    def resolve_bin(bin : String) : String?
      return bin if bin.includes?('/') && File::Info.executable?(bin)
      return bin if File::Info.executable?(bin)
      # PATH separator is ':' on Unix (and Windows targets are out of scope
      # for the daemon — it runs on the user's Linux/macOS server).
      (ENV["PATH"]?.try(&.split(':')) || [] of String).each do |dir|
        next if dir.empty?
        candidate = File.join(dir, bin)
        return candidate if File::Info.executable?(candidate)
      end
      nil
    end

    def build_json(token : String, allowed : Array(Int64), dirs : Array(String),
                   bin : String) : String
      JSON.build(indent: "  ") do |j|
        j.object do
          j.field "token", token
          j.field "allowed_user_ids" do
            j.array { allowed.each { |id| j.number id } }
          end
          j.field "dirs" do
            j.array { dirs.each { |d| j.string d } }
          end
          j.field "h2code_bin", bin
        end
      end
    end

    def mask(token : String) : String
      return token if token.size <= 10
      "#{token[0, 6]}…#{token[-4, 4]}"
    end

    # --- Prompt primitives ---

    def ask(prompt : String, default : String = "") : String
      loop do
        @output << "  " << paint("❯ ", :cyan)
        @output << prompt
        @output << " " << dim("[#{default}]") unless default.empty?
        @output << ": "
        @output.flush
        line = @input.gets
        raise Aborted.new("input closed") if line.nil?
        value = line.strip
        return default if value.empty? && !default.empty?
        return value unless value.empty?
        err("a value is required")
      end
    end

    def confirm(prompt : String, default : Bool) : Bool
      suffix = default ? "[Y/n]" : "[y/N]"
      @output << "  " << paint("❯ ", :cyan) << prompt << " " << dim(suffix) << ": "
      @output.flush
      line = @input.gets
      raise Aborted.new("input closed") if line.nil?
      value = line.strip.downcase
      return default if value.empty?
      value.in?("y", "yes", "д", "да", "1", "true")
    end

    # --- Styling helpers ---

    private def paint(text : String, fore : Colorize::Color, bold : Bool = false) : String
      painter = text.colorize.fore(fore)
      painter = painter.bold if bold
      painter.toggle(@color).to_s
    end

    private def dim(text : String) : String
      text.colorize.fore(:dark_gray).toggle(@color).to_s
    end

    private def ok(text : String) : Nil
      @output.puts "  #{paint("✓", :green)} #{text}"
    end

    private def err(text : String, hint : String? = nil) : Nil
      @output.puts "  #{paint("✗", :red)} #{text}"
      @output.puts "    #{dim(hint)}" if hint
    end

    private def banner : Nil
      title = "h2code Telegram bot · setup"
      pad = WIDTH - 2 - title.size
      left = pad // 2
      right = pad - left
      @output.puts paint("╭#{"─" * (WIDTH - 2)}╮", :cyan)
      @output.puts "#{paint("│", :cyan)}#{" " * left}#{paint(title, :white, bold: true)}#{" " * right}#{paint("│", :cyan)}"
      @output.puts paint("╰#{"─" * (WIDTH - 2)}╯", :cyan)
      @output.puts
      @output.puts "  #{dim("config:")} #{@config_path}"
      @output.puts "  #{dim("Enter keeps the [default]")}"
    end

    private def heading(text : String) : Nil
      lead = "── #{text} "
      fill = "─" * {WIDTH - lead.size, 3}.max
      @output.puts
      @output.puts "  #{paint(lead, :cyan)}#{dim(fill)}"
    end

    private def print_summary(bot_name : String, token : String, allowed : Array(Int64),
                              dirs : Array(String), bin : String) : Nil
      heading("summary")
      rows = {
        "bot"        => "@#{bot_name}",
        "token"      => mask(token),
        "allowlist"  => allowed.join(", "),
        "dirs"       => dirs.empty? ? "(cwd)" : dirs.join(", "),
        "h2code_bin" => bin,
        "file"       => @config_path,
      }
      label_width = rows.keys.max_of(&.size)
      rows.each do |label, value|
        @output.puts "  #{paint(label.ljust(label_width), :cyan)}  #{value}"
      end
    end
  end
end
