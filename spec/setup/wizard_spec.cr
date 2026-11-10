require "../spec_helper"
require "../../src/setup/wizard"
require "../../src/config/config"

def choice_for(name : String) : H2code::Setup::ProviderChoice
  H2code::Setup.choices.find! { |c| c.name == name }
end

# Select a provider into a fresh state (the Provider step).
def select_provider(name : String, stored : String = "") : H2code::Setup::State
  H2code::Setup::State.new.with(H2code::Setup.select_provider(choice_for(name), stored))
end

# Run one planner step: submit text for the head of `missing`.
def submit_step(state : H2code::Setup::State, text : String) : H2code::Setup::State
  head = H2code::Setup.missing(state).first?
  raise "goal already complete" unless head
  filled = case head
           when H2code::Setup::Requirement::Key
             H2code::Setup.submit_key(state, text)
           when H2code::Setup::Requirement::Endpoint
             H2code::Setup.submit_endpoint(state, text)
           when H2code::Setup::Requirement::Model
             H2code::Setup.submit_model(state, text)
           when H2code::Setup::Requirement::Yolo
             H2code::Setup.submit_yolo(text)
           else
             raise "provider step does not take text"
           end
  state.with(filled)
end

# Drive a provider selection to completion using defaults (empty submits),
# declining yolo. Asserts the flow terminates.
def complete(provider : String, key : String = "sk-test",
             stored : String = "", yolo : String = "n") : H2code::Setup::Result
  state = select_provider(provider, stored)
  10.times do
    break if H2code::Setup.missing(state).empty?
    head = H2code::Setup.missing(state).first
    text = head.key? ? (stored.empty? ? key : "") : (head.yolo? ? yolo : "")
    state = submit_step(state, text)
  end
  state.result?.not_nil!
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
      H2code::Setup.choices.find!(&.name.==("ollama")).needs_key?.should be_false
      H2code::Setup.choices.find!(&.name.==("lmstudio")).needs_key?.should be_false
    end

    it "marks cloud providers as needing a key" do
      H2code::Setup.choices.find!(&.name.==("moonshot")).needs_key?.should be_true
    end

    it "excludes hidden providers (mock) from the wizard" do
      H2code::Setup.choices.map(&.name).should_not contain("mock")
    end

    it "includes all seven new OpenAI-compatible cloud providers" do
      names = H2code::Setup.choices.map(&.name)
      %w[deepseek groq openrouter xai cerebras fireworks together].each do |name|
        names.should contain(name)
      end
    end
  end

  describe "mosaic — requirements map 1:1 onto closing types" do
    # The compile-time macro in wizard.cr fails the build on a mismatch;
    # this is its runtime mirror, so a violation shows up as a readable
    # spec failure too. (TypeNode#constants exists only in macro land, so
    # the lists are interpolated as literals here.)
    it "Requirement constants and Filled constants agree" do
      {{ H2code::Setup::Requirement.constants.map(&.stringify).sort }}.should eq({{ H2code::Setup::Filled.constants.map(&.stringify).sort }})
    end

    it "each Filled type closes the requirement named after it" do
      {H2code::Setup::Filled::Provider.new(choice_for("zai")),
       H2code::Setup::Filled::Key.new("k"),
       H2code::Setup::Filled::Endpoint.new("e"),
       H2code::Setup::Filled::Model.new("m"),
       H2code::Setup::Filled::Yolo.new(false)}.each do |filled|
        filled.requirement.to_s.should eq(filled.class.name.split("::").last)
      end
    end

    it "submit functions return the closing type of their requirement" do
      state = select_provider("zai")
      H2code::Setup.submit_key(state, "sk").should be_a(H2code::Setup::Filled::Key)
      H2code::Setup.submit_endpoint(state, "e").should be_a(H2code::Setup::Filled::Endpoint)
      H2code::Setup.submit_model(state, "m").should be_a(H2code::Setup::Filled::Model)
      H2code::Setup.submit_yolo("y").should be_a(H2code::Setup::Filled::Yolo)
    end
  end

  describe "fill-level — keyless provider (ollama)" do
    it "never lists Key as missing, even with a stored key" do
      state = select_provider("ollama", "sk-stored")
      H2code::Setup.missing(state).should eq([
        H2code::Setup::Requirement::Endpoint,
        H2code::Setup::Requirement::Model,
        H2code::Setup::Requirement::Yolo,
      ])
    end

    it "accepts default endpoint and model with empty submits" do
      state = select_provider("ollama")
      state = submit_step(state, "") # endpoint default
      state.endpoint.not_nil!.value.should eq("http://localhost:11434/v1")
      state = submit_step(state, "") # model default
      state.model.not_nil!.value.should eq("llama3.2")
    end

    it "honours overridden endpoint and model" do
      state = select_provider("ollama")
      state = submit_step(state, "http://gpu:11434/v1")
      state = submit_step(state, "qwen2.5")
      state.endpoint.not_nil!.value.should eq("http://gpu:11434/v1")
      state.model.not_nil!.value.should eq("qwen2.5")
    end
  end

  describe "fill-level — keyed provider (moonshot)" do
    it "lists Key first in missing" do
      H2code::Setup.missing(select_provider("moonshot")).should eq([
        H2code::Setup::Requirement::Key,
        H2code::Setup::Requirement::Endpoint,
        H2code::Setup::Requirement::Model,
        H2code::Setup::Requirement::Yolo,
      ])
    end

    it "rejects an empty key without a stored one" do
      expect_raises(ArgumentError) { H2code::Setup.submit_key(select_provider("moonshot"), "") }
    end

    it "parses the yolo answer (empty Enter always means yes)" do
      H2code::Setup.submit_yolo("").value?.should be_true
      H2code::Setup.submit_yolo("y").value?.should be_true
      H2code::Setup.submit_yolo("n").value?.should be_false
      H2code::Setup.submit_yolo("нет").value?.should be_false
    end
  end

  describe "fill-level — keyed provider with a stored key" do
    it "empty submit keeps the stored key and completes the goal" do
      state = select_provider("moonshot", "sk-stored-key-123456")
      H2code::Setup.submit_key(state, "").kept?.should be_true

      state = submit_step(state, "") # keep
      H2code::Setup.missing(state).should be_empty
      result = state.result?.not_nil!
      result.keep_existing?.should be_true
      result.api_key.should eq("sk-stored-key-123456")
    end

    it "typed key reconfigures and keeps walking the requirements" do
      state = select_provider("moonshot", "sk-stored-key-123456")
      state = submit_step(state, "sk-new-key-999")
      state.key.not_nil!.value.should eq("sk-new-key-999")
      state.key.not_nil!.kept?.should be_false
      H2code::Setup.missing(state).first?.should eq(H2code::Setup::Requirement::Endpoint)
    end
  end

  describe "result? is nil until the goal is complete" do
    it "cannot produce a Result mid-flow" do
      select_provider("zai").result?.should be_nil
      select_provider("zai").with(H2code::Setup::Filled::Key.new("sk")).result?.should be_nil
    end

    it "produces a Result once nothing is missing" do
      complete("zai").provider_name.should eq("zai")
    end
  end

  describe "placeholder" do
    it "shows a provider-picker hint before selection" do
      H2code::Setup.placeholder(H2code::Setup::State.new).should contain("provider")
    end

    it "shows the API key prompt at the key step" do
      H2code::Setup.placeholder(select_provider("moonshot")).should contain("API key")
    end

    it "shows keep-or-reconfigure with a stored key" do
      H2code::Setup.placeholder(select_provider("moonshot", "sk-stored-key-123456"))
        .should contain("•")
    end

    it "includes the defaults in endpoint/model placeholders" do
      H2code::Setup.placeholder(select_provider("ollama")).should contain("http://localhost:11434/v1")
      state = submit_step(select_provider("ollama"), "")
      H2code::Setup.placeholder(state).should contain("llama3.2")
    end
  end

  describe "progress_steps — the goal view" do
    it "marks the current step and the closed ones" do
      state = select_provider("moonshot")
      H2code::Setup.progress_steps(state).map(&.name).should eq(["key", "endpoint", "model", "yolo"])
      H2code::Setup.progress_steps(state).map(&.kind)
        .should eq([:current, :pending, :pending, :pending])

      state = submit_step(state, "sk-test")
      H2code::Setup.progress_steps(state).map(&.kind)
        .should eq([:closed, :current, :pending, :pending])

      state = submit_step(state, "")
      state = submit_step(state, "")
      H2code::Setup.progress_steps(state).map(&.kind)
        .should eq([:closed, :closed, :closed, :current])
    end

    it "never lists the key for keyless providers" do
      H2code::Setup.progress_steps(select_provider("ollama")).map(&.name)
        .should eq(["endpoint", "model", "yolo"])
    end

    it "shows just the provider requirement before selection" do
      H2code::Setup.progress_steps(H2code::Setup::State.new)
        .map(&.name).should eq(["provider"])
    end
  end

  describe "step_name" do
    it "matches the legacy status-line rendering" do
      H2code::Setup.step_name(H2code::Setup::State.new).should eq("welcome")
      H2code::Setup.step_name(select_provider("moonshot")).should eq("credentials")
      H2code::Setup.step_name(select_provider("moonshot", "sk-stored")).should eq("existing_key")
      H2code::Setup.step_name(select_provider("ollama")).should eq("endpoint")
      H2code::Setup.step_name(complete_state("moonshot")).should eq("done")
    end
  end

  describe "apply_to" do
    it "writes ollama config fields" do
      result = complete("ollama")

      config = H2code::Config::Config.new
      result.apply_to(config)
      config.provider_name.should eq("ollama")
      config.ollama_endpoint.should eq("http://localhost:11434/v1")
      config.ollama_model.should eq("llama3.2")
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

  # The goal projection proved as properties over every registered provider:
  # planning is derived from the fill-level data, every submit closes exactly
  # the head requirement, and the goal is complete exactly when missing is
  # empty. New providers join this matrix automatically via the registry.
  describe "walk — every provider, every entry situation" do
    H2code::Setup.choices.each do |choice|
      it "completes #{choice.name} with defaults, each submit closing the head" do
        state = select_provider(choice.name)
        10.times do
          break if H2code::Setup.missing(state).empty?
          was = H2code::Setup.missing(state)
          head = was.first
          text = head.key? ? "sk-walk" : (head.yolo? ? "n" : "")
          state = submit_step(state, text)
          # A submit closes exactly the head requirement — no more, no less.
          H2code::Setup.missing(state).should eq(was.skip(1))
          state.result?.nil?.should eq(!H2code::Setup.missing(state).empty?)
        end
        H2code::Setup.missing(state).should be_empty
        result = state.result?.not_nil!
        result.provider_name.should eq(choice.name)
        result.endpoint.should eq(choice.default_endpoint)
        result.model.should eq(choice.default_model)
      end

      it "offers keep-or-reconfigure for keyed #{choice.name} with a stored key" do
        next unless choice.needs_key?
        state = select_provider(choice.name, "sk-stored")
        H2code::Setup.missing(state).first?.should eq(H2code::Setup::Requirement::Key)
        # Keep short-circuits the whole goal — the stored config satisfies it.
        state = submit_step(state, "")
        H2code::Setup.missing(state).should be_empty
        state.result?.not_nil!.keep_existing?.should be_true
      end

      it "never plans the Key step for keyless #{choice.name}" do
        next if choice.needs_key?
        H2code::Setup.missing(select_provider(choice.name, "sk-stored"))
          .should_not contain(H2code::Setup::Requirement::Key)
      end
    end
  end
end

# Drive a provider selection to a completed state (declining yolo) and
# return the state, not the Result — for step_name and similar checks.
def complete_state(provider : String) : H2code::Setup::State
  state = select_provider(provider)
  10.times do
    break if H2code::Setup.missing(state).empty?
    head = H2code::Setup.missing(state).first
    text = head.key? ? "sk-walk" : (head.yolo? ? "n" : "")
    state = submit_step(state, text)
  end
  state
end
