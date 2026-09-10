require "../spec_helper"
require "../support/mock_http_transport"

# Minimal concrete subclass so we can instantiate the abstract provider.
private class TestProvider < H2code::LLM::OpenAIChatProvider
  def token : String
    "test-key"
  end

  def name : String
    "test"
  end
end

# Helper: build a valid SSE line for a text-content delta chunk.
private def sse_text_chunk(content : String, finish : String? = nil) : String
  JSON.build do |json|
    json.object do
      json.field "choices" do
        json.array do
          json.object do
            json.field "delta" do
              json.object { json.field "content", content }
            end
            json.field "finish_reason", finish if finish
          end
        end
      end
    end
  end
end

# Helper: build a final chunk carrying usage.
private def sse_usage_chunk : String
  JSON.build do |json|
    json.object do
      json.field "choices" { json.array { } }
      json.field "usage" do
        json.object do
          json.field "prompt_tokens", 10
          json.field "completion_tokens", 5
          json.field "total_tokens", 15
        end
      end
    end
  end
end

describe H2code::LLM::OpenAIChatProvider do
  describe "with MockHttpTransport" do
    it "streams response chunks and aggregates text" do
      transport = H2code::MockHttpTransport.new
      transport.mode = H2code::MockHttpTransport::Mode::NormalStream
      transport.stream_lines = [
        sse_text_chunk("Hello"),
        sse_text_chunk(" world"),
        sse_text_chunk("", "end_turn"),
        sse_usage_chunk,
      ]

      provider = TestProvider.new("m", "http://localhost", transport: transport)

      parts = [] of H2code::LLM::MessagePart
      result = provider.chat([H2code::LLM::Message.user("hi")], nil) { |p| parts << p }

      texts = parts.select(H2code::LLM::TextPart).map(&.text).join
      texts.should eq("Hello world")
      result.text.should eq("Hello world")
      result.stop_reason.should eq("end_turn")
    end

    it "raises ApiError on non-200 status" do
      transport = H2code::MockHttpTransport.new
      transport.mode = H2code::MockHttpTransport::Mode::ErrorStatus
      transport.error_status = 429
      transport.error_body = %({"error":{"message":"rate limited"}})

      provider = TestProvider.new("m", "http://localhost", transport: transport)

      expect_raises(H2code::LLM::ApiError) do
        provider.chat([H2code::LLM::Message.user("hi")], nil) { }
      end
    end

    it "surfaces network drop (IO::Error) from mid-stream as provider error" do
      transport = H2code::MockHttpTransport.new
      transport.mode = H2code::MockHttpTransport::Mode::DropMidStream
      transport.stream_lines = [sse_text_chunk("partial")]
      transport.stream_error = IO::Error.new("Broken pipe")

      provider = TestProvider.new("m", "http://localhost", transport: transport)

      error = expect_raises(IO::Error) do
        provider.chat([H2code::LLM::Message.user("hi")], nil) { }
      end
      (error.message || "").should contain("Broken pipe")
    end

    it "aborts an in-flight stream without unhandled spawn exceptions" do
      transport = H2code::MockHttpTransport.new
      transport.mode = H2code::MockHttpTransport::Mode::Blocking

      provider = TestProvider.new("m", "http://localhost", transport: transport)

      abort_flag = -> { true }

      expect_raises(H2code::LLM::AbortedError) do
        provider.chat([H2code::LLM::Message.user("hi")], nil, aborted?: abort_flag) { }
      end
    end

    it "aborts during active streaming (chunks arriving faster than timeout)" do
      transport = H2code::MockHttpTransport.new
      transport.mode = H2code::MockHttpTransport::Mode::NormalStream
      transport.stream_lines = Array.new(20) { |i| sse_text_chunk("chunk#{i}") }

      provider = TestProvider.new("m", "http://localhost", transport: transport)

      # Flip the abort flag after the first chunk is processed. Without the
      # post-chunk abort check, the timeout branch never fires during fast
      # streaming and the abort is silently ignored.
      chunk_count = 0
      abort_flag = -> { chunk_count >= 1 }

      expect_raises(H2code::LLM::AbortedError) do
        provider.chat([H2code::LLM::Message.user("hi")], nil, aborted?: abort_flag) do
          chunk_count += 1
        end
      end
    end

    it "raises StreamTimeoutError when the provider never answers" do
      transport = H2code::MockHttpTransport.new
      transport.mode = H2code::MockHttpTransport::Mode::Blocking

      provider = TestProvider.new("m", "http://localhost", transport: transport)
      provider.stream_stall_timeout = 0.3.seconds

      error = expect_raises(H2code::LLM::StreamTimeoutError) do
        provider.chat([H2code::LLM::Message.user("hi")], nil) { }
      end
      (error.message || "").should contain("no data")
    end

    it "raises StreamTimeoutError when the stream stalls mid-response" do
      transport = H2code::MockHttpTransport.new
      transport.mode = H2code::MockHttpTransport::Mode::StallMidStream
      transport.stream_lines = [sse_text_chunk("partial")]

      provider = TestProvider.new("m", "http://localhost", transport: transport)
      provider.stream_stall_timeout = 0.3.seconds

      parts = [] of H2code::LLM::MessagePart
      error = expect_raises(H2code::LLM::StreamTimeoutError) do
        provider.chat([H2code::LLM::Message.user("hi")], nil) { |p| parts << p }
      end
      # The chunks received before the stall were still delivered.
      parts.select(H2code::LLM::TextPart).map(&.text).join.should eq("partial")
      (error.message || "").should contain("no data")
    end

    it "uses transport for fetch_models (single-shot request)" do
      transport = H2code::MockHttpTransport.new
      provider = TestProvider.new("m", "http://localhost", transport: transport)

      models = provider.fetch_models
      models.should eq([] of String)

      last = transport.last_uri || raise "last_uri should not be nil"
      last.to_s.should contain("/models")
      (transport.last_headers || raise "last_headers should not be nil")["Authorization"].should eq("Bearer test-key")
    end

    it "strips media content parts from the request when text_only is set" do
      transport = H2code::MockHttpTransport.new
      transport.mode = H2code::MockHttpTransport::Mode::NormalStream
      transport.stream_lines = [sse_text_chunk("ok", "end_turn")]

      provider = TestProvider.new("m", "http://localhost", transport: transport)
      provider.text_only = true

      media_parts = [
        H2code::LLM::TextContent.new("look at this"),
        H2code::LLM::ImageContent.new(H2code::LLM::ImageRef.new("data:image/png;base64,AAAA")),
      ] of H2code::LLM::ContentPart

      json = JSON.parse(provider.build_request(
        [H2code::LLM::Message.user(media_parts)], nil).to_json)
      json["messages"][0]["content"].should eq("look at this")
      json["messages"][0]["content"].to_s.should_not contain("image_url")

      # Media-only message becomes a text placeholder, not an empty message.
      image_only = [H2code::LLM::ImageContent.new(
        H2code::LLM::ImageRef.new("data:image/png;base64,AAAA"))] of H2code::LLM::ContentPart
      json2 = JSON.parse(provider.build_request(
        [H2code::LLM::Message.user(image_only)], nil).to_json)
      json2["messages"][0]["content"].to_s.should contain("only accepts text")
    end

    it "keeps media content parts when text_only is unset" do
      provider = TestProvider.new("m", "http://localhost",
        transport: H2code::MockHttpTransport.new)

      media_parts = [
        H2code::LLM::TextContent.new("look at this"),
        H2code::LLM::ImageContent.new(H2code::LLM::ImageRef.new("data:image/png;base64,AAAA")),
      ] of H2code::LLM::ContentPart

      wire = provider.build_request([H2code::LLM::Message.user(media_parts)], nil).to_json
      wire.should contain("image_url")
    end
  end
end
