module H2code
  module LLM
    # Shared transport for any backend that speaks the OpenAI Chat Completions
    # wire format over SSE (Moonshot, Z.AI/Zhipu, ...).
    #
    # Subclasses supply the auth token (api key, OAuth, ...) via `token` and a
    # short backend id via `name`. Everything else — request shaping, SSE
    # parsing, tool-call accumulation, abort-aware streaming — is identical and
    # lives here.
    abstract class OpenAIChatProvider < Provider
      property model : String
      property endpoint : String
      property api_key : String = ""
      property temperature : Float64?
      property max_tokens : Int32?
      # Configured hard cap on output tokens. When set it overrides `max_tokens`
      # on the wire (Moonshot prefers `max_completion_tokens` for reasoning models,
      # which share the budget with `reasoning_content`).
      property max_completion_tokens : Int32?
      # Stable session key reused across steps so the backend caches the prompt
      # prefix. Set once per session; read in `chat`.
      property prompt_cache_key : String? = nil
      # Human thinking-effort token (off/low/medium/high/max/on). Translated to
      # the provider-specific wire shape by `build_request` according to
      # `thinking_wire`.
      property thinking_effort : String? = nil
      # Model context window, used to clamp the per-step completion budget.
      property max_context_tokens : Int32? = nil
      # Reasoning models share the output budget with reasoning; without an
      # explicit cap a large input can leave no room for a visible answer.
      @used_context_tokens : Int32 = 0
      # How this backend transmits the effort hint on the wire. Moonshot uses
      # the `thinking` object; OpenAI-compatible backends (ZAI / GLM) use
      # the top-level `reasoning_effort` string; others send nothing.
      property thinking_wire : ThinkingWire = ThinkingWire::None
      # Effort levels this model accepts, parsed from the backend's `/models`
      # `think_efforts.valid_efforts`. Nil until `refresh_model_metadata` runs.
      # A nil/empty list means the model is boolean-only reasoning and the
      # `effort` subfield must not be sent (it is rejected with HTTP 400).
      property valid_efforts : Array(String)? = nil
      property default_effort : String? = nil
      @meta_fetched : Bool = false
      # Whether to send the completion budget as `max_completion_tokens` (Moonshot
      # transport + OpenAI reasoning models) instead of the legacy `max_tokens`
      # (GLM / other OpenAI-compatible endpoints). Mirrors TS
      # `usesMaxCompletionTokens`.
      property? uses_max_completion_tokens : Bool = false
      # How long the stream may stay silent (no SSE chunks) before the request
      # is torn down and retried. Covers both "connected but the server never
      # answers" and "the stream stalled after partial output" — the hung
      # connections that otherwise leave the agent spinning on the busy badge
      # forever. Reset on every received chunk. Local backends (ollama,
      # lmstudio) override with a longer first-token budget in their
      # constructors because loading a model into RAM can legitimately take
      # minutes.
      property stream_stall_timeout : Time::Span = 60.seconds

      # Transport used for all outbound HTTP. Defaults to the real proxy-aware
      # client; tests inject a fake to simulate network drops and aborts.
      @transport : HttpTransport

      def initialize(@model : String, @endpoint : String,
                     @api_key : String = "",
                     @temperature : Float64? = nil,
                     @max_tokens : Int32? = nil,
                     transport : HttpTransport? = nil)
        @transport = transport || HttpTransport::RealHttpTransport.new(->make_client(URI))
      end

      def used_context_tokens=(@used_context_tokens : Int32) : Nil
      end

      # Expose the configured endpoint so provider-derived services (e.g.
      # WebSearch) can build provider-specific URLs such as `<endpoint>/search`.
      def base_url : String?
        @endpoint
      end

      # Expose the live auth token so provider-derived services can reuse the
      # same bearer/API key without reimplementing OAuth refresh.
      def auth_token : String?
        token
      end

      # Build an HTTP::Client for `uri`, applying an HTTP proxy from env when
      # one is set. Crystal's stdlib (1.14) has no built-in proxy support on
      # `HTTP::Client`, so for HTTPS endpoints we open a plaintext TCP socket
      # to the proxy, issue an HTTP `CONNECT` to establish a tunnel, then wrap
      # the upgraded stream in OpenSSL and hand it to `HTTP::Client.new(io)`.
      # For HTTP endpoints we use the simpler absolute-URI form. NO_PROXY and
      # loopback hosts bypass the proxy.
      private def make_client(uri : URI) : HTTP::Client
        proxy = ENV["HTTPS_PROXY"]? || ENV["HTTP_PROXY"]? || ENV["ALL_PROXY"]?
        if (p = proxy) && !p.empty? && !bypass_proxy?(uri)
          return proxy_client(uri, p)
        end
        HTTP::Client.new(uri)
      end

      private def bypass_proxy?(uri : URI) : Bool
        no_proxy = ENV["NO_PROXY"]? || ENV["no_proxy"]?
        host = uri.host || ""
        loopback = {"localhost", "127.0.0.1", "::1"}
        return true if loopback.includes?(host)
        if np = no_proxy
          np.split(',').each do |entry|
            entry = entry.strip
            next if entry.empty?
            return true if host == entry || host.ends_with?(".#{entry.lstrip('.')}")
          end
        end
        false
      end

      # Parse a proxy URL into {host, port, username, password}. Port defaults
      # to 8080 (common HTTP-proxy default). Malformed URLs fall back to a
      # direct connection via `make_client`'s caller path.
      private def proxy_client(target : URI, proxy_url : String) : HTTP::Client
        proxy = URI.parse(proxy_url)
        proxy_host = proxy.host || "127.0.0.1"
        proxy_port = proxy.port || 8080
        proxy_user = proxy.user
        proxy_pass = proxy.password

        target_host = target.host || "localhost"
        target_port = target.port || (target.scheme == "https" ? 443 : 80)

        if target.scheme == "https"
          # CONNECT tunnel: open TCP socket to the proxy, send CONNECT, read
          # the proxy's response, then wrap the tunnelled socket in TLS.
          socket = TCPSocket.new(proxy_host, proxy_port)
          connect_line = String.build do |s|
            s << "CONNECT #{target_host}:#{target_port} HTTP/1.1\r\n"
            s << "Host: #{target_host}:#{target_port}\r\n"
            if proxy_user && proxy_pass
              token = Base64.strict_encode("#{proxy_user}:#{proxy_pass}")
              s << "Proxy-Authorization: Basic #{token}\r\n"
            end
            s << "\r\n"
          end
          socket << connect_line
          socket.flush

          # Read the proxy's HTTP response status line + headers.
          status_line = socket.gets || ""
          unless status_line.includes?(" 200 ")
            socket.close
            raise "Proxy CONNECT failed: #{status_line.strip}"
          end
          # Skip remaining headers until blank line.
          while line = socket.gets
            break if line.strip.empty?
          end

          context = OpenSSL::SSL::Context::Client.new
          context.verify_mode = OpenSSL::SSL::VerifyMode::PEER
          tls = OpenSSL::SSL::Socket::Client.new(socket, context: context, sync_close: true, hostname: target_host)
          client = HTTP::Client.new(tls, host: target_host, port: target_port)
          client
        else
          # HTTP target: connect to the proxy directly and use an absolute URI
          # in the request target so the proxy forwards correctly.
          client = HTTP::Client.new(proxy_host, proxy_port)
          client
        end
      rescue ex
        # Proxy parse / connect failure → degrade to a direct connection.
        # The request will likely fail with a network error, but with a
        # meaningful message instead of a proxy-setup crash.
        HTTP::Client.new(target)
      end

      # Resolve the effective completion budget for the next request.
      # Mirrors TS `applyCompletionBudget` + `withMaxCompletionTokens`: clamp the
      # configured cap against the context window's remaining headroom so the
      # model always has room to emit its answer. OpenAI-compatible endpoints
      # additionally cap at 128k (some reject a larger `max_tokens`). Returns
      # nil when no budget context is available, leaving the cap unset.
      private def effective_max_completion_tokens : Int32?
        configured = @max_completion_tokens || @max_tokens
        max_ctx = @max_context_tokens

        cap = if max_ctx && max_ctx > 0
                remaining = max_ctx - @used_context_tokens
                remaining = 1 if remaining < 1
                base = configured || max_ctx
                Math.min(base, remaining)
              else
                configured
              end

        return cap unless cap
        cap = Math.min(cap, 128 * 1024) unless @uses_max_completion_tokens
        cap
      end

      # Bearer token sent in the Authorization header. Subclasses override to
      # add OAuth refresh, alternative auth schemes, etc.
      abstract def token : String

      # Set the Authorization header unless the token is empty (local
      # OpenAI-compatible servers like Ollama / LM Studio need no auth and
      # some reject a stray Bearer header).
      private def apply_auth(headers : HTTP::Headers) : Nil
        t = token
        headers["Authorization"] = "Bearer #{t}" unless t.empty?
      end

      def model_name : String
        @model
      end

      def fetch_models : Array(String)
        uri = URI.parse("#{@endpoint}/models")

        headers = HTTP::Headers.new
        apply_auth(headers)
        headers["Accept"] = "application/json"

        response = @transport.request("GET", uri, headers)

        if response.status_code != 200
          raise ApiError.new(response.status_code,
            ApiError.extract_message("Models API error #{response.status_code}", response.body),
            ApiError.retryable_status?(response.status_code))
        end

        json = JSON.parse(response.body)
        data = json["data"]?
        return [] of String unless data && data.as_a?

        data.as_a.map do |entry|
          entry["id"]?.try(&.as_s) || ""
        end.reject(&.empty?)
      end

      def chat(messages : Array(Message), tools : Array(ToolDefinition)?,
               system_prompt : String? = nil, aborted? : -> Bool = -> { false },
               &block : MessagePart ->) : StepResult
        # Resolve the model's supported effort levels once (Moonshot wire only) so
        # build_request can decide whether to include the `effort` subfield.
        # A failure here degrades gracefully to boolean-only thinking.
        refresh_model_metadata

        all_messages = [] of Message
        if sp = system_prompt
          all_messages << Message.system(sp)
        end
        all_messages.concat(messages)

        request = build_request(all_messages, tools)

        accumulated_text = IO::Memory.new
        accumulated_thinking = IO::Memory.new
        tool_calls = Hash(Int32, {String, String, String}).new
        finish_reason = "end_turn"
        usage = Usage.new

        stream_response(request, aborted?) do |chunk|
          chunk.choices.each do |choice|
            if fr = choice.finish_reason
              finish_reason = fr
            end

            if delta = choice.delta
              if content = delta.content
                unless content.empty?
                  accumulated_text << content
                  block.call(TextPart.new(content))
                end
              end

              if reasoning = delta.reasoning_content
                unless reasoning.empty?
                  accumulated_thinking << reasoning
                  block.call(ThinkPart.new(reasoning))
                end
              end

              if dtc = delta.tool_calls
                dtc.each do |tc|
                  idx = tc.index
                  id = tc.id || ""
                  name = ""
                  args = ""

                  if func = tc.function
                    name = func.name || ""
                    args = func.arguments || ""
                  end

                  if existing = tool_calls[idx]?
                    new_id = id.empty? ? existing[0] : id
                    new_name = name.empty? ? existing[1] : name
                    new_args = existing[2] + args
                    tool_calls[idx] = {new_id, new_name, new_args}
                    unless args.empty?
                      block.call(ToolCallPart.new(new_id, new_name, args))
                    end
                  else
                    tool_calls[idx] = {id, name, args}
                    unless args.empty?
                      block.call(ToolCallPart.new(id, name, args))
                    end
                  end
                end
              end
            end
          end

          # Usage may arrive at the top-level `usage` (standard OpenAI) or
          # nested under `choices[0].usage` (Moonshot proprietary). The final
          # chunk carrying usage overwrites the default. Mirrors the TS
          # `extractUsageFromChunk` (kimi.ts:222).
          if u = chunk.usage || chunk.choices.first?.try(&.usage)
            usage = u
            block.call(UsagePart.new(u))
          end
        end

        block.call(FinishPart.new(finish_reason))

        final_tool_calls = tool_calls.values.sort_by! { |tc| tool_calls.key_for(tc) }
          .map { |id, name, args| ToolCall.new(id, ToolCallFunction.new(name, args)) }

        stop_reason = finish_reason == "tool_calls" ? "tool_use" : finish_reason

        StepResult.new(
          stop_reason: stop_reason,
          text: accumulated_text.to_s,
          thinking: accumulated_thinking.to_s,
          tool_calls: final_tool_calls,
          usage: usage,
        )
      end

      # Assemble the wire request, folding in the per-session / per-step runtime
      # config: prompt-cache key (session affinity), the completion budget clamp
      # (as `max_completion_tokens` for the Moonshot transport, the legacy
      # `max_tokens` alias for plain OpenAI-compatible backends), and the
      # reasoning-effort object for backends that speak it. Extracted from
      # `chat` so the request shape is unit-testable without a network call.
      def build_request(messages : Array(Message), tools : Array(ToolDefinition)?) : ChatRequest
        # Text-only model: strip image/audio/video blocks from the history —
        # the endpoint rejects any other content type with HTTP 400
        # ("messages.content.type is invalid, allowed values: ['text']").
        messages = messages.map(&.without_media) if text_only?

        request = ChatRequest.new(
          model: @model,
          messages: messages,
          tools: tools,
          stream: true,
          temperature: @temperature,
          max_tokens: nil,
        )
        # Session affinity: cache the prompt prefix on the backend so sequential
        # tool-driven steps (read a file, read the next, ...) only reprocess the
        # delta instead of the full growing context every step.
        request.prompt_cache_key = @prompt_cache_key
        if cap = effective_max_completion_tokens
          if @uses_max_completion_tokens
            request.max_completion_tokens = cap
          else
            request.max_tokens = cap
          end
        end
        # Reasoning effort — transmitted in the provider-specific wire shape.
        # Moonshot speaks the top-level `thinking` object (effort only when the
        # model supports it); OpenAI-compatible backends (ZAI/GLM) speak the
        # top-level `reasoning_effort` string; others send nothing.
        case @thinking_wire
        in ThinkingWire::Moonshot
          request.thinking = build_moonshot_thinking
        in ThinkingWire::ReasoningEffort
          request.reasoning_effort = build_reasoning_effort
        in ThinkingWire::None
          # no effort control on the wire
        end
        # Allow the model to emit several tool calls at once. This is what makes
        # multi-file reads happen in a single step instead of one call per turn.
        request.parallel_tool_calls = true if tools && !tools.empty?
        request
      end

      # Moonshot `thinking` object. `off`/`none` → disabled; `on` →
      # enabled with no effort; a concrete effort → enabled, but only with an
      # `effort` subfield when the model declares it in `valid_efforts`.
      # Sending an unsupported effort (e.g. "medium" to the boolean-only
      # `kimi-for-coding`) is rejected by the endpoint with HTTP 400, so when
      # the model offers no valid efforts the field is omitted and an unknown
      # requested effort falls back to the model default (if any) or to plain
      # enable. Mirrors TS `normalizeThinkingEffortForModel`.
      private def build_moonshot_thinking : ThinkingConfig?
        effort = @thinking_effort
        return nil if effort.nil?
        case effort.downcase
        when "off", "none", "disabled"
          ThinkingConfig.new("disabled")
        when "on"
          ThinkingConfig.new("enabled")
        else
          valid = @valid_efforts
          if valid && !valid.empty?
            if valid.includes?(effort.downcase)
              ThinkingConfig.new("enabled", effort.downcase)
            elsif (de = @default_effort) && de.presence && valid.includes?(de)
              ThinkingConfig.new("enabled", de)
            else
              ThinkingConfig.new("enabled")
            end
          else
            # Boolean-only model (no valid_efforts declared): no effort field.
            ThinkingConfig.new("enabled")
          end
        end
      end

      # OpenAI / ZAI / GLM `reasoning_effort` string. `off`/`on` have no wire
      # encoding on these endpoints, so they are omitted; any concrete effort
      # is passed through verbatim.
      private def build_reasoning_effort : String?
        effort = @thinking_effort
        return nil if effort.nil?
        case effort.downcase
        when "off", "none", "disabled", "on"
          nil
        else
          effort.downcase
        end
      end

      # Fetch the model's `think_efforts` from the backend's `/models` once and
      # cache the supported effort levels. Only meaningful for the Moonshot wire
      # (OpenAI-style `reasoning_effort` needs no model lookup). Failures are
      # swallowed: a missing or unparseable response leaves `valid_efforts`
      # nil, which makes `build_moonshot_thinking` omit the `effort` subfield —
      # always a valid request.
      private def refresh_model_metadata : Nil
        return if @meta_fetched
        @meta_fetched = true
        return unless @thinking_wire.moonshot?

        begin
          uri = URI.parse("#{@endpoint}/models")
          headers = HTTP::Headers.new
          apply_auth(headers)
          headers["Accept"] = "application/json"
          response = @transport.request("GET", uri, headers)
          return unless response.status_code == 200

          json = JSON.parse(response.body)
          data = json["data"]?
          return unless data && data.as_a?

          data.as_a.each do |entry|
            next unless entry["id"]?.try(&.as_s?) == @model
            te = entry["think_efforts"]?
            next unless te && te.as_h?
            @valid_efforts = te["valid_efforts"]?
              .try(&.as_a?)
              .try(&.map(&.to_s))
            @default_effort = te["default_effort"]?.try(&.as_s?)
          end
        rescue ex
          # Network/parse failure → degrade to boolean-only thinking.
        end
      end

      private def stream_response(request : ChatRequest, aborted? : -> Bool,
                                  &block : StreamChunk ->)
        uri = URI.parse("#{@endpoint}/chat/completions")

        headers = HTTP::Headers.new
        apply_auth(headers)
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "text/event-stream"

        active = HttpTransport::Session.new
        chunks = Channel(StreamChunk).new(64)

        # The HTTP request runs in its own fiber so this fiber is never stuck
        # inside a blocking socket read. That lets us poll the abort flag from
        # the consumer loop below and tear the connection down mid-flight —
        # which is the only way to interrupt a request that is still connecting.
        spawn do
          begin
            reader, writer = IO.pipe
            spawn do
              begin
                request.to_json(writer)
              rescue ex : IO::Error | Channel::ClosedError
                # Consumer closed the pipe (abort / network drop) mid-write.
              ensure
                writer.close rescue nil
              end
            end
            @transport.request_stream("POST", uri, headers, reader, active) do |response|
              if response.status_code != 200
                error_body = response.body_io.gets_to_end
                status = response.status_code
                raise ApiError.new(status,
                  ApiError.extract_message("Chat API error #{status}", error_body),
                  ApiError.retryable_status?(status))
              end

              response.body_io.each_line do |line|
                line = line.strip
                next if line.empty?

                if line.starts_with?("data: ")
                  data = line[6..]
                  break if data == "[DONE]"

                  begin
                    # Some backends (LM Studio) report failures mid-stream:
                    # the HTTP status is 200, but the payload is a bare
                    # `{"error":{...}}` object with no choices (e.g. the
                    # prompt exceeds the loaded model's context). Surface it
                    # instead of silently swallowing the whole stream.
                    if data.starts_with?("{\"error\"")
                      raise ApiError.new(400,
                        ApiError.extract_message("Stream error", data),
                        retryable: false)
                    end
                    chunk = StreamChunk.from_json(data)
                    chunks.send(chunk)
                  rescue ex : JSON::ParseException
                    if @debug
                      STDERR.puts "[debug] Failed to parse SSE: #{ex.message}"
                      STDERR.puts "[debug] Data: #{data[0..200]}"
                    end
                  end
                end
              end
            end
          rescue ex : Channel::ClosedError
            # Consumer closed the channel on abort; stop silently.
          rescue ex
            active.error = ex
          ensure
            reader.try(&.close) rescue nil
            chunks.close
          end
        end

        # Stall clock: starts when the request is issued and resets on every
        # received chunk, so it covers both first-byte and mid-stream stalls.
        last_activity = Time.monotonic

        loop do
          select
          when chunk = chunks.receive?
            break if chunk.nil?
            last_activity = Time.monotonic
            block.call(chunk)
            # Abort can be set by the main loop fiber between chunks (via
            # Fiber.yield in the chat callback). Check immediately instead of
            # waiting for the timeout branch — during fast streaming (thinking
            # deltas arriving <100ms apart) the timeout never fires, so without
            # this check ESC/Ctrl+C would be ignored until the stream pauses.
            if aborted?.call
              chunks.close
              active.close!
              raise AbortedError.new
            end
          when timeout(100.milliseconds)
            if aborted?.call
              chunks.close
              active.close!
              raise AbortedError.new
            end
            # Stall guard: a provider that accepted the request but never
            # answers (or whose stream went silent mid-response) would
            # otherwise hang the agent forever — the loop above only ever
            # waits. Tear the connection down and let the agent loop's retry
            # policy re-issue the request.
            if Time.monotonic - last_activity > @stream_stall_timeout
              chunks.close
              active.close!
              raise StreamTimeoutError.new(@stream_stall_timeout.total_seconds)
            end
          end
        end

        if err = active.error
          raise err
        end
      end
    end
  end
end
