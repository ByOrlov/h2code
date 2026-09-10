require "../spec_helper"
require "file_utils"
require "../../src/tui/component"
require "../../src/tui/text"
require "../../src/tui/spinner"
require "../../src/tui/editor"
require "../../src/tui/markdown"
require "../../src/tui/select_list"
require "../../src/tui/diff"
require "../../src/tui/help_panel"
require "../../src/tui/terminal_mock"
require "../../src/tui/app"

def app_strip_ansi(str : String) : String
  str.gsub(/\e\[[0-9;]*m/, "")
end

def app_render_lines(app : H2code::TUI::App, width = 80) : Array(String)
  # App#build_rendered_lines is private; reach the same output through render_message.
  app.@messages.flat_map { |msg| app.render_message(msg, width) }
end

def help_strip_ansi(str : String) : String
  str.gsub(/\e\[[0-9;]*m/, "")
end

# Private handlers are reachable from a subclass — this spec-only wrapper
# drives /search the same way the slash dispatcher does.
class SearchApp < H2code::TUI::App
  def run_cmd_search
    cmd_search
  end
end

# Spec-only wrapper exposing the private submit path (placeholder → parts
# resolution → turn callback) for end-to-end paste-pipeline tests.
class SubmitApp < H2code::TUI::App
  def submit(text : String) : Nil
    submit_message(text)
  end
end

describe H2code::TUI::App do
  it "routes parallel tool results to the correct messages" do
    app = H2code::TUI::App.new

    app.add_message("user", "hello")
    app.on_event(H2code::Loop::Event.tool_call_start("c1", H2code::Tools::Names::GLOB, %({"pattern":"*.cr"})))
    app.on_event(H2code::Loop::Event.tool_call_start("c2", H2code::Tools::Names::BASH, %({"command":"echo hi"})))

    # Results arrive in reverse order; the handler must still find c1.
    app.on_event(H2code::Loop::Event.tool_result("c2", "hi", false))
    app.on_event(H2code::Loop::Event.tool_result("c1", "a.cr", false))

    glob = app.@messages.find { |m| m.role == "tool" && m.tool_call_id == "c1" }
    bash = app.@messages.find { |m| m.role == "tool" && m.tool_call_id == "c2" }

    glob.should_not be_nil
    bash.should_not be_nil
    if (g = glob) && (b = bash)
      g.tool_result.should eq("a.cr")
      b.tool_result.should eq("hi")
    end
  end

  # Regression: on_event must render synchronously via render_now so every
  # state change is drawn before the next event is processed. Without this,
  # a tool_call_start + tool_result arriving between two main-loop iterations
  # would skip the active zone entirely and jump straight to the log.
  #
  # This test verifies the state transitions that render_now makes visible:
  # after tool_call_start, the tool is pending (active zone); after
  # tool_result, it has migrated to the log zone. The @dirty flag is checked
  # to confirm on_event processes events (sets dirty=true at the end).
  it "tool transitions through active zone before log" do
    app = H2code::TUI::App.new

    # tool_call_start → tool is pending (no result), goes to active zone.
    app.on_event(H2code::Loop::Event.tool_call_start("c1", H2code::Tools::Names::READ, %({"path":"f.ts"})))
    tool = app.@messages.find { |m| m.role == "tool" && m.tool_call_id == "c1" }
    tool.should_not be_nil
    (tool || raise "tool should not be nil").tool_result.should be_nil

    # build_rendered_lines places it in the active zone (after log_lines).
    lines, _editor_line, log_size = app.build_rendered_lines(80)
    active_lines = lines[log_size..]
    active_stripped = active_lines.map { |l| app_strip_ansi(l) }
    active_stripped.join('\n').should contain("Using")

    # tool_result → tool now has result, goes to log zone.
    app.on_event(H2code::Loop::Event.tool_result("c1", "content", false))
    tool = app.@messages.find { |m| m.role == "tool" && m.tool_call_id == "c1" }
    (tool || raise "tool should not be nil").tool_result.should eq("content")

    # build_rendered_lines now places it in the log zone.
    lines2, _editor_line2, log_size2 = app.build_rendered_lines(80)
    log_lines2 = lines2[0...log_size2]
    active_lines2 = lines2[log_size2..]
    log_stripped = log_lines2.map { |l| app_strip_ansi(l) }
    log_stripped.join('\n').should contain("Used")
    # Active zone should NOT contain the completed tool.
    active_stripped2 = active_lines2.map { |l| app_strip_ansi(l) }
    active_stripped2.join('\n').should_not contain("Using Read")
  end

  # A fully-completed TodoList must migrate from the active zone into the log:
  # the live panel is frozen as a `todo_snapshot` message (rendered identically
  # to the panel) and the tool's state is cleared so a fresh list can start.
  # Partially-done lists stay in the active zone. See `snapshot_todo_if_complete!`.
  it "snapshots a fully-done TodoList into the log and clears it" do
    app = H2code::TUI::App.new
    todos = [] of {String, String}

    app.on_fetch_todos = -> : Array({String, String})? do
      todos.empty? ? nil : todos
    end
    app.on_clear_todos = -> : Nil do
      todos.clear
      nil
    end

    # Partially done → stays in the active zone, no snapshot.
    todos.replace([{"Task A", "done"}, {"Task B", "in_progress"}])
    app.on_event(H2code::Loop::Event.tool_call_start("t1", H2code::Tools::Names::TODO_LIST, %({"todos":[]})))
    app.on_event(H2code::Loop::Event.tool_result("t1", "ok", false))
    app.@messages.any? { |m| m.role == "todo_snapshot" }.should be_false
    todos.should_not be_empty

    # All done → snapshot appended, tool cleared.
    todos.replace([{"Task A", "done"}, {"Task B", "done"}])
    app.on_event(H2code::Loop::Event.tool_call_start("t2", H2code::Tools::Names::TODO_LIST, %({"todos":[]})))
    app.on_event(H2code::Loop::Event.tool_result("t2", "ok", false))

    snapshot = app.@messages.find { |m| m.role == "todo_snapshot" }
    snapshot.should_not be_nil
    if s = snapshot
      s.todo_items.should eq([{"Task A", "done"}, {"Task B", "done"}])
    end
    todos.should be_empty

    # The snapshot renders in the LOG zone (with the Todos header), and the
    # active zone no longer holds the live panel.
    lines, _editor_line, log_size = app.build_rendered_lines(80)
    log_stripped = lines[0...log_size].map { |l| app_strip_ansi(l) }
    active_stripped = lines[log_size..].map { |l| app_strip_ansi(l) }
    log_stripped.join('\n').should contain("Todos (2/2)")
    log_stripped.join('\n').should contain("✓ Task A")
    active_stripped.join('\n').should_not contain("Todos (2/2)")
  end

  it "on_event sets dirty after processing" do
    app = H2code::TUI::App.new
    app.on_event(H2code::Loop::Event.step_begin(0))
    app.@dirty.should be_true
  end

  # Regression: an exception raised inside the run_turn fiber (e.g. a store
  # append failing before the agent loop's begin/ensure) must not leave the
  # app stuck in Busy — the safety net reports the error and runs the
  # turn_end cleanup so the user can keep typing.
  it "resets busy and surfaces the error when the turn fiber crashes" do
    app = H2code::TUI::App.new
    app.run_turn_cb = ->(_text : String, _persisted : Bool, _parts : Array(H2code::LLM::ContentPart)?) { raise "boom" }

    app.deliver_external_prompt("hello")
    app.agent_busy?.should be_true

    deadline = Time.monotonic + 2.seconds
    while app.agent_busy? && Time.monotonic < deadline
      sleep 5.milliseconds
    end

    app.agent_busy?.should be_false
    app.@messages.any? { |m| m.role == "error" && m.content.includes?("boom") }.should be_true
  end

  # End-to-end paste pipeline: a submitted message carrying a media
  # placeholder resolves against the app's media store and the turn callback
  # receives native image content parts alongside the display text.
  it "delivers pasted media placeholders to the turn callback as parts" do
    app = SubmitApp.new

    png = Bytes.new(24, 0)
    png[0] = 0x89
    png[1] = 0x50
    app.media_store.add_image(png, "image/png", 800, 600)

    received = Channel({String, Array(H2code::LLM::ContentPart)?}).new
    app.run_turn_cb = ->(text : String, _persisted : Bool, parts : Array(H2code::LLM::ContentPart)?) : Nil do
      received.send({text, parts})
    end

    app.submit("look at [image #1 (800×600)]")

    text, parts = received.receive
    text.should contain("[image #1")
    parts.should_not be_nil
    if p = parts
      p.any?(H2code::LLM::ImageContent).should be_true
      p.any? { |part| part.is_a?(H2code::LLM::TextContent) && part.as(H2code::LLM::TextContent).text.includes?("look at") }.should be_true
    end
  end

  # Regression: assistant_text delivered without preceding text_delta must still
  # be committed to the transcript. Otherwise a large finalized block (e.g. a
  # plan) emitted straight into the Log zone would silently disappear.
  it "finalizes assistant_text into the log zone even without streaming deltas" do
    app = H2code::TUI::App.new
    plan = (1..30).map { |i| "#{i}. plan line" }.join("\n")

    app.on_event(H2code::Loop::Event.assistant_text(plan))

    app.@messages.size.should eq(1)
    app.@messages[0].role.should eq("assistant")
    app.@messages[0].content.should eq(plan)

    lines, _editor_line, log_size = app.build_rendered_lines(80)
    active_lines = lines[log_size..]
    active_stripped = active_lines.map { |l| app_strip_ansi(l) }
    active_stripped.join('\n').should_not contain("plan line")
  end

  # Regression: broken-token markdown streaming must not shrink the Active zone.
  # When a list marker is split across chunks ("\n-" followed by " Item N")
  # the transient "-" was rendered as a paragraph with a blank separator;
  # the next token re-absorbed it into a list item and the blank line vanished,
  # causing SyncBugsCount to increment.
  it "keeps SyncBugsCount at zero for broken-token markdown list streaming" do
    app = H2code::TUI::App.new
    app.debug_zones = true
    app.on_event(H2code::Loop::Event.step_begin(0))

    chunks = [
      "Here ", "is ", "a ", "broken-token ", "markdown ", "list:\n", "\n",
      "- Item 1",
      "\n-", " Item 2",
      "\n-", " Item 3",
      "\n-", " Item 4",
      "\n-", " Item 5",
      "\n-", " Item 6",
      "\n-", " Item 7",
      "\n-", " Item 8",
      "\n-", " Item 9",
      "\n-", " Item 10",
      "\n\n",
      "Streaming complete.",
    ]

    chunks.each do |chunk|
      app.on_event(H2code::Loop::Event.text_delta(chunk))
      app.build_rendered_lines(80)
    end

    app.@sync_bugs_count.should eq(0)
  end
end

describe H2code::TUI::SelectList do
  it "shows all items when they fit within max_visible" do
    list = H2code::TUI::SelectList.new
    list.show("Pick", ["a", "b", "c"])
    list.max_visible = 8
    start, count = list.visible_window
    start.should eq(0)
    count.should eq(3)
    list.scrolled_up?.should be_false
    list.scrolled_down?.should be_false
  end

  it "scrolls down when the selection moves past the viewport bottom" do
    list = H2code::TUI::SelectList.new
    items = (1..12).map(&.to_s).to_a
    list.show("Pick", items)
    list.max_visible = 5
    list.selected = 7
    start, count = list.visible_window
    count.should eq(5)
    start.should eq(3)
    list.scrolled_up?.should be_true
    list.scrolled_down?.should be_true
  end

  it "scrolls to the last page when selection is near the end" do
    list = H2code::TUI::SelectList.new
    items = (1..10).map(&.to_s).to_a
    list.show("Pick", items)
    list.max_visible = 5
    list.selected = 9
    start, count = list.visible_window
    start.should eq(5)
    count.should eq(5)
    list.scrolled_up?.should be_true
    list.scrolled_down?.should be_false
  end

  it "wraps around with scrolled_up false on selection 0" do
    list = H2code::TUI::SelectList.new
    items = (1..10).map(&.to_s).to_a
    list.show("Pick", items)
    list.max_visible = 5
    list.selected = 0
    start, _count = list.visible_window
    start.should eq(0)
    list.scrolled_up?.should be_false
    list.scrolled_down?.should be_true
  end

  it "resets scroll when show is called" do
    list = H2code::TUI::SelectList.new
    items = (1..10).map(&.to_s).to_a
    list.show("Pick", items)
    list.max_visible = 5
    list.selected = 9
    list.visible_window
    list.show("Pick2", ["x", "y"])
    start, count = list.visible_window
    start.should eq(0)
    count.should eq(2)
  end
end

describe H2code::TUI::App do
  it "rebuilds the transcript from a replayed context memory" do
    app = H2code::TUI::App.new
    app.add_message("user", "old conversation that should be cleared")

    memory = H2code::Context::Memory.new
    memory.add_user("hello")
    memory.add_assistant("world")
    app.load_transcript_from(memory)

    app.@messages.size.should eq(2)
    app.@messages[0].role.should eq("user")
    app.@messages[0].content.should eq("hello")
    app.@messages[1].role.should eq("assistant")
    app.@messages[1].content.should eq("world")
  end

  it "maps tool calls and tool results in the rebuilt transcript" do
    app = H2code::TUI::App.new
    memory = H2code::Context::Memory.new
    memory.add_user("list files")
    memory.add_assistant("", [H2code::LLM::ToolCall.new(
      "tc1",
      H2code::LLM::ToolCallFunction.new(H2code::Tools::Names::GLOB, %({"pattern":"*.cr"}))
    )])
    memory.add_tool_result("tc1", "a.cr\nb.cr")
    app.load_transcript_from(memory)

    roles = app.@messages.map(&.role)
    roles.should eq(["user", "tool"])
    tool_msg = app.@messages.find { |m| m.role == "tool" } || raise "tool message not found"
    tool_msg.tool_call_id.should eq("tc1")
    tool_msg.tool_name.should eq(H2code::Tools::Names::GLOB)
    tool_msg.tool_result.should eq("a.cr\nb.cr")
  end

  it "skips injection messages when rebuilding the transcript" do
    app = H2code::TUI::App.new
    memory = H2code::Context::Memory.new
    memory.add_injection("system prompt injected for tooling")
    memory.add_user("real user message")
    app.load_transcript_from(memory)

    app.@messages.size.should eq(1)
    app.@messages[0].role.should eq("user")
    app.@messages[0].content.should eq("real user message")
  end

  it "renders compaction summaries as system messages" do
    app = H2code::TUI::App.new
    memory = H2code::Context::Memory.new
    memory.add_user("first turn")
    memory.add_assistant("response")
    memory.apply_compaction("[summary of earlier turns]", [] of H2code::Context::ContextMessage)
    app.load_transcript_from(memory)

    sys_msg = app.@messages.find { |m| m.role == "system" }
    sys_msg.should_not be_nil
    (sys_msg || raise "sys_msg should not be nil").content.should contain("[compacted]")
  end
end

describe H2code::TUI::App do
  it "splits a multi-line system message into one render line per source line" do
    # Regression: the renderer invariant is "one Array(String) entry == one
    # terminal row". A multi-line system message previously landed as a single
    # entry with embedded `\n`, which broke diff_render's row math and made the
    # screen scramble (the original /help bug).
    app = H2code::TUI::App.new
    app.add_message("system", "first line\nsecond line\nthird line")

    rendered = app.render_message(app.@messages.last, 80)
    rendered.reject("").size.should eq(3)
    rendered.find { |l| l.includes?("first line") }.should_not be_nil
    rendered.find { |l| l.includes?("second line") }.should_not be_nil
    rendered.find { |l| l.includes?("third line") }.should_not be_nil
    # No rendered entry may carry an embedded newline.
    rendered.each { |l| l.should_not contain("\n") }
  end

  it "splits multi-line error and status messages the same way" do
    app = H2code::TUI::App.new
    app.add_message("error", "boom-a\nboom-b")
    app.add_message("status", "s-a\ns-b")

    err = app.render_message(app.@messages[-2], 80).reject(&.empty?)
    err.size.should eq(2)
    err.each { |l| l.should_not contain("\n") }

    stat = app.render_message(app.@messages[-1], 80).reject(&.empty?)
    stat.size.should eq(2)
    stat.each { |l| l.should_not contain("\n") }
  end

  it "starts with the help panel hidden" do
    app = H2code::TUI::App.new
    app.@help_panel.visible?.should be_false
  end

  # The loop-level exception interceptor emits Event.exception when a tool or
  # the provider blows up mid-turn. The TUI must render it as a red exception
  # block so the user sees what failed and can keep typing — instead of the
  # interface crumbling. This is the visual half of the BoomTool loop test in
  # spec/loop/agent_spec.cr.
  it "renders an exception event as a red exception block" do
    app = H2code::TUI::App.new

    # Simulate the exact event the loop interceptor emits (Event.exception
    # formats class + message + backtrace into a single multi-line string).
    app.on_event(H2code::Loop::Event.exception(
      Exception.new("kaboom from BoomTool")
    ))

    # An exception message landed in the transcript.
    exc_msg = app.@messages.find { |m| m.role == "exception" }
    exc_msg.should_not be_nil
    exc_msg_content = exc_msg.try(&.content) || ""
    exc_msg_content.should contain("kaboom from BoomTool")

    # The spinner stopped — the TUI is back in an idle state.
    app.@spinner.active?.should be_false

    # Render it and verify the block visually: a red header line, the
    # exception class + message, and one line per rendered entry (the
    # renderer invariant: no embedded newlines).
    rendered = app.render_message(exc_msg || raise("exc_msg should not be nil"), 80)
    text = rendered.map { |l| app_strip_ansi(l) }.join("\n")
    text.should contain("💥 Exception")
    text.should contain("kaboom from BoomTool")
    rendered.each { |l| l.should_not contain("\n") }
  end
end

describe H2code::TUI::HelpPanel do
  it "toggles visibility via show / hide" do
    panel = H2code::TUI::HelpPanel.new(H2code::TUI::Theme.dark)
    panel.visible?.should be_false
    panel.show
    panel.visible?.should be_true
    panel.hide
    panel.visible?.should be_false
  end

  it "dismisses on Esc, Enter, q, and Q" do
    [{H2code::TUI::Key::Escape, "Esc"},
     {H2code::TUI::Key::Enter, "Enter"}].each do |key, _|
      panel = H2code::TUI::HelpPanel.new(H2code::TUI::Theme.dark)
      panel.show
      consumed = panel.handle_input(H2code::TUI::KeyEvent.new(key))
      consumed.should be_true
      panel.visible?.should be_false
    end

    ['q', 'Q'].each do |c|
      panel = H2code::TUI::HelpPanel.new(H2code::TUI::Theme.dark)
      panel.show
      panel.handle_input(H2code::TUI::KeyEvent.new(H2code::TUI::Key::Char, c)).should be_true
      panel.visible?.should be_false
    end
  end

  it "ignores unrelated printable keys without closing" do
    panel = H2code::TUI::HelpPanel.new(H2code::TUI::Theme.dark)
    panel.show
    panel.handle_input(H2code::TUI::KeyEvent.new(H2code::TUI::Key::Char, 'x')).should be_false
    panel.visible?.should be_true
  end

  it "scrolls down on Down / PageDown and clamps at the bottom" do
    panel = H2code::TUI::HelpPanel.new(H2code::TUI::Theme.dark)
    panel.max_visible = 5
    panel.show
    panel.render(80)

    # Pressing Down past the end must not blow up — render clamps the offset.
    50.times { panel.handle_input(H2code::TUI::KeyEvent.new(H2code::TUI::Key::Down)) }
    lines_after = panel.render(80)
    lines_after.size.should be > 0

    panel.handle_input(H2code::TUI::KeyEvent.new(H2code::TUI::Key::PageDown))
    panel.render(80).size.should be > 0
  end

  it "never emits an embedded newline in any rendered line" do
    # The renderer-level invariant: every Array(String) entry is one terminal
    # row. Verify across several widths so truncation paths are exercised.
    panel = H2code::TUI::HelpPanel.new(H2code::TUI::Theme.dark)
    panel.show
    [200, 120, 80, 40, 20].each do |w|
      rendered = panel.render(w)
      rendered.each do |line|
        line.should_not contain("\n")
      end
    end
  end

  it "lists every registered slash command" do
    panel = H2code::TUI::HelpPanel.new(H2code::TUI::Theme.dark)
    # Expand the viewport so every command is on screen at once; the scroll
    # path is covered by the windowing spec below.
    panel.max_visible = 200
    panel.show
    body = panel.render(120).map { |l| help_strip_ansi(l) }.join("\n")
    H2code::TUI::CommandRegistry::COMMANDS.each do |cmd|
      body.should contain(cmd.name)
    end
  end

  it "fires on_close when dismissed via a key" do
    fired = false
    panel = H2code::TUI::HelpPanel.new(H2code::TUI::Theme.dark)
    panel.on_close = -> { fired = true; nil }
    panel.show
    panel.handle_input(H2code::TUI::KeyEvent.new(H2code::TUI::Key::Escape))
    fired.should be_true
  end

  it "windows content to max_visible and shows a scroll indicator when overflowing" do
    panel = H2code::TUI::HelpPanel.new(H2code::TUI::Theme.dark)
    panel.max_visible = 5
    panel.show
    rendered = panel.render(120)
    body = rendered.map { |l| help_strip_ansi(l) }.join("\n")
    # The panel has more than 5 content lines, so the indicator must appear.
    body.should contain("showing")
    body.should contain("of")
  end

  # Regression tests for the TUI_BUGS.md fixes (see TUI_FIXES.md).
  describe "TUI_BUGS fixes" do
    # Issue #2: wrap_text used .size (codepoints), so CJK text (1 codepoint =
    # 2 columns) overflowed. Now wraps by visible_width and hard-breaks
    # overwide tokens.
    it "wrap_text wraps CJK content by visible width" do
      app = H2code::TUI::App.new
      # 20 Japanese chars = 40 columns; at cols=24 the bullet takes ~2 cols,
      # so the body must wrap into multiple lines each <= cols.
      cjk = "あ" * 20
      lines = app.render_message(H2code::TUI::Message.new("user", cjk), 24)
      lines.each do |l|
        H2code::TUI::CharWidth.visible_width(l).should be <= 24
      end
      lines.size.should be > 1
    end

    it "wrap_text hard-breaks a single overwide token" do
      app = H2code::TUI::App.new
      # A single 40-char ASCII word (no spaces) wider than the column.
      word = "a" * 40
      lines = app.render_message(H2code::TUI::Message.new("user", word), 10)
      lines.each do |l|
        H2code::TUI::CharWidth.visible_width(l).should be <= 10
      end
      lines.size.should be > 1
    end

    # Issue #1 + #7: build_rendered_lines now truncates every line to `cols`
    # and appends a trailing SGR reset. Reach it via render_message output
    # piped through the same post-processing.
    it "build_rendered_lines truncates overwide lines to cols" do
      app = H2code::TUI::App.new
      # Inject a long CJK line that a renderer would emit wider than cols.
      app.add_message("user", "あ" * 60)
      cols = 20
      new_lines, _, _ = app.build_rendered_lines(cols)
      new_lines.each do |l|
        H2code::TUI::CharWidth.visible_width(l).should be <= cols
      end
    end

    it "build_rendered_lines ends every line with an SGR reset" do
      app = H2code::TUI::App.new
      app.add_message("user", "hello")
      new_lines, _, _ = app.build_rendered_lines(80)
      new_lines.each do |l|
        l.should end_with(H2code::TUI::ANSI.reset)
      end
    end

    # Issue #3: plan-box title with an ANSI Rejected badge miscomputed width
    # via .size, shrinking the top border. Now uses visible_len.
    it "render_plan_box keeps top and bottom borders aligned with ANSI title" do
      app = H2code::TUI::App.new
      msg = H2code::TUI::Message.new("plan_box", "do something")
      msg.plan_kind = "rejected"
      lines = app.render_plan_box(msg, 40)
      # Find the top (┌) and bottom (└) border lines; both end with ┐/┘.
      top = lines.find { |l| l.includes?('┌') }
      bottom = lines.find { |l| l.includes?('└') }
      top.should_not be_nil
      bottom.should_not be_nil
      H2code::TUI::CharWidth.visible_width(top || raise "top not found").should eq(
        H2code::TUI::CharWidth.visible_width(bottom || raise "bottom not found")
      )
    end

    # Regression: a long line inside the plan body (e.g. a code line) overflowed
    # content_width and pushed the right border onto the next terminal row,
    # reading as a stray blank line. Now clamped via slice_by_column.
    it "render_plan_box clamps body lines so the right border stays on-row" do
      app = H2code::TUI::App.new
      long_line = "body = output[(idx + auto_marker.size)..].strip"
      msg = H2code::TUI::Message.new("plan_box", "```crystal\n#{long_line}\n```")
      lines = app.render_plan_box(msg, 40)
      # Every body row (between top ┌ and bottom └) must contain both the
      # left and right border on the SAME line — no overflow wrap.
      body = lines.reject { |l| l.includes?('┌') || l.includes?('└') || l.empty? }
      body.each do |row|
        row.should contain('│')
        # Right border present exactly once on the row
        H2code::TUI::CharWidth.visible_width(row).should be <= 40
      end
    end

    # Issue #4: single CJK grapheme at max_w=1 should not be split into an
    # empty chunk — it stays as one indivisible chunk.
    it "wrap_editor_line keeps an overwide single grapheme intact" do
      app = H2code::TUI::App.new
      chunks = app.wrap_editor_line("あ", 1)
      chunks.size.should eq(1)
      H2code::TUI::CharWidth.visible_width(chunks[0][0]).should eq(2)
    end

    # Issue #10: welcome box logo is 14 cols wide; clamp box_w so the border
    # doesn't collapse on very narrow terminals.
    it "render_welcome_box clamps box width to logo width" do
      app = H2code::TUI::App.new
      lines = app.render_welcome_box(8)
      # The top border line should be at least 14 visible columns wide so
      # the logo fits inside without pushing the right border off-screen.
      top = lines.find { |l| l.includes?('╭') }
      top.should_not be_nil
      H2code::TUI::CharWidth.visible_width(top || raise "top not found").should be >= 14
    end

    # The GitHub-token hint renders under the welcome box in the tip layout,
    # but warning-yellow (bar and text), unlike the gray-on-green tip.
    it "startup warning tip renders under the welcome box" do
      app = H2code::TUI::App.new
      app.startup_warning_tip = "GitHub Actions detected but no GitHub token is set"
      log_lines, _active, _editor = app.build_rendered_lines_split(80)
      joined = log_lines.join('\n')
      joined.should contain("GitHub Actions detected but no GitHub token is set")
      # Tip rows are bar-delimited lines.
      joined.should contain('│')
    end
  end
end

describe H2code::TUI::App do
  # SwarmMember is a struct. The terminal/progress handlers used to iterate it
  # with `each`, which yields a copy — so `sm.phase = ...` / `sm.ticks = ...`
  # mutated a throwaway clone and the array element stayed "Running" forever.
  # That kept @swarm_active true, driving an endless redraw loop that locked
  # terminal scroll even after every subagent had finished.
  describe "subagent lifecycle phase updates" do
    it "marks members Completed/Failed and clears swarm_active" do
      app = H2code::TUI::App.new
      tc = "call_swarm_1"
      app.on_event(H2code::Loop::Event.tool_call_start(tc, H2code::Tools::Names::AGENT_SWARM, "{}"))
      app.on_event(H2code::Loop::Event.subagent_started(tc, "agent-a", 1, "item a"))
      app.on_event(H2code::Loop::Event.subagent_started(tc, "agent-b", 2, "item b"))

      members = app.@messages.last.swarm_members
      members.size.should eq(2)
      members.all?(&.running?).should be_true
      app.@swarm_active.should be_true

      app.on_event(H2code::Loop::Event.subagent_progress(tc, "agent-a", 5))
      app.on_event(H2code::Loop::Event.subagent_completed(tc, "agent-a"))
      app.on_event(H2code::Loop::Event.subagent_failed(tc, "agent-b", "boom"))

      members = app.@messages.last.swarm_members
      members[0].phase.should eq("Completed")
      members[0].ticks.should eq(5)
      members[1].phase.should eq("boom")
      members.all?(&.done?).should be_true
      app.@swarm_active.should be_false
    end
  end

  # A pending Agent/AgentSwarm call (no tool_result yet) must render its live
  # progress grid in the repainted ACTIVE zone so the spinner/braille animation
  # updates each frame — not in the append-only LOG zone, where lines are written
  # once and frozen. Once the result arrives, the entry migrates into the log as
  # a final snapshot, exactly like a regular tool call. See docs/TUI_ZONES.md.
  describe "swarm progress zone routing" do
    it "renders a pending swarm in the active zone, then migrates to log on result" do
      app = H2code::TUI::App.new
      tc = "call_swarm_routing"
      app.on_event(H2code::Loop::Event.tool_call_start(tc, H2code::Tools::Names::AGENT_SWARM, %({"description":"do work"})))
      app.on_event(H2code::Loop::Event.subagent_started(tc, "agent-a", 1, "item a"))

      # Pending (no tool_result yet): swarm progress lives in the active zone.
      log, active, _ = app.build_rendered_lines_split(80)
      log.any?(&.includes?(H2code::Tools::Names::AGENT_SWARM)).should be_false
      active.any?(&.includes?(H2code::Tools::Names::AGENT_SWARM)).should be_true

      # Result arrives: the entry migrates into the append-only log.
      app.on_event(H2code::Loop::Event.tool_result(tc, "all done", false))
      log, active, _ = app.build_rendered_lines_split(80)
      log.any?(&.includes?(H2code::Tools::Names::AGENT_SWARM)).should be_true
      active.any?(&.includes?(H2code::Tools::Names::AGENT_SWARM)).should be_false
    end
  end

  # Streaming assistant text from a child agent is forwarded via SubagentText
  # events and accumulated in SwarmMember#latest_text. The TUI renders the last
  # few non-empty lines as a live preview in the active zone — mirrors
  # kimi-code's latestModelText.
  describe "subagent streaming text preview" do
    it "accumulates latest_text and renders it in the active zone" do
      app = H2code::TUI::App.new
      tc = "call_stream"
      app.on_event(H2code::Loop::Event.tool_call_start(tc, H2code::Tools::Names::AGENT, %({"description":"review"})))
      app.on_event(H2code::Loop::Event.subagent_started(tc, "agent-1"))

      member = app.@messages.last.swarm_members.first
      member.latest_text.should eq("")

      # Simulate streaming deltas forwarded by the runner.
      app.on_event(H2code::Loop::Event.subagent_text(tc, "agent-1", "First line\nSecond line"))
      member = app.@messages.last.swarm_members.first
      member.latest_text.should eq("First line\nSecond line")

      # The latest line appears in the active-zone rendering.
      _, active, _ = app.build_rendered_lines_split(80)
      active.any?(&.includes?("Second line")).should be_true
    end
  end

  # The welcome banner is rendered from @show_welcome.  It must stay in the
  #  render array after the first message so it scrolls off naturally as
  #  content grows — it must never be *removed* from the array (which would
  #  shrink content, trigger a full repaint, and visually "clear" the screen).
  describe "welcome banner persistence" do
    it "is visible on a fresh app" do
      app = H2code::TUI::App.new
      app.@show_welcome.should be_true
      lines, _, _ = app.build_rendered_lines(80)
      lines.any?(&.includes?("Welcome")).should be_true
    end

    it "stays in the render array after the first user message" do
      app = H2code::TUI::App.new
      app.add_message("user", "hello")
      app.@show_welcome.should be_true
      lines, _, _ = app.build_rendered_lines(80)
      lines.any?(&.includes?("Welcome")).should be_true
    end

    it "stays in the render array after loading a transcript" do
      app = H2code::TUI::App.new
      memory = H2code::Context::Memory.new
      memory.add_user("previous message")
      app.load_transcript_from(memory)
      app.@show_welcome.should be_true
    end

    it "is present even as multiple messages accumulate" do
      app = H2code::TUI::App.new
      5.times { |i| app.add_message("user", "message #{i}") }
      app.@show_welcome.should be_true
      lines, _, _ = app.build_rendered_lines(80)
      lines.any?(&.includes?("Welcome")).should be_true
    end

    # Regression: full_render must never emit \e[2J (full-screen erase).
    # That blanks the entire visible area for one frame even inside a
    # synchronized update, causing a visible flicker/"clear".  full_render
    # must rewrite lines in place (\e[H + per-line \e[K + trailing \e[J).
    #
    # NOTE: full_render is currently disabled; this test is kept commented out
    # alongside the method in app.cr.
    # it "full_render does not emit \\e[2J" do
    #   app = H2code::TUI::App.new
    #   app.add_message("user", "hello")
    #   # @first_render is true on a fresh app, so build_render_output takes
    #   # the full_render path.
    #   output = app.build_render_output
    #   output.should_not contain("\e[2J")
    # end
  end

  describe "plan mode input frame" do
    # Normal mode tints the input frame white; Plan mode tints it yellow
    # (opencode darkYellow, 180). Both are exposed via the box border.
    # Plan mode also swaps the placeholder to "Plan mode" instead of pushing
    # a transcript system message.
    it "uses the white colour for the border in normal mode" do
      app = H2code::TUI::App.new
      app.plan_mode = false
      lines, _, _ = app.build_rendered_lines(40)
      joined = lines.join('\n')
      joined.should contain("\e[38;5;255m")
      joined.should_not contain("\e[38;5;180m")
    end

    it "tints the border yellow when plan mode is on" do
      app = H2code::TUI::App.new
      app.plan_mode = true
      lines, _, _ = app.build_rendered_lines(40)
      joined = lines.join('\n')
      joined.should contain("\e[38;5;180m")
    end

    it "shows the plan mode placeholder and no system message" do
      app = H2code::TUI::App.new
      app.plan_mode = true
      lines, _, _ = app.build_rendered_lines(40)
      joined = lines.join('\n')
      # Placeholder shown inside the input box.
      app_strip_ansi(joined).should contain("Send a message... (Plan mode)")
      # No transcript system message is pushed on toggle.
      app.@messages.none? { |m| m.role == "system" && m.content.includes?("Plan mode") }.should be_true
    end

    # Regression: when the active zone shrinks (e.g. the editor box was tall
    # because of wrapped long text, then the text was cleared), the leftover
    # rows below the new zone bottom must be cleared.
    it "clears stale rows when the active zone shrinks" do
      app = H2code::TUI::App.new
      # App#initialize memoizes Terminal.current; set_size mutates that shared
      # singleton, so restore the real size afterwards — later specs (e.g.
      # streaming_markdown_spec) build Apps off the same instance and render
      # at widths that must agree with @terminal.cols.
      prev_cols = app.@terminal.cols
      prev_rows = app.@terminal.rows
      app.@terminal.set_size(40, 24)
      begin
        mock = H2code::TUI::TerminalMock.new(rows: 24, cols: 80)

        # Frame 1: tall editor box (long text wraps to many rows).
        app.@editor.set("x" * 200)
        app.render_to(mock)
        tall = mock.visible_rows.size

        # Frame 2: short editor box (text cleared → single placeholder row).
        app.@editor.clear
        app.render_to(mock)
        short = mock.visible_rows.size

        short.should be < tall

        # All rows below the new content must be blank.
        content_end = mock.visible_rows.size
        mock.screen[content_end..].each { |row| row.should eq("") }
      ensure
        app.@terminal.set_size(prev_cols, prev_rows)
      end
    end
  end

  describe "session picker async search" do
    it "defers the content filter to the debounced worker fiber" do
      home = File.join(Dir.tempdir, "h2code-test-#{Random::Secure.hex(8)}")
      begin
        dir_a = File.join(home, ".h2code", "sessions", "sessA")
        dir_b = File.join(home, ".h2code", "sessions", "sessB")
        Dir.mkdir_p(dir_a)
        Dir.mkdir_p(dir_b)
        File.write(File.join(dir_a, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"fix the login bug"}}))
        File.write(File.join(dir_b, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"unrelated talk"}}))

        app = H2code::TUI::App.new
        app.home = home
        entries = H2code::Session::Index.new(home).list(include_archived: true, include_empty: true)
        app.session_entries = entries
        app.@session_list.show("Resume session", entries.map(&.label))

        # Typing updates the query immediately but does not filter inline —
        # keystrokes never wait on wire-log scans.
        app.@session_list.handle_input(H2code::TUI::KeyEvent.char('l'))
        app.@session_list.handle_input(H2code::TUI::KeyEvent.char('o'))
        app.@session_list.query.should eq("lo")
        app.@session_list.filtered_size.should eq(2)

        # After the 200ms debounce window the worker fiber applies the
        # filter and only the matching session stays.
        sleep 600.milliseconds
        app.@session_list.filtered_size.should eq(1)
        app.@session_list.current.should eq("fix the login bug")
      ensure
        FileUtils.rm_rf(home)
      end
    end

    # Private handlers are reachable from a subclass (SearchApp at the top
    # of this file) — it drives /search the same way the dispatcher does.
    it "/search lists sessions from every workspace, archived included, with cwd labels" do
      home = File.join(Dir.tempdir, "h2code-test-#{Random::Secure.hex(8)}")
      begin
        ws_a = H2code::Session::Index.workspace_id("/repoA")
        ws_b = H2code::Session::Index.workspace_id("/repoB")
        dir_a = File.join(home, ".h2code", "sessions", ws_a, "sessA")
        dir_b = File.join(home, ".h2code", "sessions", ws_b, "sessB")
        dir_arch = File.join(home, ".h2code", "sessions", ws_b, "sessArch")
        [dir_a, dir_b, dir_arch].each { |d| Dir.mkdir_p(d) }
        File.write(File.join(dir_a, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"alpha bug"}}))
        File.write(File.join(dir_b, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"beta bug"}}))
        File.write(File.join(dir_arch, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"old arch"}}))
        arch_meta = H2code::Session::StateMeta.new("sessArch")
        arch_meta.cwd = "/repoB"
        arch_meta.archived = true
        File.write(File.join(dir_arch, "state.json"), arch_meta.to_json)

        app = SearchApp.new
        app.home = home
        app.work_dir = "/repoA" # /resume would scope to ws_a only
        app.run_cmd_search

        app.@session_list.visible?.should be_true
        ids = app.session_entries.map(&.id)
        ids.sort!
        ids.should eq(["sessA", "sessArch", "sessB"])
        # Global list shows each session's directory so workspaces are
        # distinguishable.
        joined = app.@session_list.items.join('\n')
        joined.should contain("/repoB")
      ensure
        FileUtils.rm_rf(home)
      end
    end
  end
end
