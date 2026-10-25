{% skip_file unless flag?(:win32) %}

module TgBot
  # Windows adapter: a named mutex created with CreateMutexW. The name is
  # derived from the bot token in the "Local\" namespace (one mutex per
  # login session), so different tokens are different bots and run side by
  # side, while a second copy for the same token sees ERROR_ALREADY_EXISTS.
  # The handle is intentionally never closed: the kernel releases it when
  # the process exits, crashed or not.
  class Win32SingleInstancePort < SingleInstancePort
    lib LibKernel32
      fun CreateMutexW(lp_mutex_attributes : Void*, b_initial_owner : Int32,
        lp_name : UInt16*) : Void*
      fun GetLastError : UInt32
    end

    ERROR_ALREADY_EXISTS = 183_u32

    @handle : Void*?

    def acquire(key : String) : Nil
      hash = Digest::SHA256.hexdigest(key)[0, 16]
      # String#to_utf16 returns a slice terminated with a 0, as Win32 expects.
      name = "Local\\h2code-tg-bot-#{hash}".to_utf16
      handle = LibKernel32.CreateMutexW(nil, 1, name)
      if handle.null? || LibKernel32.GetLastError == ERROR_ALREADY_EXISTS
        raise AlreadyRunning.new(
          "another h2code-tg-bot is already running for this bot")
      end
      @handle = handle
    end
  end
end
