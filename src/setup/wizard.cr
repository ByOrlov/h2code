module H2code
  module Setup
    class SetupRequired < Exception
      def initialize(message : String? = nil)
        super(message || H2code.t("setup.required_message"))
      end
    end

    # Alias so call sites (`Setup::Wizard.choices`, `current_choice`) read
    # naturally while staying backed by `LLM::ProviderInfo` from the registry.
    alias ProviderChoice = H2code::LLM::Provider::ProviderInfo

    # Stateful first-run wizard. Driven by the TUI input box: each step
    # produces a placeholder string; the user types a value and submits.
    # When the provider needs no key (ollama / lmstudio), the credentials
    # step is skipped entirely.
    class Wizard
      enum Step
        Welcome
        ExistingKey
        Credentials
        Endpoint
        Model
        Yolo
        Done
      end

      property step : Step = Step::Welcome
      property provider_name : String? = nil
      property api_key : String = ""
      property endpoint : String? = nil
      property model : String? = nil
      # Key the selected provider already has in the config (set by the
      # driver from Config#api_key_for before select_provider). Non-empty →
      # the wizard shows the keep-or-reconfigure step instead of forcing key
      # entry.
      property existing_api_key : String = ""
      # True when the user chose to keep the stored key (skip): apply_to then
      # only switches the default provider and leaves the stored credentials,
      # endpoint and model untouched.
      property? keep_existing : Bool = false
      # Whether the user asked for YOLO to be the default permission mode.
      # Collected on the Yolo step right after model selection: the step
      # offers trust-by-default (yes) or per-action confirmations (no). An
      # empty answer means "yes" — trust is always the recommended default.
      property? yolo : Bool = false

      # The provider list shown in the first-run selector. Sourced directly
      # from the LLM provider registry (the single source of truth) so every
      # registered backend appears automatically — no second list to maintain.
      def self.choices : Array(ProviderChoice)
        H2code::LLM::Provider.wizard_choices
      end

      def current_choice : ProviderChoice?
        self.class.choices.find { |choice| choice.name == provider_name }
      end

      def done? : Bool
        step == Step::Done
      end

      # Placeholder text for the editor input box at the current step.
      def placeholder : String
        case step
        when Step::Welcome
          H2code.t("setup.pick_provider")
        when Step::ExistingKey
          H2code.t("setup.existing_key", k: existing_key_mask)
        when Step::Credentials
          if hint = current_choice.try(&.key_hint).presence
            H2code.t("setup.enter_api_key_hint", hint: hint)
          else
            H2code.t("setup.enter_api_key")
          end
        when Step::Endpoint
          H2code.t("setup.enter_endpoint", value: default_endpoint)
        when Step::Model
          H2code.t("setup.enter_model", value: default_model)
        when Step::Yolo
          H2code.t("setup.enable_yolo")
        else
          ""
        end
      end

      private def default_endpoint : String
        current_choice.try(&.default_endpoint) || ""
      end

      private def default_model : String
        current_choice.try(&.default_model) || ""
      end

      # Masked form of the stored key for display (first char + tail).
      def existing_key_mask : String
        k = existing_api_key
        return k if k.size <= 5
        "#{k[0]}•••#{k[-3..]}"
      end

      # Called when the user submits a provider name (from the selector list).
      def select_provider(name : String) : Nil
        self.provider_name = name
        choice = current_choice
        if choice && !choice.needs_key?
          # Local providers skip credentials; endpoint and model get sensible
          # defaults so we can fast-forward unless the user wants to override.
          self.endpoint = choice.default_endpoint
          self.model = choice.default_model
          self.step = Step::Endpoint
        elsif !existing_api_key.empty?
          # The provider already has a key in the config: offer keep-vs-
          # reconfigure instead of forcing key entry.
          self.keep_existing = false
          self.step = Step::ExistingKey
        else
          self.step = Step::Credentials
        end
      end

      # Called when the user submits typed text (key / endpoint / model).
      # An empty submission keeps the default for endpoint/model.
      def submit_text(text : String) : Nil
        case step
        when Step::ExistingKey
          if text.strip.empty?
            # Skip: keep the stored key — and, since nothing else is
            # collected, the stored endpoint/model too.
            self.keep_existing = true
            self.api_key = existing_api_key
            self.step = Step::Done
          else
            self.api_key = text
            self.step = Step::Endpoint
          end
        when Step::Credentials
          self.api_key = text
          self.step = Step::Endpoint
        when Step::Endpoint
          self.endpoint = text.empty? ? default_endpoint : text
          self.step = Step::Model
        when Step::Model
          self.model = text.empty? ? default_model : text
          self.step = Step::Yolo
        when Step::Yolo
          # Two choices only: yes (trust by default) or no. Anything except
          # an explicit "no" — including an empty Enter — counts as yes.
          declined = text.strip.downcase.in?("n", "no", "0", "off", "false", "н", "нет")
          self.yolo = !declined
          self.step = Step::Done
        end
      end

      # Step the wizard one step backward. Clears any value collected on the
      # step being left so re-entering it starts clean.
      def back : Nil
        case step
        when Step::ExistingKey
          self.keep_existing = false
          self.provider_name = nil
          self.step = Step::Welcome
        when Step::Credentials
          self.api_key = ""
          self.provider_name = nil
          self.step = Step::Welcome
        when Step::Endpoint
          self.endpoint = nil
          self.step = Step::Credentials
        when Step::Model
          self.model = nil
          self.step = Step::Endpoint
        when Step::Yolo
          self.yolo = false
          self.step = Step::Model
        end
      end

      # Cloud providers that share the same config shape (api_key + endpoint +
      # model), mapped to their config setters. Keeps `apply_to` flat instead of
      # one `when` branch per provider.
      CLOUD_APPLIERS = {
        "zai" => ->(c : Config::Config, k : String, ep : String?, m : String?) {
          c.zai_api_key = k; c.zai_endpoint = ep || ""; c.zai_model = m || ""
        },
        "zai-coding-plan" => ->(c : Config::Config, k : String, ep : String?, m : String?) {
          c.zai_api_key = k; c.zai_coding_plan_endpoint = ep || ""; c.zai_coding_plan_model = m || ""
        },
        "deepseek" => ->(c : Config::Config, k : String, ep : String?, m : String?) {
          c.deepseek_api_key = k; c.deepseek_endpoint = ep || ""; c.deepseek_model = m || ""
        },
        "openrouter" => ->(c : Config::Config, k : String, ep : String?, m : String?) {
          c.openrouter_api_key = k; c.openrouter_endpoint = ep || ""; c.openrouter_model = m || ""
        },
        "xai" => ->(c : Config::Config, k : String, ep : String?, m : String?) {
          c.xai_api_key = k; c.xai_endpoint = ep || ""; c.xai_model = m || ""
        },
        "groq" => ->(c : Config::Config, k : String, ep : String?, m : String?) {
          c.groq_api_key = k; c.groq_endpoint = ep || ""; c.groq_model = m || ""
        },
        "cerebras" => ->(c : Config::Config, k : String, ep : String?, m : String?) {
          c.cerebras_api_key = k; c.cerebras_endpoint = ep || ""; c.cerebras_model = m || ""
        },
        "fireworks" => ->(c : Config::Config, k : String, ep : String?, m : String?) {
          c.fireworks_api_key = k; c.fireworks_endpoint = ep || ""; c.fireworks_model = m || ""
        },
        "together" => ->(c : Config::Config, k : String, ep : String?, m : String?) {
          c.together_api_key = k; c.together_endpoint = ep || ""; c.together_model = m || ""
        },
      }

      # Write the collected values into a Config and persist it.
      def apply_to(config : Config::Config) : Nil
        config.provider_name = provider_name
        # Skip: only the default provider changes — the stored key, endpoint
        # and model for this provider are kept as they were.
        return if keep_existing?
        config.permission_mode = "yolo" if yolo?
        case provider_name
        when "moonshot"
          config.api_key = api_key
          config.endpoint = endpoint
          config.model = model
        when "ollama"
          config.ollama_endpoint = endpoint
          config.ollama_model = model
        when "lmstudio"
          config.lmstudio_endpoint = endpoint
          config.lmstudio_model = model
        when "strata"
          config.strata_endpoint = endpoint
          config.strata_model = model
        else
          if applier = CLOUD_APPLIERS[provider_name || ""]?
            applier.call(config, api_key, endpoint, model)
          end
        end
      end
    end
  end
end
