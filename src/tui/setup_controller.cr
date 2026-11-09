# Setup-wizard controller, mixed into `TUI::App`. Owns the first-run provider
# configuration flow, driven by the compile-time state machine in
# `Setup::Wiz`: the controller cases over the current state type, submits
# input through the state's own transition methods, and invokes
# `on_setup_complete` with the `Setup::Result` when the flow reaches Done.
module H2code
  module TUI
    module SetupController
      # When false (specs), `fetch_setup_models` runs its fetch inline instead
      # of in a spawned fiber, so the model selector is open by the time the
      # key event returns — full-path tests need no polling.
      property? setup_fetch_async : Bool = true

      # First-run setup (true) aborts the whole app when the user escapes the
      # provider selector; runtime reconfiguration (false, started via
      # /provider → start_setup_for_provider) only exits setup mode.
      property? setup_first_run : Bool = true

      # Enter setup mode: show the wizard transcript and open the provider
      # selector. Called once at first-run before the normal TUI loop starts.
      def start_setup : Nil
        @setup_mode = true
        @setup_first_run = true
        @wizard = Setup::Wiz::Welcome.new
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

      # Open the wizard's provider selector. *preferred* names the provider
      # the user was already configuring (Esc-back from the Credentials step):
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

          w = @wizard
          unless w.is_a?(Setup::Wiz::Welcome)
            raise "BUG: provider selector open in state #{w.class}"
          end

          # A key already stored for this provider turns the credentials step
          # into keep-or-reconfigure (empty Enter keeps the stored key).
          existing = @app_config.try(&.api_key_for(choice.name)) || ""
          @wizard = w.select_provider(choice.name, existing)
          @provider_name = choice.name
          emit_to_log(Message.new("user", choice.label))

          if @wizard.is_a?(Setup::Wiz::Endpoint)
            # Keyless provider: jump straight to endpoint, but still show a
            # transcript entry so the user knows why no key was asked.
            emit_to_log(Message.new("system",
              "No API key needed for #{choice.name}."))
          end
          advance_setup_step
        when .escape?, .ctrl_d?
          # Clear the search query first; exit setup only once it is empty.
          unless @provider_list.clear_query
            @running = false
            @dirty = true
          end
        else
          # ↑/↓, Backspace, and typed characters drive the fuzzy filter.
          @provider_list.handle_input(key)
          @dirty = true
        end
      end

      private def advance_setup_step : Nil
        w = @wizard
        case w
        when Setup::Wiz::Done
          finish_setup(w)
          return
        when Nil
          return
        end

        @status = "Setup: #{w.status}"
        @editor.clear
        @dirty = true

        # On the Model step, replace the text input with a live model selector
        # driven by a real provider API call. Falls back to text input if the
        # callback is not wired up or the fetch fails.
        if (w = @wizard).is_a?(Setup::Wiz::Model)
          fetch_setup_models(w)
        end

        # On the Yolo step, explain what is being asked before the y/N input.
        if (w = @wizard).is_a?(Setup::Wiz::Yolo)
          emit_to_log(Message.new("system", H2code.t("setup.yolo_note")))
        end

        # On the keep-or-reconfigure step, explain the choice before input.
        if (w = @wizard).is_a?(Setup::Wiz::ExistingKey)
          emit_to_log(Message.new("system",
            H2code.t("setup.existing_key_note", k: w.existing_key_mask)))
        end
      end

      # Fetch the model list for the provider being configured and open the
      # model selector. On error or empty list, fall back to the Model step's
      # text input (placeholder shows the default model) — never restart the
      # wizard, which would wipe the collected key and trap the user in a
      # select → key → fetch-fail loop.
      private def fetch_setup_models(w : Setup::Wiz::Model) : Nil
        cb = @on_fetch_models_for
        unless cb
          # No way to list models — stay on the text input with the default.
          return
        end

        name = w.provider_name
        @status = "Loading models for #{name}..."
        @model_fetch_active = true
        @editor.clear
        @dirty = true

        fetch = -> do
          begin
            models = cb.call(w.scratch)
            if models.empty?
              emit_to_log(Message.new("system", H2code.t("ui.models_unavailable")))
            else
              @model_list.show(H2code.t("ui.select_model", name: name), models)
              default = w.default_model || models.first?
              @model_list.selected = models.index(default) || 0
            end
          rescue ex
            emit_to_log(Message.new("system", H2code.t("ui.models_unavailable")))
          ensure
            @model_fetch_active = false
            # The fetch captured the Model state it was started for; report
            # that step rather than whatever state is current when it lands.
            @status = "Setup: #{w.status}"
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
          w = @wizard
          unless w.is_a?(Setup::Wiz::Model)
            raise "BUG: model selector open in state #{w.class}"
          end
          model = @model_list.current || w.default_model || ""
          @model_list.hide
          @dirty = true
          emit_to_log(Message.new("user", model))
          @wizard = w.select_model(model)
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

      # Step the wizard backward via the state's `prev` chain. Landing back on
      # Welcome reopens the provider selector (positioned on the provider the
      # user came from); landing on Model re-runs the model fetch. Backward
      # navigation is correct by construction — the chain was built by the
      # forward walk, so no transition table to maintain.
      private def back_setup_step : Nil
        case w = @wizard
        when Setup::Wiz::Welcome
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
        when Setup::Wiz::Credentials, Setup::Wiz::ExistingKey,
             Setup::Wiz::Endpoint, Setup::Wiz::Model, Setup::Wiz::Yolo
          preferred = w.provider_name
          prev = w.back
          @wizard = prev
          @editor.clear
          @model_list.hide
          case prev
          when Setup::Wiz::Welcome
            @status = "Setup: welcome"
            open_setup_provider_selector(preferred)
          when Setup::Wiz::Model
            # Re-entering the Model step re-fetches the model list and
            # reopens the selector via advance_setup_step.
            advance_setup_step
          else
            @status = "Setup: #{prev.status}"
          end
          @dirty = true
        when Setup::Wiz::Done
          raise "BUG: back on Done — the flow should have finished"
        end
      end

      private def finish_setup(done : Setup::Wiz::Done) : Nil
        result = done.result

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

      private def submit_setup_text(text : String) : Nil
        case w = @wizard
        when Setup::Wiz::Credentials
          masked = text.empty? ? "(skipped)" : "#{"•" * {text.size, 8}.min}"
          emit_to_log(Message.new("user", masked))
          @wizard = w.submit_text(text)
        when Setup::Wiz::ExistingKey
          masked = text.strip.empty? ? "(keep existing key)" : "#{"•" * {text.size, 8}.min}"
          emit_to_log(Message.new("user", masked))
          @wizard = w.submit_text(text)
        when Setup::Wiz::Yolo
          emit_to_log(Message.new("user", text.empty? ? "(yes)" : text.strip))
          @wizard = w.submit_text(text)
        when Setup::Wiz::Endpoint, Setup::Wiz::Model
          display = text.empty? ? "(default)" : text
          emit_to_log(Message.new("user", display))
          @wizard = w.submit_text(text)
        else
          raise "BUG: text submit in state #{w.class}"
        end
        advance_setup_step
      end
    end
  end
end
