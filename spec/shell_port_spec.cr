require "./spec_helper"

describe H2code::ShellPort do
  port = H2code::ShellPort.default

  {% if flag?(:win32) %}
    it "resolves to an interpreter with a name" do
      {"bash", "powershell"}.should contain(port.name)
    end
  {% else %}
    it "wraps the command in -c argv" do
      port.shell_args("echo hi").should eq(["-c", "echo hi"])
    end

    it "reports an honest interpreter name backed by a real executable" do
      {"bash", "sh"}.should contain(port.name)
      File.executable?(port.program).should be_true
      if port.name == "bash"
        port.program.should contain("bash")
      else
        port.program.should eq("/bin/sh")
      end
    end

    it "defaults the SHELL env var to the resolved program" do
      port.env_shell.should eq(port.program)
    end
  {% end %}

  it "exposes model-facing guidance naming the interpreter" do
    port.guidance.should contain(port.name)
    port.guidance.size.should be > 10
  end

  it "runs a command and propagates its exit code" do
    status = Process.new(port.program, port.shell_args("exit 7")).wait
    status.exit_code.should eq(7)
  end
end

describe H2code::Tools::Tool do
  it "exposes a shell port composition root" do
    H2code::Tools::Tool::SHELL_PORT.name.size.should be > 0
  end
end

describe H2code::Tools::Bash do
  it "embeds the resolved shell into the tool description" do
    bash = H2code::Tools::Bash.new("/tmp")
    bash.description.should contain("`#{H2code::Tools::Tool::SHELL_PORT.name}`")
    bash.description.should contain(H2code::Tools::Tool::SHELL_PORT.guidance)
  end
end
