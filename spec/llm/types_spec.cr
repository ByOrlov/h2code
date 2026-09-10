require "../spec_helper"

describe H2code::LLM::Message do
  describe ".user" do
    it "creates a user message" do
      msg = H2code::LLM::Message.user("hello")
      msg.role.should eq("user")
      msg.text.should eq("hello")
      msg.tool_calls.should be_nil
      msg.tool_call_id.should be_nil
    end

    it "wraps the string in a single TextContent part" do
      msg = H2code::LLM::Message.user("hello")
      msg.content.size.should eq(1)
      msg.content[0].is_a?(H2code::LLM::TextContent).should be_true
      msg.content[0].as(H2code::LLM::TextContent).text.should eq("hello")
    end
  end

  describe ".assistant" do
    it "creates an assistant message with text only" do
      msg = H2code::LLM::Message.assistant("hi there")
      msg.role.should eq("assistant")
      msg.text.should eq("hi there")
      msg.tool_calls.should be_nil
    end

    it "creates an assistant message with tool_calls" do
      tc = H2code::LLM::ToolCall.new("call_1", H2code::LLM::ToolCallFunction.new(H2code::Tools::Names::BASH, "{\"command\":\"ls\"}"))
      msg = H2code::LLM::Message.assistant("", [tc])
      msg.role.should eq("assistant")
      msg.tool_calls.should_not be_nil
      if tcs = msg.tool_calls
        tcs.size.should eq(1)
        tcs[0].name.should eq(H2code::Tools::Names::BASH)
      end
    end

    it "builds from content parts via assistant_parts" do
      parts = [
        H2code::LLM::ThinkContent.new("reasoning here"),
        H2code::LLM::TextContent.new("final answer"),
      ] of H2code::LLM::ContentPart
      msg = H2code::LLM::Message.assistant_parts(parts)
      msg.role.should eq("assistant")
      msg.text.should eq("final answer")
      msg.thinking.should eq("reasoning here")
    end
  end

  describe ".tool" do
    it "creates a tool result message" do
      msg = H2code::LLM::Message.tool("result text", "call_1")
      msg.role.should eq("tool")
      msg.text.should eq("result text")
      msg.tool_call_id.should eq("call_1")
    end
  end

  describe "JSON serialization" do
    it "serializes content as an array of typed parts" do
      msg = H2code::LLM::Message.user("test")
      json = JSON.parse(msg.to_json)
      json["role"].should eq("user")
      json["content"].as_a.size.should eq(1)
      json["content"][0]["type"].should eq("text")
      json["content"][0]["text"].should eq("test")
      json.as_h.has_key?("tool_calls").should be_false
      json.as_h.has_key?("tool_call_id").should be_false
    end

    it "includes tool_calls when present" do
      tc = H2code::LLM::ToolCall.new("call_1", H2code::LLM::ToolCallFunction.new(H2code::Tools::Names::BASH, "{}"))
      msg = H2code::LLM::Message.assistant(nil, [tc])
      json = JSON.parse(msg.to_json)
      json["tool_calls"].as_a.size.should eq(1)
    end

    it "round-trips TextContent and ThinkContent through JSON" do
      parts = [
        H2code::LLM::ThinkContent.new("reasoning"),
        H2code::LLM::TextContent.new("answer"),
      ] of H2code::LLM::ContentPart
      msg = H2code::LLM::Message.assistant_parts(parts)
      json = JSON.parse(msg.to_json)
      json["content"].as_a.size.should eq(2)
      json["content"][0]["type"].should eq("think")
      json["content"][0]["think"].should eq("reasoning")
      json["content"][1]["type"].should eq("text")
      json["content"][1]["text"].should eq("answer")

      restored = H2code::LLM::Message.from_json(msg.to_json)
      restored.text.should eq("answer")
      restored.thinking.should eq("reasoning")
    end
  end
end

