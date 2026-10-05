require "../spec_helper"
require "../support/mock_http_transport"

  # Scripted transport: first chat attempt gets Strata's overflow 400 (which
# names the exact allowed budget), the retry streams a normal SSE answer.
class OverflowRetryTransport < H2code::HttpTransport
  property calls = 0
  property last_body : String? = nil

  def request(method : String, uri : URI, headers : HTTP::Headers, body : String? = nil) : HTTP::Client::Response
    HTTP::Client::Response.new(200, body: %({"data":[]}))
  end

  def request_stream(method : String, uri : URI, headers : HTTP::Headers,
                     body : String, session : Session,
                     & : HTTP::Client::Response, IO ->)
    @calls += 1
    @last_body = body
    if @calls == 1
      err = %({"error":{"message":"prompt (19055 tokens) + max tokens (64219) exceeds the context (65536); requests are never truncated. Send a smaller max_tokens (at most 46473 here), or add fit_max_tokens"}})
      io = IO::Memory.new(err)
      yield HTTP::Client::Response.new(400, body_io: io), io
    else
      sse = %q(data: {"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"OK"},"finish_reason":null}]}) + "\n\ndata: [DONE]\n\n"
      response = HTTP::Client::Response.new(200, body_io: IO::Memory.new(sse))
      yield response, response.body_io
    end
  end
end



# Strata is a keyless local backend (own GPU, OpenAI-compatible /v1). Verify
# the registry surface, config wiring and that the optional api-key (only set
# when the server runs with --api-key) passes through.

describe "H2code::LLM Strata provider" do
  it "registers in the Provider registry" do
    H2code::LLM::Provider.known_provider?("strata").should be_true
    info = H2code::LLM::Provider.providers.find(&.name.==("strata")).not_nil!
    info.needs_key?.should be_false
    info.hidden?.should be_false
  end

  it "is always configured (local keyless server)" do
    config = H2code::Config::Config.new
    config.provider_configured?("strata").should be_true
  end

  it "builds without a key and defaults to the local endpoint" do
    config = H2code::Config::Config.new
    reg = H2code::LLM::Provider.find("strata").not_nil!
    provider = reg.builder.call(config, nil).as(H2code::LLM::OpenAIChatProvider)
    provider.name.should eq("strata")
    provider.token.should eq("")
    provider.model_name.should eq("default")
    provider.base_url.should eq("http://127.0.0.1:8080/v1")
  end

  it "passes the configured endpoint, model and api key through" do
    config = H2code::Config::Config.new
    config.strata_endpoint = "http://gpu:8080/v1"
    config.strata_model = "qwen3.8"
    config.strata_api_key = "secret"
    reg = H2code::LLM::Provider.find("strata").not_nil!
    provider = reg.builder.call(config, nil).as(H2code::LLM::OpenAIChatProvider)
    provider.base_url.should eq("http://gpu:8080/v1")
    provider.model_name.should eq("qwen3.8")
    provider.token.should eq("secret")
  end

  it "maps thinking 'off' to reasoning_effort=none (Strata supports it)" do
    config = H2code::Config::Config.new
    provider = H2code::LLM::StrataProvider.new
    provider.thinking_effort = "off"
    request = provider.build_request([] of H2code::LLM::Message, nil)
    request.reasoning_effort.should eq("none")

    provider.thinking_effort = "high"
    request = provider.build_request([] of H2code::LLM::Message, nil)
    request.reasoning_effort.should eq("high")
  end

  it "discovers the engine context limit from /health" do
    transport = H2code::MockHttpTransport.new
    transport.response_body = %({"status":"ok","max_context":65536,"loaded":true})
    provider = H2code::LLM::StrataProvider.new(transport: transport)
    provider.fetch_context_limit.should eq(65536)
    # Memoized: a second call makes no further requests.
    provider.fetch_context_limit.should eq(65536)
  end

  it "falls back to /v1/models meta.n_ctx when /health has no max_context" do
    transport = H2code::MockHttpTransport.new
    transport.response_body = %({"data":[{"id":"qwen3.8-flash-next-iq2_xs","meta":{"n_ctx":32768}}]})
    provider = H2code::LLM::StrataProvider.new(transport: transport)
    provider.fetch_context_limit.should eq(32768)
  end

  it "returns nil when the backend reports no limit" do
    transport = H2code::MockHttpTransport.new
    transport.response_status = 500
    transport.response_body = %({"error":true})
    provider = H2code::LLM::StrataProvider.new(transport: transport)
    provider.fetch_context_limit.should be_nil
  end

  it "keeps completion headroom so its token count can exceed our estimate" do
    provider = H2code::LLM::StrataProvider.new
    provider.max_context_tokens = 65_536
    msg = H2code::LLM::Message.user("a" * 76_000) # ~19,000 tokens
    request = provider.build_request([msg], nil)
    # estimate 19,000 + 4 (message overhead) + margin max(1024, 19_004 // 8 = 2,375) = 21,379 → 65,536 − 21,379
    request.max_tokens.should eq(44_157)
  end

  it "retries once with the exact budget parsed from Strata's overflow 400" do
    transport = OverflowRetryTransport.new
    provider = H2code::LLM::StrataProvider.new(transport: transport)
    provider.max_context_tokens = 65_536
    result = provider.chat([H2code::LLM::Message.user("hi")], nil) { |_part| }
    result.text.should eq("OK")
    transport.calls.should eq(2)
    transport.last_body.to_s.should contain(%("max_tokens":46473))
  end
end
