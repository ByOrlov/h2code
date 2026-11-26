module H2code
  module LLM
    # Z.AI / Zhipu backend (GLM Coding Plan) over the OpenAI Chat Completions
    # protocol. Auth is a plain API key — no OAuth. Shares the SSE transport
    # with MoonshotProvider through OpenAIChatProvider.
    class ZaiProvider < OpenAIChatProvider
      DEFAULT_MODEL    = "glm-4.6"
      DEFAULT_ENDPOINT = "https://api.z.ai/api/paas/v4"

      # Server-side context windows per model family (docs.z.ai): GLM-5.2
      # and newer ship a 1M-token context; the 4.x generation is 200K.
      # Model names carrying the "1m" marker (ZCode's `[1m]` suffix, e.g.
      # a pinned "glm-4.6-1m") are fixed at 1M regardless of generation.
      CONTEXT_TOKENS_1M   = 1_048_576
      CONTEXT_TOKENS_200K =   204_800

      property provider_label : String
      # When true, injects Z.AI's built-in `web_search` tool into every chat
      # completions request so the model can search the web transparently.
      # Covered by the GLM Coding Plan quota (no separate PaaS balance needed).
      property? builtin_web_search : Bool = false

      def initialize(model : String = DEFAULT_MODEL,
                     endpoint : String = DEFAULT_ENDPOINT,
                     api_key : String = "",
                     @provider_label : String = "zai",
                     temperature : Float64? = nil,
                     max_tokens : Int32? = nil,
                     builtin_web_search : Bool = false)
        super(model, endpoint, api_key, temperature, max_tokens)
        # Z.AI / Zhipu (GLM) is OpenAI-compatible: it speaks the top-level
        # `reasoning_effort` string for reasoning control, not the Moonshot
        # `thinking` object. Unsupported efforts are clamped per model family
        # in `build_request` — see `forced_thinking?`.
        @thinking_wire = ThinkingWire::ReasoningEffort
        @builtin_web_search = builtin_web_search
      end

      def name : String
        @provider_label
      end

      def token : String
        @api_key
      end

      # Per-model default context window — see Provider#default_context_tokens.
      # Unknown/unparseable model names return nil (fall back to the
      # configured window) rather than guessing.
      def default_context_tokens : Int32?
        model = @model.downcase
        return CONTEXT_TOKENS_1M if model.includes?("1m")
        if match = model.match(/^glm-(\d+)(?:\.(\d+))?/)
          major = match[1].to_i
          minor = match[2]?.try(&.to_i) || 0
          return CONTEXT_TOKENS_1M if major > 5 || (major == 5 && minor >= 2)
          return CONTEXT_TOKENS_200K if major >= 4
        end
        nil
      end

      def build_request(messages : Array(Message), tools : Array(ToolDefinition)?) : ChatRequest
        request = super
        if @builtin_web_search
          # Z.AI built-in web_search tool — the model searches internally and
          # returns results in its response, no client-side tool_call needed.
          current = request.extra_tools || [] of JSON::Any
          current << JSON.parse(%({"type":"web_search","web_search":{"enable":true,"search_result":true}}))
          request.extra_tools = current
        end
        # Forced-thinking models can't disable reasoning: "off" maps to "low"
        # (the docs' recommended substitute), "on"/unset keep the server
        # default, everything else is clamped to a valid level.
        if forced_thinking?
          effort = @thinking_effort.try(&.downcase)
          request.reasoning_effort =
            case effort
            when "off", "none", "disabled" then "low"
            when nil, "on"                 then nil
            else                           clamp_forced_effort(effort.not_nil!)
            end
        end
        request
      end

      # GLM-5.3 and newer are forced-thinking models: the endpoint accepts
      # `reasoning_effort` only as "low"/"high"/"max" and answers anything
      # else (e.g. the config-default "medium") with HTTP 400 — "This model
      # always engages in thinking and cannot be disabled; please use low,
      # high, or max". Older GLM models accept the full OpenAI set and map
      # aliases server-side (docs.z.ai openapi: medium→high, none/minimal→
      # skip thinking, xhigh→max), so their efforts pass through untouched.
      # Z.AI exposes no effort metadata over /models (ids only), so the
      # split is derived from the model name the same way
      # `default_context_tokens` is.
      private def forced_thinking? : Bool
        return false unless match = @model.downcase.match(/^glm-(\d+)(?:\.(\d+))?/)
        major = match[1].to_i
        minor = match[2]?.try(&.to_i) || 0
        major > 5 || (major == 5 && minor >= 3)
      end

      private def clamp_forced_effort(effort : String) : String
        case effort.downcase
        when "low", "high", "max" then effort.downcase
        when "xhigh"              then "max"
        when "minimal"            then "low"
        else                      "high"
        end
      end
    end

    Provider.register("zai", "Z.AI / Zhipu — pay-as-you-go (OpenAI-compatible)",
      label: "Z.AI / Zhipu (GLM)", needs_key: true,
      default_endpoint: "https://api.z.ai/api/paas/v4",
      default_model: "glm-4.6",
      key_hint: "Get a key at https://z.ai") do |config, _|
      if config.zai_api_key.empty?
        raise ProviderConfigError.new(
          "No Z.AI credentials found. Set the ZAI_API_KEY or ZHIPU_API_KEY environment variable " \
          "(or [provider.zai] api_key in config).")
      end
      ZaiProvider.new(
        model: config.zai_model,
        endpoint: config.zai_endpoint,
        api_key: config.zai_api_key,
        provider_label: "zai",
        builtin_web_search: true,
      )
    end

    Provider.register("zai-coding-plan", "Z.AI / Zhipu — Coding Plan subscription",
      label: "Z.AI / Zhipu — Coding Plan", needs_key: true,
      default_endpoint: "https://api.z.ai/api/coding/paas/v4",
      default_model: "glm-5.2",
      key_hint: "Get a key at https://z.ai") do |config, _|
      if config.zai_api_key.empty?
        raise ProviderConfigError.new(
          "No Z.AI credentials found. Set the ZAI_API_KEY or ZHIPU_API_KEY environment variable.")
      end
      # Coding Plan uses the official Web Search MCP server (auto-configured in
      # Config#auto_mcp_servers), not the chat-completions built-in web_search.
      ZaiProvider.new(
        model: config.zai_coding_plan_model,
        endpoint: config.zai_coding_plan_endpoint,
        api_key: config.zai_api_key,
        provider_label: "zai-coding-plan",
        builtin_web_search: false,
      )
    end
  end
end