describe H2code::LLM::Usage do
  it "adds two usages" do
    u1 = H2code::LLM::Usage.new(prompt_tokens: 100, completion_tokens: 50, total_tokens: 150)
    u2 = H2code::LLM::Usage.new(prompt_tokens: 200, completion_tokens: 100, total_tokens: 300)
    combined = u1 + u2
    combined.prompt_tokens.should eq(300)
    combined.completion_tokens.should eq(150)
    combined.total_tokens.should eq(450)
  end
end

describe H2code::LLM::StreamChunk do
  it "parses usage from the top-level field" do
    chunk = H2code::LLM::StreamChunk.from_json(%({"usage":{"prompt_tokens":42,"completion_tokens":7,"total_tokens":49}}))
    u = chunk.usage || raise "usage should not be nil"
    u.prompt_tokens.should eq(42)
    u.completion_tokens.should eq(7)
  end

  it "parses Moonshot-proprietary usage from choices[0].usage" do
    chunk = H2code::LLM::StreamChunk.from_json(%({"choices":[{"index":0,"usage":{"prompt_tokens":120,"completion_tokens":30,"total_tokens":150}}]}))
    chunk.usage.should be_nil
    choice_usage = chunk.choices.first.usage || raise "usage should not be nil"
    choice_usage.prompt_tokens.should eq(120)
    choice_usage.completion_tokens.should eq(30)
  end
end

describe "Message wire serialization" do
  it "serializes a single text part as a plain string content" do
    msg = H2code::LLM::Message.user("hello")
    json = JSON.parse(JSON.build { |b| msg.to_wire_json(b) })
    json["role"].should eq("user")
    json["content"].as_s.should eq("hello")
    json.as_h.has_key?("reasoning_content").should be_false
    json.as_h.has_key?("tool_calls").should be_false
  end

  it "lifts ThinkContent to top-level reasoning_content and strips it from content" do
    parts = [
      H2code::LLM::ThinkContent.new("reasoning here"),
      H2code::LLM::TextContent.new("final answer"),
    ] of H2code::LLM::ContentPart
    msg = H2code::LLM::Message.assistant_parts(parts)
    json = JSON.parse(JSON.build { |b| msg.to_wire_json(b) })

    # content must NOT contain a think part — only the text part
    json["content"].as_s.should eq("final answer")
    json["reasoning_content"].as_s.should eq("reasoning here")
    json.as_h.has_key?("tool_calls").should be_false
  end

  it "omits content when an assistant tool-call message has only empty text" do
    tc = H2code::LLM::ToolCall.new("call_1", H2code::LLM::ToolCallFunction.new(H2code::Tools::Names::BASH, "{}"))
    msg = H2code::LLM::Message.assistant("", [tc])
    json = JSON.parse(JSON.build { |b| msg.to_wire_json(b) })
    json["role"].should eq("assistant")
    json.as_h.has_key?("content").should be_false
    json["tool_calls"].as_a.size.should eq(1)
  end

  it "round-trips tool_call_id on tool messages" do
    msg = H2code::LLM::Message.tool("result text", "call_42")
    json = JSON.parse(JSON.build { |b| msg.to_wire_json(b) })
    json["role"].should eq("tool")
    json["content"].as_s.should eq("result text")
    json["tool_call_id"].should eq("call_42")
  end

  it "serializes multiple non-text parts as a content array" do
    img = H2code::LLM::ImageContent.new(H2code::LLM::ImageRef.new("data:image/png;base64,abc"))
    parts = [
      H2code::LLM::TextContent.new("see image"),
      img,
    ] of H2code::LLM::ContentPart
    msg = H2code::LLM::Message.user(parts)
    json = JSON.parse(JSON.build { |b| msg.to_wire_json(b) })
    json["content"].as_a.size.should eq(2)
    json["content"][0]["type"].should eq("text")
    json["content"][1]["type"].should eq("image_url")
    json["content"][1]["image_url"]["url"].should eq("data:image/png;base64,abc")
  end
