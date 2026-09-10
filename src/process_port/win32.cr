{% skip_file unless flag?(:win32) %}

module H2code
  # Windows adapter: force-kill via `Process#terminate(graceful: false)`, which
  # the Crystal stdlib maps to `TerminateProcess`.
  #
  # Windows has no SIGKILL/SIGTERM distinction: both graceful and forceful
  # termination go through `TerminateProcess`, which the kernel applies
  # immediately. The distinction is preserved at the API level only for
  # symmetry with the Unix adapter and the two-phase kill ladders in the tools.
  #
  # TerminateProcess kills only the direct child. The Bash tool spawns
  # `cmd.exe`, which itself spawns PowerShell / daemons / build tools; killing
  # just the shell orphans that tree — the survivors keep running and hold
  # locks on the working directory (a cwd cannot be deleted while any process
  # has it open). Both kill entry points therefore route through `taskkill
  # /T /F`, which walks and force-terminates the whole tree.
  class Win32ProcessPort < ProcessPort
    def terminate(process : Process) : Nil
      force_kill(process)
    end

    def force_kill(process : Process) : Nil
      # /T kills the tree rooted at the pid, /F forces console processes
      # (they ignore the polite WM_CLOSE path). Close stdio so taskkill
      # itself can never block on a pipe.
      Process.new(
        "taskkill", {"/PID", process.pid.to_s, "/T", "/F"},
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      ).wait
      # Belt-and-braces: if taskkill could not see the process (already
      # reaped, access denied), still terminate the direct child.
      process.terminate(graceful: false) rescue nil
    rescue
      process.terminate(graceful: false) rescue nil
    end
  end
end
