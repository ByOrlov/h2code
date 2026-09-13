module H2code
  module TUI
    # Voice-message recording driven by the local h2voice server (see
    # VOICE_PROTOCOL.md). Ctrl+R or a double-Space press starts a recording
    # session: the TUI shows a pending "RECORDING" tool entry (active zone,
    # animated), while a detached fiber consumes the server's SSE stream.
    # Ctrl+R or Space stops the capture; the server transcribes and
    # the final text is delivered as a normal user
    # message (queued when the agent is busy, sent immediately when idle).
    # Escape cancels instead (protocol 0.3.0): the audio is discarded, no
    # transcription runs.
    module VoiceController
      # Tool name shown in the transcript for a voice recording.
      RECORDING_TOOL = "RECORDING"

      # True while a voice session is connecting, recording or transcribing —
      # drives the 80 ms animation tick so the timer/level meter keeps moving
      # even when the agent itself is idle.
      def voice_active? : Bool
        !@voice_msg_idx.nil?
      end

      def voice_recording? : Bool
        @voice_recording && voice_active?
      end

      # Ctrl+R / Space handler. Toggle: start when idle, stop-and-
      # transcribe while a session is in flight (ignored during the stop→result
      # gap). Public so embedded drivers and specs can drive the same action as
      # the key. Escape is NOT wired here — it cancels via
      # cancel_voice_recording instead of stopping.
      def toggle_voice_recording : Nil
        if voice_active?
          stop_voice_recording
        else
          start_voice_recording
        end
      end

      # Escape handler: abort the capture without transcription (the server
      # discards the audio; the terminal `cancelled` SSE event finalizes the
      # entry). Public so embedded drivers and specs can drive the same action
      # as the key.
      def cancel_voice_recording : Nil
        return unless voice_recording?
        cfg = voice_config
        client = Transcription::Client.from_config(cfg) if cfg
        @voice_recording = false
        # Freeze the recorded duration like stop does, so the cancelled
        # header can show how much audio was thrown away.
        @voice_recorded_ms = voice_elapsed_ms
        @dirty = true
        spawn do
          begin
            # Fall back to stop when the server rejects the cancel (404 on a
            # pre-0.3.0 server, or 409 race): leaving the mic capturing
            # forever is worse than transcribing audio the user discarded.
            unless client.try(&.record_cancel)
              client.try(&.record_stop)
            end
          rescue ex : IO::Error
            # The SSE stream will surface the failure; cancel is best-effort.
          end
        end
      end

      private def voice_config : Config::TranscriptionConfig?
        cfg = @app_config
        return cfg.transcription if cfg
        nil
      end

      # Advice shown when a recording cannot even start: with H2 Voice
      # absent from the system, point at the install page; when it is
      # installed but the config is missing/disabled, at the config section.
      private def voice_missing_hint : String
        if @voice_presence.installed?
          H2code.t("ui.voice_disabled")
        else
          H2code.t("ui.voice_not_installed", url: Transcription::VoicePresencePort::INSTALL_URL)
        end
      end

      # Socket-connect failure during record_start: distinguish "server not
      # running" (installed but stopped) from "H2 Voice not installed at
      # all" — the latter gets the install advice + link.
      private def voice_socket_error(client : Transcription::Client, ex : IO::Error) : String
        if @voice_presence.installed?
          H2code.t("ui.voice_server_unavailable", socket: client.socket_path, message: ex.message.to_s)
        else
          H2code.t("ui.voice_not_installed", url: Transcription::VoicePresencePort::INSTALL_URL)
        end
      end

      private def start_voice_recording : Nil
        cfg = voice_config
        unless cfg && cfg.enabled?
          emit_to_log(Message.new("error", voice_missing_hint))
          invalidate_log_cache!
          @dirty = true
          return
        end

        client = Transcription::Client.from_config(cfg)
        started_at = Time.monotonic
        msg = Message.new("tool", "")
        msg.tool_call_id = "voice-#{Time.utc.to_unix_ms}"
        msg.tool_name = RECORDING_TOOL
        emit_to_log(msg)
        # The message index doubles as a session token: a new session gets a
        # new entry, so a stale fiber can tell its session is over.
        msg_idx = @messages.size - 1
        @voice_msg_idx = msg_idx
        @voice_recording = false
        @voice_level = 0.0
        @voice_started_at = started_at
        @voice_engine = ""
        @voice_recorded_ms = 0_i64
        invalidate_log_cache!
        @dirty = true

        spawn do
          begin
            client.record_start(cfg.language, cfg.engine) { |evt| handle_voice_event(evt) }
            # The SSE stream ended without a result or error event: the
            # server died or dropped the connection mid-session. Finish the
            # entry with an error instead of hanging forever — nothing can
            # retry the transcription, the audio buffer lives server-side.
            if @voice_msg_idx == msg_idx
              voice_finish(error: H2code.t("ui.voice_stream_closed"))
            end
          rescue ex : IO::Error
            voice_finish(error: voice_socket_error(client, ex))
          rescue ex : Exception
            ExceptionHandler.report(ex, "voice recording")
            voice_finish(error: H2code.t("ui.voice_failed_detail", message: ex.message.to_s))
          end
        end

        # Auto-stop watchdog: cap the recording at max_duration_sec.
        if max = cfg.max_duration_sec
          spawn do
            sleep ({max, 1}.max).seconds
            # Only fire when this exact session is still recording. Cannot
            # compare @voice_started_at: the "started" event resets it, so the
            # message index is the session token here.
            stop_voice_recording if @voice_recording && @voice_msg_idx == msg_idx
          end
        end
      end

      private def stop_voice_recording : Nil
        return unless voice_recording?
        cfg = voice_config
        client = Transcription::Client.from_config(cfg) if cfg
        @voice_recording = false
        # Freeze the recorded duration before the timer stops: the
        # transcribing frame keeps showing it until the result arrives.
        @voice_recorded_ms = voice_elapsed_ms
        @dirty = true
        spawn do
          begin
            client.try(&.record_stop)
          rescue ex : IO::Error
            # The SSE stream will surface the failure; stop is best-effort.
          end
        end
      end

      # SSE event pump. Runs on the recording fiber — only touches shared App
      # state, same as any other event fiber (single-threaded scheduler).
      private def handle_voice_event(evt : Transcription::RecordEvent) : Nil
        case evt.type
        when "started"
          @voice_recording = true
          @voice_started_at = Time.monotonic
          @dirty = true
        when "level"
          @voice_level = evt.rms
          @dirty = true
        when "transcribing"
          @voice_recording = false
          @voice_engine = evt.engine
          @dirty = true
        when "result"
          duration = evt.duration_ms > 0 ? evt.duration_ms : voice_elapsed_ms
          meta = {"duration_ms" => duration, "engine" => evt.engine,
                  "language" => evt.language}.to_json
          voice_finish(result: evt.text, meta: meta)
          deliver_transcription(evt.text)
        when "cancelled"
          # Terminal event of /v1/record/cancel: the audio was discarded
          # server-side, nothing to transcribe or deliver.
          duration = evt.duration_ms > 0 ? evt.duration_ms : voice_elapsed_ms
          voice_finish(cancelled: true,
                       meta: {"cancelled" => true, "duration_ms" => duration}.to_json)
        when "error"
          voice_finish(error: "#{evt.code}: #{evt.message}")
        end
      end

      # Terminal path for the voice tool message: attach the result (or the
      # error, or the cancelled marker) so it migrates from the active zone
      # into the log.
      private def voice_finish(*, result : String? = nil, meta : String? = nil,
                               error : String? = nil, cancelled : Bool = false) : Nil
        @voice_recording = false
        @voice_level = 0.0
        idx = @voice_msg_idx
        if idx && (msg = @messages[idx]?)
          if err = error
            msg.is_error = true
            msg.tool_result = err
            msg.tool_args = nil
          elsif cancelled
            # Empty (but non-nil) result: the entry counts as finished, the
            # header reads "Cancelled", and no result body is rendered.
            msg.tool_result = ""
            msg.tool_args = meta
          else
            msg.tool_result = result.to_s
            msg.tool_args = meta
          end
          @messages[idx] = msg
        end
        @voice_msg_idx = nil
        invalidate_log_cache!
        @dirty = true
        render_now
      end

      # Feed the transcription into the normal message path: queued while the
      # agent is mid-turn, sent immediately when idle (same as typed input).
      private def deliver_transcription(text : String) : Nil
        submit_message(text) unless text.strip.empty?
      end

      # Milliseconds since the current recording started (monotonic clock).
      def voice_elapsed_ms : Int64
        return 0_i64 unless start = @voice_started_at
        ((Time.monotonic - start).total_milliseconds).to_i64.clamp(0_i64..)
      end
    end
  end
end
