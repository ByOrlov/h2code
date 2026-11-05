module H2code
  module Session
    # Serialised disk-write queue for session persistence.
    #
    # Every session-store write (wire.jsonl appends, state.json / cron /
    # task metadata replacements) flows through one queue instance instead
    # of calling `File` directly. On the happy path the op is executed
    # inline — regular-file I/O never yields the fiber, so this is
    # indistinguishable from a direct write for callers. When the disk
    # errors (`No space left on device`, vanished directories, …) the op
    # stays in a bounded pending buffer, a warning is surfaced through
    # `#on_warning` (throttled), and a background fiber retries with
    # growing backoff. New ops enqueued while an episode is active are
    # queued behind the failed ones so on-disk order is never shuffled.
    # A disk error therefore never raises into the caller's turn fiber.
    #
    # Reads that need to reflect the very latest state can consult the
    # pending buffer (`#pending_appends`, `#pending_replace`) so a queued
    # write is visible before it reaches the disk.
    class WriteQueue
      # A single disk operation. `Append` opens the target in "a" mode and
      # writes one line + fsync (wire.jsonl semantics); `Replace` writes
      # the content to a temp file, fsyncs and renames it into place
      # (atomic whole-file semantics).
      class Op
        enum Kind
          Append
          Replace
        end

        getter kind : Kind
        getter path : String
        getter dir : String
        getter line : String
        getter content : String

        def self.append(path : String, dir : String, line : String) : Op
          new(Kind::Append, path, dir, line, "")
        end

        def self.replace(path : String, dir : String, content : String) : Op
          new(Kind::Replace, path, dir, "", content)
        end

        private def initialize(@kind : Kind, @path : String, @dir : String,
                               @line : String, @content : String)
        end

        def append? : Bool
          @kind.append?
        end

        def replace? : Bool
          @kind.replace?
        end
      end

      # Pending-buffer cap. Oldest ops are dropped (with a warning) once
      # exceeded so an endlessly broken disk cannot grow memory without
      # bound.
      DEFAULT_MAX_PENDING = 10_000

      # Backoff schedule between retries: sub-second at first, capped at
      # 30s. Retries continue indefinitely — combined with the cap this
      # bounds both memory and disk pounding.
      RETRY_DELAYS = {
        0.25.seconds, 0.5.seconds, 1.second, 2.seconds,
        5.seconds, 10.seconds, 30.seconds,
      }

      # Minimum spacing between repeated failure warnings so a broken disk
      # doesn't flood the log zone (the first failure warns immediately).
      WARN_INTERVAL = 60.seconds

      # Poll interval used by #flush while waiting for the buffer to drain.
      FLUSH_POLL = 0.02.seconds

      # Instance-level override of the pending cap (specs).
      property max_pending : Int32 = DEFAULT_MAX_PENDING

      # Warning sink. Set by the TUI to route messages into the log zone;
      # nil falls back to stderr (headless / ACP modes).
      property on_warning : (String -> Nil)?

      @pending = Deque(Op).new
      @signal = Channel(Nil).new(1)
      @started = false
      @failing_since : Time::Span?
      @last_warn_at : Time::Span?
      @last_drop_warn_at : Time::Span?
      @dropped_unwarned = 0
      @attempt = 0
      @flushed_during_episode = 0

      @@default : self?
      @@exit_hook_registered = false

      # The process-wide queue shared by every `Store`. All session writes
      # funnel through it, which keeps per-file ordering global and gives
      # one place to flush at shutdown.
      def self.default : self
        @@default ||= new
      end

      def initialize
        @@exit_hook_registered ||= begin
          # Best-effort drain of anything still buffered (e.g. a full disk
          # that freed up late) before the process exits.
          at_exit { WriteQueue.default.flush(2.seconds) }
          true
        end
      end

      def enqueue(op : Op) : Nil
        if @pending.empty?
          begin
            execute(op)
            return
          rescue ex : IO::Error
            enter_failure(op, ex)
            return
          end
        end
        # An episode is active: never jump the queue with an inline write,
        # or later events would reach the disk before earlier ones.
        @pending << op
        trim_overflow
        wake_writer
      end

      def enqueue_append(path : String, dir : String, line : String) : Nil
        enqueue(Op.append(path, dir, line))
      end

      def enqueue_replace(path : String, dir : String, content : String) : Nil
        enqueue(Op.replace(path, dir, content))
      end

      # Buffered append lines still waiting for *path*, in write order.
      def pending_appends(path : String) : Array(String)
        results = [] of String
        @pending.each do |op|
          results << op.line if op.path == path && op.append?
        end
        results
      end

      # Content of the newest queued whole-file replacement for *path*,
      # or nil when none is pending. Supersedes the disk state for reads.
      def pending_replace(path : String) : String?
        @pending.reverse_each do |op|
          return op.content if op.replace? && op.path == path
        end
        nil
      end

      # True when any op is still buffered for *path*.
      def pending_for?(path : String) : Bool
        @pending.any?(&.path.==(path))
      end

      def pending_size : Int32
        @pending.size.to_i32
      end

      def pending? : Bool
        !@pending.empty?
      end

      # Block until the pending buffer drains (writer fiber flushed it) or
      # *timeout* elapses. Returns true when the buffer is empty.
      def flush(timeout : Time::Span = 5.seconds) : Bool
        deadline = Time.monotonic + timeout
        until @pending.empty?
          return false if Time.monotonic >= deadline
          sleep FLUSH_POLL
        end
        true
      end

      # ------------------------------------------------------------------
      # Internals
      # ------------------------------------------------------------------

      # First failure of an episode: buffer the op, warn, start the retry
      # fiber. Subsequent enqueues take the queueing path in `#enqueue`.
      private def enter_failure(op : Op, ex : Exception) : Nil
        @failing_since = Time.monotonic unless @failing_since
        @pending << op
        trim_overflow
        warn_failure(ex)
        start_writer
        wake_writer
      end

      private def trim_overflow : Nil
        return unless @pending.size > max_pending
        dropped = @pending.size - max_pending
        dropped.times { @pending.shift }
        # Drops are summed between throttled warnings so a sustained
        # overflow doesn't flood the log zone one event at a time.
        @dropped_unwarned += dropped
        now = Time.monotonic
        return if (last = @last_drop_warn_at) && (now - last) < WARN_INTERVAL
        @last_drop_warn_at = now
        notify_warning(H2code.t("ui.wire_queue_dropped", count: @dropped_unwarned))
        @dropped_unwarned = 0
      end

      private def start_writer : Nil
        return if @started
        @started = true
        spawn(name: "session-write-queue") { run_writer }
      end

      # Wake the retry fiber without blocking the caller: the signal is a
      # 1-slot semaphore, a dropped wakeup is harmless (the writer always
      # re-checks the buffer before parking).
      private def wake_writer : Nil
        select
        when @signal.send(nil)
        else
        end
      end

      private def run_writer : Nil
        loop do
          until @pending.empty?
            op = @pending.first
            begin
              execute(op)
              @pending.shift
              @flushed_during_episode += 1 if @failing_since
              notify_recovered if @pending.empty? && @failing_since
            rescue ex : Exception
              # Anything raised on the disk touches (IO::Error subclasses
              # for ENOSPC/EISDIR/…, plus the unexpected) is a retryable
              # failure here: this fiber must never die, or the buffer
              # would hang and #flush would never return.
              @failing_since = Time.monotonic unless @failing_since
              warn_failure(ex)
              sleep RETRY_DELAYS[Math.min(@attempt, RETRY_DELAYS.size - 1)]
              @attempt += 1
            end
          end
          @signal.receive
        end
      end

      private def warn_failure(ex : Exception) : Nil
        now = Time.monotonic
        return if (last = @last_warn_at) && (now - last) < WARN_INTERVAL
        @last_warn_at = now
        notify_warning(H2code.t("ui.wire_write_failed",
          reason: ex.message.to_s, count: @pending.size))
      end

      private def notify_recovered : Nil
        @failing_since = nil
        @last_warn_at = nil
        @attempt = 0
        count = @flushed_during_episode
        @flushed_during_episode = 0
        notify_warning(H2code.t("ui.wire_write_flushed", count: count))
      end

      private def notify_warning(message : String) : Nil
        if cb = @on_warning
          cb.call(message)
        else
          STDERR.puts "h2code: #{message}"
        end
      end

      # The actual disk touch, shared by the inline path and the retry
      # fiber. `Dir.mkdir_p` up front keeps a vanished session directory
      # (tmp cleaners, session GC) from failing the write permanently.
      private def execute(op : Op) : Nil
        Dir.mkdir_p(op.dir) unless Dir.exists?(op.dir)
        case op.kind
        in .append?
          File.open(op.path, "a") do |f|
            f.puts(op.line)
            f.fsync
          end
        in .replace?
          # Atomic write: temp file in the same directory, fsync, rename.
          # Same-directory rename is atomic on POSIX and never crosses a
          # filesystem boundary.
          tmp = File.join(op.dir, ".#{File.basename(op.path)}.tmp.#{Random::Secure.hex(4)}")
          begin
            File.open(tmp, "w") do |f|
              f.print(op.content)
              f.fsync
            end
            File.rename(tmp, op.path)
          rescue ex
            begin
              File.delete(tmp) if File.exists?(tmp)
            rescue
            end
            raise ex
          end
        end
      end
    end
  end
end
