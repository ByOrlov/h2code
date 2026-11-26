require "../spec_helper"
require "../support/mock_http_transport"

# Scripted transport: first chat attempt gets Maya's overflow 400 (OpenAI's
# wording: no allowed budget named), the retry streams a normal SSE answer.
class MayaOverflowTransport < H2code::HttpTransport
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
      err = %({"error":{"type":"invalid_request_error","code":"context_length_exceeded","message":"maximum context length is 65536 tokens; prompt (19055 tokens) + max tokens (64219) exceeds the context; requests are never truncated"}})
      io = IO::Memory.new(err)
      yield HTTP::Client::Response.new(400, body_io: io), io
    else
      sse = %q(data: {"id":"1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"OK"},"finish_reason":null}]}) + "\n\ndata: [DONE]\n\n"
      response = HTTP::Client::Response.new(200, body_io: IO::Memory.new(sse))
      yield response, response.body_io
    end
  end
end

# Maya is a keyless local backend (own GPU, OpenAI-compatible /v1, the same
# engine and server surface as Strata). Verify the registry surface, config
# wiring, context discovery from Maya's /health and the overflow retry.

describe "H2code::LLM Maya provider" do
  it "registers in the Provider registry" do
    H2code::LLM::Provider.known_provider?("maya").should be_true
    info = H2code::LLM::Provider.providers.find(&.name.==("maya")).not_nil!
    info.needs_key?.should be_false
    info.hidden?.should be_false
  end

  it "is always configured (local keyless server)" do
    config = H2code::Config::Config.new
    config.provider_configured?("maya").should be_true
  end

  it "builds without a key and defaults to the local endpoint" do
    config = H2code::Config::Config.new
    reg = H2code::LLM::Provider.find("maya").not_nil!
    provider = reg.builder.call(config, nil).as(H2code::LLM::OpenAIChatProvider)
    provider.name.should eq("maya")
    provider.token.should eq("")
    provider.model_name.should eq("default")
    provider.base_url.should eq("http://127.0.0.1:8080/v1")
  end

  it "passes the configured endpoint, model and api key through" do
    config = H2code::Config::Config.new
    config.maya_endpoint = "http://gpu:8099/v1"
    config.maya_model = "glm-5.3"
    config.maya_api_key = "secret"
    reg = H2code::LLM::Provider.find("maya").not_nil!
    provider = reg.builder.call(config, nil).as(H2code::LLM::OpenAIChatProvider)
    provider.base_url.should eq("http://gpu:8099/v1")
    provider.model_name.should eq("glm-5.3")
    provider.token.should eq("secret")
  end

  it "keeps the Strata config apart from Maya's" do
    config = H2code::Config::Config.new
    config.provider_name = "maya"
    H2code::Setup.apply_fields(config, "maya", nil, "http://gpu:8099/v1", "glm-5.3")
    config.maya_endpoint.should eq("http://gpu:8099/v1")
    config.maya_model.should eq("glm-5.3")
    config.strata_endpoint.should be_nil
    config.strata_model.should be_nil
  end

  it "reads MAYA_* env vars" do
    with_tmpdir do |dir|
      clean_env do
        ENV["MAYA_API_KEY"] = "k"
        ENV["MAYA_ENDPOINT"] = "http://gpu:8099/v1"
        ENV["MAYA_MODEL"] = "glm-5.3"
        # No file at this path: every value comes from the environment.
        config = H2code::Config::Config.load(File.join(dir, "config.json"))
        config.maya_api_key.should eq("k")
        config.maya_endpoint.should eq("http://gpu:8099/v1")
        config.maya_model.should eq("glm-5.3")
      end
    end
  end

  it "maps thinking 'off' to reasoning_effort=none (Maya supports it)" do
    provider = H2code::LLM::MayaProvider.new
    provider.thinking_effort = "off"
    request = provider.build_request([] of H2code::LLM::Message, nil)
    request.reasoning_effort.should eq("none")

    provider.thinking_effort = "max"
    request = provider.build_request([] of H2code::LLM::Message, nil)
    request.reasoning_effort.should eq("max")
  end

  it "discovers the engine context limit from /health" do
    transport = H2code::MockHttpTransport.new
    transport.response_body = %({"status":"ok","max_context":131072,"model":"glm-5.3","unloaded":false})
    provider = H2code::LLM::MayaProvider.new(transport: transport)
    provider.fetch_context_limit.should eq(131072)
    # Memoized: a second call makes no further requests.
    provider.fetch_context_limit.should eq(131072)
  end

  it "falls back to /v1/models meta.n_ctx when /health has no max_context" do
    transport = H2code::MockHttpTransport.new
    transport.response_body = %({"data":[{"id":"glm-5.3","meta":{"n_ctx":32768},"context_length":32768}]})
    provider = H2code::LLM::MayaProvider.new(transport: transport)
    provider.fetch_context_limit.should eq(32768)
  end

  it "retries once with the budget derived from Maya's overflow 400" do
    transport = MayaOverflowTransport.new
    provider = H2code::LLM::MayaProvider.new(transport: transport)
    result = provider.chat([H2code::LLM::Message.user("hi")], nil) { |_part| }
    result.text.should eq("OK")
    transport.calls.should eq(2)
    # 65,536 context − 19,055 prompt − 8 engine slack
    transport.last_body.to_s.should contain(%("max_tokens":46473))
  end
end

# Scoped ENV mutation: restores (or clears) each MAYA_* variable afterwards.
private def clean_env(&)
  keys = %w[MAYA_API_KEY MAYA_ENDPOINT MAYA_MODEL]
  saved = keys.to_h { |k| {k, ENV[k]?} }
  begin
    yield
  ensure
    saved.each do |k, v|
      if v
        ENV[k] = v
      else
        ENV.delete(k)
      end
    end
  end
end
