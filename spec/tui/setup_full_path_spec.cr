require "../spec_helper"
require "../support/setup_script_driver"

# Full-path setup-wizard specs: drive the App through the same entry point
# the run loop uses (`read_key → handle_key`) with scripted key events —
# arrows over the provider selector, bracketed-paste of the API key, Enter
# through endpoint/model/yolo — and assert on wizard state, the rendered
# transcript, and the config the completed wizard produces.

def strip_setup_ansi(str : String) : String
  str.gsub(/\e\[[0-9;]*[A-Za-z]/, "")
end

def new_setup_app(&on_fetch : H2code::Setup::Wizard -> Array(String))
  input = H2code::TUI::ScriptedInput.new
  app = H2code::TUI::App.new(input: input)
  # Inline model fetch: the selector is open when the key event returns.
  app.setup_fetch_async = false
  app.on_fetch_models_for = on_fetch
  {app, SetupScriptDriver.new(app, input)}
end

describe "setup wizard full path" do
  it "keyed provider: arrows → paste key → defaults → model list → yolo" do
    app, d = new_setup_app { |_w| ["glm-4.6", "glm-4.5"] }
    completed = [] of H2code::Setup::Wizard
    app.on_setup_complete = ->(w : H2code::Setup::Wizard) { completed << w; nil }

    app.start_setup
    app.@provider_list.visible?.should be_true

    # Select zai by arrowing to its position in the registry order.
    idx = H2code::Setup::Wizard.choices.index!(&.name.==("zai"))
    d.down(idx)
    d.hit_enter

    wizard = app.wizard.not_nil!
    wizard.provider_name.should eq("zai")
    wizard.step.should eq(H2code::Setup::Wizard::Step::Credentials)
    app.@provider_list.visible?.should be_false

    # Paste the key like a real terminal delivers it, then submit.
    d.paste("sk-test-123")
    d.hit_enter
    wizard.api_key.should eq("sk-test-123")
    wizard.step.should eq(H2code::Setup::Wizard::Step::Endpoint)

    # Empty Enter keeps the default endpoint.
    d.hit_enter
    wizard.step.should eq(H2code::Setup::Wizard::Step::Model)
    wizard.endpoint.should eq(wizard.current_choice.not_nil!.default_endpoint)

    # The model selector opened synchronously; Enter picks the first entry.
    app.@model_list.visible?.should be_true
    d.hit_enter
    wizard.model.should eq("glm-4.6")
    wizard.step.should eq(H2code::Setup::Wizard::Step::Yolo)

    # Empty Enter on Yolo means trust-by-default.
    d.hit_enter
    wizard.done?.should be_true
    wizard.yolo?.should be_true
    app.setup_mode?.should be_false
    completed.size.should eq(1)

    config = H2code::Config::Config.new
    completed.first.apply_to(config)
    config.provider_name.should eq("zai")
    config.zai_api_key.should eq("sk-test-123")
    config.zai_model.should eq("glm-4.6")
    config.permission_mode.should eq("yolo")
  end

  it "keyless provider: type-to-filter, no key asked, decline yolo" do
    app, d = new_setup_app { |_w| [] of String }
    app.start_setup

    # Fuzzy-filter down to the single ollama entry and commit.
    d.type("ollama")
    d.hit_enter

    wizard = app.wizard.not_nil!
    wizard.provider_name.should eq("ollama")
    wizard.step.should eq(H2code::Setup::Wizard::Step::Endpoint)
    # The transcript explains why no key was asked.
    app.@messages.any? { |m| m.content.includes?("No API key needed") }.should be_true

    d.hit_enter # default endpoint
    d.hit_enter # empty model list → text input, default model
    wizard.step.should eq(H2code::Setup::Wizard::Step::Yolo)
    wizard.model.should eq("llama3.2")

    d.type("n")
    d.hit_enter
    wizard.done?.should be_true
    wizard.yolo?.should be_false

    config = H2code::Config::Config.new
    wizard.apply_to(config)
    config.ollama_endpoint.should eq("http://localhost:11434/v1")
    config.ollama_model.should eq("llama3.2")
    config.permission_mode.should eq("manual")
  end

  it "masks the pasted key on screen and never renders the raw secret" do
    app, d = new_setup_app { |_w| ["glm-4.6"] }
    app.start_setup

    idx = H2code::Setup::Wizard.choices.index!(&.name.==("zai"))
    d.down(idx)
    d.hit_enter
    d.paste("sk-super-secret-value")
    d.hit_enter
    app.wizard.not_nil!.step.should eq(H2code::Setup::Wizard::Step::Endpoint)

    screen = H2code::TUI::TerminalMock.new(rows: 60, cols: 120)
    app.render_to(screen)
    rendered = strip_setup_ansi(screen.visible_rows.join('\n'))
    rendered.should contain("•")
    rendered.should_not contain("sk-super-secret-value")
  end

  it "Enter on an empty editor does not advance the credentials step" do
    app, d = new_setup_app { |_w| [] of String }
    app.start_setup

    idx = H2code::Setup::Wizard.choices.index!(&.name.==("zai"))
    d.down(idx)
    d.hit_enter
    wizard = app.wizard.not_nil!

    d.hit_enter # empty editor — the submit gate must hold
    wizard.step.should eq(H2code::Setup::Wizard::Step::Credentials)
    wizard.api_key.should eq("")

    d.type("sk-typed")
    d.hit_enter
    wizard.api_key.should eq("sk-typed")
    wizard.step.should eq(H2code::Setup::Wizard::Step::Endpoint)
  end

  it "Escape walks back: credentials → provider selector, values cleared" do
    app, d = new_setup_app { |_w| ["glm-4.6"] }
    app.start_setup

    idx = H2code::Setup::Wizard.choices.index!(&.name.==("zai"))
    d.down(idx)
    d.hit_enter
    d.paste("sk-test")
    d.hit_enter # → Endpoint

    d.hit_escape # Endpoint → Credentials
    wizard = app.wizard.not_nil!
    wizard.step.should eq(H2code::Setup::Wizard::Step::Credentials)
    wizard.endpoint.should be_nil

    d.hit_escape # Credentials → provider selector
    wizard.step.should eq(H2code::Setup::Wizard::Step::Welcome)
    wizard.provider_name.should be_nil
    wizard.api_key.should eq("")
    app.@provider_list.visible?.should be_true

    # The selector is usable again: the list still has entries to pick from.
    app.@provider_list.filtered_size.should be > 0
  end
end
