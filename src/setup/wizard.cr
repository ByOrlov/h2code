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

    # ------------------------------------------------------------------
    # Goal: what a complete configuration consists of, and one closing type
    # per requirement. The state is just these closings, accumulated.
    # ------------------------------------------------------------------

    # The sub-goals of the wizard, in planning order (dependencies: the
    # model step needs the key and the endpoint, so they come first).
    enum Requirement
      Provider
      Key
      Endpoint
      Model
      Yolo
    end

    # The closing of one requirement. Each type knows what it closes; the
    # names map 1:1 onto Requirement members — that correspondence is the
    # mosaic, verified at compile time below.
    abstract struct Filled
      abstract def requirement : Requirement
    end

    struct Filled::Provider < Filled
      getter choice : ProviderChoice
      # Key already stored in the config for this provider ("" when none).
      # Context captured at selection time; it decides the Key step's input
      # mode (fresh entry vs keep-or-reconfigure).
      getter existing_key : String

      def initialize(@choice : ProviderChoice, @existing_key : String = "")
      end

      def requirement : Requirement
        Requirement::Provider
      end
    end

    struct Filled::Key < Filled
      getter value : String
      # True when the user kept the already-stored key: the goal is then
      # satisfied by the stored config (missing → [], the one conditional
      # goal in the flow).
      getter? kept : Bool

      def initialize(@value : String, @kept : Bool = false)
      end

      def requirement : Requirement
        Requirement::Key
      end
    end

    struct Filled::Endpoint < Filled
      getter value : String

      def initialize(@value : String)
      end

      def requirement : Requirement
        Requirement::Endpoint
      end
    end

    struct Filled::Model < Filled
      getter value : String

      def initialize(@value : String)
      end

      def requirement : Requirement
        Requirement::Model
      end
    end

    struct Filled::Yolo < Filled
      getter? value : Bool

      def initialize(@value : Bool)
      end

      def requirement : Requirement
        Requirement::Yolo
      end
    end

    # Mosaic, checked at compile time: every Requirement must have exactly
    # one Filled type and every Filled type must close a real Requirement —
    # the two constant lists are simply compared. Adding a requirement
    # without a closing type (or vice versa) fails the build.
    {% begin %}
      {% req_names = Requirement.constants.sort %}
      {% fill_names = Filled.constants.sort %}
      {% if req_names != fill_names %}
        {% raise "setup mosaic mismatch: requirements #{req_names} vs filled #{fill_names}" %}
      {% end %}
    {% end %}

    # ------------------------------------------------------------------
    # State = fill-level. Nothing else: which step is current is never
    # stored, it is planned from the data below.
    # ------------------------------------------------------------------

    struct State
      getter provider : Filled::Provider?
      getter key : Filled::Key?
      getter endpoint : Filled::Endpoint?
      getter model : Filled::Model?
      getter yolo : Filled::Yolo?

      def initialize(@provider : Filled::Provider? = nil, @key : Filled::Key? = nil,
                     @endpoint : Filled::Endpoint? = nil, @model : Filled::Model? = nil,
                     @yolo : Filled::Yolo? = nil)
      end

      def with(f : Filled::Provider) : State
        State.new(f, key, endpoint, model, yolo)
      end

      def with(f : Filled::Key) : State
        State.new(provider, f, endpoint, model, yolo)
      end

      def with(f : Filled::Endpoint) : State
        State.new(provider, key, f, model, yolo)
      end

      def with(f : Filled::Model) : State
        State.new(provider, key, endpoint, f, yolo)
      end

      def with(f : Filled::Yolo) : State
        State.new(provider, key, endpoint, model, f)
      end

      # What is closed so far — the closings know it themselves.
      def filled : Array(Filled)
        [provider, key, endpoint, model, yolo].compact
      end

      # The goal, reached: a complete Result. Nil while anything is missing,
      # so an incomplete flow cannot be applied to a Config.
      def result? : Result?
        return nil unless Setup.missing(self).empty?
        p = provider || return nil
        Result.new(p.choice.name, key.try(&.value) || "", endpoint.try(&.value) || "",
          model.try(&.value) || "", yolo.try(&.value?) || false, key.try(&.kept?) || false)
      end

      # Collected values for a throwaway provider (live model-list fetch).
      def scratch : Scratch?
        p = provider || return nil
        Scratch.new(p.choice.name, key.try(&.value), endpoint.try(&.value),
          model.try(&.value))
      end
    end

    # Requirements in planning order for the current fill-level: Provider
    # first; once chosen, the provider's own requirements (Keyless providers
    # never list Key — the single place this fact lives).
    def self.requirements(state : State) : Array(Requirement)
      reqs = [Requirement::Provider] of Requirement
      if p = state.provider
        reqs << Requirement::Key if p.choice.needs_key?
        reqs << Requirement::Endpoint
        reqs << Requirement::Model
        reqs << Requirement::Yolo
      end
      reqs
    end

    # Pure total function, derived from the fill-level data — no step types,
    # no tables: which requirements are still not closed. Keep-existing
    # short-circuits to an empty list: the stored config already satisfies
    # the goal.
    def self.missing(state : State) : Array(Requirement)
      return [] of Requirement if state.key.try(&.kept?)
      requirements(state).reject { |r| state.filled.any?(&.requirement.==(r)) }
    end

    # ------------------------------------------------------------------
    # Steps. The return type IS the declaration of which requirement the
    # step closes — an Endpoint step cannot produce a Key closing, the
    # compiler guarantees the wiring.
    # ------------------------------------------------------------------

    def self.select_provider(choice : ProviderChoice, existing_key : String = "") : Filled::Provider
      Filled::Provider.new(choice, existing_key)
    end

    def self.submit_key(state : State, input : String) : Filled::Key
      p = state.provider || raise ArgumentError.new("BUG: key submit without a provider")
      existing = p.existing_key
      if input.strip.empty?
        raise ArgumentError.new("api key must not be empty") if existing.empty?
        Filled::Key.new(existing, kept: true)
      else
        Filled::Key.new(input, kept: false)
      end
    end

    def self.submit_endpoint(state : State, input : String) : Filled::Endpoint
      p = state.provider || raise ArgumentError.new("BUG: endpoint submit without a provider")
      default = p.choice.default_endpoint
      Filled::Endpoint.new(input.empty? ? default : input)
    end

    def self.submit_model(state : State, input : String) : Filled::Model
      p = state.provider || raise ArgumentError.new("BUG: model submit without a provider")
      default = p.choice.default_model
      Filled::Model.new(input.empty? ? default : input)
    end

    def self.submit_yolo(input : String) : Filled::Yolo
      # Anything except an explicit "no" — including an empty Enter —
      # counts as yes: trust is always the recommended default.
      declined = input.strip.downcase.in?("n", "no", "0", "off", "false", "н", "нет")
      Filled::Yolo.new(!declined)
    end

    # ------------------------------------------------------------------
    # Presentation helpers (placeholder / status line / key masking).
    # ------------------------------------------------------------------

    def self.mask_key(k : String) : String
      return k if k.size <= 5
      "#{k[0]}•••#{k[-3..]}"
    end

    # Placeholder text for the editor at the currently planned step.
    def self.placeholder(state : State) : String
      case req = missing(state).first?
      when Requirement::Provider
        H2code.t("setup.pick_provider")
      when Requirement::Key
        p = state.provider || raise "BUG: key step planned without a provider"
        if p.existing_key.empty?
          if hint = p.choice.key_hint.presence
            H2code.t("setup.enter_api_key_hint", hint: hint)
          else
            H2code.t("setup.enter_api_key")
          end
        else
          H2code.t("setup.existing_key", k: mask_key(p.existing_key))
        end
      when Requirement::Endpoint
        p = state.provider || raise "BUG: endpoint step planned without a provider"
        H2code.t("setup.enter_endpoint", value: p.choice.default_endpoint)
      when Requirement::Model
        p = state.provider || raise "BUG: model step planned without a provider"
        H2code.t("setup.enter_model", value: p.choice.default_model)
      when Requirement::Yolo
        H2code.t("setup.enable_yolo")
      else
        ""
      end
    end

    # One step of the goal view with its state: :closed, :current or
    # :pending. Consumed by the TUI, which colours each kind differently.
    record ProgressStep, name : String, kind : Symbol

    # The goal view for the status bar: every requirement of the flow with
    # its state, in planning order. Derived straight from the fill-level,
    # so it always matches what the planner will ask next. The chosen
    # provider is not included as a step — the TUI shows it as the line's
    # prefix; before a choice is made the single :current "provider" step
    # is returned instead.
    def self.progress_steps(state : State) : Array(ProgressStep)
      current = missing(state).first?
      closed = state.filled.map(&.requirement)
      chosen = state.provider
      requirements(state).compact_map do |r|
        next nil if chosen && r == Requirement::Provider
        kind = closed.includes?(r) ? :closed : (current == r ? :current : :pending)
        ProgressStep.new(r.to_s.downcase, kind)
      end
    end

    # Lowercase step name for the status line (same rendering the old
    # Step#to_s.downcase produced).
    def self.step_name(state : State) : String
      case missing(state).first?
      when Requirement::Provider
        "welcome"
      when Requirement::Key
        p = state.provider || raise "BUG: key step planned without a provider"
        p.existing_key.empty? ? "credentials" : "existing_key"
      when Requirement::Endpoint
        "endpoint"
      when Requirement::Model
        "model"
      when Requirement::Yolo
        "yolo"
      else
        "done"
      end
    end

    # ------------------------------------------------------------------
    # Applying the collected values to a Config.
    # ------------------------------------------------------------------

    # Partial configuration known mid-flow. Used to build a throwaway
    # provider for the live model-list fetch; nil fields are left untouched
    # when applied to a scratch config.
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
    # only by `State#result?` when nothing is missing, so every field is
    # guaranteed by construction — an incomplete flow cannot be applied.
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
