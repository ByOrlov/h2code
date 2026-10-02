require "../spec_helper"
require "../../src/context/compaction"

private def make_summary_provider(text : String)
  step = H2code::LLM::MockStep.new(
    parts: [H2code::LLM::TextPart.new(text)] of H2code::LLM::MessagePart,
    stop_reason: "end_turn",
    text: text,
  )
  H2code::LLM::MockProvider.new([step])
end

# A provider that records every request it receives and replays a scripted
# list of outcomes: either an exception to raise or a summary text to return.
private class ScriptedProvider < H2code::LLM::Provider
  getter requests : Array(Array(H2code::LLM::Message)) = [] of Array(H2code::LLM::Message)
  @outcomes : Array(Exception | String)

  def initialize(outcomes : Array(Exception | String))
    @outcomes = outcomes.map { |o| o.as(Exception | String) }
  end

  def name : String
    "scripted"
  end

  def model_name : String
    "scripted"
  end

  def fetch_models : Array(String)
    [] of String
  end

  def chat(messages : Array(H2code::LLM::Message), tools : Array(H2code::LLM::ToolDefinition)?,
           system_prompt : String? = nil,
           aborted? : -> Bool = -> { false },
           &_block : H2code::LLM::MessagePart ->) : H2code::LLM::StepResult
    @requests << messages
    outcome = @outcomes.shift
    raise outcome.as(Exception) if outcome.is_a?(Exception)
    text = outcome.as(String)
    H2code::LLM::StepResult.new(
      stop_reason: "end_turn",
      text: text,
      thinking: "",
      tool_calls: [] of H2code::LLM::ToolCall,
      usage: H2code::LLM::Usage.new,
    )
  end
end

private def zai_overflow_error : H2code::LLM::ApiError
  H2code::LLM::ApiError.new(400,
    "Chat API error 400: The messages parameter is illegal. Please check the documentation.",
    retryable: false)
end

