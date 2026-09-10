{% skip_file if flag?(:win32) %}

module H2code
  # POSIX adapter: force-kill via the kill(2) syscall with SIGKILL (signal 9).
  #
  # kill(2) is available on every POSIX target (Linux, macOS, BSDs), so a
  # single implementation covers all Unix builds. Signal 9 (SIGKILL) cannot be
  # caught or ignored, so the kernel reaps the process on the next scheduler
  # tick.
  class UnixProcessPort < ProcessPort
    def terminate(process : Process) : Nil
      process.terminate rescue nil # SIGTERM
    end

    def force_kill(process : Process) : Nil
      LibC.kill(process.pid, 9) rescue nil
    end
  end
end
