module H2code
  module LLM
    # Strata backend over the OpenAI Chat Completions protocol. Strata runs a
    # local Qwen3.8-Flash-Next MoE model on the user's own GPU (see
    # https://github.com/Niko1221/Strata) and serves one loaded model — any
    # model name is accepted, `/v1/models` lists the real one. No API key is
    # needed on 127.0.0.1; a key is only required when the server was started
    # with `--api-key` (LAN exposure), so `token` passes the (usually empty)
    # config key through. Strata speaks the top-level `reasoning_effort`
    # string (none / low / medium / high) for thinking control.
    class StrataProvider < OpenAIChatProvider
      DEFAULT_MODEL    = "default"
      DEFAULT_ENDPOINT = "http://127.0.0.1:8080/v1"

      def initialize(model : String = DEFAULT_MODEL,
                     endpoint : String = DEFAULT_ENDPOINT,
                     api_key : String = "",
                     temperature : Float64? = nil,
                     max_tokens : Int32? = nil,
                     transport : HttpTransport? = nil)
        super(model, endpoint, api_key, temperature, max_tokens, transport)
        # Local model — the first prompt of a chat is read in full, about
        # 1 minute per 30,000 tokens, before the first token arrives.
        @stream_stall_timeout = 5.minutes
        @thinking_wire = ThinkingWire::ReasoningEffort
      end

      # Dynamic context-limit discovery state (see fetch_context_limit).
      @context_limit_fetched = false
      @context_limit : Int32? = nil

      # Strata's engine context is fixed at setup time and reported by the
      # server: GET /health → `max_context` (fallback: /v1/models →
      # data[0].meta.n_ctx). The discovered limit hard-caps the configured
      # context window — Strata rejects prompt + max_tokens > context with
      # HTTP 400 ("requests are never truncated") instead of truncating, so
      # an over-large completion budget must never be sent. Queried once per
      # provider instance; failures degrade to nil (configured window).
      def fetch_context_limit : Int32?
        unless @context_limit_fetched
          @context_limit_fetched = true
          @context_limit = discover_context_limit
        end
        @context_limit
      end

      private def discover_context_limit : Int32?
        headers = HTTP::Headers.new
        headers["Authorization"] = "Bearer #{token}" unless token.empty?
        headers["Accept"] = "application/json"

        # /health lives next to /v1: strip the API prefix from the endpoint.
        base = @endpoint.chomp("/")
        base = base.rchop("/v1") if base.ends_with?("/v1")
        begin
          resp = @transport.request("GET", URI.parse("#{base}/health"), headers)
          if resp.status_code == 200
            limit = JSON.parse(resp.body)["max_context"]?.try(&.as_i?)
            return limit if limit && limit > 0
          end
        rescue ex
        end

        begin
          resp = @transport.request("GET", URI.parse("#{@endpoint}/models"), headers)
          if resp.status_code == 200
            data = JSON.parse(resp.body)["data"]?.try(&.as_a?)
            if entry = data.try(&.first?)
              limit = entry["meta"]?.try(&.["n_ctx"]?).try(&.as_i?)
              return limit if limit && limit > 0
            end
          end
        rescue ex
        end
        nil
      end

      # Exact completion budget parsed from Strata's overflow 400 ("…at
      # most 46473 here"). Set for a single retry attempt and consumed by
      # effective_max_completion_tokens.
      @context_retry_budget : Int32? = nil

      # Strata counts prompt tokens exactly where we estimate them
      # (chars/4, which undershoots hardest on Cyrillic), and never
      # truncates a request: any underestimate turns into an HTTP 400. Add
      # headroom to the wire estimate so most requests fit on the first try;
      # the exact retry below catches the rest.
      private def wire_prompt_tokens(messages : Array(Message), tools : Array(ToolDefinition)?) : Int32
        total = super
        total + Math.max(1024, total // 8)
      end

      # Apply the parsed exact budget when one is pending.
      private def effective_max_completion_tokens(prompt_tokens : Int32) : Int32?
        cap = super
        if budget = @context_retry_budget
          cap = budget if cap.nil? || budget < cap
        end
        cap
      end

      # Strata's overflow error names the exact remaining budget, so instead
      # of failing the step, retry once with it. Every retry's budget is
      # strictly smaller than the rejected `max_tokens`, so this terminates
      # even if the backend keeps refusing.
      def chat(messages : Array(Message), tools : Array(ToolDefinition)?,
               system_prompt : String? = nil, aborted? : -> Bool = -> { false },
               &block : MessagePart ->) : StepResult
        super(messages, tools, system_prompt, aborted?) { |part| block.call(part) }
      rescue ex : ApiError
        if (budget = parse_context_budget(ex.message)) && !aborted?.call
          @context_retry_budget = budget
          begin
            super(messages, tools, system_prompt, aborted?) { |part| block.call(part) }
          ensure
            @context_retry_budget = nil
          end
        else
          raise ex
        end
      end

      private def parse_context_budget(message : String?) : Int32?
        return nil unless message
        if md = message.match(/at most (\d+)/)
          budget = md[1].to_i?
          budget if budget && budget > 0
        end
      end

      def name : String
        "strata"
      end

      def token : String
        @api_key
      end

      # Strata is one of the few ReasoningEffort backends that can turn
      # thinking off on the wire: it accepts `"none"`. The shared mapping
      # drops `off` entirely, which would leave the server thinking at its
      # default (high) — so map it here instead.
      private def build_reasoning_effort : String?
        effort = @thinking_effort
        return nil if effort.nil?
        case effort.downcase
        when "off", "none", "disabled" then "none"
        when "on"                      then nil
        else                                effort.downcase
        end
      end
    end

    Provider.register("strata", "Strata — local Qwen3.8 on your GPU, no API key",
      label: "Local — Strata", needs_key: false,
      default_endpoint: StrataProvider::DEFAULT_ENDPOINT,
      default_model: StrataProvider::DEFAULT_MODEL,
      key_hint: "Only needed if Strata runs with --api-key") do |config, _|
      StrataProvider.new(
        model: config.strata_model || StrataProvider::DEFAULT_MODEL,
        endpoint: config.strata_endpoint || StrataProvider::DEFAULT_ENDPOINT,
        api_key: config.strata_api_key,
      )
    end
  end
end
