require "../spec_helper"

describe H2code::Tools::CurrentTime do
  tool = H2code::Tools::CurrentTime.new

  it "uses the canonical tool name" do
    tool.name.should eq(H2code::Tools::Names::CURRENT_TIME)
    tool.name.should eq("CurrentTime")
  end

  it "exposes an empty parameter schema" do
    params = tool.parameters
    params["type"].should eq("object")
    params["properties"].as_h.should be_empty
  end

  it "returns local time, UTC time, and unix milliseconds" do
    before_ms = Time.local.to_unix_ms
    result = tool.execute(JSON.parse(%q({})))
    after_ms = Time.local.to_unix_ms

    result.is_error?.should be_false
    lines = result.content.split('\n')
    lines.size.should eq(3)

    local = lines[0][/local: (.+)/, 1]?
    local.should_not be_nil
    # RFC 3339 — numeric offset (e.g. +03:00), or Z when the local zone is UTC.
    local.should match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})\z/)

    utc = lines[1][/utc: (.+)/, 1]?
    utc.should_not be_nil
    utc.should match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)

    unix_ms_raw = lines[2][/unix_ms: (\d+)/, 1]?
    unix_ms_raw.should_not be_nil
    unix_ms = unix_ms_raw.not_nil!.to_i64
    (unix_ms >= before_ms).should be_true
    (unix_ms <= after_ms).should be_true
  end
end
