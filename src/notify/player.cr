module H2code
  module Notify
    # Build without the audio backend: `crystal build -Dwithout_miniaudio`
    # compiles out the C bindings and the miniaudio link — the Player API
    # stays intact for the callers, every play is a silent no-op. Without
    # the flag the bridge (vendor/miniaudio/miniaudio_bridge.c) is linked
    # statically into the binary — see Rakefile.
    {% if flag?(:without_miniaudio) %}
    class Player
      property? enabled : Bool = true
      property volume : Int32 = 70 # 0–100

      def initialize(@done_path : String = "", @alert_path : String = "",
                     @working_path : String = "",
                     @enabled : Bool = true, @volume : Int32 = 70)
      end

      def play_for(event : String) : Nil
      end
    end
    {% else %}
    # C bindings for the miniaudio bridge (vendor/miniaudio/miniaudio_bridge.c).
    lib MiniAudio
      fun ma_notify_init : Int32
      fun ma_notify_is_ready : Int32
      fun ma_notify_play(data : UInt8*, size : UInt64, volume : Float32)
      fun ma_notify_shutdown
    end

    # In-process sound playback via miniaudio. The notification OGG is embedded
    # directly in the binary (compile-time `read_file`), decoded at runtime by
    # miniaudio's built-in Vorbis decoder, and played through the OS-native
    # audio backend (CoreAudio / PulseAudio / ALSA / WASAPI) — no external
    # programs or system libraries beyond what miniaudio dlopens itself.
    #
    # The audio engine is initialised lazily on the first `play` call. If init
    # fails (headless server, no audio device) every subsequent play is a
    # silent no-op so the agent loop is never affected.
    class Player
      # Embedded default notification sound — Ogg Vorbis, mono 44.1 kHz, ~4.7 KB.
      # `read_file` embeds the raw bytes at compile time; the String is just a
      # byte buffer that miniaudio decodes.
      DEFAULT_SOUND = {{ read_file("#{__DIR__}/../../sounds/notification.ogg") }}

      property? enabled : Bool = true
      property volume : Int32 = 70 # 0–100

      @done_path : String = ""
      @alert_path : String = ""
      @working_path : String = ""
      @init_failed : Bool = false

      def initialize(@done_path : String = "", @alert_path : String = "",
                     @working_path : String = "",
                     @enabled : Bool = true, @volume : Int32 = 70)
      end

      def play_for(event : String) : Nil
        return unless @enabled
        return if @init_failed

        path = case event
               when "turn_done"      then @done_path
               when "input_required" then @alert_path
               when "turn_started"   then @working_path
               else                       ""
               end

        if path.empty?
          # No custom file → use the embedded default for user-facing events.
          case event
          when "turn_done", "input_required"
            play_data(DEFAULT_SOUND)
          end
        else
          play_file(path)
        end
      end

      private def play_data(data : String) : Nil
        return if data.bytesize == 0
        init_engine
        vol = @volume.clamp(0, 100).to_f / 100.0
        MiniAudio.ma_notify_play(data.to_unsafe, data.bytesize.to_u64, vol.to_f32)
      end

      private def play_file(path : String) : Nil
        return unless File.exists?(path)
        data = File.read(path)
        play_data(data)
      end

      # Initialise the miniaudio engine on first play.  If init fails (no audio
      # device), set `@init_failed` so we never retry — keeps the agent loop
      # quiet on headless machines.
      private def init_engine : Nil
        return if MiniAudio.ma_notify_is_ready != 0
        if MiniAudio.ma_notify_init != 0
          @init_failed = true
        end
      end
    end
    {% end %}
  end
end
