require "../spec_helper"
require "file_utils"
require "../../src/tui/app"

# Private handlers are reachable from a subclass — this spec-only wrapper
# drives /set the same way the slash dispatcher does.
class SetCommandApp < H2code::TUI::App
  def run_cmd_set(args : String)
    cmd_set(args)
  end
end

describe "/set command" do
  it "lists the schema keys with current values and types" do
    app = SetCommandApp.new
    app.app_config = H2code::Config::Config.new

    app.run_cmd_set("")
    msg = app.@messages.last
    msg.role.should eq("system")
    msg.content.should contain("gitlab.endpoint")
    msg.content.should contain("permission.mode")
    msg.content.should contain("manual|auto|yolo")
    msg.content.should contain("model.default = ()")
  end

  it "shows a single setting and masks secrets" do
    app = SetCommandApp.new
    cfg = H2code::Config::Config.new
    cfg.github_token = "ghp_secret123"
    app.app_config = cfg

    app.run_cmd_set("github.token")
    msg = app.@messages.last
    msg.role.should eq("system")
    msg.content.should contain("ghp_")
    msg.content.should contain("•")
    msg.content.should_not contain("ghp_secret123")
  end

  it "rejects unknown keys with the valid key list" do
    app = SetCommandApp.new
    app.app_config = H2code::Config::Config.new

    app.run_cmd_set("nope.key 1")
    msg = app.@messages.last
    msg.role.should eq("error")
    msg.content.should contain("nope.key")
    msg.content.should contain("gitlab.token")
  end

  it "rejects values that do not match the schema type" do
    app = SetCommandApp.new
    app.app_config = H2code::Config::Config.new

    app.run_cmd_set("agent.max_steps many")
    msg = app.@messages.last
    msg.role.should eq("error")
    msg.content.should contain("many")
    msg.content.should contain("int")

    app.run_cmd_set("permission.mode sideways")
    app.@messages.last.role.should eq("error")
    app.@messages.last.content.should contain("manual|auto|yolo")

    # Nothing was applied.
    app.app_config.not_nil!.permission_mode.should eq("manual")
  end

  it "rejects tokens that do not match the expected format" do
    app = SetCommandApp.new
    app.app_config = H2code::Config::Config.new

    app.run_cmd_set("github.token just-garbage")
    msg = app.@messages.last
    msg.role.should eq("error")
    msg.content.should contain("ghp_")
    # The secret input is never echoed back in plain text.
    msg.content.should_not contain("just-garbage")
    app.app_config.not_nil!.github_token.should be_empty

    app.run_cmd_set("gitlab.token glpat-tooshort")
    app.@messages.last.role.should eq("error")
    app.@messages.last.content.should contain("glpat-")
    app.@messages.last.content.should_not contain("glpat-tooshort")
    app.app_config.not_nil!.gitlab_token.should be_empty
  end

  it "validates, applies and persists a schema-conforming value" do
    with_tmpdir do |dir|
      ENV["H2CODE_HOME"] = dir
      begin
        app = SetCommandApp.new
        cfg = H2code::Config::Config.new
        app.app_config = cfg

        app.run_cmd_set("gitlab.endpoint https://gl.corp.io")
        app.@messages.last.role.should eq("system")
        cfg.gitlab_endpoint.should eq("https://gl.corp.io")
        # Persisted to disk in H2CODE_HOME, not the real config.
        config_path = File.join(dir, "config.json")
        File.exists?(config_path).should be_true
        File.read(config_path).should contain("https://gl.corp.io")

        # The saved config round-trips through load.
        H2code::Config::Config.load(config_path).gitlab_endpoint.should eq("https://gl.corp.io")

        app.run_cmd_set("agent.max_steps 42")
        cfg.max_steps.should eq(42)
        H2code::Config::Config.load(config_path).max_steps.should eq(42)
      ensure
        ENV.delete("H2CODE_HOME")
      end
    end
  end

  it "applies tokens to the live CI service without a reload" do
    with_tmpdir do |dir|
      ENV["H2CODE_HOME"] = dir
      app = SetCommandApp.new
      cfg = H2code::Config::Config.new
      app.app_config = cfg
      old = H2code::Tools::Ci.service
      svc = H2code::Tools::Ci::LiveCiService.new
      H2code::Tools::Ci.service = svc
      begin
        token = "glpat-" + "y" * 20
        app.run_cmd_set("gitlab.token #{token}")
        cfg.gitlab_token.should eq(token)
        svc.gitlab_token.should eq(token)
        # Never echoed back in plain text.
        app.@messages.map(&.content).join.should_not contain(token)
      ensure
        H2code::Tools::Ci.service = old
        ENV.delete("H2CODE_HOME")
      end
    end
  end
end
