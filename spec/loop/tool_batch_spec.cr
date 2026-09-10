require "../spec_helper"

module H2code
  class SleepTool < Tools::Tool
    def name : String
      "Sleep"
    end

    def description : String
      "Sleeps for a configured duration and returns a fixed result."
    end

    def parameters : JSON::Any
      JSON.parse(%({
        "type": "object",
        "properties": {
          "duration_ms": {"type": "integer"},
          "result": {"type": "string"}
        },
        "required": ["duration_ms", "result"]
      }))
    end

    def execute(input : JSON::Any) : Tools::ToolResult
      duration_ms = input["duration_ms"].as_i
      result = input["result"].to_s
      sleep duration_ms.milliseconds
      Tools::ToolResult.success(result)
    end
  end

  # A tool that emits a fixed (possibly binary) result string. Used to verify
  # that the ToolBatch boundary sanitizes invalid-UTF-8 / control-byte output
  # before it reaches the context and the wire.
  class BinaryTool < Tools::Tool
    @payload : String

    def initialize(@payload : String)
    end

    def name : String
      "Binary"
    end

    def description : String
      "Returns a fixed payload."
    end

    def parameters : JSON::Any
      JSON.parse(%({"type":"object","properties":{}}))
    end

    def execute(input : JSON::Any) : Tools::ToolResult
      Tools::ToolResult.success(@payload)
    end
  end

  # A tool that emits a media data-URL alongside its text result — the
  # ReadMediaFile delivery shape. Verifies the batch assembles a multi-part
  # tool message (text + native image content part) instead of inline base64.
  class MediaTool < Tools::Tool
    def name : String
      "Media"
    end

    def description : String
      "Returns a text result plus a media data-URL."
    end

    def parameters : JSON::Any
      JSON.parse(%({"type":"object","properties":{}}))
    end

    def execute(input : JSON::Any) : Tools::ToolResult
      result = Tools::ToolResult.success("<image path=\"img.png\">\n[media: image, image/png, 8 bytes]\n</image>")
      result.media = ["data:image/png;base64,aVBOR"]
      result
    end
  end

  module ToolBatchSpecHelper
    def self.make_registry(tools : Array(Tools::Tool)) : Tools::Registry
      registry = Tools::Registry.new
      tools.each { |t| registry.register(t) }
      registry
    end

    def self.make_batch(tools : Array(Tools::Tool),
                        permission : Permission::Manager? = nil,
                        context : Context::Memory? = nil) : Loop::ToolBatch
      Loop::ToolBatch.new(
        registry: make_registry(tools),
        permission: permission || Permission::Manager.new(Permission::Mode::Yolo),
        dedup: Loop::DedupTracker.new,
        abort_controller: Loop::AbortController.new,
        context: context || Context::Memory.new,
      )
    end

    def self.tool_call(id : String, name : String, args : String = "{}") : LLM::ToolCall
      LLM::ToolCall.new(id, LLM::ToolCallFunction.new(name, args))
    end
  end
end

