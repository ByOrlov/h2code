require "../spec_helper"
require "../../src/loop/agent"
require "random/secure"

# Provider that always raises an IO::Error to simulate a network drop.
private class NetworkDropProvider < H2code::LLM::Provider
  def name : String
    "network-drop"
  end

  def model_name : String
    "test"
  end

  def fetch_models : Array(String)
    [] of String
  end

  def chat(messages : Array(H2code::LLM::Message), tools : Array(H2code::LLM::ToolDefinition)?,
           system_prompt : String? = nil, aborted? : -> Bool = -> { false },
           &_block : H2code::LLM::MessagePart ->) : H2code::LLM::StepResult
    raise IO::Error.new("Broken pipe")
  end
end

# Integration coverage for the agent loop, driven end-to-end by the offline
# MockProvider. No network, no API key: the mock replays a fixed multi-step
# script (parallel tool calls → write → finish) so run_turn, the parallel
# tool batch, result assembly, and termination all execute against real tools.
describe H2code::Loop::Agent do
  it "runs a multi-step turn with parallel tool calls on the mock provider" do
    work_dir = File.join(Dir.tempdir, "h2code-mock-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(work_dir)

    begin
      provider = H2code::LLM::MockProvider.new
      memory = H2code::Context::Memory.new
      memory.max_context_tokens = 131_072

      tools = H2code::Tools::Registry.new
      tools.register(H2code::Tools::Bash.new(work_dir))
      tools.register(H2code::Tools::Glob.new(work_dir))
      tools.register(H2code::Tools::Write.new(work_dir))

      permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
      agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

      events = [] of H2code::Loop::Event
      result = agent.run_turn("self-test", nil) { |e| events << e }

      # The script ends on an end_turn step with no tool calls.
      result.stop_reason.should eq("end_turn")
      result.steps.should eq(4)
      result.usage.total_tokens.should be > 0

      # Every scripted tool call was dispatched and completed without error.
      started = events.select { |e| e.type.tool_call_start? }.map(&.tool_name)
      started.sort.should eq([H2code::Tools::Names::BASH, H2code::Tools::Names::BASH, H2code::Tools::Names::GLOB, H2code::Tools::Names::WRITE])

      tool_results = events.select { |e| e.type.tool_result? }
      tool_results.size.should eq(4)
      tool_results.all? { |e| !e.is_error? }.should be_true

      # The Write tool actually wrote the file — proving tool execution ran,
      # not just that events fired.
      File.exists?(File.join(work_dir, ".mock-selftest")).should be_true
    ensure
      File.delete(File.join(work_dir, ".mock-selftest")) rescue nil
      Dir.delete(work_dir) rescue nil
    end
  end

  it "accumulates assistant text from the final step" do
    provider = H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::TextPart.new("all done here")] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "all done here",
      ),
    ])
    memory = H2code::Context::Memory.new
    tools = H2code::Tools::Registry.new
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

    result = agent.run_turn("hi", nil) { }

    result.stop_reason.should eq("end_turn")
    result.steps.should eq(1)
    memory.messages.last.role.should eq("assistant")
    memory.messages.last.text.should eq("all done here")
  end

  it "hot-swaps the provider at runtime via swap_provider!" do
    first = H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::TextPart.new("first")] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "first",
      ),
    ])
    second = H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::TextPart.new("second")] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "second",
      ),
    ])

    memory = H2code::Context::Memory.new
    tools = H2code::Tools::Registry.new
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    agent = H2code::Loop::Agent.new(first, memory, tools, permission)

    agent.provider.should be(first)
    agent.run_turn("turn one", nil) { }
    memory.messages.last.text.should eq("first")

    agent.swap_provider!(second)
    agent.provider.should be(second)

    agent.run_turn("turn two", nil) { }
    memory.messages.last.text.should eq("second")
  end

  it "appends the model/provider identity block to the system prompt sent to the provider" do
    provider = PromptCaptureProvider.new(H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::TextPart.new("ok")] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "ok",
      ),
    ]))
    memory = H2code::Context::Memory.new
    tools = H2code::Tools::Registry.new
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

    agent.run_turn("who are you?", "You are H2Code, an agent.") { }

    provider.captured_system_prompts.size.should eq(1)
    sent = provider.captured_system_prompts.first
    sent.should_not be_nil
    sent = sent || raise "system prompt capture failed"
    sent.should start_with("You are H2Code, an agent.")
    sent.should contain("# Identity")
    sent.should contain("identity-capture")
    sent.should contain("test-model")
  end

  it "sends no identity block when no system prompt is set" do
    provider = PromptCaptureProvider.new(H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::TextPart.new("ok")] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "ok",
      ),
    ]))
    memory = H2code::Context::Memory.new
    tools = H2code::Tools::Registry.new
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

    agent.run_turn("hi", nil) { }

    provider.captured_system_prompts.first.should be_nil
  end

  it "emits ThinkingDelta events when the provider streams ThinkParts" do
    provider = H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [
          H2code::LLM::ThinkPart.new("Let me analyze"),
          H2code::LLM::ThinkPart.new(" this problem."),
          H2code::LLM::TextPart.new("Here is the answer."),
        ] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "Here is the answer.",
      ),
    ])
    memory = H2code::Context::Memory.new
    tools = H2code::Tools::Registry.new
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

    events = [] of H2code::Loop::Event
    agent.run_turn("test", nil) { |e| events << e }

    thinking_deltas = events.select(&.type.thinking_delta?)
    thinking_deltas.size.should eq(2)
    thinking_deltas[0].text.should eq("Let me analyze")
    thinking_deltas[1].text.should eq(" this problem.")

    text_deltas = events.select(&.type.text_delta?)
    text_deltas.size.should eq(1)
    text_deltas[0].text.should eq("Here is the answer.")
  end

  it "emits exactly one TurnEnd at the end of a normal turn" do
    provider = H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::TextPart.new("ok")] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "ok",
      ),
    ])
    memory = H2code::Context::Memory.new
    tools = H2code::Tools::Registry.new
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

    events = [] of H2code::Loop::Event
    agent.run_turn("x", nil) { |e| events << e }

    turn_ends = events.select(&.type.turn_end?)
    turn_ends.size.should eq(1)
    turn_ends.first.is_error?.should be_false # not cancelled
    # TurnEnd must be the last event so the TUI can safely drain the queue.
    events.last.type.turn_end?.should be_true
  end

  it "emits TurnEnd even when the turn is cancelled" do
    # Tool call that sleeps 30s gives the cancel a window to fire mid-tool.
    provider = H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::ToolCallPart.new(
          "call_1", H2code::Tools::Names::BASH, %({"command":"sleep 30"})
        )] of H2code::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
    ])
    work_dir = File.join(Dir.tempdir, "h2code-cancel-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(work_dir)
    begin
      memory = H2code::Context::Memory.new
      tools = H2code::Tools::Registry.new
      tools.register(H2code::Tools::Bash.new(work_dir))
      permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
      agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

      events = [] of H2code::Loop::Event
      expect_raises(H2code::Loop::UserCancellationError) do
        # Cancel from a sibling fiber once the tool step is in flight.
        spawn do
          sleep 50.milliseconds
          agent.cancel
        end
        agent.run_turn("x", nil) { |e| events << e }
      end

      turn_ends = events.select(&.type.turn_end?)
      turn_ends.size.should eq(1)
      turn_ends.first.is_error?.should be_true # cancelled flag
    ensure
      Dir.delete(work_dir) rescue nil
    end
  end

  it "injects a steering message into the live context via #steer" do
    provider = H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::TextPart.new("ack")] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "ack",
      ),
    ])
    memory = H2code::Context::Memory.new
    tools = H2code::Tools::Registry.new
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

    agent.context.history.size.should eq(0)
    agent.steer("a side note")
    agent.context.history.size.should eq(1)
    agent.context.history.last.message.role.should eq("user")
    agent.context.history.last.message.text.should eq("a side note")
  end

  it "raises NetworkFailureError after exhausting retries on a network error" do
    provider = NetworkDropProvider.new
    memory = H2code::Context::Memory.new
    memory.max_context_tokens = 131_072
    tools = H2code::Tools::Registry.new
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

    events = [] of H2code::Loop::Event
    error = expect_raises(H2code::Loop::NetworkFailureError) do
      agent.run_turn("hi", nil) { |e| events << e }
    end

    (error.message || "").should contain("Network failure")
    (error.message || "").should contain("3 retries")
    (error.message || "").should contain("Broken pipe")

    # The user should have seen retry info messages.
    retry_infos = events.select(&.type.info?).map(&.text)
    retry_infos.size.should eq(3)
    retry_infos.all? { |t| t.includes?("Retrying") }.should be_true
  end

  # End-to-end plan-mode flow: enter → blocked Write → exit. Verifies the
  # wiring between Permission guard, the Agent's plan reminder injection, and
  # the plan-mode service lifecycle — the piece that was missing before this
  # change (EnterPlanMode/ExitPlanMode existed but were dead code).
  it "enforces plan mode: Write is blocked and a reminder is injected" do
    dir = File.join(Dir.tempdir, "h2code-plan-flow-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    plan_path = File.join(dir, "plan.md")

    # Mock provider that records every message list it receives, so the test
    # can assert the plan-mode reminder was present on some step even though
    # `prune_injections` removes it on the next step.
    captured_messages = [] of Array(H2code::LLM::Message)
    recording_provider = H2code::LLM::MockProvider.new([
      # Step 1: enter plan mode.
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::ToolCallPart.new("c1", H2code::Tools::Names::ENTER_PLAN_MODE, %({}))] of H2code::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
      # Step 2: attempt a Write (should be blocked by the guard).
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::ToolCallPart.new(
          "c2", H2code::Tools::Names::WRITE, %({"path":"/tmp/h2code-plan-block.txt","content":"x"})
        )] of H2code::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
      # Step 3: write the plan to the plan file (allowed).
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::ToolCallPart.new(
          "c3", H2code::Tools::Names::WRITE, %({"path":#{plan_path.inspect},"content":"## Plan\\n\\nDo it."})
        )] of H2code::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
      # Step 4: exit plan mode (auto-approved).
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::ToolCallPart.new("c4", H2code::Tools::Names::EXIT_PLAN_MODE, %({}))] of H2code::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
      # Step 5: done.
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::TextPart.new("finished")] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "finished",
      ),
    ])

    service = H2code::Tools::AgentPlanService.new(dir, "main", plan_path)
    H2code::Tools::PlanMode.plan_service = service
    H2code::Tools::PlanMode.permission_mode = H2code::Tools::PermissionModeRef.new(auto: true)
    H2code::Tools::PlanMode.plan_review_service = nil

    begin
      # Build a provider subclass that records messages before delegating.
      provider = RecordingProvider.new(recording_provider, captured_messages)

      memory = H2code::Context::Memory.new
      memory.max_context_tokens = 131_072
      tools = H2code::Tools::Registry.new
      tools.register(H2code::Tools::EnterPlanMode.new)
      tools.register(H2code::Tools::ExitPlanMode.new)
      tools.register(H2code::Tools::Write.new(dir))
      permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
      agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

      events = [] of H2code::Loop::Event
      agent.run_turn("plan something", nil) { |e| events << e }

      tool_results = events.select(&.type.tool_result?).map(&.text)
      # The second tool call (Write to a non-plan path) must be blocked by the
      # plan-mode guard — the deny reason (the guard message itself) is
      # surfaced to the model in the tool result.
      blocked_result = tool_results.select(&.includes?("Plan mode is active"))
      blocked_result.should_not be_empty
      guard_infos = events.select(&.type.info?).map(&.text)
      guard_infos.any?(&.includes?("Plan mode is active")).should be_true

      # The plan file was writable (step 3 succeeded) and ExitPlanMode reported
      # auto-approval (step 4).
      exit_result = tool_results.find(&.includes?("Exited plan mode"))
      exit_result.should_not be_nil
      (exit_result || raise "exit_result should not be nil").includes?("auto-approved").should be_true

      # The forbidden file was never created.
      File.exists?("/tmp/h2code-plan-block.txt").should be_false

      # Plan-mode reminder was injected into the messages sent to the LLM on at
      # least one step while plan mode was active.
      reminders = captured_messages.flatten.select(&.text.includes?("Plan mode is active"))
      reminders.should_not be_empty

      # Plan mode is off after exit.
      service.status.should be_nil
    ensure
      H2code::Tools::PlanMode.plan_service = nil
      H2code::Tools::PlanMode.permission_mode = nil
      FileUtils.rm_rf(dir)
      File.delete("/tmp/h2code-plan-block.txt") rescue nil
    end
  end

  # The loop-level exception interceptor: when a tool raises an unexpected
  # Crystal exception mid-turn, the loop catches it, emits an Exception event
  # (so the TUI can render it red), then re-raises. Crucially, turn_end is
  # always emitted so the TUI resets to idle and the user can keep typing —
  # instead of the interface crumbling.
  it "surfaces a tool exception as an Exception event and still emits turn_end" do
    provider = H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::ToolCallPart.new("c1", "Boom", %({}))] of H2code::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
    ])
    memory = H2code::Context::Memory.new
    memory.max_context_tokens = 131_072
    tools = H2code::Tools::Registry.new
    tools.register(BoomTool.new)
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

    events = [] of H2code::Loop::Event
    # The exception is re-raised so callers keep their failure contract.
    expect_raises(Exception, "kaboom from BoomTool") do
      agent.run_turn("trigger boom", nil) { |e| events << e }
    end

    # An Exception event was emitted with the formatted exception text.
    exc_events = events.select(&.type.exception?)
    exc_events.size.should eq(1)
    exc_events.first.text.should contain("BoomTool")
    exc_events.first.text.should contain("kaboom from BoomTool")

    # turn_end was still emitted (in the ensure block), so the TUI resets.
    turn_ends = events.select(&.type.turn_end?)
    turn_ends.size.should eq(1)

    # turn_end comes after the Exception event in the stream.
    exc_idx = events.index!(&.type.exception?)
    te_idx = events.index!(&.type.turn_end?)
    te_idx.should be > exc_idx

    # The agent is no longer busy after the turn.
    agent.busy?.should be_false
  end

  # Regression: background-subagent completion notifications are injected
  # into the parent context with the Notification origin (the path used by
  # `SubagentAgentRunner#inject_completion_notification`). The per-step
  # `prune_injections` sweep removes transient Injection-origin reminders
  # BEFORE the API call — it must not remove notifications, or background
  # results are silently dropped and the model never sees them.
  it "delivers a context-injected notification to the provider" do
    captured = [] of Array(H2code::LLM::Message)
    provider = RecordingProvider.new(
      H2code::LLM::MockProvider.new([
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("ok")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "ok",
        ),
      ]),
      captured,
    )
    memory = H2code::Context::Memory.new
    memory.max_context_tokens = 131_072
    tools = H2code::Tools::Registry.new
    permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
    agent = H2code::Loop::Agent.new(provider, memory, tools, permission)

    # Simulate a background subagent finishing while the parent is idle.
    memory.add_notification("<notification id=\"task.t1.completed\">Background agent completed</notification>")

    agent.run_turn("hello", nil) { |_e| }

    captured.any? do |msgs|
      msgs.any?(&.text.includes?("Background agent completed"))
    end.should be_true
  end
