require "../spec_helper"
require "../support/pty_session"

# End-to-end setup-wizard smoke against the real binary in a pseudo-terminal:
# fresh H2CODE_HOME (no config) → first-run wizard, driven purely with raw
# keystroke bytes — typing, arrows, bracketed paste — the way a user at a
# terminal would. Asserts on what the child prints and on the config.json
# the completed wizard persists.
#
# Opt-in: set H2CODE_TEST_BIN to a built binary (rake spec:pty builds one
# and runs this spec), otherwise the examples are pending.
{% if flag?(:unix) %}
  # Fresh isolated environment for one first-run wizard session.
  def pty_env(home : String) : Hash(String, String)
    {
      "HOME"        => home,
      "H2CODE_HOME" => File.join(home, ".h2code"),
      "TERM"        => "xterm-256color",
      "H2CODE_LANG" => "en", # deterministic prompts regardless of host LANG
    }
  end

  describe "setup wizard PTY smoke" do
    bin = ENV["H2CODE_TEST_BIN"]?

    if bin && File.exists?(bin)
      it "first run: keyless provider (ollama) — type, defaults, yolo, config saved" do
        with_tmpdir do |dir|
          home = File.join(dir, "home")
          Dir.mkdir_p(home)
          config_path = File.join(home, ".h2code", "config.json")

          session = PtySession.new(bin, env: pty_env(home))
          begin
            session.read_until("Select provider", 20.seconds).should_not be_nil

            # Fuzzy-type the provider, Enter to commit.
            session.send("ollama\r")
            session.read_until("No API key needed for ollama.", 10.seconds).should_not be_nil

            session.send("\r") # endpoint default
            session.send("\r") # model default
            session.send("\r") # yolo — empty Enter = trust by default

            deadline = Time.monotonic + 15.seconds
            until File.exists?(config_path) || Time.monotonic > deadline
              sleep 100.milliseconds
            end
            File.exists?(config_path).should be_true

            config = JSON.parse(File.read(config_path))
            config["provider"]["default"].should eq("ollama")
            config["provider"]["ollama"]["endpoint"].should eq("http://localhost:11434/v1")
            config["provider"]["ollama"]["model"].should eq("llama3.2")
            config["permission"]["mode"].should eq("yolo")

            # Leave the TUI: Ctrl+C twice (exit confirmation).
            session.send("\u{3}\u{3}")
            session.wait_exit(10.seconds).should be_true
          ensure
            session.close
          end
        end
      end

      it "first run: keyed provider (zai) — arrows, bracketed-pasted key, typed model" do
        with_tmpdir do |dir|
          home = File.join(dir, "home")
          Dir.mkdir_p(home)
          config_path = File.join(home, ".h2code", "config.json")

          session = PtySession.new(bin, env: pty_env(home))
          begin
            session.read_until("Select provider", 20.seconds).should_not be_nil

            # Arrow down to zai's slot in the registry order, then Enter.
            idx = H2code::Setup::Wizard.choices.index!(&.name.==("zai"))
            session.send("\e[B" * idx)
            session.send("\r")
            session.read_until("API key", 10.seconds).should_not be_nil

            # Paste the key the way a terminal delivers it, submit, defaults.
            session.send("\e[200~sk-pty-test\e[201~")
            session.send("\r")
            session.send("\r")        # endpoint default
            session.send("glm-4.6\r") # model typed
            session.send("\r")        # yolo

            deadline = Time.monotonic + 15.seconds
            until File.exists?(config_path) || Time.monotonic > deadline
              sleep 100.milliseconds
            end
            File.exists?(config_path).should be_true

            config = JSON.parse(File.read(config_path))
            config["provider"]["default"].should eq("zai")
            config["provider"]["zai"]["api_key"].should eq("sk-pty-test")
            config["provider"]["zai"]["model"].should eq("glm-4.6")

            # The pasted key is masked with bullets — never printed verbatim.
            session.output.should_not contain("sk-pty-test")

            session.send("\u{3}\u{3}")
            session.wait_exit(10.seconds).should be_true
          ensure
            session.close
          end
        end
      end
    else
      pending "setup wizard PTY smoke (set H2CODE_TEST_BIN, or run `rake spec:pty`)"
    end
  end
{% else %}
  pending "setup wizard PTY smoke (unix only)"
{% end %}
