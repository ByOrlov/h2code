module H2code
  module LLM
    # Raised when a provider cannot be built from the current config (missing
    # credentials, unknown name, ...). At startup it is rescued and turned into
    # an exit; at runtime the /provider selector catches it to show an inline
    # error without leaving the TUI.
    class ProviderConfigError < Exception
    end

    # Abstract base for all chat-completion backends.
    #
    # A Provider converts the shared Message / ToolDefinition types into a
    # provider-specific request, streams the response back as MessagePart
    # deltas, and returns the aggregated StepResult. The agent loop depends
    # only on this abstraction, so a new backend can be added by subclassing
    # Provider and appending a `Provider.register` call to it.
    abstract class Provider
      # Debug logging toggle, propagated from Config.debug. When true,
      # providers emit verbose stderr diagnostics (e.g. failed SSE parses).
      property? debug : Bool = false

      # Short stable identifier for the backend ("moonshot", "openai", ...).
      # Surfaced by the /provider selector and the status footer.
      abstract def name : String

      # Upstream model name sent to the API (e.g. "kimi-for-coding").
      abstract def model_name : String

      # Fetch the list of model IDs available on this backend via
      # GET /models. Used by the /model selector at runtime.
      abstract def fetch_models : Array(String)

      # Send a conversation to the model and stream the response.
      #
      # Yields each streaming MessagePart (text deltas, tool-call deltas,
      # usage, finish reason) as they arrive, then returns the aggregated
      # StepResult. `aborted?` is polled so the provider can tear down an
      # in-flight connection when the user cancels.
      abstract def chat(messages : Array(Message), tools : Array(ToolDefinition)?,
                        system_prompt : String? = nil,
                        aborted? : -> Bool = -> { false },
                        &block : MessagePart ->) : StepResult

      # Whether the active model accepts only `{"type":"text"}` content
      # parts. When true, the transport strips image/audio/video blocks
      # from the message history before sending — text-only endpoints
      # (e.g. GLM coding-plan models) reject them with HTTP 400. Set from
      # the config's per-model `text_only_models` mark, or flipped
      # automatically by the agent loop when the endpoint rejects media.
      property? text_only : Bool = false

      # Runtime request-config hooks. The base Provider no-ops them so the
      # agent loop can call them uniformly on any backend; OpenAIChatProvider
      # overrides to fold them into the request body (prompt-cache key, thinking
      # effort, per-step completion-token budget clamp). Providers that do not
      # support a given field simply ignore it.
      def prompt_cache_key=(key : String?) : Nil
      end

      def thinking_effort=(effort : String?) : Nil
      end

      # Returns the current thinking-effort hint or nil. The base Provider
      # always returns nil (no concept of effort); OpenAIChatProvider
      # overrides to expose the configured value.
      def thinking_effort : String?
        nil
      end

      def max_context_tokens=(tokens : Int32?) : Nil
      end

      # Updated by the agent before each step so the provider can clamp the
      # completion budget against the remaining context window.
      def used_context_tokens=(tokens : Int32) : Nil
      end

      # Provider base URL / endpoint, when the backend has one. Used by the
      # WebSearch service to derive the Moonshot search URL. Base Provider
      # returns nil; OpenAIChatProvider overrides with its endpoint.
      def base_url : String?
        nil
      end

      # Current bearer token / API key for outbound requests. Used by the
      # WebSearch service to authorize Moonshot search calls. Base Provider
      # returns nil; OpenAIChatProvider overrides with its auth token.
      def auth_token : String?
        nil
      end

      # Metadata for a selectable backend, listed by the /provider command and
      # the first-run setup wizard. Carries both the selector description and
      # the wizard-facing fields (label, key requirement, defaults). The
      # registry is the single source of truth — every place that lists
      # backends enumerates this, so a new provider appears everywhere by
      # adding one `Provider.register` call.
      struct ProviderInfo
        property name : String
        property description : String
        # Human-facing label shown in the first-run wizard selector.
        property label : String
        # Whether this backend requires an API key (true) or runs keyless
        # (local servers like ollama / lmstudio).
        property? needs_key : Bool
        property default_endpoint : String
        property default_model : String
        property key_hint : String
        # Hidden backends are excluded from the first-run wizard but still
        # reachable via `/provider` and config (used by `mock`).
        property? hidden : Bool

        def initialize(@name : String, @description : String,
                       @label : String = @name, @needs_key : Bool = true,
                       @default_endpoint : String = "", @default_model : String = "",
                       @key_hint : String = "", @hidden : Bool = false)
        end
      end

      # One registered backend: the metadata shown in selectors plus the
      # factory that builds a live `Provider` from a `Config` (and optional
      # OAuth creds). The registry is the single source of truth — both the
      # `/provider` selector, the setup wizard, and `build_named_provider`
      # enumerate it, so adding a backend is just one `Provider.register`
      # call in its file.
      struct Registration
        getter info : ProviderInfo
        getter builder : Proc(Config::Config, OAuthCredentials?, Provider)

        def initialize(@info : ProviderInfo,
                       @builder : Proc(Config::Config, OAuthCredentials?, Provider))
        end
      end

      @@registry = [] of Registration

      # Register a backend under a stable name. Each provider file calls this
      # at top level so `require`-ing the file is enough to make the backend
      # appear in selectors, the setup wizard, and `build_named_provider` — no
      # second list to keep in sync.
      #
      # Wizard metadata (`label`, `needs_key`, `default_endpoint`,
      # `default_model`, `key_hint`) is supplied as named args so the registry
      # stays the single source of truth. `hidden` excludes a backend from the
      # first-run wizard (e.g. `mock`) while keeping it usable elsewhere.
      def self.register(name : String, description : String, *,
                        label : String = name, needs_key : Bool = true,
                        default_endpoint : String = "", default_model : String = "",
                        key_hint : String = "", hidden : Bool = false,
                        &builder : Config::Config, OAuthCredentials? -> Provider) : Nil
        info = ProviderInfo.new(name, description, label, needs_key,
          default_endpoint, default_model, key_hint, hidden)
        @@registry << Registration.new(info, builder)
      end

      # All registered backends, sorted A→Z by name.
      def self.providers : Array(ProviderInfo)
        @@registry.map(&.info).sort_by!(&.name)
      end

      # Backends visible in the first-run wizard (hidden ones excluded).
      def self.wizard_choices : Array(ProviderInfo)
        providers.reject(&.hidden?)
      end

      def self.known_provider?(name : String) : Bool
        @@registry.any? { |r| r.info.name == name }
      end

      def self.find(name : String) : Registration?
        @@registry.find { |r| r.info.name == name }
      end
    end

    DEFAULT_PROVIDER_NAME = nil
  end
end
