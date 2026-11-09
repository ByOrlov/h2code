require "../spec_helper"
require "../../src/setup/wizard"
require "../../src/config/config"

# Forward-walks any text-accepting state one step. Returns the base type so
# callers can hold mixed states in one variable.
private def submit_any(state : H2code::Setup::Wiz, text : String) : H2code::Setup::Wiz
  case s = state
  when H2code::Setup::Wiz::Credentials
    s.submit_text(text)
  when H2code::Setup::Wiz::ExistingKey
    s.submit_text(text)
  when H2code::Setup::Wiz::Endpoint
    s.submit_text(text)
  when H2code::Setup::Wiz::Model
    s.submit_text(text)
  when H2code::Setup::Wiz::Yolo
    s.submit_text(text)
  else
    raise "not a text-submitting state: #{s.class}"
  end
end

# Drives a provider selection to completion using defaults (empty submits),
# declining yolo. Asserts the flow terminates.
private def complete(provider : String, key : String = "sk-test",
                     stored : String = "", yolo : String = "n") : H2code::Setup::Result
  state : H2code::Setup::Wiz = H2code::Setup::Wiz::Welcome.new.select_provider(provider, stored)
  10.times do
    case s = state
    when H2code::Setup::Wiz::Done
      return s.result
    when H2code::Setup::Wiz::Credentials
      state = s.submit_text(key)
    when H2code::Setup::Wiz::ExistingKey
      state = s.submit_text("")
    when H2code::Setup::Wiz::Endpoint, H2code::Setup::Wiz::Model
      state = s.submit_text("")
    when H2code::Setup::Wiz::Yolo
      state = s.submit_text(yolo)
    else
      raise "unreachable state: #{s.class}"
    end
  end
  raise "wizard did not finish in 10 steps for #{provider}"
end

