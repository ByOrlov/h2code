module H2code
  module TUI
    # Scriptable `Input` for full-path tests: instead of parsing raw stdin,
    # a spec enqueues `KeyEvent`s and `read_key` hands them out one by one.
    # Implements the exact `Input` interface (`read_key` / `inject` /
    # `drain_pending_enters`) so App code cannot tell it apart from the real
    # keyboard source — setup-wizard specs pump it through `App#handle_key`
    # exactly like the main run loop does.
    class ScriptedInput < Input
      @script : Array(KeyEvent) = [] of KeyEvent

      # Queue one event at the end of the script.
      def enqueue(key : KeyEvent) : Nil
        @script << key
      end

      def read_key : KeyEvent?
        @script.shift?
      end

      # Re-injected probe leftovers have no raw source here; accept and drop.
      def inject(bytes : Array(UInt8)) : Nil
      end

      # Mirrors Input: a queued Enter must not leak through to a modal that
      # just opened (e.g. the provider selector after the /provider submit).
      def drain_pending_enters : Nil
        @script.reject!(&.key.enter?)
      end
    end
  end
end
