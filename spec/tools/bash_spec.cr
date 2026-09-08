require "../spec_helper"

describe H2code::Tools::Bash do
  it "exposes command, cwd, timeout, and description in the schema" do
    bash = H2code::Tools::Bash.new("/tmp")
    bash.name.should eq(H2code::Tools::Names::BASH)

    props = bash.parameters["properties"].as_h
    props.has_key?("command").should be_true
    props.has_key?("cwd").should be_true
    props.has_key?("timeout").should be_true
    props.has_key?("description").should be_true
    bash.parameters["properties"]["timeout"]["default"].as_i.should eq(60)
    bash.parameters["required"].as_a.map(&.to_s).should contain("command")
  end

  it "describes cwd, timeout cap, and the kill-on-timeout behavior" do
    bash = H2code::Tools::Bash.new("/tmp")
    bash.description.should contain("cwd")
    bash.description.should contain("absolute paths")
    bash.description.should contain("hits its timeout is killed")
    # Background is now a real feature; the description documents it.
    bash.description.should contain("run_in_background: true")
  end

  it "runs a command and returns stdout" do
    bash = H2code::Tools::Bash.new("/tmp")
    result = bash.execute(JSON.parse(%({"command":"printf hello"})))
    result.is_error?.should be_false
    result.content.should contain("hello")
  end

  it "combines stdout and stderr" do
    bash = H2code::Tools::Bash.new("/tmp")
    result = bash.execute(JSON.parse(%({"command":"printf out; printf err 1>&2"})))
    result.content.should contain("out")
    result.content.should contain("err")
  end

  it "honors the cwd argument" do
    Dir.mkdir_p("/tmp/h2code-bash-cwd")
    bash = H2code::Tools::Bash.new("/tmp")
    result = bash.execute(JSON.parse(%({"command":"pwd","cwd":"/tmp/h2code-bash-cwd"})))
    result.is_error?.should be_false
    result.content.should contain("/tmp/h2code-bash-cwd")
  end

  it "marks non-zero exit codes as errors with an [exit code: N] trailer" do
    bash = H2code::Tools::Bash.new("/tmp")
    result = bash.execute(JSON.parse(%({"command":"exit 2"})))
    result.is_error?.should be_true
    result.content.should contain("[exit code: 2]")
  end

  it "injects noninteractive env (NO_COLOR, TERM, GIT_TERMINAL_PROMPT)" do
    prev = ENV["GIT_TERMINAL_PROMPT"]?
    ENV.delete("GIT_TERMINAL_PROMPT")
    begin
      bash = H2code::Tools::Bash.new("/tmp")
      result = bash.execute(JSON.parse(%({"command":"printenv NO_COLOR; printenv TERM; printenv GIT_TERMINAL_PROMPT"})))
      lines = result.content.strip.split('\n')
      lines.should contain("1")    # NO_COLOR=1
      lines.should contain("dumb") # TERM=dumb
      lines.should contain("0")    # GIT_TERMINAL_PROMPT=0 (hardened default)
    ensure
      ENV["GIT_TERMINAL_PROMPT"] = prev if prev
    end
  end

  it "honors an ambient GIT_TERMINAL_PROMPT instead of forcing 0" do
    prev = H2code::Tools::Bash.git_terminal_prompt
    H2code::Tools::Bash.git_terminal_prompt = "1"
    begin
      bash = H2code::Tools::Bash.new("/tmp")
      result = bash.execute(JSON.parse(%({"command":"printenv GIT_TERMINAL_PROMPT"})))
      result.content.strip.should eq("1")
    ensure
      H2code::Tools::Bash.git_terminal_prompt = prev
    end
  end

  it "closes stdin so an interactive command sees EOF instead of hanging" do
    bash = H2code::Tools::Bash.new("/tmp")
    # `cat` with no input reads stdin; if stdin stayed open it would hang.
    result = bash.execute(JSON.parse(%({"command":"cat"})))
    result.is_error?.should be_false
    result.content.strip.should eq("")
  end

  it "clamps an over-limit timeout to MAX_TIMEOUT_S" do
    bash = H2code::Tools::Bash.new("/tmp")
    result = bash.execute(JSON.parse(%({"command":"true","timeout":99999})))
    result.is_error?.should be_false
  end

  it "kills a command that exceeds its timeout" do
    bash = H2code::Tools::Bash.new("/tmp")
    result = bash.execute(JSON.parse(%({"command":"sleep 30","timeout":1})))
    result.is_error?.should be_true
    result.content.should contain("timed out after 1s")
  end

  it "kills its subprocess promptly when the abort check fires" do
    bash = H2code::Tools::Bash.new("/tmp")
    # Always-aborted: the wait_for_exit poll fires within ~100ms, then the
    # process is SIGTERM/SIGKILL'd. Previously the bare select left the child
    # running for the full Loop.execute_tool grace period.
    bash.abort_check = -> { true }

    started = Time.monotonic
    result = bash.execute(JSON.parse(%({"command":"sleep 30","timeout":60})))
    elapsed = Time.monotonic - started

    result.is_error?.should be_true
    result.content.should contain("interrupted by user")
    # Kill ladder (poll + SIGTERM + SIGKILL grace) should be well under the
    # 30s sleep — assert a generous ceiling that still catches a regression.
    (elapsed < 5.seconds).should be_true
  end

  it "rejects an empty command" do
    bash = H2code::Tools::Bash.new("/tmp")
    result = bash.execute(JSON.parse(%({"command":""})))
    result.is_error?.should be_true
    result.content.should contain("empty")
  end

  it "rejects run_in_background=true when no task service is wired" do
    bash = H2code::Tools::Bash.new("/tmp")
    result = bash.execute(JSON.parse(%({"command":"sleep 10","run_in_background":true})))
    result.is_error?.should be_true
    result.content.should contain("Background execution is not available")
  end

  it "rejects run_in_background=true without a description" do
    task_svc = H2code::Tools::InMemoryTaskService.new
    bash = H2code::Tools::Bash.new("/tmp", task_svc, "/tmp")
    result = bash.execute(JSON.parse(%({"command":"sleep 10","run_in_background":true})))
    result.is_error?.should be_true
    result.content.should contain("description is required when run_in_background is true.")
  end

  it "rejects run_in_background=true with a blank description" do
    task_svc = H2code::Tools::InMemoryTaskService.new
    bash = H2code::Tools::Bash.new("/tmp", task_svc, "/tmp")
    result = bash.execute(JSON.parse(%({"command":"sleep 10","run_in_background":true,"description":"   "})))
    result.is_error?.should be_true
    result.content.should contain("description is required when run_in_background is true.")
  end

  it "moves a timed-out foreground command to the background" do
    Dir.tempdir.tap do |tmp|
      session_dir = File.join(tmp, "bg-detach-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(session_dir)
      task_svc = H2code::Tools::InMemoryTaskService.new
      bash = H2code::Tools::Bash.new("/tmp", task_svc, session_dir)

      result = bash.execute(JSON.parse(%({"command":"sleep 2 && echo detached-done","timeout":1})))
      result.is_error?.should be_false
      result.content.should contain("timed out after 1s and was moved to the background")
      result.content.should contain("task_id:")
      task_id = result.content.match(/task_id: (\S+)/).try(&.[1]) || raise "task_id not found"

      # The task is registered and running.
      info = task_svc.get_task(task_id) || raise "task not found"
      info.status.running?.should be_true

      # The process finishes on its own (~2s); poll for the terminal state.
      40.times do
        info = task_svc.get_task(task_id).not_nil!
        break if info.status.terminal?
        sleep 0.1.seconds
      end
      info = task_svc.get_task(task_id).not_nil!
      info.status.completed?.should be_true

      # Post-detach output landed in the task's log file.
      output_path = File.join(session_dir, "tasks", "#{task_id}.log")
      File.exists?(output_path).should be_true
      File.read(output_path).should contain("detached-done")
    end
  end

  it "still kills a timed-out command when auto-background is disabled" do
    session_dir = File.join(Dir.tempdir, "bg-nodetach-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(session_dir)
    task_svc = H2code::Tools::InMemoryTaskService.new
    bash = H2code::Tools::Bash.new("/tmp", task_svc, session_dir, nil, false)

    result = bash.execute(JSON.parse(%({"command":"sleep 30","timeout":1})))
    result.is_error?.should be_true
    result.content.should contain("timed out after 1s and was killed")
  end

  it "runs a quick foreground command normally when a task service is wired" do
    task_svc = H2code::Tools::InMemoryTaskService.new
    bash = H2code::Tools::Bash.new("/tmp", task_svc, "/tmp")
    result = bash.execute(JSON.parse(%({"command":"printf detach-ok"})))
    result.is_error?.should be_false
    result.content.should contain("detach-ok")
  end

  it "truncates runaway output with a [...truncated] sentinel" do
    bash = H2code::Tools::Bash.new("/tmp")
    # Generate well over the 10 MB in-tool cap.
    result = bash.execute(JSON.parse(%({"command":"yes x | head -c 12000000"})))
    result.content.should contain("[...truncated]")
    result.content.should contain("Output is truncated")
  end
end

describe H2code::Tools::Bash do
  it "runs a background command and captures output" do
    Dir.tempdir.tap do |tmp|
      session_dir = File.join(tmp, "bg-test-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(session_dir)
      task_svc = H2code::Tools::InMemoryTaskService.new
      bash = H2code::Tools::Bash.new("/tmp", task_svc, session_dir)

      result = bash.execute(JSON.parse(%({"command":"echo hello-bg","run_in_background":true,"description":"test bg"})))
      result.is_error?.should be_false
      result.content.should contain("Background task started.")
      result.content.should contain("task_id:")

      # Extract task_id.
      task_id = result.content.match(/task_id: (\S+)/).try(&.[1]) || raise "task_id not found"

      # Wait for the process to finish (should be near-instant for echo).
      task_svc.wait(task_id, 5_000_i64)
      info = task_svc.get_task(task_id) || raise "task not found"
      info.status.completed?.should be_true

      # The output file should contain the echo output.
      output_path = File.join(session_dir, "tasks", "#{task_id}.log")
      File.exists?(output_path).should be_true
      File.read(output_path).should contain("hello-bg")
    end
  end

  it "delivers a completion notification for a background task" do
    Dir.tempdir.tap do |tmp|
      session_dir = File.join(tmp, "bg-notify-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(session_dir)
      task_svc = H2code::Tools::InMemoryTaskService.new
      delivered = [] of String
      delivery = ->(xml : String) { delivered << xml; nil }
      bash = H2code::Tools::Bash.new("/tmp", task_svc, session_dir, delivery)

      result = bash.execute(JSON.parse(%({"command":"echo done","run_in_background":true,"description":"test bg"})))
      task_id = result.content.match(/task_id: (\S+)/).try(&.[1]) || raise "task_id not found"

      # Wait for the monitor fiber to finish.
      task_svc.wait(task_id, 5_000_i64)
      # Give the delivery fiber a chance to run.
      10.times do
        break unless delivered.empty?
        sleep 0.1.seconds
      end

      delivered.empty?.should be_false
      xml = delivered.first
      xml.should contain("<notification")
      xml.should contain(%(source_id="#{task_id}"))
      xml.should contain("Background process completed")
    end
  end

  it "stops a running background process via TaskStop" do
    Dir.tempdir.tap do |tmp|
      session_dir = File.join(tmp, "bg-stop-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(session_dir)
      task_svc = H2code::Tools::InMemoryTaskService.new
      bash = H2code::Tools::Bash.new("/tmp", task_svc, session_dir)

      result = bash.execute(JSON.parse(%({"command":"sleep 100","run_in_background":true,"description":"test bg"})))
      task_id = result.content.match(/task_id: (\S+)/).try(&.[1]) || raise "task_id not found"

      # The process should be running.
      info = task_svc.get_task(task_id) || raise "task not found"
      info.status.running?.should be_true

      # Stop it.
      task_svc.suppress_terminal_notification(task_id)
      stopped = task_svc.stop(task_id, "test stop")
      stopped.should_not be_nil
      stopped.try(&.status.terminal?).should be_true
    end
  end

  describe "per-instance sudo state" do
    it "defaults sudo_mode to Off" do
      bash = H2code::Tools::Bash.new("/tmp")
      bash.sudo_mode.should eq(H2code::Tools::Bash::SudoMode::Off)
    end

    it "isolates sudo_mode between instances (subagents don't inherit parent)" do
      parent = H2code::Tools::Bash.new("/tmp")
      parent.sudo_mode = H2code::Tools::Bash::SudoMode::Always

      child = H2code::Tools::Bash.new("/tmp")
      child.sudo_mode.should eq(H2code::Tools::Bash::SudoMode::Off)
    end

    it "starts new instances from the app-wide default_sudo_mode" do
      prev = H2code::Tools::Bash.default_sudo_mode
      begin
        H2code::Tools::Bash.default_sudo_mode = H2code::Tools::Bash::SudoMode::Request
        H2code::Tools::Bash.new("/tmp").sudo_mode.should eq(H2code::Tools::Bash::SudoMode::Request)
        # Runtime changes on one instance do not leak into the default.
        parent = H2code::Tools::Bash.new("/tmp")
        parent.sudo_mode = H2code::Tools::Bash::SudoMode::Always
        H2code::Tools::Bash.new("/tmp").sudo_mode.should eq(H2code::Tools::Bash::SudoMode::Request)
      ensure
        H2code::Tools::Bash.default_sudo_mode = prev
      end
    end

    it "holds terminal_exec and sudo_approval per instance" do
      a = H2code::Tools::Bash.new("/tmp")
      b = H2code::Tools::Bash.new("/tmp")

      a.terminal_exec.should be_nil
      a.sudo_approval.should be_nil
      b.terminal_exec.should be_nil

      a.sudo_approval = ->(_cmd : String) { H2code::Tools::Bash::SudoApprovalChoice::Deny }
      a.sudo_approval.should_not be_nil
      b.sudo_approval.should be_nil
    end
  end

  describe "background-parameter schema" do
    it "omits run_in_background when no TaskService is wired" do
      bash = H2code::Tools::Bash.new("/tmp")
      props = bash.parameters["properties"].as_h
      props.has_key?("run_in_background").should be_false
      props.has_key?("disable_timeout").should be_false
    end

    it "advertises run_in_background when a TaskService is wired" do
      task_svc = H2code::Tools::InMemoryTaskService.new
      bash = H2code::Tools::Bash.new("/tmp", task_svc, "/tmp")
      props = bash.parameters["properties"].as_h
      props.has_key?("run_in_background").should be_true
      props.has_key?("disable_timeout").should be_true
    end
  end
end
