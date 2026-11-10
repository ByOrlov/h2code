require "../spec_helper"
require "../support/setup_script_driver"

# Full-path specs for the runtime setup wizard (reached via /setup): the
# model-fetch callback receives the wizard's collected key, and a failed or
# empty fetch falls back to the model text input instead of restarting the
# wizard. Driven through ScriptedInput + App#handle_key — the exact path the
# main run loop takes.
def new_setup_wizard_app(&on_fetch : H2code::Setup::Scratch -> Array(String))
  input = H2code::TUI::ScriptedInput.new
  app = H2code::TUI::App.new(input: input)
  app.setup_fetch_async = false
  app.on_fetch_models_for = on_fetch
  app.start_setup(first_run: false)
  {app, SetupScriptDriver.new(app, input)}
end

def missing_head(app) : H2code::Setup::Requirement?
  H2code::Setup.missing(app.wizard.not_nil!).first?
end

describe H2code::TUI::App do
  it "passes the wizard's collected key to the model-fetch callback" do
    seen_key = ""
    app, d = new_setup_wizard_app do |scratch|
      seen_key = scratch.api_key || ""
      ["glm-4.6"]
    end

    d.type("zai")
    d.hit_enter # → key step
    missing_head(app).should eq(H2code::Setup::Requirement::Key)
    d.paste("sk-just-entered")
    d.hit_enter # → endpoint step
    d.hit_enter # endpoint default → model step, fetch runs inline
    missing_head(app).should eq(H2code::Setup::Requirement::Model)

    app.@model_list.visible?.should be_true
    seen_key.should eq("sk-just-entered")
  end

  it "falls back to the model text input when the fetch raises, instead of restarting the wizard" do
    app, d = new_setup_wizard_app do |_scratch|
      raise H2code::LLM::ProviderConfigError.new("no credentials in config")
    end

    d.type("zai")
    d.hit_enter # → key step
    d.paste("sk-just-entered")
    d.hit_enter # → endpoint step
    d.hit_enter # endpoint default → model step, fetch raises

    # The wizard stays on the Model step with everything collected intact —
    # no restart back to provider selection (the old infinite-loop path).
    state = app.wizard.not_nil!
    missing_head(app).should eq(H2code::Setup::Requirement::Model)
    state.key.not_nil!.value.should eq("sk-just-entered")
    state.provider.not_nil!.choice.name.should eq("zai")
    app.@provider_list.visible?.should be_false
    app.@model_list.visible?.should be_false
    app.setup_mode?.should be_true

    # The user can still finish setup by typing a model name.
    d.type("glm-4.6")
    d.hit_enter
    missing_head(app).should eq(H2code::Setup::Requirement::Yolo)
  end

  it "falls back to the model text input when the fetch returns an empty list" do
    app, d = new_setup_wizard_app { |_scratch| [] of String }

    d.type("zai")
    d.hit_enter # → key step
    d.paste("sk-just-entered")
    d.hit_enter # → endpoint step
    d.hit_enter # endpoint default → model step, empty list

    state = app.wizard.not_nil!
    missing_head(app).should eq(H2code::Setup::Requirement::Model)
    state.key.not_nil!.value.should eq("sk-just-entered")
    app.@provider_list.visible?.should be_false
  end
end
