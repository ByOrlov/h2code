require "../spec_helper"
require "../../src/config/config"

describe H2code::Config::Config do
  describe "defaults" do
    it "starts with nil provider/model/endpoint/api_key" do
      config = H2code::Config::Config.new
      config.provider_name.should be_nil
      config.model.should be_nil
      config.endpoint.should be_nil
      config.api_key.should be_nil
    end

    it "keeps non-nil defaults for thinking/permission/max_context" do
      config = H2code::Config::Config.new
      config.thinking_effort.should eq("medium")
      config.permission_mode.should eq("manual")
      config.max_context_tokens.should eq(262144)
    end

    it "defaults behavioral flags to safe values" do
      config = H2code::Config::Config.new
      config.debug?.should be_false
      config.cron_enabled?.should be_true
      config.cron_no_stale?.should be_false
      config.subagent_timeout_ms.should be_nil
      config.experimental_flag.should be_nil
      config.mock_script.should be_nil
      config.editor.should be_nil
      config.tmp_dir.should be_nil
      config.git_terminal_prompt.should be_nil
      config.shell.should be_nil
    end

    it "allows behavioral flags to be set" do
      config = H2code::Config::Config.new
      config.debug = true
      config.cron_enabled = false
      config.cron_no_stale = true
      config.subagent_timeout_ms = 5000
      config.experimental_flag = "1"
      config.mock_script = "plan"
      config.editor = "nano"
      config.tmp_dir = "/var/tmp"
      config.git_terminal_prompt = "1"
      config.shell = "/bin/zsh"
      config.debug?.should be_true
      config.cron_enabled?.should be_false
      config.cron_no_stale?.should be_true
      config.subagent_timeout_ms.should eq(5000)
      config.experimental_flag.should eq("1")
      config.mock_script.should eq("plan")
      config.editor.should eq("nano")
      config.tmp_dir.should eq("/var/tmp")
      config.git_terminal_prompt.should eq("1")
      config.shell.should eq("/bin/zsh")
    end
  end

  describe ".load" do
    it "maps behavioral ENV overrides to config fields" do
      prev = {
        "H2CODE_DEBUG"               => ENV["H2CODE_DEBUG"]?,
        "H2CODE_DISABLE_CRON"        => ENV["H2CODE_DISABLE_CRON"]?,
        "H2CODE_CRON_NO_STALE"       => ENV["H2CODE_CRON_NO_STALE"]?,
        "H2CODE_SUBAGENT_TIMEOUT_MS" => ENV["H2CODE_SUBAGENT_TIMEOUT_MS"]?,
        "H2CODE_EXPERIMENTAL_FLAG"   => ENV["H2CODE_EXPERIMENTAL_FLAG"]?,
        "H2CODE_MOCK_SCRIPT"         => ENV["H2CODE_MOCK_SCRIPT"]?,
        "EDITOR"                     => ENV["EDITOR"]?,
        "TMPDIR"                     => ENV["TMPDIR"]?,
        "GIT_TERMINAL_PROMPT"        => ENV["GIT_TERMINAL_PROMPT"]?,
        "SHELL"                      => ENV["SHELL"]?,
      }
      begin
        ENV["H2CODE_DEBUG"] = "1"
        ENV["H2CODE_DISABLE_CRON"] = "1"
        ENV["H2CODE_CRON_NO_STALE"] = "1"
        ENV["H2CODE_SUBAGENT_TIMEOUT_MS"] = "9000"
        ENV["H2CODE_EXPERIMENTAL_FLAG"] = "on"
        ENV["H2CODE_MOCK_SCRIPT"] = "plan"
        ENV["EDITOR"] = "emacs"
        ENV["TMPDIR"] = "/custom-tmp"
        ENV["GIT_TERMINAL_PROMPT"] = "1"
        ENV["SHELL"] = "/bin/fish"

        # Load from a nonexistent path so only ENV overrides apply.
        config = H2code::Config::Config.load("/tmp/h2code-spec-nonexistent-#{Random::Secure.hex(4)}.json")
        config.debug?.should be_true
        config.cron_enabled?.should be_false
        config.cron_no_stale?.should be_true
        config.subagent_timeout_ms.should eq(9000)
        config.experimental_flag.should eq("on")
        config.mock_script.should eq("plan")
        config.editor.should eq("emacs")
        config.tmp_dir.should eq("/custom-tmp")
        config.git_terminal_prompt.should eq("1")
        config.shell.should eq("/bin/fish")
      ensure
        prev.each do |k, v|
          if v.nil?
            ENV.delete(k)
          else
            ENV[k] = v.as(String)
          end
        end
      end
    end
  end

  describe "#provider_configured?" do
    it "returns false when no provider is set" do
      config = H2code::Config::Config.new
      config.provider_configured?.should be_false
    end

    it "returns true for ollama with no key (local)" do
      config = H2code::Config::Config.new
      config.provider_name = "ollama"
      config.provider_configured?.should be_true
    end

    it "returns true for lmstudio with no key (local)" do
      config = H2code::Config::Config.new
      config.provider_name = "lmstudio"
      config.provider_configured?.should be_true
    end

    it "returns true for mock with no key" do
      config = H2code::Config::Config.new
      config.provider_name = "mock"
      config.provider_configured?.should be_true
    end

    it "returns false for moonshot without a key when no oauth file exists" do
      config = H2code::Config::Config.new
      config.provider_name = "moonshot"
      config.api_key = ""
      # Depends on whether ~/.kimi-code/credentials exists; either way,
      # an empty api_key with no oauth should be false on a clean machine.
      # This assertion is best-effort — skip if the oauth file is present.
      home = ENV["HOME"]? || "/tmp"
      oauth_path = File.join(home, ".kimi-code", "credentials", "kimi-code.json")
      config.provider_configured?.should be_false unless File.exists?(oauth_path)
    end

    it "returns true for moonshot with an api key" do
      config = H2code::Config::Config.new
      config.provider_name = "moonshot"
      config.api_key = "sk-test"
      config.provider_configured?.should be_true
    end

    it "returns false for zai without a key" do
      config = H2code::Config::Config.new
      config.provider_name = "zai"
      config.zai_api_key = ""
      config.provider_configured?.should be_false
    end

    it "returns true for zai with a key" do
      config = H2code::Config::Config.new
      config.provider_name = "zai"
      config.zai_api_key = "sk-test"
      config.provider_configured?.should be_true
    end

    it "returns false for an unknown provider with no key" do
      config = H2code::Config::Config.new
      config.provider_name = "custom"
      config.api_key = ""
      config.provider_configured?.should be_false
    end

    it "returns true for an unknown provider with a key" do
      config = H2code::Config::Config.new
      config.provider_name = "custom"
      config.api_key = "sk-test"
      config.provider_configured?.should be_true
    end
  end

  describe "#provider_configured?(name)" do
    it "checks an arbitrary provider name independent of provider_name" do
      config = H2code::Config::Config.new
      config.provider_name = "ollama"
      config.api_key = "sk-test"
      config.provider_configured?("moonshot").should be_true
      config.provider_configured?("zai").should be_false
      config.provider_configured?("ollama").should be_true
    end

    it "returns false for nil" do
      config = H2code::Config::Config.new
      config.provider_configured?(nil).should be_false
    end
  end

  describe "#auto_mcp_servers" do
    it "returns Z.AI Web Search MCP server for zai-coding-plan" do
      config = H2code::Config::Config.new
      config.provider_name = "zai-coding-plan"
      config.zai_api_key = "test-key"

      servers = config.auto_mcp_servers
      servers.size.should eq(1)

      server = servers.first
      server.name.should eq("zai-web-search")
      server.type.should eq("http")
      server.url.should eq("https://api.z.ai/api/mcp/web_search_prime/mcp")
      server.headers["Authorization"].should eq("Bearer test-key")
      server.providers.should eq(["zai-coding-plan"])
      server.tool_aliases.should eq({"web_search_prime" => H2code::Tools::Names::WEB_SEARCH})
      server.aliased_tool_name("web_search_prime").should eq(H2code::Tools::Names::WEB_SEARCH)
      server.aliased_tool_name("other_tool").should eq("other_tool")
    end

    it "returns empty for zai-coding-plan without an API key" do
      config = H2code::Config::Config.new
      config.provider_name = "zai-coding-plan"
      config.auto_mcp_servers.should be_empty
    end

    it "returns empty for other providers" do
      config = H2code::Config::Config.new
      config.provider_name = "zai"
      config.zai_api_key = "test-key"
      config.auto_mcp_servers.should be_empty
    end
  end

  describe "JSON round-trip" do
    it "parses nil-able fields from JSON" do
      json = <<-JSON
        {
          "model": { "default": "llama3.2" },
          "provider": {
            "default": "ollama",
            "ollama": { "endpoint": "http://gpu:11434/v1", "model": "qwen2.5" }
          }
        }
      JSON
      config = H2code::Config::Config.parse_json(json)
      config.provider_name.should eq("ollama")
      config.model.should eq("llama3.2")
      config.ollama_endpoint.should eq("http://gpu:11434/v1")
      config.ollama_model.should eq("qwen2.5")
    end

    it "round-trips the gitlab token and endpoint" do
      config = H2code::Config::Config.parse_json(%({"gitlab": {"token": "glpat_xyz", "endpoint": "https://gitlab.corp.io"}}))
      config.gitlab_token.should eq("glpat_xyz")
      config.gitlab_endpoint.should eq("https://gitlab.corp.io")

      path = File.join(Dir.tempdir, "h2code-config-test-#{Random::Secure.hex(8)}.json")
      begin
        config.save(path)
        reloaded = H2code::Config::Config.parse_json(File.read(path))
        reloaded.gitlab_token.should eq("glpat_xyz")
        reloaded.gitlab_endpoint.should eq("https://gitlab.corp.io")

        # Empty by default, and the section is not written when unset.
        H2code::Config::Config.parse_json(%({})).gitlab_token.should eq("")
        H2code::Config::Config.new.save(path)
        File.read(path).should_not contain("\"gitlab\"")
      ensure
        File.delete(path) rescue nil
      end
    end

    it "round-trips the github token" do
      config = H2code::Config::Config.parse_json(%({"github": {"token": "ghp_abc123"}}))
      config.github_token.should eq("ghp_abc123")

      path = File.join(Dir.tempdir, "h2code-config-test-#{Random::Secure.hex(8)}.json")
      begin
        config.save(path)
        reloaded = H2code::Config::Config.parse_json(File.read(path))
        reloaded.github_token.should eq("ghp_abc123")

        # Empty by default, and the section is not written when unset.
        H2code::Config::Config.parse_json(%({})).github_token.should eq("")
        File.delete(path)
        H2code::Config::Config.new.save(path)
        File.read(path).should_not contain("\"github\"")
      ensure
        File.delete(path) rescue nil
      end
    end

    it "leaves nil-able fields nil when absent" do
      json = %({"model": {"thinking_effort": "high"}})
      config = H2code::Config::Config.parse_json(json)
      config.provider_name.should be_nil
      config.model.should be_nil
      config.api_key.should be_nil
      config.endpoint.should be_nil
      config.thinking_effort.should eq("high")
    end

    it "saves ollama/lmstudio sections only when set" do
      config = H2code::Config::Config.new
      config.provider_name = "ollama"
      config.ollama_endpoint = "http://localhost:11434/v1"

      path = File.join(Dir.tempdir, "h2code-config-test-#{Random::Secure.hex(8)}.json")
      begin
        config.save(path)
        content = File.read(path)
        content.should contain("\"default\": \"ollama\"")
        content.should contain("\"ollama\"")
        content.should contain("\"endpoint\": \"http://localhost:11434/v1\"")
        # lmstudio section should not be written when unset
        content.should_not contain("\"lmstudio\"")
      ensure
        File.delete(path) rescue nil
      end
    end

    it "round-trips the debug_zones ui flag" do
      config = H2code::Config::Config.new
      config.debug_zones = true

      path = File.join(Dir.tempdir, "h2code-config-test-#{Random::Secure.hex(8)}.json")
      begin
        config.save(path)
        reloaded = H2code::Config::Config.parse_json(File.read(path))
        reloaded.debug_zones?.should be_true
      ensure
        File.delete(path) rescue nil
      end
    end

    it "round-trips the show_tips ui flag (explicit false survives)" do
      config = H2code::Config::Config.new
      config.show_tips?.should be_true

      config.show_tips = false
      path = File.join(Dir.tempdir, "h2code-config-test-#{Random::Secure.hex(8)}.json")
      begin
        config.save(path)
        reloaded = H2code::Config::Config.parse_json(File.read(path))
        reloaded.show_tips?.should be_false

        # Missing key keeps the default (enabled).
        reloaded = H2code::Config::Config.parse_json(%({"ui":{}}))
        reloaded.show_tips?.should be_true
      ensure
        File.delete(path) rescue nil
      end
    end

    it "round-trips permission.sudo_mode and rejects unknown values" do
      config = H2code::Config::Config.new
      config.sudo_mode.should eq("off")

      config.sudo_mode = "request"
      path = File.join(Dir.tempdir, "h2code-config-test-#{Random::Secure.hex(8)}.json")
      begin
        config.save(path)
        content = File.read(path)
        content.should contain("\"sudo_mode\": \"request\"")
        reloaded = H2code::Config::Config.parse_json(content)
        reloaded.sudo_mode.should eq("request")

        # Unknown values fall back to the default instead of poisoning startup.
        reloaded = H2code::Config::Config.parse_json(%({"permission":{"mode":"manual","sudo_mode":"yolo"}}))
        reloaded.sudo_mode.should eq("off")
      ensure
        File.delete(path) rescue nil
      end
    end

    it "round-trips the transcription section" do
      json = %({"transcription":{"enabled":true,"socket":"/tmp/voice.sock","engine":"gigaam","language":"ru","max_duration_sec":60}})
      config = H2code::Config::Config.parse_json(json)
      config.transcription.enabled?.should be_true
      config.transcription.socket.should eq("/tmp/voice.sock")
      config.transcription.engine.should eq("gigaam")
      config.transcription.language.should eq("ru")
      config.transcription.max_duration_sec.should eq(60)

      path = File.join(Dir.tempdir, "h2code-config-test-#{Random::Secure.hex(8)}.json")
      begin
        config.save(path)
        reloaded = H2code::Config::Config.parse_json(File.read(path))
        reloaded.transcription.enabled?.should be_true
        reloaded.transcription.socket.should eq("/tmp/voice.sock")
        reloaded.transcription.engine.should eq("gigaam")
        reloaded.transcription.language.should eq("ru")
        reloaded.transcription.max_duration_sec.should eq(60)
      ensure
        File.delete(path) rescue nil
      end
    end

    it "defaults the transcription section" do
      config = H2code::Config::Config.parse_json(%({}))
      config.transcription.enabled?.should be_true
      config.transcription.socket.should eq("~/.h2voice/voice.sock")
      config.transcription.engine.should eq("auto")
      config.transcription.max_duration_sec.should eq(1800)
    end

    it "keeps transcription enabled when the section omits the flag" do
      config = H2code::Config::Config.parse_json(%({"transcription":{"socket":"/tmp/voice.sock"}}))
      config.transcription.enabled?.should be_true
      config.transcription.socket.should eq("/tmp/voice.sock")
    end

    it "survives an explicit transcription opt-out" do
      config = H2code::Config::Config.parse_json(%({"transcription":{"enabled":false}}))
      config.transcription.enabled?.should be_false
    end

    it "maps H2CODE_VOICE_SOCKET to the transcription socket" do
      prev = ENV["H2CODE_VOICE_SOCKET"]?
      begin
        ENV["H2CODE_VOICE_SOCKET"] = "/tmp/other-voice.sock"
        config = H2code::Config::Config.load(
          "/tmp/h2code-spec-nonexistent-#{Random::Secure.hex(4)}.json")
        config.transcription.socket.should eq("/tmp/other-voice.sock")
      ensure
        if prev
          ENV["H2CODE_VOICE_SOCKET"] = prev
        else
          ENV.delete("H2CODE_VOICE_SOCKET")
        end
      end
    end

    it "round-trips services.moonshot_search" do
      ms = H2code::Config::MoonshotServiceConfig.new(
        base_url: "https://search.example.com",
        api_key: "search-key",
        custom_headers: {"X-Foo" => "bar"},
      )
      config = H2code::Config::Config.new
      config.services = H2code::Config::ServicesConfig.new(moonshot_search: ms)

      path = File.join(Dir.tempdir, "h2code-config-test-#{Random::Secure.hex(8)}.json")
      begin
        config.save(path)
        reloaded = H2code::Config::Config.parse_json(File.read(path))
        ms = reloaded.services.moonshot_search
        ms.should_not be_nil
        if ms
          ms.base_url.should eq("https://search.example.com")
          ms.api_key.should eq("search-key")
          ms.custom_headers.should eq({"X-Foo" => "bar"})
        end
      ensure
        File.delete(path) rescue nil
      end
    end
  end
end

describe "H2code.build_named_provider with nil" do
  # build_named_provider lives in h2code.cr which auto-runs the CLI on require,
  # so these are covered by the integration test in spec/h2code_spec.cr instead.
  it "placeholder — see h2code integration tests" do
    true.should be_true
  end
end