end

describe H2code::LLM::ChatRequest do
  it "emits only the base fields when nothing extra is configured" do
    req = H2code::LLM::ChatRequest.new("m", [H2code::LLM::Message.user("hi")])
    json = JSON.parse(req.to_json)
    json["model"].should eq("m")
    json["stream"].should eq(true)
    json.as_h.has_key?("prompt_cache_key").should be_false
    json.as_h.has_key?("max_completion_tokens").should be_false
    json.as_h.has_key?("thinking").should be_false
  end

  it "includes prompt_cache_key and stream_options when streaming" do
    req = H2code::LLM::ChatRequest.new("m", [H2code::LLM::Message.user("hi")], stream: true)
    req.prompt_cache_key = "sess-123"
    json = JSON.parse(req.to_json)
    json["prompt_cache_key"].should eq("sess-123")
    json["stream_options"]["include_usage"].should be_true
  end

  it "prefers max_completion_tokens over the legacy max_tokens alias" do
    req = H2code::LLM::ChatRequest.new("m", [H2code::LLM::Message.user("hi")], max_tokens: 4096)
    req.max_completion_tokens = 1024
    json = JSON.parse(req.to_json)
    json["max_completion_tokens"].should eq(1024)
    json.as_h.has_key?("max_tokens").should be_false
  end

  it "falls back to max_tokens when max_completion_tokens is unset" do
    req = H2code::LLM::ChatRequest.new("m", [H2code::LLM::Message.user("hi")], max_tokens: 4096)
    json = JSON.parse(req.to_json)
    json["max_tokens"].should eq(4096)
  end

  describe "thinking wire dialects" do
    it "Moonshot dialect emits a thinking object without effort for boolean-only models" do
      req = H2code::LLM::ChatRequest.new("m", [H2code::LLM::Message.user("hi")])
      req.thinking = H2code::LLM::ThinkingConfig.new("enabled")
      json = JSON.parse(req.to_json)
      json["thinking"]["type"].should eq("enabled")
      json["thinking"].as_h.has_key?("effort").should be_false
    end

    it "reasoning_effort dialect emits a top-level string" do
      req = H2code::LLM::ChatRequest.new("m", [H2code::LLM::Message.user("hi")])
      req.reasoning_effort = "medium"
      json = JSON.parse(req.to_json)
      json["reasoning_effort"].should eq("medium")
      json.as_h.has_key?("thinking").should be_false
    end
  end

  it "includes parallel_tool_calls when set" do
    tool = H2code::LLM::ToolDefinition.new(H2code::LLM::ToolFunction.new(H2code::Tools::Names::READ, "reads", JSON.parse("{}")))
    req = H2code::LLM::ChatRequest.new("m", [H2code::LLM::Message.user("hi")], tools: [tool])
    req.parallel_tool_calls = true
    json = JSON.parse(req.to_json)
    json["parallel_tool_calls"].should be_true
  end

  it "omits parallel_tool_calls when unset" do
    req = H2code::LLM::ChatRequest.new("m", [H2code::LLM::Message.user("hi")])
    json = JSON.parse(req.to_json)
    json.as_h.has_key?("parallel_tool_calls").should be_false
  end
end

