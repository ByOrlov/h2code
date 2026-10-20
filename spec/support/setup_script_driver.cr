require "../../src/tui/scripted_input"

# Full-path driver for setup-wizard specs: enqueues key events into a
# `ScriptedInput` and pumps them through `App#handle_key` — the exact path
# the main run loop takes (`key = @input.read_key; handle_key(key)`), so
# every gate (Enter on empty editor, paste handling, Esc-back, selector
# input) is exercised for real.
class SetupScriptDriver
  getter input : H2code::TUI::ScriptedInput

  def initialize(@app : H2code::TUI::App, @input : H2code::TUI::ScriptedInput)
  end

  # Type text character by character (editor input / selector fuzzy filter).
  def type(text : String) : Nil
    text.each_char { |c| press(H2code::TUI::KeyEvent.char(c)) }
  end

  # Bracketed-paste event, as the terminal delivers a pasted API key.
  def paste(text : String) : Nil
    press(H2code::TUI::KeyEvent.paste(text))
  end

  def hit(key : H2code::TUI::Key) : Nil
    press(H2code::TUI::KeyEvent.new(key))
  end

  def hit_enter : Nil
    hit(H2code::TUI::Key::Enter)
  end

  def hit_escape : Nil
    hit(H2code::TUI::Key::Escape)
  end

  def down(times : Int32 = 1) : Nil
    times.times { hit(H2code::TUI::Key::Down) }
  end

  # Queue an event and immediately pump the input queue, mirroring one (or
  # more) iterations of the main run loop.
  private def press(key : H2code::TUI::KeyEvent) : Nil
    @input.enqueue(key)
    while k = @input.read_key
      @app.handle_key(k)
    end
  end
end
