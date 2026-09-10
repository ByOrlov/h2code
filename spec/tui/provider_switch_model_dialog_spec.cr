require "../spec_helper"
require "../../src/tui/app"

# Private handlers are reachable from a subclass — this spec-only wrapper
# drives /provider the same way the slash dispatcher does.
class ProviderSwitchApp < H2code::TUI::App
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

  def model_list
    @model_list
  end
end

# Wait for the async model-fetch fiber (open_model_selector spawns) to finish.
def provider_switch_wait_until(timeout_ms = 1000, &)
  deadline = Time.monotonic + timeout_ms.milliseconds
  until yield
    Fiber.yield
    return false if Time.monotonic > deadline
    sleep 1.millisecond
  end
  true
end

describe H2code::TUI::App do
  it "opens the model selector after switching provider, positioned on the saved model" do
    app = ProviderSwitchApp.new
    switched_to = nil
    app.on_provider_configured = ->(_name : String) : Bool { true }
    app.on_provider_change = ->(name : String) : Bool do
      switched_to = name
      # Mirrors the real callback in h2code.cr: after the swap the app model
      # becomes the provider's saved/default model.
      app.model = "glm-4.6"
      true
    end
    app.on_fetch_models = -> : Array(String) { ["glm-4.5", "glm-4.6", "glm-5.2"] }

    app.provider_name.should eq("moonshot")
    app.open_provider
    app.select_provider("zai")
    app.provider_enter

    switched_to.should eq("zai")
    app.provider_name.should eq("zai")

    # The fetch runs in a spawned fiber; wait for the selector to appear.
    provider_switch_wait_until { app.model_list.visible? }.should be_true
    app.model_list.visible?.should be_true
    # Positioned on the provider's saved model, not on the first entry.
    app.model_list.current.should eq("glm-4.6")
  end

  it "does not open the model selector when the provider switch fails" do
    app = ProviderSwitchApp.new
    app.on_provider_configured = ->(_name : String) : Bool { true }
    app.on_provider_change = ->(_name : String) : Bool { false }
    app.on_fetch_models = -> : Array(String) { ["glm-4.5"] }

    app.open_provider
    app.select_provider("zai")
    app.provider_enter

    app.provider_name.should eq("moonshot")
    # Give the (absent) fetch fiber a chance to run before asserting.
    10.times { Fiber.yield }
    app.model_list.visible?.should be_false
  end
end