describe H2code::LLM::ApiError do
  describe ".retryable_status?" do
    it "treats rate-limit and request-timeout as retryable" do
      H2code::LLM::ApiError.retryable_status?(408).should be_true
      H2code::LLM::ApiError.retryable_status?(429).should be_true
    end

    it "treats 5xx server errors as retryable" do
      H2code::LLM::ApiError.retryable_status?(500).should be_true
      H2code::LLM::ApiError.retryable_status?(502).should be_true
      H2code::LLM::ApiError.retryable_status?(503).should be_true
      H2code::LLM::ApiError.retryable_status?(504).should be_true
    end

    it "treats auth/quota/not-found/bad-request as non-retryable" do
      {400, 401, 403, 404, 422}.each do |code|
        H2code::LLM::ApiError.retryable_status?(code).should be_false
      end
    end
  end

  it "carries status code and the computed retryable flag" do
    err = H2code::LLM::ApiError.new(403, "quota exceeded", retryable: false)
    err.status_code.should eq(403)
    err.retryable?.should be_false
    (err.message || "").should contain("quota exceeded")
  end

  describe ".extract_message" do
    it "pulls the message out of an OpenAI-style error envelope" do
      body = %({"error":{"message":"membership not active","type":"invalid_request_error"}})
      H2code::LLM::ApiError.extract_message("Chat API error 402", body)
        .should eq("Chat API error 402: membership not active")
    end

    it "handles a string-valued error field" do
      body = %({"error":"rate limited"})
      H2code::LLM::ApiError.extract_message("x", body).should eq("x: rate limited")
    end

    it "handles a top-level message field" do
      body = %({"message":"nope"})
      H2code::LLM::ApiError.extract_message("x", body).should eq("x: nope")
    end

    it "handles a top-level detail field" do
      body = %({"detail":"forbidden"})
      H2code::LLM::ApiError.extract_message("x", body).should eq("x: forbidden")
    end

    it "falls back to the full raw body when it is not JSON" do
      H2code::LLM::ApiError.extract_message("x", "plain text").should eq("x: plain text")
    end

    it "returns the full original body when JSON has no recognized field" do
      body = %({"foo":"bar"}).to_s
      H2code::LLM::ApiError.extract_message("x", body).should eq("x: #{body}")
    end

    it "returns the full long body verbatim when it cannot be parsed" do
      long = "x" * 500
      result = H2code::LLM::ApiError.extract_message("x", long)
      result.should eq("x: #{long}")
    end

    it "returns only the prefix for an empty body" do
      H2code::LLM::ApiError.extract_message("x", "").should eq("x")
    end
  end
end

describe H2code::LLM::Provider do
  it "is the base class of MoonshotProvider" do
    provider = H2code::LLM::MoonshotProvider.new(model: "h2code-for-coding")
    provider.is_a?(H2code::LLM::Provider).should be_true
  end
end

describe H2code::LLM::MoonshotProvider do
  it "identifies itself as the moonshot backend" do
    provider = H2code::LLM::MoonshotProvider.new(model: "h2code-for-coding")
    provider.name.should eq("moonshot")
  end

  it "exposes the upstream model name" do
    provider = H2code::LLM::MoonshotProvider.new(model: "h2code-for-coding")
    provider.model_name.should eq("h2code-for-coding")
  end

  it "shares the OpenAI Chat Completions transport" do
    provider = H2code::LLM::MoonshotProvider.new(model: "h2code-for-coding")
    provider.is_a?(H2code::LLM::OpenAIChatProvider).should be_true
  end
end

describe H2code::LLM::ZaiProvider do
  it "is a Provider sharing the OpenAI Chat Completions transport" do
    provider = H2code::LLM::ZaiProvider.new(api_key: "sk-test")
    provider.is_a?(H2code::LLM::Provider).should be_true
    provider.is_a?(H2code::LLM::OpenAIChatProvider).should be_true
  end

  it "identifies itself as the zai backend" do
    provider = H2code::LLM::ZaiProvider.new(api_key: "sk-test")
    provider.name.should eq("zai")
  end

  it "defaults to the GLM coding model and the z.ai paas endpoint" do
    provider = H2code::LLM::ZaiProvider.new(api_key: "sk-test")
    provider.model_name.should eq("glm-4.6")
    provider.endpoint.should eq("https://api.z.ai/api/paas/v4")
  end

  it "authenticates with the plain API key (no OAuth)" do
    provider = H2code::LLM::ZaiProvider.new(api_key: "sk-test")
    provider.token.should eq("sk-test")
  end

  it "honours an explicit model and endpoint override" do
    provider = H2code::LLM::ZaiProvider.new(model: "glm-4.7", endpoint: "https://custom.example/v4", api_key: "k")
    provider.model_name.should eq("glm-4.7")
    provider.endpoint.should eq("https://custom.example/v4")
  end
