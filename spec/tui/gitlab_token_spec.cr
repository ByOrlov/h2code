require "../spec_helper"
require "file_utils"
require "../../src/tui/app"

# Private handlers are reachable from a subclass — this spec-only wrapper
# drives /gitlab the same way the slash dispatcher does.
class GitlabApp < H2code::TUI::App
  def run_cmd_gitlab(args : String)
    cmd_gitlab(args)
  end

  def run_submit_gitlab_token(text : String)
    submit_gitlab_token(text)
  end

  def run_cancel_gitlab_token_wizard
    cancel_gitlab_token_wizard
  end
end

describe "GitLab token wizard" do
  it "/gitlab token collects the token via the input flow and saves it to config" do
    with_tmpdir do |dir|
      ENV["H2CODE_HOME"] = dir
      begin
        app = GitlabApp.new
        cfg = H2code::Config::Config.new
        app.app_config = cfg

        app.run_cmd_gitlab("token")
        app.gitlab_token_mode?.should be_true
        app.@messages.any? { |m| m.role == "system" && m.content.includes?("personal access token") }.should be_true

        app.run_submit_gitlab_token("glpat_testtoken123")
        app.gitlab_token_mode?.should be_false
        cfg.gitlab_token.should eq("glpat_testtoken123")

        # Persisted to disk in H2CODE_HOME, not the real config.
        config_path = File.join(dir, "config.json")
        File.exists?(config_path).should be_true
        File.read(config_path).should contain("glpat_testtoken123")

        # The transcript only ever shows a mask, never the raw token.
        joined = app.@messages.map(&.content).join('\n')
        joined.should contain("•")
        joined.should_not contain("glpat_testtoken123")

        # The saved message is reported.
        app.@messages.any? { |m| m.role == "system" && m.content.includes?("GitLab") }.should be_true
      ensure
        ENV.delete("H2CODE_HOME")
      end
    end
  end

  it "Escape cancels the wizard without saving" do
    app = GitlabApp.new
    app.app_config = H2code::Config::Config.new

    app.run_cmd_gitlab("token")
    app.gitlab_token_mode?.should be_true

    app.run_cancel_gitlab_token_wizard
    app.gitlab_token_mode?.should be_false
    (app.app_config.try(&.gitlab_token) || "").should be_empty
    app.@messages.any? { |m| m.role == "system" && m.content.includes?("cancelled") }.should be_true
  end

  it "/gitlab token clear removes the saved token" do
    with_tmpdir do |dir|
      ENV["H2CODE_HOME"] = dir
      begin
        app = GitlabApp.new
        cfg = H2code::Config::Config.new
        cfg.gitlab_token = "glpat_old"
        app.app_config = cfg

        app.run_cmd_gitlab("token clear")
        cfg.gitlab_token.should be_empty
        File.read(File.join(dir, "config.json")).should_not contain("glpat_old")
      ensure
        ENV.delete("H2CODE_HOME")
      end
    end
  end

  it "/gitlab status reports the token state without exposing it" do
    app = GitlabApp.new
    cfg = H2code::Config::Config.new
    app.app_config = cfg

    app.run_cmd_gitlab("")
    app.@messages.any? { |m| m.role == "system" && m.content.includes?("not set") }.should be_true

    cfg.gitlab_token = "glpat_secretvalue"
    app.run_cmd_gitlab("status")
    status = app.@messages.reverse_each.find { |m| m.role == "system" }
    status.should_not be_nil
    (status || raise "status should not be nil").content.should contain("glp")
    status.content.should_not contain("glpat_secretvalue")
  end
end