describe H2code::Loop::ToolBatch do
  helper = H2code::ToolBatchSpecHelper

  it "executes independent tool calls in parallel" do
    batch = helper.make_batch([H2code::SleepTool.new])

    calls = [
      helper.tool_call("call_1", "Sleep", %({"duration_ms":150,"result":"a"})),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":150,"result":"b"})),
    ]

    events = [] of H2code::Loop::Event
    started = Time.monotonic
    results = batch.run(calls) { |e| events << e }
    elapsed = Time.monotonic - started

    results.size.should eq(2)
    results.map(&.tool_call_id).should eq(["call_1", "call_2"])
    # Parallel: two 150ms sleeps should finish in well under 300ms even with scheduler jitter.
    elapsed.total_milliseconds.should be < 275
  end

  it "preserves result order regardless of completion order" do
    batch = helper.make_batch([H2code::SleepTool.new])

    calls = [
      helper.tool_call("call_1", "Sleep", %({"duration_ms":200,"result":"slow-first"})),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":20,"result":"fast-second"})),
    ]

    results = batch.run(calls) { |_| }

    results.size.should eq(2)
    results[0].tool_call_id.should eq("call_1")
    results[1].tool_call_id.should eq("call_2")
    results[0].text.should contain("slow-first")
    results[1].text.should contain("fast-second")
  end

  it "emits tool_result events as results arrive" do
    batch = helper.make_batch([H2code::SleepTool.new])

    calls = [
      helper.tool_call("call_1", "Sleep", %({"duration_ms":150,"result":"a"})),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":20,"result":"b"})),
    ]

    result_events = [] of H2code::Loop::Event
    batch.run(calls) do |e|
      result_events << e if e.type.tool_result?
    end

    result_events.size.should eq(2)
    # The faster tool should report first even though it is second in the batch.
    result_events[0].tool_call_id.should eq("call_2")
    result_events[1].tool_call_id.should eq("call_1")
  end

  it "returns an error for unknown tools without affecting others" do
    batch = helper.make_batch([H2code::SleepTool.new])

    calls = [
      helper.tool_call("call_1", "MissingTool"),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":20,"result":"ok"})),
    ]

    events = [] of H2code::Loop::Event
    results = batch.run(calls) { |e| events << e }

    results.size.should eq(2)
    results[0].text.should contain("Unknown tool")
    results[1].text.should contain("ok")
  end

  it "deduplicates identical calls within the same step" do
    batch = helper.make_batch([H2code::SleepTool.new])

    calls = [
      helper.tool_call("call_1", "Sleep", %({"duration_ms":20,"result":"only-once"})),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":20,"result":"only-once"})),
    ]

    results = batch.run(calls) { |_| }

    results.size.should eq(2)
    results[0].text.should contain("only-once")
    results[1].text.should contain("Duplicate")
  end

  it "aborts running tool fibers" do
    batch = helper.make_batch([H2code::SleepTool.new])

    calls = [
      helper.tool_call("call_1", "Sleep", %({"duration_ms":5000,"result":"never"})),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":20,"result":"quick"})),
    ]

    abort = batch.@abort_controller
    spawn do
      sleep 50.milliseconds
      abort.abort("test cancel")
    end

    results = batch.run(calls) { |_| }

    # The quick tool should finish; the long one should be cancelled or time out.
    results.size.should eq(2)
    results[0].text.should match(/Cancelled|timed out|Execution failed/)
    results[1].text.should contain("quick")
  end

  it "appends tool results to context in input order" do
    context = H2code::Context::Memory.new
    batch = helper.make_batch([H2code::SleepTool.new], context: context)

    calls = [
      helper.tool_call("call_1", "Sleep", %({"duration_ms":200,"result":"slow"})),
      helper.tool_call("call_2", "Sleep", %({"duration_ms":20,"result":"fast"})),
    ]

    batch.run(calls) { |_| }

    tool_messages = context.messages.select { |m| m.role == "tool" }
    tool_messages.size.should eq(2)
    tool_messages[0].tool_call_id.should eq("call_1")
    tool_messages[1].tool_call_id.should eq("call_2")
    tool_messages[0].text.should contain("slow")
    tool_messages[1].text.should contain("fast")
  end

  it "sanitizes binary / invalid-UTF-8 tool output before it reaches the wire" do
    # ELF magic + invalid continuation bytes + a NUL, exactly the failure mode
    # behind "Chat API error 400" when an agent `cat`s a compiled binary.
    binary = String.new(Bytes[0x7F, 0x45, 0x4C, 0x46, 0xFF, 0xFE, 0x00, 0x1B])
    context = H2code::Context::Memory.new
    batch = helper.make_batch([H2code::BinaryTool.new(binary)], context: context)

    results = batch.run([helper.tool_call("call_1", "Binary")]) { |_| }

    content = results[0].text
    content.valid_encoding?.should be_true
    content.should contain(H2code::Tools::Tool::SANITIZE_NOTICE)

    # The persisted tool message must also be clean and JSON-serializable.
    msg = context.messages.find! { |m| m.role == "tool" }
    msg.text.valid_encoding?.should be_true
    json = String.build do |io|
      JSON.build(io) { |b| msg.to_wire_json(b) }
    end
    json.valid_encoding?.should be_true
    json.should contain("\"role\":\"tool\"")
  end

  it "delivers tool media as native image content parts" do
    context = H2code::Context::Memory.new
    batch = helper.make_batch([H2code::MediaTool.new], context: context)

    results = batch.run([helper.tool_call("call_1", "Media")]) { |_| }

    msg = results[0]
    msg.role.should eq("tool")
    msg.content.size.should eq(2)
    msg.content[0].should be_a(H2code::LLM::TextContent)
    img = msg.content[1].should be_a(H2code::LLM::ImageContent)
    img.image_url.url.should eq("data:image/png;base64,aVBOR")
    # Text stays clean — no base64 in the textual context.
    msg.text.should_not contain("base64")

    # The persisted context message carries the same parts.
    persisted = context.messages.find! { |m| m.role == "tool" }
    persisted.content[1].should be_a(H2code::LLM::ImageContent)

    # Wire shape: role=tool with a content array containing an image_url part.
    json = String.build do |io|
      JSON.build(io) { |b| msg.to_wire_json(b) }
    end
    json.should contain("\"role\":\"tool\"")
    json.should contain("\"type\":\"image_url\"")
    json.should contain("data:image/png;base64,aVBOR")
  end
end
