require "../spec_helper"
require "../../src/tools/fetch_url"
require "../support/mock_http_transport"
require "compress/gzip"

# Тестовый fetcher: возвращает заданные данные / ошибки.
private class FakeFetcher < H2code::Tools::UrlFetcher
  def initialize(@behaviour : Proc(String, H2code::Tools::UrlFetchResult))
  end

  def fetch(url : String, tool_call_id : String? = nil, signal : H2code::Tools::AbortController? = nil) : H2code::Tools::UrlFetchResult
    @behaviour.call(url)
  end
end

private class FakeService < H2code::Tools::WebFetchService
  def initialize(@fetcher : H2code::Tools::UrlFetcher)
  end

  def get_url_fetcher : H2code::Tools::UrlFetcher
    @fetcher
  end
end

describe H2code::Tools::FetchURL do
  after_each do
    H2code::Tools::FetchURL.service = H2code::Tools::LocalWebFetchService.new
  end

  it "exposes JS-name and identical schema" do
    tool = H2code::Tools::FetchURL.new
    tool.name.should eq(H2code::Tools::Names::FETCH_URL)
    tool.description.should contain("http")
    props = tool.parameters["properties"].as_h
    props.has_key?("url").should be_true
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "returns error on empty url" do
    tool = H2code::Tools::FetchURL.new
    result = tool.execute(JSON.parse(%({ "url": "" })))
    result.is_error?.should be_true
    result.content.should contain("URL is required")
  end

  it "renders passthrough note for text/plain content" do
    H2code::Tools::FetchURL.service = FakeService.new(FakeFetcher.new(->(_url : String) do
      H2code::Tools::UrlFetchResult.new("plain text content", H2code::Tools::UrlFetchKind::Passthrough)
    end))

    tool = H2code::Tools::FetchURL.new
    result = tool.execute(JSON.parse(%({ "url": "https://example.com" })))
    result.is_error?.should be_false
    result.content.should contain("full response body, returned verbatim")
    result.content.should contain("cite this page as a markdown link")
    result.content.should contain("plain text content")
  end

  it "renders extracted note for HTML content" do
    H2code::Tools::FetchURL.service = FakeService.new(FakeFetcher.new(->(_url : String) do
      H2code::Tools::UrlFetchResult.new("# Title\n\nbody", H2code::Tools::UrlFetchKind::Extracted)
    end))

    tool = H2code::Tools::FetchURL.new
    result = tool.execute(JSON.parse(%({ "url": "https://example.com" })))
    result.is_error?.should be_false
    result.content.should contain("main text extracted from the page")
    result.content.should contain("# Title")
  end

  it "returns empty-body message when content is empty" do
    H2code::Tools::FetchURL.service = FakeService.new(FakeFetcher.new(->(_url : String) do
      H2code::Tools::UrlFetchResult.new("", H2code::Tools::UrlFetchKind::Passthrough)
    end))

    tool = H2code::Tools::FetchURL.new
    result = tool.execute(JSON.parse(%({ "url": "https://example.com" })))
    result.is_error?.should be_false
    result.content.should eq("The response body is empty.")
  end

  it "formats HttpFetchError with status code" do
    H2code::Tools::FetchURL.service = FakeService.new(FakeFetcher.new(->(_url : String) do
      raise H2code::Tools::HttpFetchError.new(404, "Not Found")
    end))

    tool = H2code::Tools::FetchURL.new
    result = tool.execute(JSON.parse(%({ "url": "https://example.com" })))
    result.is_error?.should be_true
    result.content.should contain("Failed to fetch URL. Status: 404")
    result.content.should contain("Not Found")
  end

  it "formats generic network error" do
    H2code::Tools::FetchURL.service = FakeService.new(FakeFetcher.new(->(_url : String) do
      raise Exception.new("Connection refused")
    end))

    tool = H2code::Tools::FetchURL.new
    result = tool.execute(JSON.parse(%({ "url": "https://example.com" })))
    result.is_error?.should be_true
    result.content.should contain("network error")
    result.content.should contain("Connection refused")
  end

  it "truncates content above MAX_CHARS and sets truncated flag" do
    big = "a" * (H2code::Tools::FetchURL::MAX_CHARS + 5000)
    H2code::Tools::FetchURL.service = FakeService.new(FakeFetcher.new(->(_url : String) do
      H2code::Tools::UrlFetchResult.new(big, H2code::Tools::UrlFetchKind::Passthrough)
    end))

    tool = H2code::Tools::FetchURL.new
    result = tool.execute(JSON.parse(%({ "url": "https://example.com" })))
    result.is_error?.should be_false
    result.content.size.should be < (H2code::Tools::FetchURL::MAX_CHARS + 200)
    result.content.should contain(H2code::Tools::FetchURL::TRUNCATION_MARKER)
    result.content.should contain(H2code::Tools::FetchURL::TRUNCATION_MESSAGE)
    result.truncated?.should be_true
  end

  describe "LocalFetcher URL validation" do
    it "rejects non-http schemes" do
      fetcher = H2code::Tools::LocalFetcher.new
      expect_raises(Exception, /Unsupported URL scheme/) do
        fetcher.fetch("file:///etc/passwd")
      end
    end

    it "rejects localhost" do
      fetcher = H2code::Tools::LocalFetcher.new
      expect_raises(Exception, /Refusing to fetch private host/) do
        fetcher.fetch("http://localhost/")
      end
    end

    it "rejects 127.0.0.1" do
      fetcher = H2code::Tools::LocalFetcher.new
      expect_raises(Exception, /Refusing to fetch private address/) do
        fetcher.fetch("http://127.0.0.1/")
      end
    end

    it "rejects 10.x addresses" do
      fetcher = H2code::Tools::LocalFetcher.new
      expect_raises(Exception, /Refusing to fetch private address/) do
        fetcher.fetch("http://10.0.0.1/")
      end
    end

    it "rejects 192.168.x addresses" do
      fetcher = H2code::Tools::LocalFetcher.new
      expect_raises(Exception, /Refusing to fetch private address/) do
        fetcher.fetch("http://192.168.1.1/")
      end
    end

    it "rejects malformed URLs" do
      fetcher = H2code::Tools::LocalFetcher.new
      # "not a url" parses as a relative URI without scheme/host; either
      # "Unsupported URL scheme" or "missing host" is acceptable here.
      err = expect_raises(Exception) do
        fetcher.fetch("not a url")
      end
      err.message.to_s.should contain("Unsupported URL scheme")
    end
  end

  describe "LocalFetcher HTML extraction" do
    it "extracts title and strips script/style" do
      fetcher = H2code::Tools::LocalFetcher.new
      html = <<-HTML
        <html><head><title>Hello World</title>
        <style>body { color: red; }</style>
        <script>console.log('hack');</script>
        </head><body>
        <h1>Heading</h1>
        <p>First paragraph.</p>
        <p>Second paragraph.</p>
        </body></html>
      HTML
      result = fetcher.extract_main_content(html, "text/html")
      result.kind.passthrough?.should be_false
      result.content.should contain("# Hello World")
      result.content.should contain("Heading")
      result.content.should contain("First paragraph.")
      result.content.should_not contain("hack")
      result.content.should_not contain("color")
    end

    it "passes through text/plain unchanged" do
      fetcher = H2code::Tools::LocalFetcher.new
      result = fetcher.extract_main_content("hello plain", "text/plain; charset=utf-8")
      result.kind.passthrough?.should be_true
      result.content.should eq("hello plain")
    end

    it "passes through text/markdown unchanged" do
      fetcher = H2code::Tools::LocalFetcher.new
      result = fetcher.extract_main_content("# md", "text/markdown")
      result.kind.passthrough?.should be_true
    end

    it "raises when extraction yields nothing meaningful" do
      fetcher = H2code::Tools::LocalFetcher.new
      expect_raises(Exception, /Failed to extract meaningful content/) do
        fetcher.extract_main_content("<html><body><script>x</script></body></html>", "text/html")
      end
    end

    it "decodes numeric HTML entities instead of dropping them" do
      fetcher = H2code::Tools::LocalFetcher.new
      html = %(<html><body><p>It&#39;s a &#8220;test&#8221;</p></body></html>)
      result = fetcher.extract_main_content(html, "text/html")
      result.content.should contain("It's a")
      result.content.should contain("“test”")
      result.content.should_not contain("&#")
    end

    it "decodes hex HTML entities" do
      fetcher = H2code::Tools::LocalFetcher.new
      html = %(<html><body><p>&#x27;hi&#x27;</p></body></html>)
      result = fetcher.extract_main_content(html, "text/html")
      result.content.should contain("'hi'")
      result.content.should_not contain("&#x")
    end

    it "handles invalid UTF-8 bytes without regex crash" do
      fetcher = H2code::Tools::LocalFetcher.new
      # Bytes[0x80, 0xFF] are invalid UTF-8 — PCRE2 throws "isolated byte
      # with 0x80 bit set" unless scrubbed before regex.
      html = String.new(Bytes[0x3C, 0x70, 0x3E, 0x68, 0x69, 0x80, 0xFF, 0x3C, 0x2F, 0x70, 0x3E])
      result = fetcher.extract_main_content(html, "text/html")
      result.content.should contain("hi")
    end
  end

  describe "LocalFetcher with MockHttpTransport" do
    it "fetches content through the transport" do
      transport = H2code::MockHttpTransport.new
      transport.response_body = "hello world"
      transport.response_status = 200

      fetcher = H2code::Tools::LocalFetcher.new(transport)
      result = fetcher.fetch("https://example.com")
      result.content.should contain("hello world")
      (transport.last_uri || raise "last_uri should not be nil").to_s.should contain("example.com")
    end

    it "raises HttpFetchError on 404" do
      transport = H2code::MockHttpTransport.new
      transport.response_status = 404
      transport.response_body = "Not Found"

      fetcher = H2code::Tools::LocalFetcher.new(transport)
      error = expect_raises(H2code::Tools::HttpFetchError) do
        fetcher.fetch("https://example.com")
      end
      error.status.should eq(404)
    end

    it "surfaces IO::Error (broken pipe) as a network error" do
      transport = H2code::MockHttpTransport.new
      transport.request_error = IO::Error.new("Broken pipe")

      fetcher = H2code::Tools::LocalFetcher.new(transport)
      error = expect_raises(IO::Error) do
        fetcher.fetch("https://example.com")
      end
      (error.message || "").should contain("Broken pipe")
    end

    it "decompresses gzip-encoded response body" do
      transport = H2code::MockHttpTransport.new
      raw = "hello gzipped world"
      compressed = IO::Memory.new
      Compress::Gzip::Writer.open(compressed) { |gz| gz << raw }
      transport.response_body = String.new(compressed.to_slice)
      transport.response_status = 200
      transport.response_headers["Content-Encoding"] = "gzip"
      transport.response_headers["Content-Type"] = "text/plain"

      fetcher = H2code::Tools::LocalFetcher.new(transport)
      result = fetcher.fetch("https://example.com")
      result.kind.passthrough?.should be_true
      result.content.should eq(raw)
    end

    it "passes through non-encoded response unchanged" do
      transport = H2code::MockHttpTransport.new
      transport.response_body = "plain text"
      transport.response_status = 200

      fetcher = H2code::Tools::LocalFetcher.new(transport)
      result = fetcher.fetch("https://example.com")
      result.content.should contain("plain text")
    end

    it "falls back to uncompressed request when gzip body is corrupted" do
      transport = CountingMockTransport.new(
        first_body: "not valid gzip",
        first_encoding: "gzip",
        second_body: "<html><body><p>fallback html</p></body></html>",
        second_encoding: "",
      )

      fetcher = H2code::Tools::LocalFetcher.new(transport)
      result = fetcher.fetch("https://example.com")
      result.content.should contain("fallback html")
      transport.request_count.should eq(2)
    end
  end
end

# Mock transport that returns different responses on consecutive requests.
private class CountingMockTransport < H2code::HttpTransport
  getter request_count : Int32 = 0

  def initialize(@first_body : String, @first_encoding : String,
                 @second_body : String, @second_encoding : String)
  end

  def request(method : String, uri : URI, headers : HTTP::Headers,
              body : String? = nil) : HTTP::Client::Response
    @request_count += 1
    if @request_count == 1
      resp_headers = HTTP::Headers.new
      resp_headers["Content-Encoding"] = @first_encoding unless @first_encoding.empty?
      resp_headers["Content-Type"] = "text/html"
      HTTP::Client::Response.new(200, body: @first_body, headers: resp_headers)
    else
      resp_headers = HTTP::Headers.new
      resp_headers["Content-Encoding"] = @second_encoding unless @second_encoding.empty?
      resp_headers["Content-Type"] = "text/html"
      HTTP::Client::Response.new(200, body: @second_body, headers: resp_headers)
    end
  end

  def request_stream(method : String, uri : URI, headers : HTTP::Headers,
                     body : String, session : H2code::HttpTransport::Session,
                     &_block : HTTP::Client::Response, IO ->)
    raise NotImplementedError.new("CountingMockTransport does not support streaming")
  end
end
