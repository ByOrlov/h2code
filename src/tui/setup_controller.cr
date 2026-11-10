# Setup-wizard controller, mixed into `TUI::App`. The flow is planned, not
# hardcoded: `Setup.missing(state)` derives what is still unconfigured from
# the fill-level data, and this controller runs the step for the head of
# that list. Steps live in `Setup` as typed submit functions (the return
# type declares which requirement they close); this module owns the
# interactive layer — selectors, editor input, transcript, Esc history.
module H2code
  module TUI
    module SetupController
      # When false (specs), `fetch_setup_models` runs its fetch inline instead
      # of in a spawned fiber, so the model selector is open by the time the
      # key event returns — full-path tests need no polling.
      property? setup_fetch_async : Bool = true

      # First-run setup (true) aborts the whole app when the user escapes the
      # provider selector; runtime reconfiguration (false, started via
      # /setup) only exits setup mode.
      property? setup_first_run : Bool = true

      # Enter setup mode: fresh fill-state, welcome banner, provider
      # selector. First-run (`first_run: true`) aborts the whole app when
      # the user escapes the provider selector; `/setup` (false) only exits
      # setup mode — the running session stays untouched.
      def start_setup(first_run : Bool = true) : Nil
        @setup_mode = true
        @setup_first_run = first_run
        @wizard = Setup::State.new
        @setup_history.clear
        # The wizard is a guided flow, not an agent lifecycle phase: drop any
        # stale error/waiting status from before it (e.g. a failed provider
        # switch) so the steps render neutrally and nothing dangles after
        # setup completes.
        @agent_status = AgentStatus::Hello
        # Keep the welcome banner visible so the first-run flow opens with the
        # same branded box as a normal launch, instead of a bare transcript.
        @show_welcome = true
        emit_to_log(Message.new("system",
          H2code.t("ui.setup_welcome")))
        @status = H2code.t("ui.setup_status")
        open_setup_provider_selector
        invalidate_log_cache!
        @dirty = true
      end

      private def setup_current : Setup::State
        @wizard || raise "BUG: setup state accessed outside setup mode"
      end

      # Open the wizard's provider selector. *preferred* names the provider
      # the user was already configuring (Esc-back to the provider step):
      # the cursor is positioned on it instead of the first entry, so a
      # confirming Enter re-selects the same provider rather than silently
      # switching to the alphabetically-first one (Cerebras).
      private def open_setup_provider_selector(preferred : String? = nil) : Nil
        choices = Setup.choices
        items = choices.map(&.label)
        @provider_list.show(H2code.t("ui.select_provider"), items)
        @provider_list.selected = preferred ? (choices.index(&.name.== preferred) || 0) : 0
        @input.drain_pending_enters
        @dirty = true
      end

      private def handle_setup_provider_key(key : KeyEvent) : Nil
        case key.key
        when .up?, .down?
          @provider_list.handle_input(key)
          @dirty = true
        when .enter?
          idx = @provider_list.selected_original_index
          choices = Setup.choices
          # A filter that matches nothing (or a stale index) selects nothing —
          # never silently fall back to the first provider in the registry.
          choice = @provider_list.filtered_size > 0 ? choices[idx]? : nil
          return unless choice
          @provider_list.hide
          @dirty = true

          state = setup_current
          unless Setup.missing(state).first? == Setup::Requirement::Provider
            raise "BUG: provider selector open when missing head is #{Setup.missing(state).first?}"
          end

          # A key already stored for this provider turns the Key step into
          # keep-or-reconfigure (empty Enter keeps the stored key).
          existing = @app_config.try(&.api_key_for(choice.name)) || ""
          filled = Setup.select_provider(choice, existing)
          @setup_history << state
          @wizard = state.with(filled)
          @provider_name = choice.name
          emit_to_log(Message.new("user", choice.label))

          if !choice.needs_key?
            # Keyless provider: the Key requirement does not exist for it,
            # but still show a transcript entry so the user knows why no key
            # was asked.
            emit_to_log(Message.new("system",
              "No API key needed for #{choice.name}."))
          end
          advance_setup_step
        when .escape?, .ctrl_d?
          # Clear the search query first; leave only once it is empty.
          unless @provider_list.clear_query
            if setup_first_run?
              @running = false
            else
              # /setup at runtime: Esc just leaves setup mode — the running
              # session and its provider stay untouched.
              @setup_mode = false
              @status = ""
            end
            @dirty = true
          end
        else
          # ↑/↓, Backspace, and typed characters drive the fuzzy filter.
          @provider_list.handle_input(key)
          @dirty = true
        end
      end

      # Plan-and-enter: run the step for the head of `Setup.missing`, or
      # finish when nothing is missing. *forward* is false when re-entering
      # a step via Esc-back (skip re-emitting transcript notes).
      private def advance_setup_step(forward : Bool = true, preferred : String? = nil) : Nil
        state = setup_current
        case Setup.missing(state).first?
        when Nil
          finish_setup(state)
          return
        when Setup::Requirement::Provider
          @status = "Setup: welcome"
          @editor.clear
          open_setup_provider_selector(preferred)
        when Setup::Requirement::Key
          p = state.provider || raise "BUG: key step planned without a provider"
          if p.existing_key.empty?
            @status = "Setup: credentials"
          else
            @status = "Setup: existing_key"
            if forward
              emit_to_log(Message.new("system",
                H2code.t("setup.existing_key_note", k: Setup.mask_key(p.existing_key))))
            end
          end
          @editor.clear
        when Setup::Requirement::Endpoint
          @status = "Setup: endpoint"
          @editor.clear
        when Setup::Requirement::Model
          @status = "Setup: model"
          @editor.clear
          fetch_setup_models(state)
        when Setup::Requirement::Yolo
          @status = "Setup: yolo"
          @editor.clear
          if forward
            emit_to_log(Message.new("system", H2code.t("setup.yolo_note")))
          end
        end
        @dirty = true
      end

      # Fetch the model list for the provider being configured and open the
      # model selector. On error or empty list, fall back to the Model step's
      # text input (placeholder shows the default model) — never restart the
      # wizard, which would wipe the collected key and trap the user in a
      # select → key → fetch-fail loop.
      private def fetch_setup_models(state : Setup::State) : Nil
        cb = @on_fetch_models_for
        unless cb
          # No way to list models — stay on the text input with the default.
          return
        end

        p = state.provider || raise "BUG: model fetch planned without a provider"
        name = p.choice.name
        @status = "Loading models for #{name}..."
        @model_fetch_active = true
        @editor.clear
        @dirty = true

        fetch = -> do
          begin
            scratch = state.scratch || raise "BUG: model fetch without collected values"
            models = cb.call(scratch)
            if models.empty?
              emit_to_log(Message.new("system", H2code.t("ui.models_unavailable")))
            else
              @model_list.show(H2code.t("ui.select_model", name: name), models)
              default = p.choice.default_model || models.first?
              @model_list.selected = models.index(default) || 0
            end
          rescue ex
            emit_to_log(Message.new("system", H2code.t("ui.models_unavailable")))
          ensure
            @model_fetch_active = false
            # The fetch captured the wizard state it was started for; report
            # that step rather than whatever state is current when it lands.
            @status = "Setup: #{Setup.step_name(setup_current)}"
            @dirty = true
          end
        end

        if setup_fetch_async?
          spawn { fetch.call }
        else
          fetch.call
        end
      end

      # Handle keys while the model selector is open during setup. Enter
      # commits the selection; Esc closes the selector and steps back.
      private def handle_setup_model_key(key : KeyEvent) : Nil
        case key.key
        when .enter?
          state = setup_current
          unless Setup.missing(state).first? == Setup::Requirement::Model
            raise "BUG: model selector open when missing head is #{Setup.missing(state).first?}"
          end
          p = state.provider || raise "BUG: model selector open without a provider"
          default = p.choice.default_model || ""
          model = @model_list.current || default
          @model_list.hide
          @dirty = true
          emit_to_log(Message.new("user", model))
          filled = Setup.submit_model(state, model)
          @setup_history << state
          @wizard = state.with(filled)
          advance_setup_step
        when .escape?, .ctrl_d?
          # Clear the search query first; only step back once it is empty.
          unless @model_list.clear_query
            @model_list.hide
            back_setup_step
          end
          @dirty = true
        else
          # ↑/↓, Backspace, and typed characters drive the fuzzy filter.
          @model_list.handle_input(key)
          @dirty = true
        end
      end

      # Step backward through the fill history: the state before the last
      # submit. Bottoming out (history empty ⇒ the provider step) leaves the
      # wizard. Re-entering a step re-runs its planning side effects (model
      # fetch, provider selector) but not the transcript notes.
      private def back_setup_step : Nil
        state = setup_current
        if @setup_history.empty?
          if setup_first_run?
            # Already at the top: exit the app (abort first-run setup).
            @running = false
          else
            # Runtime reconfiguration: Esc just leaves setup mode — the
            # running session and its provider stay untouched.
            @setup_mode = false
            @status = ""
          end
          @dirty = true
          return
        end

        preferred = state.provider.try(&.choice.name)
        @wizard = @setup_history.pop
        @editor.clear
        @model_list.hide
        advance_setup_step(forward: false, preferred: preferred)
      end

      private def finish_setup(state : Setup::State) : Nil
        result = state.result? || raise "BUG: finish_setup with an incomplete wizard"

        config_msg = "Provider: #{result.provider_name}"
        config_msg += " | Model: #{result.model}" unless result.model.empty?
        config_msg += " | YOLO: on" if result.yolo?
        emit_to_log(Message.new("system", H2code.t("ui.config_saved", msg: config_msg)))
        emit_to_log(Message.new("system", H2code.t("ui.starting")))
        @status = ""
        @setup_mode = false
        @dirty = true

        if cb = @on_setup_complete
          cb.call(result)
        end
      end

      # May the user submit an empty editor at the currently planned step?
      # Endpoint/Model keep their default, Yolo counts it as "yes", Key only
      # when a stored key exists (keep-or-reconfigure).
      private def setup_accepts_empty_submit? : Bool
        state = setup_current
        case Setup.missing(state).first?
        when Setup::Requirement::Key
          p = state.provider || return false
          !p.existing_key.empty?
        when Setup::Requirement::Endpoint, Setup::Requirement::Model, Setup::Requirement::Yolo
          true
        else
          false
        end
      end

      private def submit_setup_text(text : String) : Nil
        state = setup_current
        head = Setup.missing(state).first?
        raise "BUG: text submit when missing head is #{head}" if head.nil? ||
                                                                 head == Setup::Requirement::Provider

        filled = case head
                 when Setup::Requirement::Key
                   Setup.submit_key(state, text)
                 when Setup::Requirement::Endpoint
                   Setup.submit_endpoint(state, text)
                 when Setup::Requirement::Model
                   Setup.submit_model(state, text)
                 when Setup::Requirement::Yolo
                   Setup.submit_yolo(text)
                 else
                   raise "BUG: unreachable"
                 end

        # Echo the submission to the transcript; secrets are masked.
        case filled
        when Setup::Filled::Key
          display = filled.kept? ? "(keep existing key)" : "#{"•" * {filled.value.size, 8}.min}"
          emit_to_log(Message.new("user", display))
        when Setup::Filled::Endpoint, Setup::Filled::Model
          emit_to_log(Message.new("user", text.empty? ? "(default)" : text))
        when Setup::Filled::Yolo
          emit_to_log(Message.new("user", text.empty? ? "(yes)" : text.strip))
        end

        @setup_history << state
        @wizard = state.with(filled)
        advance_setup_step
      end
    end
  end
end
