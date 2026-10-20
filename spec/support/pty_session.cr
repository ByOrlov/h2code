{% if flag?(:unix) %}
require "process"

@[Link("util")]
lib LibPty
  fun openpty(amaster : Int32*, aslave : Int32*, name : UInt8*, termp : Void*, winp : Void*) : Int32
end

# Minimal PTY harness for integration specs: spawns a command with a
# pseudo-terminal slave as its stdin/stdout/stderr so the child sees a real
# TTY (raw mode, TIOCGWINSZ). The spec writes raw keystroke bytes to the
# master and reads the child's screen output — driving the TUI exactly like
# a human at a terminal, bracketed paste included.
class PtySession
  # Set the pty size after openpty (TIOCSWINSZ, Linux/macOS request codes).
  TIOCSWINSZ = {% if flag?(:darwin) %}
                 0x80087467_u64
               {% else %}
                 0x5414_u64
               {% end %}

  getter process : Process

  # Everything the child has printed so far (ANSI included).
  getter output : String

  @master : IO::FileDescriptor

  def initialize(command : String, args : Array(String) = [] of String,
                 env : Hash(String, String)? = nil,
                 rows : Int32 = 30, cols : Int32 = 100)
    master_fd = uninitialized Int32
    slave_fd = uninitialized Int32
    rc = LibPty.openpty(pointerof(master_fd), pointerof(slave_fd), nil, nil, nil)
    raise "openpty failed (#{rc})" unless rc == 0

    ws = uninitialized LibCExtra::Winsize
    ws.ws_row = rows.to_u16
    ws.ws_col = cols.to_u16
    ws.ws_xpixel = 0
    ws.ws_ypixel = 0
    LibCExtra.ioctl(master_fd, TIOCSWINSZ, pointerof(ws))

    @master = IO::FileDescriptor.new(master_fd)
    @master.sync = true
    @output = ""

    slave = IO::FileDescriptor.new(slave_fd)
    begin
      @process = Process.new(command, args, env: env, input: slave, output: slave, error: slave)
    ensure
      slave.close
    end
  end

  # Send raw bytes (keystrokes, ANSI sequences, bracketed paste) to the
  # child's terminal input.
  def send(bytes : String) : Nil
    @master.write(bytes.to_slice)
    @master.flush
  end

  # Read screen output until *pattern* appears — returns the chunk that
  # contained it — or nil once *timeout* elapses. Everything read is
  # appended to #output either way, so later assertions can scan the whole
  # transcript.
  def read_until(pattern : String, timeout = 15.seconds) : String?
    deadline = Time.monotonic + timeout
    buf = Bytes.new(4096)
    until Time.monotonic > deadline
      if chunk = read_chunk(buf)
        @output += chunk
        return chunk if chunk.includes?(pattern)
      end
      return @output if @output.includes?(pattern)
    end
    nil
  end

  # Wait for the child to exit on its own within *timeout*.
  def wait_exit(timeout = 10.seconds) : Bool
    deadline = Time.monotonic + timeout
    until @process.terminated?
      return false if Time.monotonic > deadline
      sleep 50.milliseconds
    end
    true
  end

  private def read_chunk(buf : Bytes) : String?
    @master.read_timeout = 0.1.seconds
    n = @master.read(buf)
      # Decode as UTF-8 (invalid bytes become U+FFFD — substring probes on
      # ASCII patterns stay safe even when a chunk splits a codepoint).
      n > 0 ? String.new(buf[0, n]) : nil
  rescue IO::TimeoutError
    nil
  rescue IO::Error
    nil # child exited / pty closed
  end

  def close : Nil
    @process.terminate unless @process.terminated?
    @master.close
  ensure
    @process.wait
  end
end
{% end %}
