# Setup-wizard controller, mixed into `TUI::App`. Owns the first-run provider
# configuration flow: a small finite-state machine driven by `Setup::Wizard`
# that steps through provider → credentials → endpoint → model, renders its
# state into the transcript, and invokes `on_setup_complete` when done.
module H2code
  module TUI
    module SetupController
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

      private def open_setup_provider_selector : Nil
        items = Setup::Wizard.choices.map(&.label)
        @provider_list.show(H2code.t("ui.select_provider"), items)
        @provider_list.selected = 0
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
          choice = choices[idx]? || choices.first
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
      # model selector. On error or empty list, reset the wizard back to the
      # provider selection so the user can start over.
      private def fetch_setup_models : Nil
        wizard = @wizard
        return unless wizard
        cb = @on_fetch_models_for
        unless cb
          # No way to list models — stay on the text input with the default.
          return
        end

        name = wizard.provider_name.to_s
        @status = "Loading models for #{name}..."
        @model_fetch_active = true
        @editor.clear
        @dirty = true

        spawn do
          begin
            models = cb.call(name)
            if models.empty?
              emit_to_log(Message.new("system", "Models unavailable."))
              restart_setup
            else
              @model_list.show(H2code.t("ui.select_model", name: name), models)
              default = wizard.model || wizard.current_choice.try(&.default_model) || models.first?
              @model_list.selected = models.index(default) || 0
            end
          rescue ex
            emit_to_log(Message.new("system", "Models unavailable."))
            restart_setup
          ensure
            @model_fetch_active = false
            @status = "Setup: #{wizard.step.to_s.downcase}"
            @dirty = true
          end
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
          wizard.back
          @editor.clear
          @status = "Setup: #{wizard.step.to_s.downcase}"
          open_setup_provider_selector
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

      # Reset the wizard to the provider-selection step. Used when fetching
      # models fails so the user can pick a different provider.
      private def restart_setup : Nil
        wizard = @wizard
        return unless wizard
        @model_list.hide
        @editor.clear
        wizard.back if wizard.step.credentials?
        wizard.back if wizard.step.endpoint?
        wizard.back if wizard.step.model?
        wizard.back if wizard.step.yolo?
        wizard.api_key = ""
        wizard.endpoint = nil
        wizard.model = nil
        wizard.provider_name = nil
        wizard.yolo = false
        wizard.step = Setup::Wizard::Step::Welcome
        @status = "Setup: select provider"
        open_setup_provider_selector
        @dirty = true
      end

      private def finish_setup : Nil
        wizard = @wizard
        return unless wizard

        config_msg = "Provider: #{wizard.provider_name}"
        config_msg += " | Model: #{wizard.model}" if wizard.model
        config_msg += " | YOLO: on" if wizard.yolo?
        emit_to_log(Message.new("system", "Configuration saved. #{config_msg}"))
        emit_to_log(Message.new("system", "Starting H2Code..."))
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
