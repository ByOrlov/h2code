require "../spec_helper"

def setup_iservice
  H2code::Tools::InteractiveShell.service = H2code::Tools::InteractiveShellService.new
end

def is_tool
  H2code::Tools::InteractiveShellTool.new
end

# Read from a session until `pattern` appears in the accumulated output or
# `timeout_s` elapses (interactive programs answer asynchronously).
def read_until(session : H2code::Tools::ShellSession, pattern : String, timeout_s : Int32 = 10) : String
  deadline = Time.monotonic + timeout_s.seconds
  accumulated = ""
  while Time.monotonic < deadline
    accumulated += session.read_new_output(200)
    return accumulated if accumulated.includes?(pattern)
  end
  accumulated
end

describe H2code::Tools::InteractiveShellTool do
  it "uses the canonical tool name" do
    is_tool.name.should eq(H2code::Tools::Names::INTERACTIVE_SHELL)
    is_tool.name.should eq("InteractiveShell")
  end

  it "rejects an unknown action" do
    setup_iservice
    result = is_tool.execute(JSON.parse(%({"action":"explode"})))
    result.is_error?.should be_true
    result.content.should contain("Unknown action")
  end

  it "round-trips input through cat and observes EOF exit" do
    setup_iservice
    result = is_tool.execute(JSON.parse(%({"action":"start","command":"cat"})))
    result.is_error?.should be_false
    session_id = result.content[/session_id: (\S+)/, 1]
    session_id.should_not be_nil

    result = is_tool.execute(JSON.parse(%({"action":"write","session_id":"#{session_id}","data":"hello\\n"})))
    result.is_error?.should be_false
    result.content.should contain("wrote")

    session = H2code::Tools::InteractiveShell.service.not_nil!.get(session_id).not_nil!
    read_until(session, "hello").should contain("hello")

    result = is_tool.execute(JSON.parse(%({"action":"close_input","session_id":"#{session_id}"})))
    result.is_error?.should be_false

    read_until(session, "exited with code 0")
    session.alive?.should be_false

    result = is_tool.execute(JSON.parse(%({"action":"kill","session_id":"#{session_id}"})))
    result.is_error?.should be_false
  end

  it "reports sessions via list and rejects unknown ids" do
    setup_iservice
    is_tool.execute(JSON.parse(%({"action":"start","command":"sleep 30"})))
    result = is_tool.execute(JSON.parse(%({"action":"list"})))
    result.is_error?.should be_false
    result.content.should contain("shell-1")
    result.content.should contain("sleep 30")

    result = is_tool.execute(JSON.parse(%({"action":"write","session_id":"shell-999","data":"x"})))
    result.is_error?.should be_true
    result.content.should contain("Session not found")

    H2code::Tools::InteractiveShell.service.not_nil!.stop_all
  end
end

# Integration: a real Python REPL — hello world, arithmetic, state carried
# across writes (the whole point of an interactive session).
describe "InteractiveShell python3 integration" do
  python_available = begin
    Process.run("python3", ["--version"],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
    true
  rescue
    false
  end

  {% if flag?(:unix) %}
    it "holds a python3 REPL dialogue" do
      pending! "python3 not available" unless python_available
      setup_iservice

      result = is_tool.execute(JSON.parse(%({"action":"start","command":"python3 -i"})))
      result.is_error?.should be_false
      session_id = result.content[/session_id: (\S+)/, 1]
      session = H2code::Tools::InteractiveShell.service.not_nil!.get(session_id).not_nil!

      # Wait for the banner so the REPL is really accepting input.
      read_until(session, ">>>").should contain(">>>")

      # hello world
      session.write("print('hello world')\n")
      read_until(session, "hello world").should contain("hello world")

      # 2+2
      session.write("2+2\n")
      read_until(session, "4").should contain("4")

      # State must persist across writes: bind a variable, then use it.
      session.write("answer = 6 * 7\n")
      read_until(session, ">>>")
      session.write("answer\n")
      read_until(session, "42").should contain("42")

      session.kill
      read_until(session, "exited")
      session.alive?.should be_false
    end
  {% end %}
end
