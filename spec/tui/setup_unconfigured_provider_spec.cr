require "../spec_helper"
require "../../src/tui/app"

# Private handlers are reachable from a subclass — this spec-only wrapper
# drives the runtime setup wizard (started when /provider picks an
# unconfigured provider) the same way the input dispatcher does.
class SetupWizardApp < H2code::TUI::App
  def open_provider
    open_provider_selector
  end

  def provider_enter
    handle_provider_key(H2code::TUI::KeyEvent.new(H2code::TUI::Key::Enter))
  end

  def select_provider(name : String)
    list = @provider_list
    list.selected = list.items.index(name) || 0
  end

  def setup_text(text : String)
    submit_setup_text(text)
  end

  def provider_list
    @provider_list
  end

  def model_list
    @model_list
  end

  def status
    @status
  end
end

# Wait for the async model-fetch fiber (fetch_setup_models spawns) to finish.
def setup_wait_until(timeout_ms = 1000, &)
  deadline = Time.monotonic + timeout_ms.milliseconds
  until yield
    Fiber.yield
    return false if Time.monotonic > deadline
    sleep 1.millisecond
  end
  true
end

describe H2code::TUI::App do
  it "passes the wizard's collected key to the model-fetch callback" do
    app = SetupWizardApp.new
    seen_key = ""
    app.on_provider_configured = ->(_name : String) : Bool { false }
    app.on_fetch_models_for = ->(wizard : H2code::Setup::Wizard) : Array(String) do
      seen_key = wizard.api_key
      ["glm-4.6"]
    end

    app.open_provider
    app.select_provider("zai")
    app.provider_enter

    app.wizard.not_nil!.step.should eq(H2code::Setup::Wizard::Step::Credentials)
    app.setup_text("sk-just-entered")
    app.setup_text("") # endpoint default
    app.wizard.not_nil!.step.should eq(H2code::Setup::Wizard::Step::Model)

    setup_wait_until { app.model_list.visible? }.should be_true
    seen_key.should eq("sk-just-entered")
  end

  it "falls back to the model text input when the fetch raises, instead of restarting the wizard" do
    app = SetupWizardApp.new
    app.on_provider_configured = ->(_name : String) : Bool { false }
    app.on_fetch_models_for = ->(_wizard : H2code::Setup::Wizard) : Array(String) do
      raise H2code::LLM::ProviderConfigError.new("no credentials in config")
    end

    app.open_provider
    app.select_provider("zai")
    app.provider_enter
    app.setup_text("sk-just-entered")
    app.setup_text("") # endpoint default

    setup_wait_until { app.status != "Loading models..." }.should be_true

    wizard = app.wizard.not_nil!
    # The wizard stays on the Model step with everything collected intact —
    # no restart back to provider selection (the old infinite-loop path).
    wizard.step.should eq(H2code::Setup::Wizard::Step::Model)
    wizard.api_key.should eq("sk-just-entered")
    wizard.provider_name.should eq("zai")
    app.provider_list.visible?.should be_false
    app.model_list.visible?.should be_false
    app.setup_mode?.should be_true

    # The user can still finish setup by typing a model name.
    app.setup_text("glm-4.6")
    app.wizard.not_nil!.step.should eq(H2code::Setup::Wizard::Step::Yolo)
  end

  it "falls back to the model text input when the fetch returns an empty list" do
    app = SetupWizardApp.new
    app.on_provider_configured = ->(_name : String) : Bool { false }
    app.on_fetch_models_for = ->(_wizard : H2code::Setup::Wizard) : Array(String) { [] of String }

    app.open_provider
    app.select_provider("zai")
    app.provider_enter
    app.setup_text("sk-just-entered")
    app.setup_text("") # endpoint default

    setup_wait_until { app.status != "Loading models..." }.should be_true

    wizard = app.wizard.not_nil!
    wizard.step.should eq(H2code::Setup::Wizard::Step::Model)
    wizard.api_key.should eq("sk-just-entered")
    app.provider_list.visible?.should be_false
  end
end
