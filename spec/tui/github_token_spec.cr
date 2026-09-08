require "../spec_helper"
require "file_utils"
require "../../src/tui/app"

# Private handlers are reachable from a subclass — this spec-only wrapper
# drives /github the same way the slash dispatcher does.
class GithubApp < H2code::TUI::App
  def run_cmd_github(args : String)
    cmd_github(args)
  end

  def run_submit_github_token(text : String)
    submit_github_token(text)
  end

  def run_cancel_github_token_wizard
    cancel_github_token_wizard
  end
end

describe "GitHub token wizard" do
  it "/github token collects the token via the input flow and saves it to config" do
    with_tmpdir do |dir|
      ENV["H2CODE_HOME"] = dir
      begin
        app = GithubApp.new
        cfg = H2code::Config::Config.new
        app.app_config = cfg

        app.run_cmd_github("token")
        app.github_token_mode?.should be_true
        app.@messages.any? { |m| m.role == "system" && m.content.includes?("personal access token") }.should be_true

        app.run_submit_github_token("ghp_testtoken123")
        app.github_token_mode?.should be_false
        cfg.github_token.should eq("ghp_testtoken123")

        # Persisted to disk in H2CODE_HOME, not the real config.
        config_path = File.join(dir, "config.json")
        File.exists?(config_path).should be_true
        File.read(config_path).should contain("ghp_testtoken123")

        # The transcript only ever shows a mask, never the raw token.
        joined = app.@messages.map(&.content).join('\n')
        joined.should contain("•")
        joined.should_not contain("ghp_testtoken123")

        # The saved message is reported.
        app.@messages.any? { |m| m.role == "system" && m.content.includes?("api.github.com") }.should be_true
      ensure
        ENV.delete("H2CODE_HOME")
      end
    end
  end

  it "Escape cancels the wizard without saving" do
    app = GithubApp.new
    app.app_config = H2code::Config::Config.new

    app.run_cmd_github("token")
    app.github_token_mode?.should be_true

    app.run_cancel_github_token_wizard
    app.github_token_mode?.should be_false
    (app.app_config.try(&.github_token) || "").should be_empty
    app.@messages.any? { |m| m.role == "system" && m.content.includes?("cancelled") }.should be_true
  end

  it "/github token clear removes the saved token" do
    with_tmpdir do |dir|
      ENV["H2CODE_HOME"] = dir
      begin
        app = GithubApp.new
        cfg = H2code::Config::Config.new
        cfg.github_token = "ghp_old"
        app.app_config = cfg

        app.run_cmd_github("token clear")
        cfg.github_token.should be_empty
        File.read(File.join(dir, "config.json")).should_not contain("ghp_old")
      ensure
        ENV.delete("H2CODE_HOME")
      end
    end
  end

  it "/github status reports the token state without exposing it" do
    app = GithubApp.new
    cfg = H2code::Config::Config.new
    app.app_config = cfg

    app.run_cmd_github("")
    app.@messages.any? { |m| m.role == "system" && m.content.includes?("not set") }.should be_true

    cfg.github_token = "ghp_secretvalue"
    app.run_cmd_github("status")
    status = app.@messages.reverse_each.find { |m| m.role == "system" }
    status.should_not be_nil
    (status || raise "status should not be nil").content.should contain("ghp_")
    status.content.should_not contain("ghp_secretvalue")
  end
end