describe H2code::Context::Compaction do
  it "summarizes and applies the compaction" do
    memory = H2code::Context::Memory.new
    memory.add_user("first message")
    memory.add_assistant("first reply")
    memory.add_user("second message")
    memory.add_assistant("second reply")

    provider = make_summary_provider("Summary of the conversation.")
    compactor = H2code::Context::Compaction.new(provider, memory, kept_count: 2)

    result = compactor.compact { }

    result.completed?.should be_true
    result.summary.should eq("Summary of the conversation.")
    # Kept the last 2 messages + the summary message itself.
    memory.history.size.should eq(3)
    result.messages_after.should eq(2)
  end

  it "sends the history as a message list plus a trailing instruction, not one blob" do
    memory = H2code::Context::Memory.new
    memory.add_user("first message")
    memory.add_assistant("first reply")

    provider = ScriptedProvider.new(["Summary."])
    compactor = H2code::Context::Compaction.new(provider, memory, kept_count: 1)

    compactor.compact { }

    request = provider.requests.first
    request.map(&.role).should eq(["user", "assistant", "user"])
    request[0].text.should eq("first message")
    request[1].text.should eq("first reply")
    request.last.text.should contain("handoff note")
  end

  it "excludes injection-origin messages from the summarizer input" do
    memory = H2code::Context::Memory.new
    memory.add_user("real question")
    memory.add_injection("[step reminder]")
    memory.add_assistant("answer")

    provider = ScriptedProvider.new(["Summary."])
    compactor = H2code::Context::Compaction.new(provider, memory, kept_count: 1)

    compactor.compact { }

    request = provider.requests.first
    request.map(&.role).should eq(["user", "assistant", "user"])
    request.none?(&.text.includes?("step reminder")).should be_true
  end

  it "synthesizes missing tool results and drops orphan tool results" do
    projected = H2code::Context::Compaction.project([
      H2code::LLM::Message.user("run tools"),
      H2code::LLM::Message.assistant("", tool_calls: [
        H2code::LLM::ToolCall.new("call_1", H2code::LLM::ToolCallFunction.new("bash", "{}")),
        H2code::LLM::ToolCall.new("call_2", H2code::LLM::ToolCallFunction.new("read", "{}")),
      ]),
      H2code::LLM::Message.tool("out 1", "call_1"),
      # Orphan: no assistant message ever made this call.
      H2code::LLM::Message.tool("stray", "call_unknown"),
    ])

    roles = projected.map(&.role)
    # user, assistant, then both tool results (the synthesized one for the
    # unanswered call_2 lands directly after the assistant, before the real
    # call_1 result); the orphan is dropped.
    roles.should eq(["user", "assistant", "tool", "tool"])
    tool_ids = projected.select(&.role.==("tool")).compact_map(&.tool_call_id).sort!
    tool_ids.should eq(["call_1", "call_2"])
    synthesized = projected.find!(&.text.includes?("unavailable"))
    synthesized.tool_call_id.should eq("call_2")
    projected.none?(&.text.includes?("stray")).should be_true
  end

  it "shrinks the history and retries when the summarizer request overflows" do
    memory = H2code::Context::Memory.new
    20.times do |i|
      memory.add_user("question number #{i} with some padding text to give it tokens")
      memory.add_assistant("answer number #{i} with some padding text to give it tokens")
    end
    # Small window so the request estimate crosses the recovery ratio gate.
    memory.max_context_tokens = 1000

    provider = ScriptedProvider.new([zai_overflow_error, zai_overflow_error, "Shrunk summary."])
    compactor = H2code::Context::Compaction.new(provider, memory, kept_count: 2)

    result = compactor.compact { }

    result.completed?.should be_true
    result.summary.should eq("Shrunk summary.")
    result.dropped_count.should be > 0
    provider.requests.size.should eq(3)
    # Each overflow retry sent a strictly smaller prefix of the history.
    provider.requests[1].size.should be < provider.requests[0].size
    provider.requests[2].size.should be < provider.requests[1].size
    # Shrunk requests still end with the instruction and never start on a tool result.
    provider.requests.each do |request|
      request.last.text.should contain("handoff note")
      request.first.role.should_not eq("tool")
    end
  end

  it "uses the provider usage figure as overflow evidence when the local estimate undercounts" do
    memory = H2code::Context::Memory.new
    memory.max_context_tokens = 100_000
    4.times do |i|
      memory.add_user("question #{i}")
      memory.add_assistant("answer #{i}")
    end
    # Local estimate of this tiny history is far below the 50% gate, but the
    # provider's usage says the live context was near the window — the Z.AI
    # 400 is an input overflow all the same.
    memory.update_token_count_from_usage(95_000, 0)

    provider = ScriptedProvider.new([zai_overflow_error, "Recovered summary."])
    compactor = H2code::Context::Compaction.new(provider, memory, kept_count: 2)

    result = compactor.compact { }

    result.completed?.should be_true
    result.summary.should eq("Recovered summary.")
    result.dropped_count.should be > 0
    provider.requests[1].size.should be < provider.requests[0].size
  end

  it "hard-truncates history when the input rejection persists past the shrink budget" do
    memory = H2code::Context::Memory.new
    memory.max_context_tokens = 1000
    20.times do |i|
      memory.add_user("question number #{i} with some padding text to give it tokens")
      memory.add_assistant("answer number #{i} with some padding text to give it tokens")
    end

    # Every summarizer attempt — the initial one and the shrink retries — is
    # rejected as oversized input; the last-resort truncation must kick in
    # instead of retaining the unusable full history.
    provider = ScriptedProvider.new([zai_overflow_error] * 5)
    compactor = H2code::Context::Compaction.new(provider, memory, kept_count: 2)

    result = compactor.compact { }

    result.completed?.should be_true
    result.dropped_count.should be > 0
    memory.history.size.should be < 41 # 40 messages + summary marker if retained
    memory.history.first.message.text.should contain("truncated without a summary")
  end

  it "does not treat a small-request 400 as overflow" do
    memory = H2code::Context::Memory.new
    memory.add_user("hello")
    memory.max_context_tokens = 1_000_000

    provider = ScriptedProvider.new([zai_overflow_error])
    compactor = H2code::Context::Compaction.new(provider, memory, kept_count: 1)

    result = compactor.compact { }

    result.failed?.should be_true
    provider.requests.size.should eq(1)
    memory.history.size.should eq(2) # full history retained + failure summary
  end

  it "retains full history on provider failure" do
    memory = H2code::Context::Memory.new
    memory.add_user("hello")

    failing = FailingProvider.new
    compactor = H2code::Context::Compaction.new(failing, memory, kept_count: 2)

    result = compactor.compact { }

    result.failed?.should be_true
    # Full history retained (1) + the failure summary message = 2.
    memory.history.size.should eq(2)
  end

  it "drops the oldest message and retries on an empty summary" do
    memory = H2code::Context::Memory.new
    memory.add_user("first")
    memory.add_assistant("first reply")
    memory.add_user("second")

    provider = ScriptedProvider.new(["", "Retry summary."])
    compactor = H2code::Context::Compaction.new(provider, memory, kept_count: 1)

    result = compactor.compact { }

    result.completed?.should be_true
    result.summary.should eq("Retry summary.")
    result.dropped_count.should eq(1)
    provider.requests[1].size.should be < provider.requests[0].size
  end

  it "reports token reduction when tokens decrease" do
    memory = H2code::Context::Memory.new
    memory.add_user("a somewhat longer message here")
    memory.add_assistant("a reply that is also reasonably long")

    provider = make_summary_provider("Short summary.")
    compactor = H2code::Context::Compaction.new(provider, memory, kept_count: 1)

    result = compactor.compact { }

    result.tokens_after.should be <= result.tokens_before
  end

  describe ".take_recent_within_token_budget" do
    it "keeps the most recent messages that fit and never returns a tool-first slice" do
      cms = [
        H2code::Context::ContextMessage.new(H2code::LLM::Message.user("0123456789" * 10)),
        H2code::Context::ContextMessage.new(H2code::LLM::Message.tool("out", "c1")),
        H2code::Context::ContextMessage.new(H2code::LLM::Message.user("short")),
      ]
      kept = H2code::Context::Compaction.take_recent_within_token_budget(cms, 10)
      kept.size.should eq(1)
      kept.first.message.text.should eq("short")
    end
  end

  describe ".input_rejection?" do
    it "matches 413 and input-blaming 400s regardless of request size" do
      overflow_413 = H2code::LLM::ApiError.new(413, "Chat API error 413: too large")
      H2code::Context::Compaction.input_rejection?(overflow_413).should be_true
      H2code::Context::Compaction.input_rejection?(zai_overflow_error).should be_true
      other_400 = H2code::LLM::ApiError.new(400, "Chat API error 400: invalid model id", retryable: false)
      H2code::Context::Compaction.input_rejection?(other_400).should be_false
      rate_limited = H2code::LLM::ApiError.new(429, "Chat API error 429: rate limited")
      H2code::Context::Compaction.input_rejection?(rate_limited).should be_false
    end
  end

  describe ".overflow_error?" do
    it "classifies 413 and Z.AI-style oversized-input 400s" do
      overflow_413 = H2code::LLM::ApiError.new(413, "Chat API error 413: too large")
      H2code::Context::Compaction.overflow_error?(overflow_413, 600, 1000).should be_true
      # Estimate below the recovery ratio: shrinking cannot be the fix.
      H2code::Context::Compaction.overflow_error?(overflow_413, 400, 1000).should be_false
      # 400 with a matching body and a near-full request.
      H2code::Context::Compaction.overflow_error?(zai_overflow_error, 900, 1000).should be_true
      # 400 that does not blame the input (e.g. invalid model).
      other_400 = H2code::LLM::ApiError.new(400, "Chat API error 400: invalid model id", retryable: false)
      H2code::Context::Compaction.overflow_error?(other_400, 900, 1000).should be_false
    end
  end
end

private class FailingProvider < H2code::LLM::Provider
  def name : String
    "failing"
  end

  def model_name : String
    "failing"
  end

  def fetch_models : Array(String)
    [] of String
  end

  def chat(messages : Array(H2code::LLM::Message), tools : Array(H2code::LLM::ToolDefinition)?,
           system_prompt : String? = nil,
           aborted? : -> Bool = -> { false },
           &_block : H2code::LLM::MessagePart ->) : H2code::LLM::StepResult
    raise "provider down"
  end
end
