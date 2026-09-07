# Integration specs: the Bash tool executed headlessly — no TTY, no user
# approval callbacks, no terminal-exec bridge — exactly how headless agents
# (ACP server, subagents, cron) drive it. Unlike the unit specs these verify
# real system behaviour end-to-end through the resolved ShellPort
# interpreter, so commands must be valid for the platform shell: use
# `cmd(posix_variant, powershell_variant)` to keep them portable across the
# CI matrix (ubuntu / macos / windows).
require "../spec_helper"

def integration_shell
  H2code::Tools::Tool::SHELL_PORT
end

# True when the resolved interpreter speaks POSIX shell syntax (bash or sh).
def posix_shell? : Bool
  {"bash", "sh"}.includes?(integration_shell.name)
end

# Pick the command variant for the resolved interpreter. When the default
# shell is cmd.exe, PowerShell variants are invoked explicitly via
# `powershell -NoProfile -Command "..."` — exactly the pattern the tool's
# guidance teaches the model.
def cmd(posix : String, powershell : String = "") : String
  return posix if posix_shell?
  return posix if powershell.empty?
  integration_shell.name == "powershell" ? powershell : %(powershell -NoProfile -Command "#{powershell}")
end

# A headless Bash instance: default abort check, no sudo approval, no
# terminal-exec, no delivery callback — nothing that could wait on a user.
def headless_bash(work_dir : String)
  H2code::Tools::Bash.new(work_dir)
end

