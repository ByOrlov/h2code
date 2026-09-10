module H2code
  module Transcription
    # Port: is the H2 Voice server present in this system at all?
    #
    # The socket check in Client only tells whether the server is *running*
    # right now; this port answers the coarser question — has the user ever
    # installed H2 Voice — so the TUI can point at the install page instead
    # of the "is the server running?" hint. Detection is OS-specific
    # (executable name, home-directory lookup), so concrete adapters
    # implement it; the adapter for the compile target is selected in exactly
    # one place - the composition root `default` below (same pattern as
    # ProcessPort).
    abstract class VoicePresencePort
      # Install page referenced by the "not installed" advice in the TUI.
      INSTALL_URL = "https://github.com/ByOrlov/H2Voice"

      # $PATH entries are ":"-separated on POSIX, ";" on Windows.
      PATH_SEPARATOR = {% if flag?(:win32) %} ";" {% else %} ":" {% end %}

      # True when H2 Voice is detectable in this system (binary on PATH or
      # the server's ~/.h2voice data directory).
      abstract def installed? : Bool

      # Composition root: instantiate the adapter matching the compile
      # target. This is the single point where the platform is decided.
      def self.default : VoicePresencePort
        {% if flag?(:win32) %}
          Win32VoicePresence.new
        {% else %}
          UnixVoicePresence.new
        {% end %}
      end

      # The server's data directory (~/.h2voice, created on first run on
      # both platforms - HOME on Unix, USERPROFILE on Windows).
      private def voice_dir_present? : Bool
        home = HomePort.home
        Dir.exists?(File.join(home, ".h2voice"))
      end

      # Scan $PATH for any of *names* as a regular executable file.
      private def executable_on_path?(names : Array(String)) : Bool
        return false unless path = ENV["PATH"]?
        path.split(PATH_SEPARATOR).each do |dir|
          next if dir.empty?
          names.each do |name|
            file = File.join(dir, name)
            return true if File.file?(file) && File::Info.executable?(file)
          end
        end
        false
      end
    end
  end
end

require "./presence/unix"
require "./presence/win32"
