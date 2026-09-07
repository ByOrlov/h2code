module H2code
  # Port: the command-line interpreter used to execute agent commands.
  #
  # The Bash tool needs a real shell for pipes, redirections and control flow,
  # but which interpreter exists is OS-specific: POSIX always has /bin/sh,
  # while Windows ships no bash at all — Git for Windows (an optional, separate
  # package) provides one, otherwise the native command-line tools PowerShell
  # or cmd.exe must be used. Concrete adapters resolve the interpreter and
  # translate a raw command string into a program + argv suitable for
  # `Process.new`; application code depends solely on this abstraction. The
  # adapter for the compile target is selected in exactly one place - the
  # composition root `default` below - so no platform branching leaks into the
  # rest of the codebase.
  abstract class ShellPort
    # Resolved interpreter executable (absolute path or bare name found on
    # PATH) to pass as the program to `Process.new`.
    abstract def program : String

    # argv (excluding the program) that runs *command* through the interpreter.
    abstract def shell_args(command : String) : Array(String)

    # Default value for the SHELL environment variable of spawned children
    # (used unless the user configured an explicit one).
    abstract def env_shell : String

    # Short lowercase name of the resolved interpreter ("bash", "sh",
    # "powershell") for tool descriptions and diagnostics. Must be honest:
    # the model decides which syntax is safe based on it.
    abstract def name : String

    # One-sentence, model-facing note about the resolved interpreter: what it
    # is and which syntax is available. Embedded verbatim into the Bash tool
    # description — the tool's *name* is fixed platform-independent ("Bash"),
    # so this guidance is the only channel through which the model learns
    # what it can actually use.
    abstract def guidance : String

    # Composition root: instantiate the adapter matching the compile target.
    # This is the single point where the platform is decided.
    def self.default : ShellPort
      {% if flag?(:win32) %}
        Win32ShellPort.new
      {% else %}
        UnixShellPort.new
      {% end %}
    end

    # Explicit bash location for the Windows adapter (set via `/bash patch`,
    # persisted in config as `bash_available`). Inert on Unix. This never
    # changes which interpreter *executes* commands — on Windows that is
    # always cmd.exe — it only advertises the bash path to the model so it
    # can invoke it explicitly for POSIX-only tasks.
    class_property bash_path : String? = nil
  end
end

require "./shell_port/unix"
require "./shell_port/win32"
