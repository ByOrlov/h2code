require "../spec_helper"
require "../../src/tui/app"

# Private handler reachable from a subclass, mirroring set_command_spec.
class RetryCommandApp < H2code::TUI::App
  def run_cmd_retry(args : String)
    cmd_retry(args)
  end
end

describe "/retry command" do
  it "shows the current retry count when called without args" do
    app = RetryCommandApp.new
    app.on_get_max_retries = -> { 7 }

    app.run_cmd_retry("")
    msg = app.@messages.last
    msg.role.should eq("system")
    msg.content.should contain("7")
  end

  it "sets the retry count via the callback" do
    app = RetryCommandApp.new
    set_to = 0
    app.on_get_max_retries = -> { 3 }
    app.on_set_max_retries = ->(n : Int32) { set_to = n; nil }

    app.run_cmd_retry("10")
    msg = app.@messages.last
    msg.role.should eq("system")
    set_to.should eq(10)
  end

  it "rejects non-numeric and out-of-range values" do
    app = RetryCommandApp.new
    app.on_get_max_retries = -> { 3 }
    called = false
    app.on_set_max_retries = ->(_n : Int32) { called = true; nil }

    app.run_cmd_retry("many")
    app.@messages.last.role.should eq("error")

    app.run_cmd_retry("51")
    app.@messages.last.role.should eq("error")
    called.should be_false
  end
end