end

# Mock provider wrapper that records every message list handed to `chat`,
# then delegates to the underlying MockProvider's script. Used by the plan-mode
# integration test to assert the plan-mode reminder injection reached the LLM.
private class RecordingProvider < H2code::LLM::Provider
  @step : Int32 = 0

  def initialize(@inner : H2code::LLM::MockProvider, @captured : Array(Array(H2code::LLM::Message)))
  end

  def name : String
    "recording"
  end

  def model_name : String
    "test"
  end

  def fetch_models : Array(String)
    [] of String
  end

  def chat(messages : Array(H2code::LLM::Message), tools : Array(H2code::LLM::ToolDefinition)?,
           system_prompt : String? = nil, aborted? : -> Bool = -> { false },
           &block : H2code::LLM::MessagePart ->) : H2code::LLM::StepResult
    @captured << messages.map(&.dup)
    @inner.chat(messages, tools, system_prompt, aborted?) { |p| block.call(p) }
  end
end

# Test tool that raises an unexpected Crystal exception on every call. Used to
# verify the loop-level exception interceptor: the exception is surfaced as an
# Exception event and turn_end still fires so the TUI does not crumble.
private class BoomTool < H2code::Tools::Tool
  def name : String
    "Boom"
  end

  def description : String
    "Always raises an exception — for tests."
  end

  def parameters : JSON::Any
    JSON.parse(%({"type":"object","properties":{},"additionalProperties":false}))
  end

  def execute(input : JSON::Any) : H2code::Tools::ToolResult
    raise Exception.new("kaboom from BoomTool")
  end
end

# Wraps the offline MockProvider and records the exact system_prompt each
# chat call received, so specs can assert on prompt augmentation.
private class PromptCaptureProvider < H2code::LLM::Provider
  property captured_system_prompts = [] of String?

  def initialize(@inner : H2code::LLM::MockProvider)
  end

  def name : String
    "identity-capture"
  end

  def model_name : String
    "test-model"
  end

  def fetch_models : Array(String)
    [] of String
  end

  def chat(messages : Array(H2code::LLM::Message), tools : Array(H2code::LLM::ToolDefinition)?,
           system_prompt : String? = nil, aborted? : -> Bool = -> { false },
           &block : H2code::LLM::MessagePart ->) : H2code::LLM::StepResult
    @captured_system_prompts << system_prompt
    @inner.chat(messages, tools, system_prompt, aborted?) { |p| block.call(p) }
  end
end
