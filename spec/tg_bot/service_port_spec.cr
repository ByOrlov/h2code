require "../spec_helper"
require "../../src/tg_bot/service_port"

describe TgBot::ServicePort do
  {% if flag?(:win32) %}
    # Windows adapter refuses installation; exercised on Windows builds.
  {% else %}
    describe TgBot::UnixServicePort do
      it "renders a user unit pointing ExecStart at the binary" do
        unit = TgBot::UnixServicePort.new.unit("/usr/local/bin/h2code-tg-bot")
        unit.should contain("ExecStart=/usr/local/bin/h2code-tg-bot")
        unit.should contain("[Install]\nWantedBy=default.target")
      end

      it "keeps resident sessions alive across daemon restarts" do
        unit = TgBot::UnixServicePort.new.unit("/usr/bin/h2code-tg-bot")
        # KillMode=process: restarting the daemon must not kill the
        # `h2code --resident` children (plans/telegram_bot.md, «Деплой»).
        unit.should contain("KillMode=process")
        unit.should contain("Restart=always")
      end

      it "places the unit under XDG_CONFIG_HOME when set" do
        port = TgBot::UnixServicePort.new
        default_path = port.unit_path
        default_path.should end_with("systemd/user/h2code-tg-bot.service")

        old = ENV["XDG_CONFIG_HOME"]?
        ENV["XDG_CONFIG_HOME"] = "/tmp/h2code-xdg-spec"
        begin
          port.unit_path.should eq("/tmp/h2code-xdg-spec/systemd/user/h2code-tg-bot.service")
        ensure
          if old
            ENV["XDG_CONFIG_HOME"] = old
          else
            ENV.delete("XDG_CONFIG_HOME")
          end
        end
      end
    end
  {% end %}
end
