require "../spec_helper"

describe H2code::Tools::GetContextRemaining do
  it "uses the canonical tool name" do
    memory = H2code::Context::Memory.new
    tool = H2code::Tools::GetContextRemaining.new(memory)
    tool.name.should eq(H2code::Tools::Names::GET_CONTEXT_REMAINING)
    tool.name.should eq("GetContextRemaining")
  end

  it "exposes an empty parameter schema" do
    memory = H2code::Context::Memory.new
    tool = H2code::Tools::GetContextRemaining.new(memory)
    params = tool.parameters
    params["type"].should eq("object")
    params["properties"].as_h.should be_empty
  end

  it "reports the budget from the context memory" do
    memory = H2code::Context::Memory.new
    memory.max_context_tokens = 1000
    memory.update_token_count_from_usage(250, 50) # 300 used

    tool = H2code::Tools::GetContextRemaining.new(memory)
    result = tool.execute(JSON.parse(%q({})))

    result.is_error?.should be_false
    lines = result.content.split('\n')
    lines[0].should eq("tokens_used: 300")
    lines[1].should eq("context_window: 1000")
    lines[2].should eq("tokens_remaining: 700")
    lines[3].should eq("percent_used: 30.0")
    lines[4].should eq("near_limit: false")
  end

  it "warns when near the compaction limit" do
    memory = H2code::Context::Memory.new
    memory.max_context_tokens = 1000
    memory.update_token_count_from_usage(950, 0)

    tool = H2code::Tools::GetContextRemaining.new(memory)
    result = tool.execute(JSON.parse(%q({})))

    result.is_error?.should be_false
    result.content.should contain("near_limit: true")
    result.content.should contain("note:")
  end

  it "clamps remaining tokens at zero when over budget" do
    memory = H2code::Context::Memory.new
    memory.max_context_tokens = 1000
    memory.update_token_count_from_usage(1100, 0)

    tool = H2code::Tools::GetContextRemaining.new(memory)
    result = tool.execute(JSON.parse(%q({})))

    result.is_error?.should be_false
    result.content.should contain("tokens_remaining: 0")
  end
end