describe H2code::Setup do
  describe "provider choices" do
    it "includes moonshot, ollama, lmstudio, zai" do
      names = H2code::Setup.choices.map(&.name)
      names.should contain("moonshot")
      names.should contain("ollama")
      names.should contain("lmstudio")
      names.should contain("zai")
    end

    it "marks local providers as not needing a key" do
      ollama = H2code::Setup.choices.find! { |c| c.name == "ollama" }
      ollama.needs_key?.should be_false
      lmstudio = H2code::Setup.choices.find! { |c| c.name == "lmstudio" }
      lmstudio.needs_key?.should be_false
    end

    it "marks cloud providers as needing a key" do
      moonshot = H2code::Setup.choices.find! { |c| c.name == "moonshot" }
      moonshot.needs_key?.should be_true
    end

    it "excludes hidden providers (mock) from the wizard" do
      names = H2code::Setup.choices.map(&.name)
      names.should_not contain("mock")
    end

    it "includes all seven new OpenAI-compatible cloud providers" do
      names = H2code::Setup.choices.map(&.name)
      %w[deepseek groq openrouter xai cerebras fireworks together].each do |name|
        names.should contain(name)
      end
    end
  end

  describe "state machine — keyless provider (ollama)" do
    it "skips credentials and fast-forwards to endpoint" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("ollama")
      state.should be_a(H2code::Setup::Wiz::Endpoint)
      state.provider_name.should eq("ollama")
    end

    it "accepts default endpoint with empty submit" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("ollama").as(H2code::Setup::Wiz::Endpoint)
      next_state = state.submit_text("")
      next_state.should be_a(H2code::Setup::Wiz::Model)
      next_state.endpoint.should eq("http://localhost:11434/v1")
    end

    it "accepts default model with empty submit and moves to the yolo step" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("ollama").as(H2code::Setup::Wiz::Endpoint)
      model = state.submit_text("")
      yolo = model.submit_text("")
      yolo.should be_a(H2code::Setup::Wiz::Yolo)
      yolo.model.should eq("llama3.2")
    end

    it "honours overridden endpoint and model" do
      result = complete("ollama", yolo: "n")
      result.endpoint.should eq("http://localhost:11434/v1")
      result.model.should eq("llama3.2")
    end

    it "parses the yolo answer (empty Enter always means yes)" do
      result = complete("ollama", yolo: "")
      result.yolo?.should be_true

      result2 = complete("ollama", yolo: "y")
      result2.yolo?.should be_true

      result3 = complete("ollama", yolo: "n")
      result3.yolo?.should be_false
    end

    it "back from endpoint returns to welcome (keyless regression)" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("ollama")
      state.back.should be_a(H2code::Setup::Wiz::Welcome)
    end
  end

  describe "state machine — keyed provider (moonshot)" do
    it "goes through credentials → endpoint → model" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("moonshot")
      state.should be_a(H2code::Setup::Wiz::Credentials)

      creds = state.as(H2code::Setup::Wiz::Credentials)
      endpoint = creds.submit_text("sk-test-123")
      endpoint.should be_a(H2code::Setup::Wiz::Endpoint)
      endpoint.api_key.should eq("sk-test-123")

      model = endpoint.submit_text("")
      model.should be_a(H2code::Setup::Wiz::Model)
      model.endpoint.should eq("https://api.kimi.com/coding/v1")

      yolo = model.submit_text("")
      yolo.should be_a(H2code::Setup::Wiz::Yolo)
      yolo.model.should eq("kimi-for-coding")

      done = yolo.submit_text("n")
      done.should be_a(H2code::Setup::Wiz::Done)
    end

    it "rejects an empty key" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("moonshot")
      creds = state.as(H2code::Setup::Wiz::Credentials)
      expect_raises(ArgumentError) { creds.submit_text("") }
    end
  end

  describe "state machine — keyed provider with a stored key" do
    it "offers keep-or-reconfigure instead of forcing key entry" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("moonshot", "sk-stored-key-123456")
      state.should be_a(H2code::Setup::Wiz::ExistingKey)
    end

    it "empty submit keeps the stored key and finishes" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("moonshot", "sk-stored-key-123456")
      done = state.as(H2code::Setup::Wiz::ExistingKey).submit_text("")
      done.should be_a(H2code::Setup::Wiz::Done)
      result = done.as(H2code::Setup::Wiz::Done).result
      result.keep_existing?.should be_true
      result.api_key.should eq("sk-stored-key-123456")
    end

    it "typed key reconfigures and continues to endpoint" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("moonshot", "sk-stored-key-123456")
      endpoint = state.as(H2code::Setup::Wiz::ExistingKey).submit_text("sk-new-key-999")
      endpoint.should be_a(H2code::Setup::Wiz::Endpoint)
      endpoint.as(H2code::Setup::Wiz::Endpoint).api_key.should eq("sk-new-key-999")
    end

    it "without a stored key the wizard always asks for one" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("moonshot")
      state.should be_a(H2code::Setup::Wiz::Credentials)
    end

    it "back from the keep-or-reconfigure step returns to the provider picker" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("moonshot", "sk-stored-key-123456")
      state.back.should be_a(H2code::Setup::Wiz::Welcome)
    end

    it "rejects an unknown provider" do
      expect_raises(ArgumentError) do
        H2code::Setup::Wiz::Welcome.new.select_provider("does-not-exist")
      end
    end
  end

  describe "#placeholder" do
    it "shows a provider-picker hint at welcome" do
      H2code::Setup::Wiz::Welcome.new.placeholder.should contain("provider")
    end

    it "shows the API key prompt at credentials" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("moonshot")
      state.placeholder.should contain("API key")
    end

    it "includes the default endpoint in the endpoint placeholder" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("ollama")
      state.placeholder.should contain("http://localhost:11434/v1")
    end

    it "includes the default model in the model placeholder" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("ollama").as(H2code::Setup::Wiz::Endpoint)
      state.submit_text("").placeholder.should contain("llama3.2")
    end
  end

  describe "#back" do
    it "steps credentials back to welcome" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("moonshot")
      state.back.should be_a(H2code::Setup::Wiz::Welcome)
    end

    it "steps endpoint back to credentials for a keyed provider" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("moonshot")
      endpoint = state.as(H2code::Setup::Wiz::Credentials).submit_text("sk-test")
      endpoint.back.should be_a(H2code::Setup::Wiz::Credentials)
    end

    it "steps model back to endpoint" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("moonshot")
      model = state.as(H2code::Setup::Wiz::Credentials).submit_text("sk-test").submit_text("")
      model.back.should be_a(H2code::Setup::Wiz::Endpoint)
    end

    it "steps yolo back to model" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("moonshot")
      yolo = state.as(H2code::Setup::Wiz::Credentials).submit_text("sk-test").submit_text("").submit_text("")
      yolo.back.should be_a(H2code::Setup::Wiz::Model)
    end

    it "is a no-op on welcome" do
      welcome = H2code::Setup::Wiz::Welcome.new
      welcome.back.should be(welcome)
    end
  end

  describe "#apply_to" do
    it "writes ollama config fields" do
      state = H2code::Setup::Wiz::Welcome.new.select_provider("ollama")
      yolo = state.as(H2code::Setup::Wiz::Endpoint).submit_text("http://gpu:11434/v1").submit_text("qwen2.5")
      done = yolo.submit_text("n")
      result = done.as(H2code::Setup::Wiz::Done).result

      config = H2code::Config::Config.new
      result.apply_to(config)
      config.provider_name.should eq("ollama")
      config.ollama_endpoint.should eq("http://gpu:11434/v1")
      config.ollama_model.should eq("qwen2.5")
    end

    it "writes moonshot config fields" do
      result = complete("moonshot", key: "sk-test")

      config = H2code::Config::Config.new
      result.apply_to(config)
      config.provider_name.should eq("moonshot")
      config.api_key.should eq("sk-test")
      config.endpoint.should eq("https://api.kimi.com/coding/v1")
      config.model.should eq("kimi-for-coding")
    end

    it "skip (keep existing) only switches the default provider" do
      result = complete("moonshot", stored: "sk-stored")

      config = H2code::Config::Config.new
      config.api_key = "sk-stored"
      config.endpoint = "https://custom.example/v1"
      config.model = "custom-model"
      result.apply_to(config)
      config.provider_name.should eq("moonshot")
      config.api_key.should eq("sk-stored")
      config.endpoint.should eq("https://custom.example/v1")
      config.model.should eq("custom-model")
    end

    it "writes lmstudio config fields" do
      result = complete("lmstudio")

      config = H2code::Config::Config.new
      result.apply_to(config)
      config.provider_name.should eq("lmstudio")
      config.lmstudio_endpoint.should eq("http://localhost:1234/v1")
    end

    it "writes permission_mode=yolo when yolo was accepted" do
      result = complete("ollama", yolo: "y")

      config = H2code::Config::Config.new
      result.apply_to(config)
      config.permission_mode.should eq("yolo")
    end

    it "keeps the manual permission default when yolo was declined" do
      result = complete("ollama", yolo: "n")

      config = H2code::Config::Config.new
      result.apply_to(config)
      config.permission_mode.should eq("manual")
    end
  end

  # The FSM "compiler": for every registered provider and both key
  # situations, the flow must reach Done with a valid Result, and every
  # intermediate state must walk back to Welcome. New providers appear in
  # this matrix automatically via the registry.
  describe "walk — every provider, every entry situation" do
    H2code::Setup.choices.each do |choice|
      it "completes #{choice.name} with no stored key" do
        result = complete(choice.name)
        result.provider_name.should eq(choice.name)
        result.endpoint.should eq(choice.default_endpoint)
        result.model.should eq(choice.default_model)
      end

      it "never asks for a key on keyless #{choice.name} (even with a stored key)" do
        next if choice.needs_key?
        state : H2code::Setup::Wiz = H2code::Setup::Wiz::Welcome.new.select_provider(choice.name, "sk-stored")
        state.should be_a(H2code::Setup::Wiz::Endpoint)
        # And the whole flow must not pass through Credentials/ExistingKey.
        8.times do
          break if state.is_a?(H2code::Setup::Wiz::Done)
          state.should_not be_a(H2code::Setup::Wiz::Credentials)
          state.should_not be_a(H2code::Setup::Wiz::ExistingKey)
          state = submit_any(state, "")
        end
        state.should be_a(H2code::Setup::Wiz::Done)
      end

      if choice.needs_key?
        it "offers keep-or-reconfigure for #{choice.name} with a stored key" do
          state = H2code::Setup::Wiz::Welcome.new.select_provider(choice.name, "sk-stored")
          state.should be_a(H2code::Setup::Wiz::ExistingKey)
          done = state.as(H2code::Setup::Wiz::ExistingKey).submit_text("")
          done.should be_a(H2code::Setup::Wiz::Done)
        end
      end

      it "back-walks #{choice.name} to welcome from every state" do
        seen = [] of H2code::Setup::Wiz
        state : H2code::Setup::Wiz = H2code::Setup::Wiz::Welcome.new.select_provider(choice.name)
        8.times do
          break if state.is_a?(H2code::Setup::Wiz::Done)
          seen << state
          # Credentials rejects an empty key — feed the walk a dummy one.
          text = state.is_a?(H2code::Setup::Wiz::Credentials) ? "sk-walk" : ""
          state = submit_any(state, text)
        end
        seen.each do |s|
          back = s.back
          until back.is_a?(H2code::Setup::Wiz::Welcome)
            back = back.back
          end
        end
      end
    end
  end
end
