require "../spec_helper"
require "../support/setup_script_driver"

# Regression specs for the runtime setup-wizard re-entry bug (reached via
# /setup): after Esc-back from the key/endpoint steps the provider selector
# re-opened on index 0 (alphabetically first = Cerebras) instead of the
# provider being configured, so a confirming Enter silently re-targeted the
# wizard — the user configured Z.ai and ended up in Cerebras with "no models
# found". See open_setup_provider_selector / back_setup_step in
# src/tui/setup_controller.cr.
def new_runtime_setup_app(&on_fetch : H2code::Setup::Scratch -> Array(String))
  input = H2code::TUI::ScriptedInput.new
  app = H2code::TUI::App.new(input: input)
  app.setup_fetch_async = false
  app.on_fetch_models_for = on_fetch
  {app, SetupScriptDriver.new(app, input)}
end

def missing_head(app) : H2code::Setup::Requirement?
  H2code::Setup.missing(app.wizard.not_nil!).first?
end

describe "setup wizard provider re-entry" do
  it "Esc back re-opens the selector on the provider being configured, not on the first entry" do
    app, d = new_runtime_setup_app { |_scratch| ["glm-4.6"] }
    app.start_setup(first_run: false)

    d.type("zai")
    d.hit_enter # → key step
    state = app.wizard.not_nil!
    state.provider.not_nil!.choice.name.should eq("zai")
    missing_head(app).should eq(H2code::Setup::Requirement::Key)

    d.paste("sk-test")
    d.hit_enter # → Endpoint
    missing_head(app).should eq(H2code::Setup::Requirement::Endpoint)

    d.hit_escape # Endpoint → key step
    d.hit_escape # key step → provider selector
    missing_head(app).should eq(H2code::Setup::Requirement::Provider)
    app.@provider_list.visible?.should be_true

    # The cursor must sit on the provider the user was configuring…
    app.@provider_list.current.to_s.should contain("Z.AI")
    # …so a confirming Enter re-selects it (this used to be Cerebras).
    d.hit_enter
    state = app.wizard.not_nil!
    state.provider.not_nil!.choice.name.should eq("zai")
    missing_head(app).should eq(H2code::Setup::Requirement::Key)
  end

  it "Enter on a filter that matches nothing selects no provider" do
    app, d = new_runtime_setup_app { |_scratch| [] of String }
    app.start_setup

    d.type("zzzz") # fuzzy query that matches nothing
    d.hit_enter

    # The selector stays open and nothing is selected — previously this
    # silently fell back to choices.first (Cerebras) and started its setup.
    app.@provider_list.visible?.should be_true
    missing_head(app).should eq(H2code::Setup::Requirement::Provider)
  end
end
