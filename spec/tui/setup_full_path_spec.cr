require "../spec_helper"
require "../support/setup_script_driver"

# Full-path setup-wizard specs: drive the App through the same entry point
# the run loop uses (`read_key → handle_key`) with scripted key events —
# arrows over the provider selector, bracketed-paste of the API key, Enter
# through endpoint/model/yolo — and assert on the fill-level state, the
# rendered transcript, and the config the completed wizard produces.
#
# `app.wizard` is the accumulated fill-state (immutable struct): re-fetch it
# before asserting.

def strip_setup_ansi(str : String) : String
  str.gsub(/\e\[[0-9;]*[A-Za-z]/, "")
end

def new_setup_app(&on_fetch : H2code::Setup::Scratch -> Array(String))
  input = H2code::TUI::ScriptedInput.new
  app = H2code::TUI::App.new(input: input)
  # Inline model fetch: the selector is open when the key event returns.
  app.setup_fetch_async = false
  app.on_fetch_models_for = on_fetch
  {app, SetupScriptDriver.new(app, input)}
end

# Head of the planner's missing list for the app's current fill-state.
def missing_head(app) : H2code::Setup::Requirement?
  H2code::Setup.missing(app.wizard.not_nil!).first?
end

# Spec-only wrapper: `obj.@ivar` is read-only from outside, so a stale error
# status is injected through a subclass method.
class SetupStatusApp < H2code::TUI::App
  def force_error_status
    @agent_status = H2code::TUI::AgentStatus::Error
  end
end

describe "setup wizard full path" do
  it "keyed provider: arrows → paste key → defaults → model list → yolo" do
    app, d = new_setup_app { |_scratch| ["glm-4.6", "glm-4.5"] }
    completed = [] of H2code::Setup::Result
    app.on_setup_complete = ->(r : H2code::Setup::Result) { completed << r; nil }

    app.start_setup
    app.@provider_list.visible?.should be_true

    # Select zai by arrowing to its position in the registry order.
    idx = H2code::Setup.choices.index!(&.name.==("zai"))
    d.down(idx)
    d.hit_enter

    state = app.wizard.not_nil!
    state.provider.not_nil!.choice.name.should eq("zai")
    missing_head(app).should eq(H2code::Setup::Requirement::Key)
    app.@provider_list.visible?.should be_false

    # Paste the key like a real terminal delivers it, then submit.
    d.paste("sk-test-123")
    d.hit_enter
    state = app.wizard.not_nil!
    missing_head(app).should eq(H2code::Setup::Requirement::Endpoint)
    state.key.not_nil!.value.should eq("sk-test-123")

    # Empty Enter keeps the default endpoint.
    d.hit_enter
    state = app.wizard.not_nil!
    missing_head(app).should eq(H2code::Setup::Requirement::Model)
    default_endpoint = H2code::Setup.choices.find!(&.name.==("zai")).default_endpoint
    state.endpoint.not_nil!.value.should eq(default_endpoint)

    # The model selector opened synchronously; Enter picks the first entry.
    app.@model_list.visible?.should be_true
    d.hit_enter
    state = app.wizard.not_nil!
    missing_head(app).should eq(H2code::Setup::Requirement::Yolo)
    state.model.not_nil!.value.should eq("glm-4.6")

    # Empty Enter on Yolo means trust-by-default.
    d.hit_enter
    H2code::Setup.missing(app.wizard.not_nil!).should be_empty
    app.setup_mode?.should be_false
    completed.size.should eq(1)
    completed.first.yolo?.should be_true

    config = H2code::Config::Config.new
    completed.first.apply_to(config)
    config.provider_name.should eq("zai")
    config.zai_api_key.should eq("sk-test-123")
    config.zai_model.should eq("glm-4.6")
    config.permission_mode.should eq("yolo")
  end

  it "keyless provider: type-to-filter, no key asked, decline yolo" do
    app, d = new_setup_app { |_scratch| [] of String }
    app.start_setup

    # Fuzzy-filter down to the single ollama entry and commit.
    d.type("ollama")
    d.hit_enter

    state = app.wizard.not_nil!
    state.provider.not_nil!.choice.name.should eq("ollama")
    # Key is never a requirement for ollama — the planner goes to Endpoint.
    missing_head(app).should eq(H2code::Setup::Requirement::Endpoint)
    # The transcript explains why no key was asked.
    app.@messages.any? { |m| m.content.includes?("No API key needed") }.should be_true

    d.hit_enter # default endpoint
    d.hit_enter # empty model list → text input, default model
    state = app.wizard.not_nil!
    missing_head(app).should eq(H2code::Setup::Requirement::Yolo)
    state.model.not_nil!.value.should eq("llama3.2")

    d.type("n")
    d.hit_enter
    H2code::Setup.missing(app.wizard.not_nil!).should be_empty

    config = H2code::Config::Config.new
    app.wizard.not_nil!.result?.not_nil!.apply_to(config)
    config.ollama_endpoint.should eq("http://localhost:11434/v1")
    config.ollama_model.should eq("llama3.2")
    config.permission_mode.should eq("manual")
  end

  it "masks the pasted key on screen and never renders the raw secret" do
    app, d = new_setup_app { |_scratch| ["glm-4.6"] }
    app.start_setup

    idx = H2code::Setup.choices.index!(&.name.==("zai"))
    d.down(idx)
    d.hit_enter
    d.paste("sk-super-secret-value")
    d.hit_enter
    missing_head(app).should eq(H2code::Setup::Requirement::Endpoint)

    screen = H2code::TUI::TerminalMock.new(rows: 60, cols: 120)
    app.render_to(screen)
    rendered = strip_setup_ansi(screen.visible_rows.join('\n'))
    rendered.should contain("•")
    rendered.should_not contain("sk-super-secret-value")
  end

  it "Enter on an empty editor does not advance the key step" do
    app, d = new_setup_app { |_scratch| [] of String }
    app.start_setup

    idx = H2code::Setup.choices.index!(&.name.==("zai"))
    d.down(idx)
    d.hit_enter

    d.hit_enter # empty editor — the submit gate must hold
    missing_head(app).should eq(H2code::Setup::Requirement::Key)

    d.type("sk-typed")
    d.hit_enter
    state = app.wizard.not_nil!
    missing_head(app).should eq(H2code::Setup::Requirement::Endpoint)
    state.key.not_nil!.value.should eq("sk-typed")
  end

  it "renders the goal view for the current step, never the error branch" do
    input = H2code::TUI::ScriptedInput.new
    app = SetupStatusApp.new(input: input)
    app.setup_fetch_async = false
    app.on_fetch_models_for = ->(_s : H2code::Setup::Scratch) { ["glm-4.6"] }
    d = SetupScriptDriver.new(app, input)

    app.start_setup

    idx = H2code::Setup.choices.index!(&.name.==("zai"))
    d.down(idx)
    d.hit_enter
    d.paste("sk-test")
    d.hit_enter # → Endpoint

    # Simulate a stale error status from before the wizard (e.g. a failed
    # provider switch): the goal view must render, not "✗ Setup: …".
    app.force_error_status

    screen = H2code::TUI::TerminalMock.new(rows: 60, cols: 120)
    app.render_to(screen)
    rendered = strip_setup_ansi(screen.visible_rows.join('\n'))
    # Provider being configured, closed key, current endpoint step — as
    # separated segments, not glued together.
    rendered.should contain("Z.AI")
    rendered.should contain("key ✓")
    rendered.should contain("▶ endpoint")
    rendered.should contain("│")
    rendered.should_not contain("✗")
  end

  it "/setup re-runs the wizard from provider selection, in runtime mode" do
    app, d = new_setup_app { |_s| [] of String }

    d.type("/setup")
    d.hit_enter

    # The wizard opens at the provider step — even though a provider may
    # already be configured: /setup is the explicit rewrite path.
    app.@provider_list.visible?.should be_true
    missing_head(app).should eq(H2code::Setup::Requirement::Provider)

    # Runtime mode: Esc leaves setup mode instead of aborting the app
    # (first-run mode would set @running = false here).
    d.hit_escape
    app.setup_mode?.should be_false
  end

  it "Escape walks back: key step → provider selector, values cleared" do
    app, d = new_setup_app { |_scratch| ["glm-4.6"] }
    app.start_setup

    idx = H2code::Setup.choices.index!(&.name.==("zai"))
    d.down(idx)
    d.hit_enter
    d.paste("sk-test")
    d.hit_enter # → Endpoint

    d.hit_escape # Endpoint → Key step
    state = app.wizard.not_nil!
    missing_head(app).should eq(H2code::Setup::Requirement::Key)
    state.key.should be_nil

    d.hit_escape # Key step → provider selector
    missing_head(app).should eq(H2code::Setup::Requirement::Provider)
    app.wizard.not_nil!.provider.should be_nil
    app.@provider_list.visible?.should be_true

    # The selector is usable again: the list still has entries to pick from.
    app.@provider_list.filtered_size.should be > 0
  end
end