end

describe H2code::LLM::OllamaProvider do
  it "is a Provider sharing the OpenAI Chat Completions transport" do
    provider = H2code::LLM::OllamaProvider.new
    provider.is_a?(H2code::LLM::Provider).should be_true
    provider.is_a?(H2code::LLM::OpenAIChatProvider).should be_true
  end

  it "identifies itself as the ollama backend" do
    provider = H2code::LLM::OllamaProvider.new
    provider.name.should eq("ollama")
  end

  it "defaults to llama3.2 on localhost:11434" do
    provider = H2code::LLM::OllamaProvider.new
    provider.model_name.should eq("llama3.2")
    provider.endpoint.should eq("http://localhost:11434/v1")
  end

  it "uses an empty token so auth is omitted on the wire" do
    provider = H2code::LLM::OllamaProvider.new
    provider.token.should eq("")
  end

  it "honours an explicit model and endpoint override" do
    provider = H2code::LLM::OllamaProvider.new(model: "qwen2.5", endpoint: "http://gpu-box:11434/v1")
    provider.model_name.should eq("qwen2.5")
    provider.endpoint.should eq("http://gpu-box:11434/v1")
  end
end

describe H2code::LLM::LmStudioProvider do
  it "is a Provider sharing the OpenAI Chat Completions transport" do
    provider = H2code::LLM::LmStudioProvider.new
    provider.is_a?(H2code::LLM::Provider).should be_true
    provider.is_a?(H2code::LLM::OpenAIChatProvider).should be_true
  end

  it "identifies itself as the lmstudio backend" do
    provider = H2code::LLM::LmStudioProvider.new
    provider.name.should eq("lmstudio")
  end

  it "defaults to localhost:1234" do
    provider = H2code::LLM::LmStudioProvider.new
    provider.endpoint.should eq("http://localhost:1234/v1")
  end

  it "uses an empty token so auth is omitted on the wire" do
    provider = H2code::LLM::LmStudioProvider.new
    provider.token.should eq("")
  end
end

describe H2code::LLM::MockProvider do
  it "is a Provider that needs no key or network" do
    provider = H2code::LLM::MockProvider.new
    provider.is_a?(H2code::LLM::Provider).should be_true
    provider.name.should eq("mock")
    provider.model_name.should eq("mock")
  end

  it "replays the script step by step and terminates" do
    provider = H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::ToolCallPart.new("c1", H2code::Tools::Names::BASH, %({"command":"echo hi"}))] of H2code::LLM::MessagePart,
        stop_reason: "tool_use",
      ),
      H2code::LLM::MockStep.new(
        parts: [H2code::LLM::TextPart.new("done")] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "done",
      ),
    ])

    first = provider.chat([] of H2code::LLM::Message, nil) { }
    first.tool_use?.should be_true
    first.tool_calls.size.should eq(1)

    second = provider.chat([] of H2code::LLM::Message, nil) { }
    second.tool_use?.should be_false
    second.text.should eq("done")
  end

  it "streams the step's parts through the block before returning" do
    provider = H2code::LLM::MockProvider.new([
      H2code::LLM::MockStep.new(
        parts: [
          H2code::LLM::ToolCallPart.new("c1", H2code::Tools::Names::GLOB, %({"pattern":"*"})),
          H2code::LLM::TextPart.new("hello"),
        ] of H2code::LLM::MessagePart,
        stop_reason: "end_turn",
        text: "hello",
      ),
    ])

    seen = [] of H2code::LLM::MessagePart
    provider.chat([] of H2code::LLM::Message, nil) { |part| seen << part }

    seen.any?(H2code::LLM::ToolCallPart).should be_true
    seen.any?(H2code::LLM::TextPart).should be_true
    seen.last.is_a?(H2code::LLM::FinishPart).should be_true
  end
