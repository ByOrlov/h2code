require "../spec_helper"
require "../../src/tools/select_tools"

describe H2code::Tools::SelectTools do
  before_each do
    H2code::Tools::ToolSelect.service = H2code::Tools::InMemoryToolSelectService.new(
      loadable: ["a", "b", "c"],
      active: ["c"]
    )
  end
  after_each do
    H2code::Tools::ToolSelect.service = nil
  end

  it "exposes snake_case JS-name and identical schema" do
    tool = H2code::Tools::SelectTools.new
    tool.name.should eq(H2code::Tools::Names::SELECT_TOOLS)
    props = tool.parameters["properties"].as_h
    props.has_key?("names").should be_true
    tool.parameters["required"].as_a.map(&.as_s).should eq(["names"])
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "loads requested tools and reports already-available" do
    tool = H2code::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["a", "b", "c"] })))
    result.is_error?.should be_false
    result.content.should contain("Loaded: a, b")
    result.content.should contain("Already available: c")
  end

  it "reports unknown tools" do
    tool = H2code::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["x", "y"] })))
    result.is_error?.should be_true
    result.content.should contain("Unknown tool: x.")
    result.content.should contain("Unknown tool: y.")
    result.content.should contain("Pick from the latest announced tools list")
  end

  it "partial case: mixed load + already-available + unknown" do
    tool = H2code::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["a", "c", "z"] })))
    result.is_error?.should be_false
    result.content.should contain("Loaded: a")
    result.content.should contain("Already available: c")
    result.content.should contain("Unknown tool: z.")
  end

  it "is_error true when only unknown" do
    tool = H2code::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["unknown_tool"] })))
    result.is_error?.should be_true
  end

  it "is_error false when at least one loaded or already-available" do
    tool = H2code::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["a"] })))
    result.is_error?.should be_false
  end

  it "rejects empty names array" do
    tool = H2code::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": [] })))
    result.is_error?.should be_true
    result.content.should contain("must be a non-empty array")
  end

  it "rejects missing names field" do
    tool = H2code::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error?.should be_true
    result.content.should contain("must be a non-empty array")
  end

  it "filters out empty strings in names" do
    tool = H2code::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["", "a"] })))
    result.is_error?.should be_false
    result.content.should contain("Loaded: a")
  end

  it "refuses when disabled" do
    service = H2code::Tools::ToolSelect.service.as(H2code::Tools::InMemoryToolSelectService)
    service.disable!
    tool = H2code::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["a"] })))
    result.is_error?.should be_true
    result.content.should contain("not available for the current model")
  end

  it "fails when no service is registered" do
    H2code::Tools::ToolSelect.service = nil
    tool = H2code::Tools::SelectTools.new
    result = tool.execute(JSON.parse(%({ "names": ["a"] })))
    result.is_error?.should be_true
    result.content.should contain("not initialized")
  end

  it "marks tools as active after successful load" do
    tool = H2code::Tools::SelectTools.new
    tool.execute(JSON.parse(%({ "names": ["a"] })))
    # Second call — a should now be already_available.
    result = tool.execute(JSON.parse(%({ "names": ["a"] })))
    result.content.should contain("Already available: a")
    result.content.should_not contain("Loaded: a")
  end
end

describe H2code::Tools::AgentToolSelectService do
  it "drops unloaded MCP tools from the provider-visible tools list when enabled" do
    registry = H2code::Tools::Registry.new
    registry.register(H2code::Tools::Read.new("/tmp"))
    registry.register(FakeMcpTool.new("mcp__github__create_issue"))
    svc = H2code::Tools::AgentToolSelectService.new(registry, true)

    defs = [mcp_def("mcp__github__create_issue"), mcp_def("Read")]
    shaped = svc.shape_tools(defs)
    shaped.map(&.name).should eq(["Read"])

    svc.load(["mcp__github__create_issue"])
    shaped = svc.shape_tools(defs)
    shaped.map(&.name).should contain("mcp__github__create_issue")
  end

  it "passes all definitions through when disabled" do
    registry = H2code::Tools::Registry.new
    svc = H2code::Tools::AgentToolSelectService.new(registry, false)
    defs = [mcp_def("mcp__github__create_issue"), mcp_def("Read")]
    svc.shape_tools(defs).map(&.name).should eq(["mcp__github__create_issue", "Read"])
    svc.announcement(defs).should be_nil
  end

  it "announces loadable (not yet loaded) MCP tools" do
    registry = H2code::Tools::Registry.new
    registry.register(FakeMcpTool.new("mcp__a__tool"))
    registry.register(FakeMcpTool.new("mcp__b__tool"))
    svc = H2code::Tools::AgentToolSelectService.new(registry, true)

    defs = [mcp_def("mcp__b__tool"), mcp_def("mcp__a__tool"), mcp_def("Read")]
    ann = svc.announcement(defs).not_nil!
    ann.should contain("<tools_loadable>")
    ann.should contain("mcp__a__tool")
    ann.should contain("mcp__b__tool")
    # Sorted: a before b.
    (ann.index!("mcp__a__tool") < ann.index!("mcp__b__tool")).should be_true

    svc.load(["mcp__a__tool"])
    ann2 = svc.announcement(defs).not_nil!
    ann2.should contain("mcp__b__tool")
    ann2.should_not contain("mcp__a__tool")
  end

  it "returns no announcement when everything is loaded" do
    registry = H2code::Tools::Registry.new
    svc = H2code::Tools::AgentToolSelectService.new(registry, true)
    svc.announcement([mcp_def("Read")]).should be_nil
    svc.announcement([] of H2code::LLM::ToolDefinition).should be_nil
  end

  it "classifies load against the registry's MCP tools" do
    registry = H2code::Tools::Registry.new
    registry.register(FakeMcpTool.new("mcp__srv__tool"))
    svc = H2code::Tools::AgentToolSelectService.new(registry, true)

    result = svc.load(["mcp__srv__tool", "Read"])
    result.to_load.should eq(["mcp__srv__tool"])
    result.unknown.should eq(["Read"])

    result = svc.load(["mcp__srv__tool"])
    result.already_available.should eq(["mcp__srv__tool"])
  end
end

# Minimal registry entry with an MCP-style name for service tests.
class FakeMcpTool < H2code::Tools::Tool
  def initialize(@n : String)
  end

  def name : String
    @n
  end

  def description : String
    "fake"
  end

  def parameters : JSON::Any
    JSON.parse(%({"type":"object"}))
  end

  def execute(input : JSON::Any) : H2code::Tools::ToolResult
    H2code::Tools::ToolResult.success("ok")
  end
end

def mcp_def(name : String) : H2code::LLM::ToolDefinition
  H2code::LLM::ToolDefinition.new(
    H2code::LLM::ToolFunction.new(name, "test", JSON.parse(%({"type":"object"}))))
end
