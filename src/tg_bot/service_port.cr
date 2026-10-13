module TgBot
  # Port: install the h2code-tg-bot daemon as an OS-level service.
  #
  # Service installation is inherently OS-specific — a systemd user unit on
  # Linux, something else entirely on other platforms. Concrete adapters
  # implement the mechanics; the CLI depends solely on this abstraction.
  # The adapter for the compile target is selected in exactly one place -
  # the composition root `default` below - so no platform branching leaks
  # into the rest of the codebase (same pattern as HomePort / ProcessPort).
  #
  # Installation never enables or starts the service: h2code does not start
  # or stop the daemon (plans/telegram_bot.md, "manual-only сервис") — the
  # user runs the follow-up commands the adapter prints.
  abstract class ServicePort
    # Failure to install the service: no supported service manager on this
    # system, unit location not writable, manager reload failed, ….
    class Error < Exception
    end

    # Install the daemon at *binary_path* (absolute) as a user-level
    # service, writing human-readable follow-up steps to *io*.
    abstract def install(binary_path : String, io : IO) : Nil

    # Composition root: instantiate the adapter matching the compile target.
    # This is the single point where the platform is decided.
    def self.default : ServicePort
      {% if flag?(:win32) %}
        Win32ServicePort.new
      {% else %}
        UnixServicePort.new
      {% end %}
    end
  end
end

require "./service_port/unix"
require "./service_port/win32"
