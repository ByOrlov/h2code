require "../spec_helper"
require "../support/mock_http_transport"

private def find_tool(name : String) : H2code::Tools::ZaiVision::Tool
  H2code::Tools::ZaiVision::Tool.all.find { |t| t.name == name }.as(H2code::Tools::ZaiVision::Tool)
end

private def wired_service(response_body : String = %({"choices":[{"message":{"content":"all good"}}]}))
  mock = H2code::MockHttpTransport.new
  mock.response_body = response_body
  mock.response_status = 200
  H2code::Tools::ZaiVision::Tool.service = H2code::Tools::ZaiVision::Service.new(
    api_key: "test-key", transport: mock, retries: 0)
  mock
end

private def tool_input(fields : Hash(String, String)) : JSON::Any
  JSON.parse(fields.to_json)
end

describe H2code::Tools::ZaiVision do
  after_each do
    H2code::Tools::ZaiVision::Tool.service = nil
  end

  describe ".all" do
    it "exposes all eight tools with unique Names constants" do
      tools = H2code::Tools::ZaiVision::Tool.all
      tools.size.should eq(8)
      names = tools.map(&.name)
      names.should eq([
        H2code::Tools::Names::UI_TO_ARTIFACT,
        H2code::Tools::Names::EXTRACT_TEXT_FROM_SCREENSHOT,
        H2code::Tools::Names::DIAGNOSE_ERROR_SCREENSHOT,
        H2code::Tools::Names::UNDERSTAND_TECHNICAL_DIAGRAM,
        H2code::Tools::Names::ANALYZE_DATA_VISUALIZATION,
        H2code::Tools::Names::UI_DIFF_CHECK,
        H2code::Tools::Names::ANALYZE_IMAGE,
        H2code::Tools::Names::ANALYZE_VIDEO,
      ])
      names.size.should eq(names.uniq.size)
    end

    it "descriptions are non-empty and schemas strict" do
      H2code::Tools::ZaiVision::Tool.all.each do |tool|
        tool.description.size.should be > 20
        tool.parameters["type"].as_s.should eq("object")
        tool.parameters["additionalProperties"].as_bool.should be_false
        tool.parameters["required"].as_a.should_not be_empty
      end
    end

    it "ui_to_artifact schema has the output_type enum" do
      props = find_tool(H2code::Tools::Names::UI_TO_ARTIFACT).parameters["properties"].as_h
      props["output_type"]["enum"].as_a.map(&.to_s).should eq(["code", "prompt", "spec", "description"])
    end
  end

  describe ".available?" do
    it "is true only for the Coding Plan provider with a key" do
      H2code::Tools::ZaiVision::Tool.available?("zai-coding-plan", "key").should be_true
      H2code::Tools::ZaiVision::Tool.available?("zai", "key").should be_false
      H2code::Tools::ZaiVision::Tool.available?("moonshot", "key").should be_false
      H2code::Tools::ZaiVision::Tool.available?("zai-coding-plan", "").should be_false
      H2code::Tools::ZaiVision::Tool.available?("zai-coding-plan", "  ").should be_false
      H2code::Tools::ZaiVision::Tool.available?(nil, "key").should be_false
    end
  end

  describe "#execute" do
    it "errors clearly when no service is wired" do
      H2code::Tools::ZaiVision::Tool.service = nil
      result = find_tool(H2code::Tools::Names::ANALYZE_IMAGE)
        .execute(JSON.parse(%({"image_source":"https://x/a.png","prompt":"what"})))
      result.is_error?.should be_true
      result.content.should contain("not available")
    end

    it "requires a non-empty prompt" do
      wired_service
      result = find_tool(H2code::Tools::Names::ANALYZE_IMAGE)
        .execute(JSON.parse(%({"image_source":"https://x/a.png","prompt":"  "})))
      result.is_error?.should be_true
      result.content.should contain("Prompt is required")
    end

    it "passes remote URLs through as image_url content parts" do
      mock = wired_service
      result = find_tool(H2code::Tools::Names::ANALYZE_IMAGE)
        .execute(JSON.parse(%({"image_source":"https://x/a.png","prompt":"describe"})))
      result.is_error?.should be_false
      result.content.should eq("all good")

      body = JSON.parse(mock.last_body.not_nil!)
      body["model"].as_s.should eq("glm-5.3-flash")
      body["stream"].as_bool.should be_false
      messages = body["messages"].as_a
      messages.size.should eq(2)
      messages[0]["role"].as_s.should eq("system")
      messages[0]["content"].as_s.should eq(
        H2code::Tools::ZaiVisionPrompts::GENERAL_IMAGE_ANALYSIS_PROMPT)
      user_parts = messages[1]["content"].as_a
      user_parts[0]["type"].as_s.should eq("image_url")
      user_parts[0]["image_url"]["url"].as_s.should eq("https://x/a.png")
      user_parts[1]["type"].as_s.should eq("text")
      user_parts[1]["text"].as_s.should eq("describe")
      mock.last_headers.not_nil!["Authorization"].should eq("Bearer test-key")
      mock.last_uri.not_nil!.to_s.should eq("https://api.z.ai/api/paas/v4/chat/completions")
    end

    it "inlines local files as base64 data URLs" do
      mock = wired_service
      path = File.join(Dir.tempdir, "zai_vision_spec_#{Random.new.hex(6)}.png")
      File.write(path, "fake-png-bytes")

      begin
        result = find_tool(H2code::Tools::Names::ANALYZE_IMAGE)
          .execute(tool_input({"image_source" => path, "prompt" => "describe"}))
        result.is_error?.should be_false
        body = JSON.parse(mock.last_body.not_nil!)
        url = body["messages"][1]["content"][0]["image_url"]["url"].as_s
        url.should start_with("data:image/png;base64,")
        url.should contain(Base64.strict_encode("fake-png-bytes"))
      ensure
        File.delete(path)
      end
    end

    it "rejects missing files and unsupported extensions" do
      wired_service
      missing = find_tool(H2code::Tools::Names::ANALYZE_IMAGE)
        .execute(JSON.parse(%({"image_source":"/no/such/file.png","prompt":"x"})))
      missing.is_error?.should be_true
      missing.content.should contain("File not found")

      path = File.join(Dir.tempdir, "zai_vision_spec_#{Random.new.hex(6)}.gif")
      File.write(path, "gif")
      begin
        bad = find_tool(H2code::Tools::Names::ANALYZE_IMAGE)
          .execute(tool_input({"image_source" => path, "prompt" => "x"}))
        bad.is_error?.should be_true
        bad.content.should contain("Unsupported image format")
      ensure
        File.delete(path)
      end
    end

    it "sends videos as video_url parts" do
      mock = wired_service
      result = find_tool(H2code::Tools::Names::ANALYZE_VIDEO)
        .execute(JSON.parse(%({"video_source":"https://x/a.mp4","prompt":"summarize"})))
      result.is_error?.should be_false
      body = JSON.parse(mock.last_body.not_nil!)
      part = body["messages"][0]["content"][0]
      part["type"].as_s.should eq("video_url")
      part["video_url"]["url"].as_s.should eq("https://x/a.mp4")
      # No system prompt for the video tool, mirroring the npm server.
      body["messages"].as_a.size.should eq(1)
    end

    it "appends optional hints exactly like the npm tools" do
      mock = wired_service
      find_tool(H2code::Tools::Names::EXTRACT_TEXT_FROM_SCREENSHOT)
        .execute(JSON.parse(%({"image_source":"https://x/a.png","prompt":"extract","programming_language":"crystal"})))
      body = JSON.parse(mock.last_body.not_nil!)
      body["messages"][1]["content"][1]["text"].as_s
        .should eq("extract\n\n<language_hint>The code is in crystal.</language_hint>")
      body["messages"][0]["content"].as_s.should eq(
        H2code::Tools::ZaiVisionPrompts::TEXT_EXTRACTION_PROMPT)
    end

    it "resolves the ui_to_artifact system prompt by output_type" do
      mock = wired_service
      find_tool(H2code::Tools::Names::UI_TO_ARTIFACT)
        .execute(JSON.parse(%({"image_source":"https://x/a.png","output_type":"spec","prompt":"make a spec"})))
      body = JSON.parse(mock.last_body.not_nil!)
      body["messages"][0]["content"].as_s.should eq(
        H2code::Tools::ZaiVisionPrompts::UI_TO_ARTIFACT_PROMPTS["spec"])
    end

    it "sends two images for ui_diff_check in expected/actual order" do
      mock = wired_service
      find_tool(H2code::Tools::Names::UI_DIFF_CHECK)
        .execute(JSON.parse(%({"expected_image_source":"https://x/e.png","actual_image_source":"https://x/a.png","prompt":"diff"})))
      body = JSON.parse(mock.last_body.not_nil!)
      parts = body["messages"][1]["content"].as_a
      parts[0]["image_url"]["url"].as_s.should eq("https://x/e.png")
      parts[1]["image_url"]["url"].as_s.should eq("https://x/a.png")
    end

    it "surfaces HTTP errors as tool errors" do
      mock = H2code::MockHttpTransport.new
      mock.response_status = 401
      mock.response_body = "unauthorized"
      H2code::Tools::ZaiVision::Tool.service = H2code::Tools::ZaiVision::Service.new(
        api_key: "bad", transport: mock, retries: 0)

      result = find_tool(H2code::Tools::Names::ANALYZE_IMAGE)
        .execute(JSON.parse(%({"image_source":"https://x/a.png","prompt":"x"})))
      result.is_error?.should be_true
      result.content.should contain("401")
    end

    it "accepts array-shaped content responses" do
      wired_service(%({"choices":[{"message":{"content":[{"type":"text","text":"part one"},{"type":"text","text":" part two"}]}}]}))
      result = find_tool(H2code::Tools::Names::ANALYZE_IMAGE)
        .execute(JSON.parse(%({"image_source":"https://x/a.png","prompt":"x"})))
      result.is_error?.should be_false
      result.content.should eq("part one part two")
    end
  end

  describe "Service.for_provider" do
    it "routes Coding Plan to the coding endpoint and payg to PaaS" do
      H2code::Tools::ZaiVision::Service.for_provider("zai-coding-plan", "k")
        .base_url.should eq(H2code::Tools::ZaiVision::Service::CODING_PLAN_BASE_URL)
      H2code::Tools::ZaiVision::Service.for_provider("zai", "k")
        .base_url.should eq(H2code::Tools::ZaiVision::Service::DEFAULT_BASE_URL)
    end
  end

  describe "Service#analyze" do
    it "sends the npm-server request shape" do
      mock = wired_service
      service = H2code::Tools::ZaiVision::Tool.service.not_nil!
      service.analyze("sys", [H2code::Tools::ZaiVision::MediaPart.new("image", "https://x/a.png")], "hi")
      body = JSON.parse(mock.last_body.not_nil!)
      body["thinking"]["type"].as_s.should eq("enabled")
      body["temperature"].as_f.should eq(1.0)
      body["top_p"].as_f.should eq(0.95)
      body["reasoning_effort"].as_s.should eq("max")
      body["max_tokens"].as_i.should eq(131072)
    end
  end
end