end

describe "LLM provider registry" do
  it "defaults to the moonshot provider" do
    H2code::LLM::DEFAULT_PROVIDER_NAME.should be_nil
  end

  it "lists all providers sorted A→Z by name" do
    names = H2code::LLM::Provider.providers.map(&.name)
    names.should contain("moonshot")
    names.should contain("zai")
    names.should contain("zai-coding-plan")
    names.should contain("ollama")
    names.should contain("lmstudio")
    names.should contain("mock")
    names.should eq(names.sort)
  end

  it "recognises known providers and rejects unknown ones" do
    H2code::LLM::Provider.known_provider?("moonshot").should be_true
    H2code::LLM::Provider.known_provider?("zai").should be_true
    H2code::LLM::Provider.known_provider?("ollama").should be_true
    H2code::LLM::Provider.known_provider?("lmstudio").should be_true
    H2code::LLM::Provider.known_provider?("mock").should be_true
    H2code::LLM::Provider.known_provider?("nope").should be_false
  end
end

describe "LLM model registry" do
  it "MockProvider returns its model id from fetch_models" do
    provider = H2code::LLM::MockProvider.new
    provider.fetch_models.should eq(["mock"])
  end

  it "fetch_models respects a custom model name on MockProvider" do
    provider = H2code::LLM::MockProvider.new(model: "custom-mock")
    provider.fetch_models.should eq(["custom-mock"])
  end
end

