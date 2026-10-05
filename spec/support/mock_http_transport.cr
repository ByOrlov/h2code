module H2code
  # Fake transport for offline tests. Records the last request and returns a
  # scripted response, or raises a scripted error to simulate a network drop.
  class MockHttpTransport < HttpTransport
    # What the mock should do when `request_stream` is called.
    enum Mode
      # Stream the lines in `stream_lines` as SSE, then close normally.
      NormalStream
      # Stream `stream_lines`, then raise `stream_error` mid-read.
      DropMidStream
      # Return a non-200 HTTP status with `error_body`.
      ErrorStatus
      # Yield an IO that blocks on read forever (simulates a hanging
      # connection), so the consumer loop hits the abort timeout.
      Blocking
      # Stream `stream_lines`, then block on read forever (simulates a
      # provider that answers and then goes silent mid-response).
      StallMidStream
    end

    property mode : Mode = Mode::NormalStream
    property stream_lines : Array(String) = [] of String
    property stream_error : Exception = IO::Error.new("Broken pipe")
    property error_status : Int32 = 500
    property error_body : String = "internal error"
    # Response body for single-shot `request` (fetch_url, web_search, OAuth).
    property response_body : String = "{\"data\":[]}"
    property response_status : Int32 = 200
    property response_headers : HTTP::Headers = HTTP::Headers.new
    # When set, `request` raises this instead of returning a response.
    property request_error : Exception? = nil
    property last_uri : URI? = nil
    property last_headers : HTTP::Headers? = nil
    property last_body : String? = nil

    def request(method : String, uri : URI, headers : HTTP::Headers,
                body : String? = nil) : HTTP::Client::Response
      @last_uri = uri
      @last_headers = headers
      @last_body = body
      if err = @request_error
        raise err
      end
      HTTP::Client::Response.new(@response_status, body: @response_body, headers: @response_headers)
    end

    def request_stream(method : String, uri : URI, headers : HTTP::Headers,
                       body : String, session : Session,
                       & : HTTP::Client::Response, IO ->)
      @last_uri = uri
      @last_headers = headers
      @last_body = body

      case @mode
      when .error_status?
        io = IO::Memory.new(@error_body)
        response = HTTP::Client::Response.new(@error_status, body_io: io)
        yield response, IO::Memory.new(@error_body)
      when .normal_stream?
        sse = @stream_lines.map { |l| "data: #{l}\n\n" }.join
        response = HTTP::Client::Response.new(200, body_io: IO::Memory.new(sse))
        yield response, response.body_io
      when .drop_mid_stream?
        partial = @stream_lines.map { |l| "data: #{l}\n\n" }.join
        io = PartialReadIO.new(partial, @stream_error)
        response = HTTP::Client::Response.new(200, body_io: io)
        yield response, response.body_io
      when .blocking?
        io = BlockingIO.new
        response = HTTP::Client::Response.new(200, body_io: io)
        yield response, response.body_io
      when .stall_mid_stream?
        io = StallReadIO.new(@stream_lines)
        response = HTTP::Client::Response.new(200, body_io: io)
        yield response, response.body_io
      end
    end

    # IO wrapper that serves `prefix`, then raises `error` on the next read.
    private class PartialReadIO < IO
      @prefix : String
      @error : Exception
      @pos : Int32 = 0

      def initialize(@prefix : String, @error : Exception)
      end

      def read(slice : Bytes) : Int32
        if @pos >= @prefix.bytesize
          raise @error
        end
        count = Math.min(slice.size, @prefix.bytesize - @pos)
        @prefix.to_slice[@pos, count].copy_to(slice)
        @pos += count
        count
      end

      def write(slice : Bytes) : Nil
      end
    end

    # IO that blocks forever on read — simulates a hung connection so the
    # consumer loop's abort timeout fires.
    private class BlockingIO < IO
      def read(slice : Bytes) : Int32
        loop { sleep 50.milliseconds }
      end

      def write(slice : Bytes) : Nil
      end
    end

    # IO that serves the scripted SSE lines, then blocks on read forever —
    # simulates a provider that streams partial output and then stalls, so the
    # consumer loop's stall timeout fires.
    private class StallReadIO < IO
      @prefix : String
      @pos : Int32 = 0

      def initialize(lines : Array(String))
        @prefix = lines.map { |l| "data: #{l}\n\n" }.join
      end

      def read(slice : Bytes) : Int32
        if @pos >= @prefix.bytesize
          loop { sleep 50.milliseconds }
        end
        count = Math.min(slice.size, @prefix.bytesize - @pos)
        @prefix.to_slice[@pos, count].copy_to(slice)
        @pos += count
        count
      end

      def write(slice : Bytes) : Nil
      end
    end
  end
end
