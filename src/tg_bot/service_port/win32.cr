{% skip_file unless flag?(:win32) %}

module TgBot
  # Windows adapter: a real Windows service requires SCM integration (a
  # service entry point talking to the Service Control Manager), which the
  # daemon does not have. Refuse with a clear error and point at Task
  # Scheduler instead of pretending a unit was installed.
  class Win32ServicePort < ServicePort
    def install(binary_path : String, io : IO) : Nil
      raise Error.new(
        "--install-service is not supported on Windows — run the daemon " +
        "manually or register a scheduled task pointing at #{binary_path}")
    end
  end
end
