# Setup-wizard controller, mixed into `TUI::App`. Owns the first-run provider
# configuration flow: a small finite-state machine driven by `Setup::Wizard`
# that steps through provider → credentials → endpoint → model, renders its
# state into the transcript, and invokes `on_setup_complete` when done.
module H2code
  module TUI
    module SetupController
      # When false (specs), `fetch_setup_models` runs its fetch inline instead
      # of in a spawned fiber, so the model selector is open by the time the
      # key event returns — full-path tests need no polling.
      property? setup_fetch_async : Bool = true

      # Enter setup mode: show the wizard transcript and open the provider
      # selector. Called once at first-run before the normal TUI loop starts.
      def start_setup : Nil
        @setup_mode = true
        @wizard = Setup::Wizard.new
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
        choices = Setup::Wizard.choices
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
          choices = Setup::Wizard.choices
          # A filter that matches nothing (or a stale index) selects nothing —
          # never silently fall back to the first provider in the registry.
          choice = @provider_list.filtered_size > 0 ? choices[idx]? : nil
          return unless choice
          @provider_list.hide
          @dirty = true

          wizard = @wizard
          return unless wizard

          wizard.select_provider(choice.name)
          @provider_name = choice.name
          emit_to_log(Message.new("user", choice.label))

          if wizard.step == Setup::Wizard::Step::Endpoint
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
        wizard = @wizard
        return unless wizard

        if wizard.done?
          finish_setup
          return
        end

        @status = "Setup: #{wizard.step.to_s.downcase}"
        @editor.clear
        @dirty = true

        # On the Model step, replace the text input with a live model selector
        # driven by a real provider API call. Falls back to text input if the
        # callback is not wired up or the fetch fails.
        if wizard.step == Setup::Wizard::Step::Model
          fetch_setup_models
        end

        # On the Yolo step, explain what is being asked before the y/N input.
        if wizard.step == Setup::Wizard::Step::Yolo
          emit_to_log(Message.new("system", H2code.t("setup.yolo_note")))
        end
      end

      # Fetch the model list for the provider being configured and open the
      # model selector. On error or empty list, fall back to the Model step's
      # text input (placeholder shows the default model) — never restart the
      # wizard, which would wipe the collected key and trap the user in a
      # select → key → fetch-fail loop.
      private def fetch_setup_models : Nil
        wizard = @wizard
        return unless wizard
        cb = @on_fetch_models_for
        unless cb
          # No way to list models — stay on the text input with the default.
          return
        end

        name = wizard.provider_name.to_s
        @status = "Loading models..."
        @editor.clear
        @dirty = true

        fetch = -> do
          begin
            models = cb.call(wizard)
            if models.empty?
              emit_to_log(Message.new("system", H2code.t("ui.models_unavailable")))
            else
              @model_list.show(H2code.t("ui.select_model", name: name), models)
              default = wizard.model || wizard.current_choice.try(&.default_model) || models.first?
              @model_list.selected = models.index(default) || 0
            end
          rescue ex
            emit_to_log(Message.new("system", H2code.t("ui.models_unavailable")))
          ensure
            @status = "Setup: #{wizard.step.to_s.downcase}"
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
          wizard = @wizard
          return unless wizard
          model = @model_list.current || wizard.current_choice.try(&.default_model) || ""
          @model_list.hide
          @dirty = true
          emit_to_log(Message.new("user", model))
          wizard.model = model
          wizard.step = Setup::Wizard::Step::Yolo
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

      # Step the wizard backward, mirroring `Setup::Wizard#back`. On the
      # Credentials step we drop back to the provider selector; on later
      # steps we just clear the value and re-render.
      private def back_setup_step : Nil
        wizard = @wizard
        return unless wizard

        case wizard.step
        when .welcome?
          # Already at the top: exit the app (abort setup).
          @running = false
          @dirty = true
        when .credentials?
          # Remember the provider before wizard.back clears it, so the
          # re-opened selector is positioned on it (see
          # open_setup_provider_selector).
          preferred = wizard.provider_name
          wizard.back
          @editor.clear
          @status = "Setup: #{wizard.step.to_s.downcase}"
          open_setup_provider_selector(preferred)
          @dirty = true
        when .endpoint?
          wizard.back
          @editor.clear
          @status = "Setup: #{wizard.step.to_s.downcase}"
          @dirty = true
        when .model?
          wizard.back
          @model_list.hide
          @editor.clear
          @status = "Setup: #{wizard.step.to_s.downcase}"
          @dirty = true
        when .yolo?
          wizard.back
          @editor.clear
          # Re-entering the Model step re-runs fetch_setup_models via
          # advance_setup_step, which reopens the model selector.
          advance_setup_step
        end
      end

      private def finish_setup : Nil
        wizard = @wizard
        return unless wizard

        config_msg = "Provider: #{wizard.provider_name}"
        config_msg += " | Model: #{wizard.model}" if wizard.model
        config_msg += " | YOLO: on" if wizard.yolo?
        emit_to_log(Message.new("system", H2code.t("ui.config_saved", msg: config_msg)))
        emit_to_log(Message.new("system", H2code.t("ui.starting")))
        @status = ""
        @setup_mode = false
        @dirty = true

        if cb = @on_setup_complete
          cb.call(wizard)
        end
      end

      private def submit_setup_text(text : String) : Nil
        wizard = @wizard
        return unless wizard

        # Echo what the user entered (mask API keys).
        if wizard.step == Setup::Wizard::Step::Credentials
          masked = text.empty? ? "(skipped)" : "#{"•" * {text.size, 8}.min}"
          emit_to_log(Message.new("user", masked))
        elsif wizard.step == Setup::Wizard::Step::Yolo
          emit_to_log(Message.new("user", text.empty? ? "(yes)" : text.strip))
        else
          display = text.empty? ? "(default)" : text
          emit_to_log(Message.new("user", display))
        end

        wizard.submit_text(text)
        advance_setup_step
      end
    end
  end
end
