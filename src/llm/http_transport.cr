require "http/client"

module H2code
  # Network abstraction layer over `HTTP::Client`.
  #
  # All outbound HTTP goes through an `HttpTransport`. The default
  # `RealHttpTransport` wraps `HTTP::Client` with proxy + TLS support; tests
  # substitute a fake to simulate connection drops, broken pipes, and
  # mid-stream aborts without touching the network.
  abstract class HttpTransport
    # Handle for one streaming request. The transport fills `close` with a
    # closure that tears the socket down; the consumer calls `close!` to
    # abort an in-flight read from another fiber.
    class Session
      property close : -> Nil = -> { }
      # Error captured by the worker fiber; the consumer re-raises it after
      # the channel drains.
      property error : Exception?

      def initialize
        @error = nil
        @close = -> { }
      end

      def close! : Nil
        @close.call rescue nil
      end
    end

    # Single-shot request whose full response fits in memory (GET /models,
    # OAuth refresh, simple POSTs). Returns the complete response.
    abstract def request(method : String, uri : URI, headers : HTTP::Headers,
                         body : String? = nil) : HTTP::Client::Response

    # Streaming request: yields the response and its body IO to the block so
    # the caller can read the SSE event stream. `session.close!` aborts the
    # read by closing the underlying socket. The body is a String (not an IO)
    # so it is sent with Content-Length — a chunked body is unreadable by some
    # local backends (e.g. Strata's stdlib-Python server).
    abstract def request_stream(method : String, uri : URI, headers : HTTP::Headers,
                                body : String, session : Session,
                                &block : HTTP::Client::Response, IO ->)

    # Production transport: builds an `HTTP::Client` per call via the
    # injected `make_client` factory (which applies proxy / TLS plumbing).
    class RealHttpTransport < HttpTransport
      def initialize(@make_client : URI -> HTTP::Client)
      end

      def request(method : String, uri : URI, headers : HTTP::Headers,
                  body : String? = nil) : HTTP::Client::Response
        client = @make_client.call(uri)
        begin
          client.exec(method, uri.request_target, headers, body)
        ensure
          client.close
        end
      end

      def request_stream(method : String, uri : URI, headers : HTTP::Headers,
                         body : String, session : Session,
                         & : HTTP::Client::Response, IO ->)
        client = @make_client.call(uri)
        session.close = -> { client.close rescue nil }
        begin
          client.exec(method, uri.request_target, headers, body) do |resp|
            yield resp, resp.body_io
          end
        ensure
          client.close rescue nil
        end
      end
    end
  end
end