describe "Bash tool, headless integration", tags: "integration" do
  it "runs a command through the resolved system interpreter" do
    with_tmpdir do |dir|
      bash = headless_bash(dir)
      result = bash.execute(JSON.parse(%({"command":"#{cmd("printf hello", "Write-Output hello")}"})))
      result.is_error?.should be_false
      result.content.should contain("hello")
    end
  end

  it "supports pipes in the platform shell" do
    with_tmpdir do |dir|
      bash = headless_bash(dir)
      command = cmd(
        "echo hello | tr a-z A-Z",
        "Write-Output hello | ForEach-Object { $_.ToUpper() }",
      )
      result = bash.execute(JSON.parse(%({"command":"#{command}"})))
      result.is_error?.should be_false
      result.content.should contain("HELLO")
    end
  end

  it "supports sequential execution with ;" do
    with_tmpdir do |dir|
      bash = headless_bash(dir)
      command = cmd(
        "printf one; printf two",
        "Write-Output one; Write-Output two",
      )
      result = bash.execute(JSON.parse(%({"command":"#{command}"})))
      result.is_error?.should be_false
      result.content.should contain("one")
      result.content.should contain("two")
    end
  end

  it "chains dependent commands with && (cmd supports it natively)" do
    with_tmpdir do |dir|
      if posix_shell? || integration_shell.name == "cmd"
        bash = headless_bash(dir)
        result = bash.execute(JSON.parse(%({"command":"true && echo chained"})))
        result.is_error?.should be_false
        result.content.should contain("chained")
      else
        # Windows PowerShell 5.1 has no &&; the tool description steers the
        # model away from it — nothing to verify on this shell.
      end
    end
  end

  it "runs native cmd syntax when cmd.exe is the interpreter" do
    with_tmpdir do |dir|
      if integration_shell.name == "cmd"
        bash = headless_bash(dir)
        result = bash.execute(JSON.parse(%({"command":"echo hello | find \"hello\""})))
        result.is_error?.should be_false
        result.content.should contain("hello")
      end
    end
  end

  it "writes files through the shell in the working directory" do
    with_tmpdir do |dir|
      bash = headless_bash(dir)
      command = cmd(
        "echo shell-write > out.txt",
        "Set-Content out.txt shell-write",
      )
      result = bash.execute(JSON.parse(%({"command":"#{command}"})))
      result.is_error?.should be_false
      File.read(File.join(dir, "out.txt")).should contain("shell-write")
    end
  end

  it "honors cwd" do
    with_tmpdir do |dir|
      target = File.join(dir, "nested")
      Dir.mkdir_p(target)
      bash = headless_bash(dir)
      # Build the payload via Hash#to_json: a Windows cwd contains backslashes
      # (D:\a\...), which are invalid escape sequences when interpolated into
      # a raw JSON literal.
      input = {"command" => cmd("pwd", "Get-Location"), "cwd" => target}.to_json
      result = bash.execute(JSON.parse(input))
      result.is_error?.should be_false
      result.content.should contain("nested")
    end
  end

  it "spawns with the hardened noninteractive environment" do
    with_tmpdir do |dir|
      bash = headless_bash(dir)
      command = cmd(
        "printenv NO_COLOR; printenv TERM",
        "$env:NO_COLOR; $env:TERM",
      )
      result = bash.execute(JSON.parse(%({"command":"#{command}"})))
      result.is_error?.should be_false
      # Windows shells emit CRLF; strip per-line before exact matching.
      lines = result.content.strip.split('\n').map(&.strip)
      lines.should contain("1")    # NO_COLOR=1
      lines.should contain("dumb") # TERM=dumb
    end
  end

  it "closes stdin so commands see EOF instead of waiting for input" do
    with_tmpdir do |dir|
      bash = headless_bash(dir)
      command = cmd("cat", "[Console]::In.ReadToEnd()")
      result = bash.execute(JSON.parse(%({"command":"#{command}"})))
      result.is_error?.should be_false
      result.content.strip.should eq("")
    end
  end

  it "propagates non-zero exit codes" do
    with_tmpdir do |dir|
      bash = headless_bash(dir)
      result = bash.execute(JSON.parse(%({"command":"exit 3"})))
      result.is_error?.should be_true
      result.content.should contain("[exit code: 3]")
    end
  end

  it "kills a command that exceeds its timeout" do
    with_tmpdir do |dir|
      bash = headless_bash(dir)
      command = cmd("sleep 30", "Start-Sleep -Seconds 30")
      started = Time.monotonic
      result = bash.execute(JSON.parse(%({"command":"#{command}","timeout":1})))
      (Time.monotonic - started).should be < 10.seconds
      result.is_error?.should be_true
      result.content.should contain("timed out after 1s")
    end
  end

  it "interrupts immediately when aborted without a user present" do
    with_tmpdir do |dir|
      bash = headless_bash(dir)
      bash.abort_check = -> { true }
      command = cmd("sleep 30", "Start-Sleep -Seconds 30")
      started = Time.monotonic
      result = bash.execute(JSON.parse(%({"command":"#{command}","timeout":60})))
      (Time.monotonic - started).should be < 10.seconds
      result.is_error?.should be_true
      result.content.should contain("interrupted by user")
    end
  end

  it "runs background tasks headlessly and streams output to the log file" do
    with_tmpdir do |dir|
      session_dir = File.join(dir, "session")
      Dir.mkdir_p(session_dir)
      task_svc = H2code::Tools::InMemoryTaskService.new
      bash = H2code::Tools::Bash.new(dir, task_svc, session_dir)

      command = cmd("echo bg-headless", "Write-Output bg-headless")
      result = bash.execute(JSON.parse(%({"command":"#{command}","run_in_background":true})))
      result.is_error?.should be_false
      result.content.should contain("task_id:")

      task_id = result.content.match(/task_id: (\S+)/).try(&.[1]) || raise "task_id not found"
      task_svc.wait(task_id, 10_000_i64)
      info = task_svc.get_task(task_id) || raise "task not found"
      info.status.completed?.should be_true

      output_path = File.join(session_dir, "tasks", "#{task_id}.log")
      File.exists?(output_path).should be_true
      File.read(output_path).should contain("bg-headless")
    end
  end
end

describe "HomePort, system integration", tags: "integration" do
  it "resolves to an existing directory on this system" do
    Dir.exists?(H2code::HomePort.home).should be_true
  end
end
