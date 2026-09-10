require "../spec_helper"

describe H2code::Context::Memory do
  it "adds and retrieves messages" do
    mem = H2code::Context::Memory.new
    mem.add_user("hello")
    mem.add_assistant("hi")

    msgs = mem.messages
    msgs.size.should eq(2)
    msgs[0].role.should eq("user")
    msgs[1].role.should eq("assistant")
  end

  it "tracks token count" do
    mem = H2code::Context::Memory.new
    mem.add_user("hello world")

    mem.token_count.should be > 0
  end

  it "undo removes messages up to last user message" do
    mem = H2code::Context::Memory.new
    mem.add_user("first prompt")
    mem.add_assistant("response")
    mem.add_tool_result("call_1", "tool output")

    mem.undo(1)

    msgs = mem.messages
    msgs.size.should eq(0)
  end

  it "undo stops at compaction boundary" do
    mem = H2code::Context::Memory.new
    mem.add_user("prompt 1")
    mem.add_assistant("response 1")
    mem.apply_compaction("summary", [] of H2code::Context::ContextMessage)
    mem.add_user("prompt 2")
    mem.add_assistant("response 2")

    mem.undo(1)

    msgs = mem.messages
    msgs.any?(&.role.==("system")).should be_true
  end

  it "undo skips injection messages instead of stopping at them" do
    mem = H2code::Context::Memory.new
    mem.add_user("prompt 1")
    mem.add_assistant("response 1")
    mem.add_injection("<system-reminder>todo</system-reminder>")
    mem.add_assistant("more")
    mem.add_user("prompt 2")

    # Undoing 2 user prompts should cross the injection (skip it) and
    # remove both prompts. The old code broke at the injection.
    mem.undo(2)

    msgs = mem.messages
    # The injection is skipped (kept), both user prompts removed.
    msgs.any?(&.content.==("prompt 1")).should be_false
    msgs.any?(&.content.==("prompt 2")).should be_false
  end

  it "Undo.undo_or_raise! raises UndoLimitError when crossing a compaction boundary" do
    mem = H2code::Context::Memory.new
    mem.add_user("prompt 1")
    mem.apply_compaction("summary", [] of H2code::Context::ContextMessage)
    mem.add_user("prompt 2")

    expect_raises(H2code::Context::UndoLimitError) do
      H2code::Context::Undo.undo_or_raise!(mem, 5)
    end

    # prompt 2 is still removed (best effort), but the boundary stops it.
    msgs = mem.messages
    msgs.any?(&.content.==("prompt 2")).should be_false
  end

  it "Undo.undo_or_raise! raises when not enough user prompts" do
    mem = H2code::Context::Memory.new
    mem.add_user("only prompt")

    expect_raises(H2code::Context::UndoLimitError) do
      H2code::Context::Undo.undo_or_raise!(mem, 3)
    end
  end

  it "calculates token usage percent" do
    mem = H2code::Context::Memory.new
    mem.max_context_tokens = 1000
    mem.add_user("hello world")

    pct = mem.token_usage_percent
    pct.should be > 0.0
    pct.should be < 100.0
  end

  it "update_token_count_from_usage overwrites the estimate with the API figure" do
    mem = H2code::Context::Memory.new
    mem.add_user("hello world")
    estimate = mem.token_count

    mem.update_token_count_from_usage(1500, 30)

    mem.token_count.should eq(1530)
    mem.token_count.should_not eq(estimate)
  end

  it "update_token_count_from_usage ignores a zero usage report" do
    mem = H2code::Context::Memory.new
    mem.add_user("hello world")
    estimate = mem.token_count

    mem.update_token_count_from_usage(0, 0)

    # The estimate must survive a provider that reports no usage.
    mem.token_count.should eq(estimate)
  end

  it "detects near limit" do
    mem = H2code::Context::Memory.new
    mem.max_context_tokens = 10
    mem.add_user("this is a longer message to push tokens up")

    mem.near_limit?.should be_true
  end

  it "prunes injection messages while keeping normal ones" do
    mem = H2code::Context::Memory.new
    mem.add_user("hello")
    mem.add_injection("<system-reminder>todo</system-reminder>")
    mem.add_assistant("response")

    mem.prune_injections

    msgs = mem.messages
    msgs.size.should eq(2)
    msgs[0].role.should eq("user")
    msgs[1].role.should eq("assistant")
  end

  it "prune_injections does not remove compaction summary" do
    mem = H2code::Context::Memory.new
    mem.add_user("old prompt")
    mem.apply_compaction("summary text", [] of H2code::Context::ContextMessage)
    mem.add_injection("reminder")

    mem.prune_injections

    msgs = mem.messages
    msgs.any?(&.text.==("summary text")).should be_true
    msgs.any?(&.text.==("reminder")).should be_false
  end

  it "prune_injections keeps notification-origin messages" do
    mem = H2code::Context::Memory.new
    mem.add_user("hello")
    mem.add_notification("<notification id=\"task.t1.completed\">agent done</notification>")
    mem.add_injection("<system-reminder>todo</system-reminder>")

    mem.prune_injections

    msgs = mem.messages
    msgs.size.should eq(2)
    msgs.any?(&.text.includes?("agent done")).should be_true
    msgs.any?(&.text.==("<system-reminder>todo</system-reminder>")).should be_false
  end
end
