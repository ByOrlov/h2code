require "../spec_helper"
require "../support/setup_script_driver"

# Regression specs for the runtime /provider → setup-wizard re-entry bug:
# after Esc-back from the credentials/endpoint steps the provider selector
# re-opened on index 0 (alphabetically first = Cerebras) instead of the
# provider being configured, so a confirming Enter silently re-targeted the
# wizard — the user configured Z.ai and ended up in Cerebras with
# "no models found". See open_setup_provider_selector /
# handle_setup_provider_key in src/tui/setup_controller.cr.
class RuntimeProviderApp < H2code::TUI::App
  def open_provider
    open_provider_selector
  end
end

def new_runtime_setup_app(&on_fetch : H2code::Setup::Wizard -> Array(String))
  input = H2code::TUI::ScriptedInput.new
  app = RuntimeProviderApp.new(input: input)
  app.setup_fetch_async = false
  app.on_fetch_models_for = on_fetch
  # Only zai is unconfigured: /provider on it launches the setup wizard.
  app.on_provider_configured = ->(name : String) { name != "zai" }
  {app, SetupScriptDriver.new(app, input)}
end

describe "setup wizard /provider re-entry" do
  it "Esc back re-opens the selector on the provider being configured, not on the first entry" do
    app, d = new_runtime_setup_app { |_w| ["glm-4.6"] }

    app.open_provider
    d.type("zai")
    d.hit_enter # → start_setup_for_provider("zai"), Credentials step
    wizard = app.wizard.not_nil!
    wizard.provider_name.should eq("zai")

    d.paste("sk-test")
    d.hit_enter # → Endpoint
    wizard.step.should eq(H2code::Setup::Wizard::Step::Endpoint)

    d.hit_escape # Endpoint → Credentials
    d.hit_escape # Credentials → provider selector
    wizard.step.should eq(H2code::Setup::Wizard::Step::Welcome)
    app.@provider_list.visible?.should be_true

    # The cursor must sit on the provider the user was configuring…
    app.@provider_list.current.to_s.should contain("Z.AI")
    # …so a confirming Enter re-selects it (this used to be Cerebras).
    d.hit_enter
    wizard.provider_name.should eq("zai")
    wizard.step.should eq(H2code::Setup::Wizard::Step::Credentials)
  end

  it "Enter on a filter that matches nothing selects no provider" do
    app, d = new_runtime_setup_app { |_w| [] of String }
    app.start_setup

    d.type("zzzz") # fuzzy query that matches nothing
    d.hit_enter

    # The selector stays open and nothing is selected — previously this
    # silently fell back to choices.first (Cerebras) and started its setup.
    app.@provider_list.visible?.should be_true
    wizard = app.wizard.not_nil!
    wizard.provider_name.should be_nil
    wizard.step.should eq(H2code::Setup::Wizard::Step::Welcome)
  end
end