describe "OpenAIChatProvider request shaping" do
  it "MoonshotProvider sends prompt_cache_key, thinking and max_completion_tokens" do
    provider = H2code::LLM::MoonshotProvider.new(model: "h2code-for-coding")
    provider.prompt_cache_key = "sess-abc"
    provider.thinking_effort = "medium"
    provider.max_context_tokens = 131072
    provider.used_context_tokens = 1000

    json = JSON.parse(provider.build_request([H2code::LLM::Message.user("hi")], nil).to_json)

    json["prompt_cache_key"].should eq("sess-abc")
    json["thinking"]["type"].should eq("enabled")
    json["stream_options"]["include_usage"].should be_true
    # Moonshot transport speaks max_completion_tokens (not the legacy alias).
    json.as_h.has_key?("max_completion_tokens").should be_true
    json.as_h.has_key?("max_tokens").should be_false
    # Clamped to the remaining window (131072 - 1000).
    json["max_completion_tokens"].should eq(130072)
  end

  it "MoonshotProvider omits effort for boolean-only models (h2code-for-coding has no valid_efforts)" do
    provider = H2code::LLM::MoonshotProvider.new(model: "h2code-for-coding")
    provider.thinking_effort = "medium"

    json = JSON.parse(provider.build_request([H2code::LLM::Message.user("hi")], nil).to_json)

    json["thinking"]["type"].should eq("enabled")
    # No model metadata fetched → treated as boolean-only → no effort field,
    # otherwise the endpoint rejects "medium" with HTTP 400.
    json["thinking"].as_h.has_key?("effort").should be_false
  end

  it "MoonshotProvider sends effort when the model declares it in valid_efforts" do
    provider = H2code::LLM::MoonshotProvider.new(model: "k3")
    provider.thinking_effort = "high"
    provider.valid_efforts = ["low", "high", "max"]
    provider.default_effort = "max"

    json = JSON.parse(provider.build_request([H2code::LLM::Message.user("hi")], nil).to_json)

    json["thinking"]["type"].should eq("enabled")
    json["thinking"]["effort"].should eq("high")
  end

  it "MoonshotProvider falls back to default_effort when the requested one is unsupported" do
    provider = H2code::LLM::MoonshotProvider.new(model: "k3")
    provider.thinking_effort = "medium" # not in valid_efforts
    provider.valid_efforts = ["low", "high", "max"]
    provider.default_effort = "max"

    json = JSON.parse(provider.build_request([H2code::LLM::Message.user("hi")], nil).to_json)

    json["thinking"]["type"].should eq("enabled")
    json["thinking"]["effort"].should eq("max")
  end

  it "MoonshotProvider disables thinking for the off token" do
    provider = H2code::LLM::MoonshotProvider.new(model: "h2code-for-coding")
    provider.thinking_effort = "off"

    json = JSON.parse(provider.build_request([H2code::LLM::Message.user("hi")], nil).to_json)

    json["thinking"]["type"].should eq("disabled")
    json["thinking"].as_h.has_key?("effort").should be_false
  end

  it "ZaiProvider uses the legacy max_tokens alias and sends reasoning_effort" do
    provider = H2code::LLM::ZaiProvider.new(api_key: "sk-test")
    provider.prompt_cache_key = "sess-xyz"
    provider.thinking_effort = "medium"
    provider.max_context_tokens = 131072

    json = JSON.parse(provider.build_request([H2code::LLM::Message.user("hi")], nil).to_json)

    # prompt_cache_key is harmless for OpenAI-compatible endpoints and is sent.
    json["prompt_cache_key"].should eq("sess-xyz")
    # GLM speaks top-level reasoning_effort, not the Moonshot thinking object.
    json["reasoning_effort"].should eq("medium")
    json.as_h.has_key?("thinking").should be_false
    # Plain OpenAI-compatible backend → legacy max_tokens, not max_completion_tokens.
    json.as_h.has_key?("max_tokens").should be_true
    json.as_h.has_key?("max_completion_tokens").should be_false
  end

  it "ZaiProvider omits reasoning_effort for off/on tokens" do
    provider = H2code::LLM::ZaiProvider.new(api_key: "sk-test")
    provider.thinking_effort = "on"

    json = JSON.parse(provider.build_request([H2code::LLM::Message.user("hi")], nil).to_json)

    json.as_h.has_key?("reasoning_effort").should be_false
    json.as_h.has_key?("thinking").should be_false
  end

  it "OllamaProvider sends no thinking/reasoning_effort and uses legacy max_tokens" do
    provider = H2code::LLM::OllamaProvider.new
    provider.prompt_cache_key = "sess-local"
    provider.thinking_effort = "medium"
    provider.max_context_tokens = 8192

    json = JSON.parse(provider.build_request([H2code::LLM::Message.user("hi")], nil).to_json)

    json["prompt_cache_key"].should eq("sess-local")
    json.as_h.has_key?("thinking").should be_false
    json.as_h.has_key?("reasoning_effort").should be_false
    json.as_h.has_key?("max_tokens").should be_true
    json.as_h.has_key?("max_completion_tokens").should be_false
  end

  it "LmStudioProvider sends no thinking/reasoning_effort" do
    provider = H2code::LLM::LmStudioProvider.new
    provider.thinking_effort = "high"

    json = JSON.parse(provider.build_request([H2code::LLM::Message.user("hi")], nil).to_json)

    json.as_h.has_key?("thinking").should be_false
    json.as_h.has_key?("reasoning_effort").should be_false
  end

  it "leaves the completion budget unset when no context window is configured" do
    provider = H2code::LLM::MoonshotProvider.new(model: "h2code-for-coding")
    json = JSON.parse(provider.build_request([H2code::LLM::Message.user("hi")], nil).to_json)
    json.as_h.has_key?("max_completion_tokens").should be_false
    json.as_h.has_key?("max_tokens").should be_false
  end

  it "enables parallel_tool_calls when tools are present" do
    provider = H2code::LLM::MoonshotProvider.new(model: "h2code-for-coding")
    tool = H2code::LLM::ToolDefinition.new(H2code::LLM::ToolFunction.new(H2code::Tools::Names::READ, "reads", JSON.parse("{}")))
    json = JSON.parse(provider.build_request([H2code::LLM::Message.user("hi")], [tool]).to_json)
    json["parallel_tool_calls"].should be_true
  end

  it "omits parallel_tool_calls when no tools are present" do
    provider = H2code::LLM::MoonshotProvider.new(model: "h2code-for-coding")
    json = JSON.parse(provider.build_request([H2code::LLM::Message.user("hi")], nil).to_json)
    json.as_h.has_key?("parallel_tool_calls").should be_false
  end
