require "../spec_helper"
require "file_utils"

# Own temp-home helper (unique name — every session spec file defines its
# own; all files compile into one spec binary).
def wq_temp_home : String
  File.join(Dir.tempdir, "h2code-test-#{Random::Secure.hex(8)}")
end

def wq_temp_base : String
  File.join(Dir.tempdir, "h2code-wq-#{Random::Secure.hex(8)}")
end

# A regular file placed where a directory is expected: every mkdir/open
# under it fails with ENOTDIR/EACCES-like errors regardless of user, so it
# simulates disk trouble deterministically (works for root too).
def wq_block(base : String, name : String) : String
  blocker = File.join(base, name)
  File.write(blocker, "x")
  blocker
end

describe H2code::Session::WriteQueue do
  it "executes appends inline on the happy path" do
    base = wq_temp_base
    begin
      Dir.mkdir_p(base)
      q = H2code::Session::WriteQueue.new
      path = File.join(base, "wire.jsonl")

      q.enqueue_append(path, base, %({"a":1}))
      q.enqueue_append(path, base, %({"b":2}))

      q.pending?.should be_false
      File.read_lines(path).should eq([%({"a":1}), %({"b":2})])
    ensure
      FileUtils.rm_rf(base)
    end
  end

  it "executes atomic replacements inline on the happy path" do
    base = wq_temp_base
    begin
      Dir.mkdir_p(base)
      q = H2code::Session::WriteQueue.new
      path = File.join(base, "state.json")

      q.enqueue_replace(path, base, %({"id":"s1"}))

      q.pending?.should be_false
      File.read(path).should eq(%({"id":"s1"}))
      # No temp files left behind.
      Dir.children(base).should eq(["state.json"])
    ensure
      FileUtils.rm_rf(base)
    end
  end

  it "buffers a failed write, warns, and retries until it succeeds" do
    base = wq_temp_base
    begin
      Dir.mkdir_p(base)
      blocker = wq_block(base, "blocker")
      q = H2code::Session::WriteQueue.new
      warnings = [] of String
      q.on_warning = ->(m : String) { warnings << m; nil }

      dir = File.join(blocker, "sub")
      path = File.join(dir, "wire.jsonl")
      q.enqueue_append(path, dir, "line-one")

      q.pending?.should be_true
      warnings.size.should eq(1)
      warnings[0].should contain("Disk write failed")
      File.exists?(path).should be_false

      # Free the disk: the retry fiber must flush the buffered line and
      # report recovery.
      File.delete(blocker)
      q.flush(10.seconds).should be_true
      File.read_lines(path).should eq(["line-one"])
      warnings.any?(&.includes?("Disk writes recovered")).should be_true
    ensure
      FileUtils.rm_rf(base)
    end
  end

  it "keeps FIFO order for ops enqueued during a failure episode" do
    base = wq_temp_base
    begin
      Dir.mkdir_p(base)
      blocker = wq_block(base, "blocker")
      q = H2code::Session::WriteQueue.new
      q.on_warning = ->(_m : String) { nil }

      dir = File.join(blocker, "sub")
      path = File.join(dir, "wire.jsonl")
      q.enqueue_append(path, dir, "line-a") # fails → episode starts
      q.enqueue_append(path, dir, "line-b") # queued behind, never inline
      q.pending_size.should eq(2)
      File.exists?(path).should be_false

      File.delete(blocker)
      q.flush(10.seconds).should be_true
      File.read_lines(path).should eq(["line-a", "line-b"])
    ensure
      FileUtils.rm_rf(base)
    end
  end

  it "drops the oldest buffered ops once the cap is hit" do
    base = wq_temp_base
    begin
      Dir.mkdir_p(base)
      blocker = wq_block(base, "blocker")
      q = H2code::Session::WriteQueue.new
      q.max_pending = 3
      warnings = [] of String
      q.on_warning = ->(m : String) { warnings << m; nil }

      dir = File.join(blocker, "sub")
      path = File.join(dir, "wire.jsonl")
      6.times { |i| q.enqueue_append(path, dir, "line-#{i}") }

      q.pending_size.should eq(3)
      warnings.any?(&.includes?("dropped")).should be_true

      File.delete(blocker)
      q.flush(10.seconds).should be_true
      File.read_lines(path).should eq(["line-3", "line-4", "line-5"])
    ensure
      FileUtils.rm_rf(base)
    end
  end

  it "exposes pending state for read overlays" do
    base = wq_temp_base
    begin
      Dir.mkdir_p(base)
      blocker = wq_block(base, "blocker")
      q = H2code::Session::WriteQueue.new
      q.on_warning = ->(_m : String) { nil }

      dir = File.join(blocker, "sub")
      path = File.join(dir, "wire.jsonl")
      other = File.join(base, "other.json")
      q.enqueue_append(path, dir, "buffered-line")
      q.enqueue_replace(other, base, %({"x":1}))

      q.pending_appends(path).should eq(["buffered-line"])
      q.pending_appends(other).should be_empty
      q.pending_replace(other).should eq(%({"x":1}))
      q.pending_replace(path).should be_nil
      q.pending_for?(path).should be_true
      q.pending_for?(other).should be_true

      FileUtils.rm_rf(blocker)
      q.flush(10.seconds).should be_true
      q.pending_appends(path).should be_empty
      q.pending_replace(other).should be_nil
    ensure
      FileUtils.rm_rf(base)
    end
  end
end

describe H2code::Session::Store do
  it "append buffers through the queue instead of raising on disk errors" do
    home = wq_temp_home
    begin
      store = H2code::Session::Store.new_workspace_session(home, "/repo", "t")
      store.append_simple("turn.prompt", "prompt", "first")

      warnings = [] of String
      store.write_queue.on_warning = ->(m : String) { warnings << m; nil }

      # Replace wire.jsonl with a directory: the append's `File.open("a")`
      # now fails (EISDIR) deterministically, regardless of user.
      File.delete(store.wire_path)
      Dir.mkdir(store.wire_path)

      store.append_simple("assistant.text", "content", "buffered")
      store.write_queue.pending_appends(store.wire_path).size.should eq(1)
      warnings.size.should eq(1)

      # Free the path and let the queue flush the buffered line.
      FileUtils.rm_rf(store.wire_path)
      store.write_queue.flush(10.seconds).should be_true
      lines = File.read_lines(store.wire_path)
      lines.size.should eq(1)
      lines[0].should contain("buffered")

      # After the flush the disk file replays cleanly.
      events = store.read_events
      events.any? { |e| e[:data]["content"]?.try(&.to_s) == "buffered" }.should be_true
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "read_state reflects a state write buffered by the queue" do
    home = wq_temp_home
    begin
      store = H2code::Session::Store.new_workspace_session(home, "/repo", "t")
      store.write_queue.on_warning = ->(_m : String) { nil }
      meta = store.read_state.not_nil!
      meta.title = "flushed title"

      # Replace state.json with a directory: the atomic replacement's
      # rename now fails (EISDIR) deterministically.
      File.delete(store.state_path)
      Dir.mkdir(store.state_path)

      store.write_state(meta)
      store.write_queue.pending_replace(store.state_path).should_not be_nil
      # The overlay still returns the new title.
      store.read_state.try(&.title).should eq("flushed title")

      FileUtils.rm_rf(store.state_path)
      store.write_queue.flush(10.seconds).should be_true
      File.exists?(store.state_path).should be_true
      store.read_state.try(&.title).should eq("flushed title")
    ensure
      FileUtils.rm_rf(home)
    end
  end
end
