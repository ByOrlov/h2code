require "../spec_helper"
require "file_utils"

# Distinct helper name: spec/session/session_spec.cr already defines a
# top-level `temp_home`; both files compile into one spec binary.
def lock_temp_home : String
  File.join(Dir.tempdir, "h2code-test-#{Random::Secure.hex(8)}")
end

describe H2code::Session::Lock do
  it "conflicts when another handle holds the lock (flock, even in-process)" do
    home = lock_temp_home
    begin
      dir = File.join(home, ".h2code", "sessions", "aaa")
      Dir.mkdir_p(dir)
      lock = H2code::Session::Lock.acquire!(dir)
      expect_raises(H2code::Session::SessionBusyError) do
        H2code::Session::Lock.acquire!(dir)
      end
      lock.release
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "reports the holder pid in the error" do
    home = lock_temp_home
    begin
      dir = File.join(home, ".h2code", "sessions", "bbb")
      Dir.mkdir_p(dir)
      lock = H2code::Session::Lock.acquire!(dir)
      begin
        H2code::Session::Lock.acquire!(dir)
        fail "expected SessionBusyError"
      rescue ex : H2code::Session::SessionBusyError
        ex.holder_pid.should eq(Process.pid)
        ex.message.to_s.should contain("pid #{Process.pid}")
      end
      lock.release
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "is re-acquirable after release" do
    home = lock_temp_home
    begin
      dir = File.join(home, ".h2code", "sessions", "ccc")
      Dir.mkdir_p(dir)
      lock = H2code::Session::Lock.acquire!(dir)
      lock.release
      lock.release # idempotent
      again = H2code::Session::Lock.acquire!(dir)
      again.release
    ensure
      FileUtils.rm_rf(home)
    end
  end

  describe ".locked?" do
    it "is true while the lock is held, false after release" do
      home = lock_temp_home
      begin
        dir = File.join(home, ".h2code", "sessions", "locked")
        Dir.mkdir_p(dir)
        H2code::Session::Lock.locked?(dir).should be_false # no lock file yet
        lock = H2code::Session::Lock.acquire!(dir)
        H2code::Session::Lock.locked?(dir).should be_true
        lock.release
        H2code::Session::Lock.locked?(dir).should be_false
      ensure
        FileUtils.rm_rf(home)
      end
    end

    it "is false for a missing directory" do
      H2code::Session::Lock.locked?(
        File.join(lock_temp_home, ".h2code", "sessions", "gone")
      ).should be_false
    end
  end
end

describe "Session store locking" do
  it "open_existing! rejects a session owned by another store" do
    home = lock_temp_home
    begin
      lc = H2code::Session::Lifecycle.new(home)
      owner = lc.create("/repo", "owner")
      expect_raises(H2code::Session::SessionBusyError) do
        H2code::Session::Store.open_existing!(owner.session_dir)
      end
      owner.unlock
      second = H2code::Session::Store.open_existing!(owner.session_dir)
      second.unlock
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "open_existing! still raises FileDeletedError before locking" do
    home = lock_temp_home
    begin
      dir = File.join(home, ".h2code", "sessions", "deleted10")
      expect_raises(H2code::Session::FileDeletedError) do
        H2code::Session::Store.open_existing!(dir)
      end
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "adopt releases the old session's lock and takes the target's" do
    home = lock_temp_home
    begin
      lc = H2code::Session::Lifecycle.new(home)
      first = lc.create("/repo", "first")
      dir1 = first.session_dir

      # TUI fork flow: fork the owned session, then adopt the fork — the
      # store must release dir1's lock and take the fork's.
      forked = lc.fork(first, "/repo")
      first.adopt(forked)

      # The adopted (fork) session is now owned by `first`.
      expect_raises(H2code::Session::SessionBusyError) do
        H2code::Session::Store.open_existing!(first.session_dir)
      end
      # dir1's lock was released by the adopt — openable again.
      reopened = H2code::Session::Store.open_existing!(dir1)
      reopened.unlock
      first.unlock
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "plain Store.new stays lock-free (metadata ops on foreign sessions)" do
    home = lock_temp_home
    begin
      lc = H2code::Session::Lifecycle.new(home)
      owner = lc.create("/repo", "owned")
      # rename/archive build lock-free stores over sessions that may be
      # owned by other processes; only state.json is touched.
      meta = H2code::Session::Store.new(owner.session_dir).read_state
      meta.should_not be_nil
      meta.try(&.title).should eq("owned")
      owner.unlock
    ensure
      FileUtils.rm_rf(home)
    end
  end
end