end

describe "Message#without_media" do
  it "strips image parts from a mixed text + image message" do
    parts = [
      H2code::LLM::TextContent.new("here is a screenshot"),
      H2code::LLM::ImageContent.new(H2code::LLM::ImageRef.new("data:image/png;base64,AAAA")),
    ] of H2code::LLM::ContentPart
    msg = H2code::LLM::Message.user(parts).without_media

    msg.content.size.should eq(1)
    msg.content.first.should be_a(H2code::LLM::TextContent)
    msg.text.should eq("here is a screenshot")
  end

  it "keeps audio and video out too" do
    parts = [
      H2code::LLM::TextContent.new("t"),
      H2code::LLM::AudioContent.new(H2code::LLM::AudioRef.new("data:audio/wav;base64,AAAA")),
      H2code::LLM::VideoContent.new(H2code::LLM::VideoRef.new("data:video/mp4;base64,AAAA")),
    ] of H2code::LLM::ContentPart
    msg = H2code::LLM::Message.user(parts).without_media

    msg.content.size.should eq(1)
    msg.content.first.should be_a(H2code::LLM::TextContent)
  end

  it "inserts a placeholder when the message was media-only" do
    parts = [H2code::LLM::ImageContent.new(H2code::LLM::ImageRef.new("data:image/png;base64,AAAA"))] of H2code::LLM::ContentPart
    msg = H2code::LLM::Message.user(parts).without_media

    msg.content.size.should eq(1)
    msg.content.first.should be_a(H2code::LLM::TextContent)
    msg.text.should contain("only accepts text")
  end

  it "keeps think parts and preserves tool metadata" do
    parts = [
      H2code::LLM::TextContent.new("look"),
      H2code::LLM::ImageContent.new(H2code::LLM::ImageRef.new("data:image/png;base64,AAAA")),
      H2code::LLM::ThinkContent.new("hmm"),
    ] of H2code::LLM::ContentPart
    original = H2code::LLM::Message.tool_parts(parts, "call-1")
    msg = original.without_media

    msg.tool_call_id.should eq("call-1")
    msg.content.size.should eq(2)
    msg.thinking.should eq("hmm")
    # The original message is untouched (struct copy, not in-place edit).
    original.content.size.should eq(3)
  end

  it "returns self when there is no media" do
    msg = H2code::LLM::Message.user("plain")
    msg.without_media.text.should eq("plain")
  end
end

describe "ApiError#text_only_rejection?" do
  it "matches the GLM text-only content-type 400" do
    ex = H2code::LLM::ApiError.new(400,
      "Chat API error 400: messages.content.type is invalid, allowed values: ['text']",
      false)
    ex.text_only_rejection?.should be_true
  end

  it "does not match endpoints that accept text plus images" do
    ex = H2code::LLM::ApiError.new(400,
      "Chat API error 400: messages.content.type is invalid, allowed values: ['text', 'image_url']",
      false)
    ex.text_only_rejection?.should be_false
  end

  it "does not match other 400s or retryable statuses" do
    H2code::LLM::ApiError.new(400, "Chat API error 400: invalid tool definition", false)
      .text_only_rejection?.should be_false
    H2code::LLM::ApiError.new(500, "messages.content.type is invalid, allowed values: ['text']", true)
      .text_only_rejection?.should be_false
  end
end
