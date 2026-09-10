module H2code
  # Port: resolve the user's home directory.
  #
  # The home directory is OS-specific: POSIX shells export HOME, while Windows
  # has no HOME variable — the canonical location is USERPROFILE (Git Bash/MSYS
  # sessions may additionally set HOME). Concrete adapters implement the lookup;
  # application code depends solely on this abstraction instead of scattering
  # `HomePort.home` (a Unix-ism that silently degrades on Windows)
  # across the codebase. The adapter for the compile target is selected in
  # exactly one place - the composition root `default` below - so no platform
  # branching leaks into the rest of the codebase.
  abstract class HomePort
    # Absolute path to the current user's home directory.
    abstract def home : String

    # Composition root: instantiate the adapter matching the compile target.
    # This is the single point where the platform is decided.
    def self.default : HomePort
      {% if flag?(:win32) %}
        Win32HomePort.new
      {% else %}
        UnixHomePort.new
      {% end %}
    end

    # Convenience shortcut: the home directory for the compile target.
    # Not memoized - the underlying ENV lookup is cheap and this keeps specs
    # free to adjust ENV between calls.
    def self.home : String
      default.home
    end
  end
end

require "./home_port/unix"
require "./home_port/win32"
