require "../spec_helper"

def setup_iservice
  H2code::Tools::InteractiveShell.service = H2code::Tools::InteractiveShellService.new
end

def new_tool
  H2code::Tools::InteractiveShellTool.new
end

# Run a diagnostic probe with a hard deadline (never hangs the suite); returns
# its exit status and captured output, or a timeout marker.
def probe(cmd : String, args : Array(String), timeout_s = 15) : String
  proc = Process.new(cmd, args, input: Process::Redirect::Close,
    output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
  deadline = Time.monotonic + timeout_s.seconds
  until proc.terminated? || Time.monotonic >= deadline
    sleep 50.milliseconds
  end
  unless proc.terminated?
    proc.terminate(graceful: false) rescue nil
    return "TIMED OUT after #{timeout_s}s (pid #{proc.pid})"
  end
  # Capture before `wait`: reaping closes the pipe IOs, after which reads
  # come back empty.
  out = (proc.output.gets_to_end rescue "")
  err = (proc.error.gets_to_end rescue "")
  status = proc.wait
  "exit=#{status.exit_status} out=#{out.inspect} err=#{err.inspect}"
rescue ex
  "raised #{ex.class}: #{ex.message}"
end

# Read from a session until `pattern` appears in the accumulated output or
# `timeout_s` elapses (interactive programs answer asynchronously). Returns
# early when the session dies — a dead session produces nothing more.
def read_until(session : H2code::Tools::ShellSession, pattern : String, timeout_s : Int32 = 10) : String
  deadline = Time.monotonic + timeout_s.seconds
  accumulated = ""
  while Time.monotonic < deadline
    accumulated += session.read_new_output(200)
    return accumulated if accumulated.includes?(pattern)
    unless session.alive?
      # Drain the exit message the watcher may have appended after the last
      # read so the failure output explains itself.
      return accumulated + session.read_new_output(100)
    end
  end
  accumulated
end

describe H2code::Tools::InteractiveShellTool do
  it "uses the canonical tool name" do
    new_tool.name.should eq(H2code::Tools::Names::INTERACTIVE_SHELL)
    new_tool.name.should eq("InteractiveShell")
  end

  it "rejects an unknown action" do
    setup_iservice
    result = new_tool.execute(JSON.parse(%({"action":"explode"})))
    result.is_error?.should be_true
    result.content.should contain("Unknown action")
  end

  it "round-trips input through cat and observes EOF exit" do
    setup_iservice
    result = new_tool.execute(JSON.parse(%({"action":"start","command":"cat"})))
    result.is_error?.should be_false
    session_id = result.content[/session_id: (\S+)/, 1]
    session_id.should_not be_nil

    result = new_tool.execute(JSON.parse(%({"action":"write","session_id":"#{session_id}","data":"hello\\n"})))
    result.is_error?.should be_false
    result.content.should contain("wrote")

    session = H2code::Tools::InteractiveShell.service.not_nil!.get(session_id).not_nil!
    read_until(session, "hello").should contain("hello")

    result = new_tool.execute(JSON.parse(%({"action":"close_input","session_id":"#{session_id}"})))
    result.is_error?.should be_false

    read_until(session, "exited with code 0")
    session.alive?.should be_false

    result = new_tool.execute(JSON.parse(%({"action":"kill","session_id":"#{session_id}"})))
    result.is_error?.should be_false
  end

  it "reports sessions via list and rejects unknown ids" do
    setup_iservice
    new_tool.execute(JSON.parse(%({"action":"start","command":"sleep 30"})))
    result = new_tool.execute(JSON.parse(%({"action":"list"})))
    result.is_error?.should be_false
    result.content.should contain("shell-1")
    result.content.should contain("sleep 30")

    result = new_tool.execute(JSON.parse(%({"action":"write","session_id":"shell-999","data":"x"})))
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

      result = new_tool.execute(JSON.parse(%({"action":"start","command":"python3 -i"})))
      result.is_error?.should be_false
      session_id = result.content[/session_id: (\S+)/, 1]
      session = H2code::Tools::InteractiveShell.service.not_nil!.get(session_id).not_nil!

      # Wait for the banner so the REPL is really accepting input. Generous
      # 30s budget: on a stalled/loaded CI runner the banner can take well
      # over the usual ~100ms; everything downstream hangs off this wait.
      banner = read_until(session, ">>>", 30)
      unless banner.includes?(">>>")
        py_probe = probe("python3", ["-c", "import sys; print('probe-ok', sys.version.split()[0])"])
        env_probe = probe("/bin/bash", ["-c", "command -v python3; python3 --version 2>&1; echo PATH=$PATH"])
        fail("python3 REPL never printed a prompt. " \
             "banner=#{banner.inspect} alive=#{session.alive?} exit=#{session.exit_message.inspect} " \
             "py_probe=[#{py_probe}] env_probe=[#{env_probe}]")
      end

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
