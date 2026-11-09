module H2code
  module Setup
    class SetupRequired < Exception
      def initialize(message : String? = nil)
        super(message || H2code.t("setup.required_message"))
      end
    end

    # Alias so call sites read naturally while staying backed by
    # `LLM::ProviderInfo` from the registry.
    alias ProviderChoice = H2code::LLM::Provider::ProviderInfo

    # Providers shown in the first-run selector. Sourced directly from the
    # LLM provider registry (the single source of truth) so every registered
    # backend appears automatically — no second list to maintain.
    def self.choices : Array(ProviderChoice)
      H2code::LLM::Provider.wizard_choices
    end

    # Partial configuration known at some point mid-flow. Used to build a
    # throwaway provider for the live model-list fetch; nil fields are left
    # untouched when applied to a scratch config.
    struct Scratch
      getter provider_name : String
      getter api_key : String?
      getter endpoint : String?
      getter model : String?

      def initialize(@provider_name : String, @api_key : String?,
                     @endpoint : String?, @model : String?)
      end

      def apply_to(config : Config::Config) : Nil
        config.provider_name = provider_name
        Setup.apply_fields(config, provider_name, api_key, endpoint, model)
      end
    end

    # The wizard's goal: a complete, valid provider configuration. Produced
    # only by `Wiz::Done#result`, so every field is guaranteed by construction
    # — an incomplete flow cannot be applied to a Config.
    struct Result
      getter provider_name : String
      getter api_key : String
      getter endpoint : String
      getter model : String
      # Whether the user asked for YOLO to be the default permission mode.
      getter? yolo : Bool
      # True when the user kept the key already stored in the config: apply
      # only switches the default provider and leaves the stored credentials,
      # endpoint and model untouched. The other fields carry no useful values
      # in that case (completeness comes from the stored config).
      getter? keep_existing : Bool

      def initialize(@provider_name : String, @api_key : String,
                     @endpoint : String, @model : String,
                     @yolo : Bool, @keep_existing : Bool)
      end

      # Write the collected values into a Config. Never persisted here.
      def apply_to(config : Config::Config) : Nil
        config.provider_name = provider_name
        # Skip: only the default provider changes — the stored key, endpoint
        # and model for this provider are kept as they were.
        return if keep_existing?
        config.permission_mode = "yolo" if yolo?
        Setup.apply_fields(config, provider_name, api_key, endpoint, model)
      end
    end

    # Compile-time state machine for the first-run / reconfiguration flow.
    # Every step is a type; valid transitions are the only methods that exist
    # on that type, so an illegal move fails to compile instead of wedging the
    # TUI in an inconsistent state. States are immutable; Esc-back walks the
    # `prev` chain the forward walk built, so backward navigation is correct
    # by construction (no hand-maintained transition table).
    abstract class Wiz
      # Placeholder text for the editor input box at this step.
      abstract def placeholder : String

      # Lowercase step name for the status line (matches the old
      # `Step#to_s.downcase` rendering).
      abstract def status : String

      # May the user submit an empty editor with Enter at this step?
      # (Endpoint/Model keep their default, Yolo counts it as "yes",
      # ExistingKey counts it as "keep the stored key".)
      def accepts_empty_submit? : Bool
        false
      end

      # Previous state for Esc-back. Welcome is the bottom of the chain and
      # returns itself; the controller decides what "back at the bottom"
      # means (abort first-run setup vs leave runtime reconfiguration).
      abstract def back : Wiz
    end

    class Wiz::Welcome < Wiz
      def placeholder : String
        H2code.t("setup.pick_provider")
      end

      def status : String
        "welcome"
      end

      def back : Wiz
        self
      end

      # Called when the user submits a provider name from the selector list.
      # existing_key is the key already stored in the config for this
      # provider ("" when none): non-empty turns the credentials step into
      # keep-or-reconfigure instead of forcing key entry.
      def select_provider(name : String, existing_key : String = "") : Credentials | ExistingKey | Endpoint
        choice = Setup.choices.find { |c| c.name == name }
        raise ArgumentError.new("unknown provider: #{name}") unless choice
        if !choice.needs_key?
          # Local providers skip credentials; endpoint/model defaults apply
          # when the user submits an empty value.
          Endpoint.new(self, name, "")
        elsif !existing_key.empty?
          ExistingKey.new(self, name, existing_key)
        else
          Credentials.new(self, name)
        end
      end
    end

    # Base for every state that has a provider chosen. Carries the Esc-back
    # chain and the per-provider defaults from the registry.
    abstract class Wiz::Stated < Wiz
      getter prev : Wiz
      getter provider_name : String

      def initialize(@prev : Wiz, @provider_name : String)
      end

      def back : Wiz
        prev
      end

      protected def choice : ProviderChoice?
        Setup.choices.find { |c| c.name == provider_name }
      end

      def default_endpoint : String
        choice.try(&.default_endpoint) || ""
      end

      def default_model : String
        choice.try(&.default_model) || ""
      end
    end

    class Wiz::Credentials < Wiz::Stated
      def placeholder : String
        if hint = choice.try(&.key_hint).presence
          H2code.t("setup.enter_api_key_hint", hint: hint)
        else
          H2code.t("setup.enter_api_key")
        end
      end

      def status : String
        "credentials"
      end

      def submit_text(text : String) : Endpoint
        raise ArgumentError.new("api key must not be empty") if text.empty?
        Endpoint.new(self, provider_name, text)
      end
    end

    class Wiz::ExistingKey < Wiz::Stated
      # Key the selected provider already has in the config.
      getter existing_api_key : String

      def initialize(prev : Wiz, provider_name : String, @existing_api_key : String)
        super(prev, provider_name)
      end

      def placeholder : String
        H2code.t("setup.existing_key", k: existing_key_mask)
      end

      def status : String
        "existing_key"
      end

      def accepts_empty_submit? : Bool
        true
      end

      # Masked form of the stored key for display (first char + tail).
      def existing_key_mask : String
        k = existing_api_key
        return k if k.size <= 5
        "#{k[0]}•••#{k[-3..]}"
      end

      # Empty submit keeps the stored key and finishes; typing a key
      # reconfigures and continues to endpoint.
      def submit_text(text : String) : Endpoint | Done
        if text.strip.empty?
          Done.new(self, provider_name, existing_api_key, "", "", false, true)
        else
          Endpoint.new(self, provider_name, text)
        end
      end
    end

    class Wiz::Endpoint < Wiz::Stated
      getter api_key : String

      def initialize(prev : Wiz, provider_name : String, @api_key : String)
        super(prev, provider_name)
      end

      def placeholder : String
        H2code.t("setup.enter_endpoint", value: default_endpoint)
      end

      def status : String
        "endpoint"
      end

      def accepts_empty_submit? : Bool
        true
      end

      def scratch : Scratch
        Scratch.new(provider_name, api_key, nil, nil)
      end

      # An empty submission keeps the default endpoint.
      def submit_text(text : String) : Model
        endpoint = text.empty? ? default_endpoint : text
        Model.new(self, provider_name, api_key, endpoint)
      end
    end

    class Wiz::Model < Wiz::Stated
      getter api_key : String
      getter endpoint : String

      def initialize(prev : Wiz, provider_name : String, @api_key : String,
                     @endpoint : String)
        super(prev, provider_name)
      end

      def placeholder : String
        H2code.t("setup.enter_model", value: default_model)
      end

      def status : String
        "model"
      end

      def accepts_empty_submit? : Bool
        true
      end

      def scratch : Scratch
        Scratch.new(provider_name, api_key, endpoint, nil)
      end

      # An empty submission keeps the default model.
      def submit_text(text : String) : Yolo
        model = text.empty? ? default_model : text
        select_model(model)
      end

      # Commit a pick from the live model selector. Replaces the old direct
      # mutation of wizard state from the controller — the transition lives
      # here, where the compiler can check it.
      def select_model(model : String) : Yolo
        Yolo.new(self, provider_name, api_key, endpoint, model)
      end
    end

    class Wiz::Yolo < Wiz::Stated
      getter api_key : String
      getter endpoint : String
      getter model : String

      def initialize(prev : Wiz, provider_name : String, @api_key : String,
                     @endpoint : String, @model : String)
        super(prev, provider_name)
      end

      def placeholder : String
        H2code.t("setup.enable_yolo")
      end

      def status : String
        "yolo"
      end

      def accepts_empty_submit? : Bool
        true
      end

      def submit_text(text : String) : Done
        # Anything except an explicit "no" — including an empty Enter — counts
        # as yes: trust is always the recommended default.
        declined = text.strip.downcase.in?("n", "no", "0", "off", "false", "н", "нет")
        Done.new(self, provider_name, api_key, endpoint, model, !declined, false)
      end
    end

    class Wiz::Done < Wiz::Stated
      getter api_key : String
      getter endpoint : String
      getter model : String
      getter? yolo : Bool
      getter? keep_existing : Bool

      def initialize(prev : Wiz, provider_name : String, @api_key : String,
                     @endpoint : String, @model : String,
                     @yolo : Bool, @keep_existing : Bool)
        super(prev, provider_name)
      end

      def placeholder : String
        ""
      end

      def status : String
        "done"
      end

      # The goal, reached. Only Done can produce a Result — an incomplete
      # flow has no way to be applied to a Config.
      def result : Result
        Result.new(provider_name, api_key, endpoint, model, yolo?, keep_existing?)
      end
    end

    # Cloud providers that share the same config shape (api_key + endpoint +
    # model), mapped to their config setters. Keeps the appliers flat instead
    # of one `when` branch per provider. Nil fields are left untouched so the
    # same table serves Scratch (partial) and Result (complete) application.
    CLOUD_APPLIERS = {
      "zai" => ->(c : Config::Config, k : String?, ep : String?, m : String?) {
        c.zai_api_key = k if k; c.zai_endpoint = ep if ep; c.zai_model = m if m
      },
      "zai-coding-plan" => ->(c : Config::Config, k : String?, ep : String?, m : String?) {
        c.zai_api_key = k if k; c.zai_coding_plan_endpoint = ep if ep; c.zai_coding_plan_model = m if m
      },
      "deepseek" => ->(c : Config::Config, k : String?, ep : String?, m : String?) {
        c.deepseek_api_key = k if k; c.deepseek_endpoint = ep if ep; c.deepseek_model = m if m
      },
      "openrouter" => ->(c : Config::Config, k : String?, ep : String?, m : String?) {
        c.openrouter_api_key = k if k; c.openrouter_endpoint = ep if ep; c.openrouter_model = m if m
      },
      "xai" => ->(c : Config::Config, k : String?, ep : String?, m : String?) {
        c.xai_api_key = k if k; c.xai_endpoint = ep if ep; c.xai_model = m if m
      },
      "groq" => ->(c : Config::Config, k : String?, ep : String?, m : String?) {
        c.groq_api_key = k if k; c.groq_endpoint = ep if ep; c.groq_model = m if m
      },
      "cerebras" => ->(c : Config::Config, k : String?, ep : String?, m : String?) {
        c.cerebras_api_key = k if k; c.cerebras_endpoint = ep if ep; c.cerebras_model = m if m
      },
      "fireworks" => ->(c : Config::Config, k : String?, ep : String?, m : String?) {
        c.fireworks_api_key = k if k; c.fireworks_endpoint = ep if ep; c.fireworks_model = m if m
      },
      "together" => ->(c : Config::Config, k : String?, ep : String?, m : String?) {
        c.together_api_key = k if k; c.together_endpoint = ep if ep; c.together_model = m if m
      },
    }

    # Writes the given values into the provider-specific config fields. Nil
    # fields are skipped, so a partial Scratch never clobbers stored values.
    def self.apply_fields(config : Config::Config, name : String,
                          api_key : String?, endpoint : String?,
                          model : String?) : Nil
      case name
      when "moonshot"
        config.api_key = api_key if api_key
        config.endpoint = endpoint if endpoint
        config.model = model if model
      when "ollama"
        config.ollama_endpoint = endpoint if endpoint
        config.ollama_model = model if model
      when "lmstudio"
        config.lmstudio_endpoint = endpoint if endpoint
        config.lmstudio_model = model if model
      when "strata"
        config.strata_endpoint = endpoint if endpoint
        config.strata_model = model if model
      else
        if applier = CLOUD_APPLIERS[name]?
          applier.call(config, api_key, endpoint, model)
        end
      end
    end
  end
end
