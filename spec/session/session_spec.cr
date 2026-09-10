require "../spec_helper"
require "file_utils"

def temp_home : String
  File.join(Dir.tempdir, "h2code-test-#{Random::Secure.hex(8)}")
end

describe H2code::Session::Index do
  it ".workspace_id is stable for the same path" do
    a = H2code::Session::Index.workspace_id("/home/oleg/h2code-code")
    b = H2code::Session::Index.workspace_id("/home/oleg/h2code-code")
    a.should eq(b)
    a.size.should eq(12)
  end

  it ".workspace_id differs for different paths" do
    a = H2code::Session::Index.workspace_id("/home/oleg/h2code-code")
    b = H2code::Session::Index.workspace_id("/home/oleg/other")
    a.should_not eq(b)
  end

  describe "#contains_substring?" do
    it "matches substrings in prompts, assistant text, and tool results, case-insensitively" do
      home = temp_home
      begin
        dir = File.join(home, ".h2code", "sessions", "sess0001")
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "wire.jsonl"), [
          %({"type":"turn.prompt","data":{"prompt":"Fix the LOGIN bug"}}),
          %({"type":"assistant.text","data":{"content":"Looking into it"}}),
          %({"type":"tool.result","data":{"tool_call_id":"t1","content":"stdout here"}}),
        ].join("\n"))

        idx = H2code::Session::Index.new(home)
        wire = File.join(dir, "wire.jsonl")
        idx.contains_substring?(wire, "login").should be_true
        idx.contains_substring?(wire, "looking").should be_true
        idx.contains_substring?(wire, "stdout").should be_true
        idx.contains_substring?(wire, "nothere").should be_false
        idx.contains_substring?(wire, "").should be_false
      ensure
        FileUtils.rm_rf(home)
      end
    end

    it "ignores non-text events and malformed lines, and handles a missing file" do
      home = temp_home
      begin
        dir = File.join(home, ".h2code", "sessions", "sess0002")
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "wire.jsonl"), [
          "not json at all",
          %({"type":"session.start","data":{"cwd":"/repo"}}),
        ].join("\n"))

        idx = H2code::Session::Index.new(home)
        wire = File.join(dir, "wire.jsonl")
        idx.contains_substring?(wire, "repo").should be_false
        idx.contains_substring?(File.join(dir, "missing.jsonl"), "x").should be_false
      ensure
        FileUtils.rm_rf(home)
      end
    end

    it "ignores raw-line candidates whose needle sits in a non-text field" do
      home = temp_home
      begin
        dir = File.join(home, ".h2code", "sessions", "sess0003")
        Dir.mkdir_p(dir)
        # The raw line contains the needle (tool_call_id + cwd), but neither
        # field is conversation text — the confirm step must reject it.
        File.write(File.join(dir, "wire.jsonl"),
          %({"type":"tool.result","data":{"tool_call_id":"ticket-42","cwd":"/ticket-42","content":"unrelated"}}))

        idx = H2code::Session::Index.new(home)
        idx.contains_substring?(File.join(dir, "wire.jsonl"), "ticket-42").should be_false
      ensure
        FileUtils.rm_rf(home)
      end
    end

    it "finds a match beyond the cooperative-yield threshold in a large wire log" do
      home = temp_home
      begin
        dir = File.join(home, ".h2code", "sessions", "sess0004")
        Dir.mkdir_p(dir)
        # ~1.5MB of non-matching filler (crosses SUBSTRING_SCAN_YIELD_BYTES
        # several times, exercising the Fiber.yield points), needle last.
        filler = %({"type":"assistant.text","data":{"content":"#{"x" * 4096}"}})
        lines = Array.new(360, filler)
        lines << %({"type":"turn.prompt","data":{"prompt":"finally the needle phrase"}})
        File.write(File.join(dir, "wire.jsonl"), lines.join("\n"))

        idx = H2code::Session::Index.new(home)
        wire = File.join(dir, "wire.jsonl")
        idx.contains_substring?(wire, "needle phrase").should be_true
        idx.contains_substring?(wire, "absent needle").should be_false
      ensure
        FileUtils.rm_rf(home)
      end
    end
  end

  describe "#substring_hits" do
    it "caches per query and prunes scans with cached prefixes" do
      home = temp_home
      begin
        dir_a = File.join(home, ".h2code", "sessions", "sessA")
        dir_b = File.join(home, ".h2code", "sessions", "sessB")
        Dir.mkdir_p(dir_a)
        Dir.mkdir_p(dir_b)
        wire_a = File.join(dir_a, "wire.jsonl")
        wire_b = File.join(dir_b, "wire.jsonl")
        File.write(wire_a, %({"type":"turn.prompt","data":{"prompt":"fix the login bug"}}))
        File.write(wire_b, %({"type":"turn.prompt","data":{"prompt":"unrelated talk"}}))

        idx = H2code::Session::Index.new(home)
        entries = idx.list(include_archived: true, include_empty: true)
        cache = Hash(String, Set(Int32)).new

        # Growing query: "logi" scans both files, "login" only re-checks
        # prefix survivors (sessB was ruled out by "logi" already).
        hits_a = Set.new((0...entries.size).select { |i| entries[i].id == "sessA" })
        idx.substring_hits(entries, "logi", cache).should eq(hits_a)
        idx.substring_hits(entries, "login", cache).should eq(hits_a)
        cache.size.should eq(2)

        # A query that matched nothing poisons every extension: "zzz" is
        # cached empty, so "zzzmore" never rescans the files — proven by
        # writing a matching prompt afterwards and still getting no hits.
        idx.substring_hits(entries, "zzz", cache).should be_empty
        File.write(wire_a, %({"type":"turn.prompt","data":{"prompt":"zzzmore now"}}))
        idx.contains_substring?(wire_a, "zzzmore").should be_true     # a direct scan finds it
        idx.substring_hits(entries, "zzzmore", cache).should be_empty # the pruned path doesn't look
      ensure
        FileUtils.rm_rf(home)
      end
    end

    it "cancels a stale scan without caching partial results" do
      home = temp_home
      begin
        dir_a = File.join(home, ".h2code", "sessions", "sessA")
        dir_b = File.join(home, ".h2code", "sessions", "sessB")
        Dir.mkdir_p(dir_a)
        Dir.mkdir_p(dir_b)
        File.write(File.join(dir_a, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"needle here"}}))
        File.write(File.join(dir_b, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"other"}}))

        idx = H2code::Session::Index.new(home)
        entries = idx.list(include_archived: true, include_empty: true)

        # Cancellation armed before anything is scanned: raises, caches
        # nothing — a retry from a clean state finds the session.
        cache = Hash(String, Set(Int32)).new
        expect_raises(H2code::Session::SearchCancelled) do
          idx.substring_hits(entries, "needle", cache, -> { true })
        end
        cache.should be_empty

        # Cancellation flips on after the first checkpoint call: the abort
        # now comes from inside `contains_substring?`'s per-line checkpoint
        # (raising through File.each_line) — partial results are NOT cached.
        cancelled = false
        flips_after_first = -> do
          if cancelled
            true
          else
            cancelled = true
            false
          end
        end
        expect_raises(H2code::Session::SearchCancelled) do
          idx.substring_hits(entries, "needle", cache, flips_after_first)
        end
        cache.should be_empty

        # Clean retry (uncancellable) succeeds.
        hits = idx.substring_hits(entries, "needle", cache)
        hits.size.should eq(1)
      ensure
        FileUtils.rm_rf(home)
      end
    end

    it "returns an empty set for an empty query without caching" do
      idx = H2code::Session::Index.new(temp_home)
      cache = Hash(String, Set(Int32)).new
      idx.substring_hits([] of H2code::Session::SessionEntry, "", cache).should be_empty
      cache.should be_empty
    end
  end

  it "lists workspace-aware v2 sessions" do
    home = temp_home
    begin
      ws = H2code::Session::Index.workspace_id("/repo")
      dir = File.join(home, ".h2code", "sessions", ws, "abc123def456")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"hello there"}}))
      meta = H2code::Session::StateMeta.new("abc123def456")
      meta.cwd = "/repo"
      meta.title = "my session"
      meta.workspace_id = ws
      File.write(File.join(dir, "state.json"), meta.to_json)

      idx = H2code::Session::Index.new(home)
      entries = idx.list
      entries.size.should eq(1)
      entries[0].id.should eq("abc123def456")
      entries[0].title.should eq("my session")
      entries[0].workspace_id.should eq(ws)
      entries[0].preview.should eq("hello there")
      entries[0].legacy?.should be_false
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "lists legacy flat-layout sessions" do
    home = temp_home
    begin
      dir = File.join(home, ".h2code", "sessions", "legacy001")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"old session"}}))
      File.write(File.join(dir, "meta.json"), %({"id":"legacy001","created_at":"2026-01-01T00:00:00Z"}))

      idx = H2code::Session::Index.new(home)
      entries = idx.list
      entries.size.should eq(1)
      entries[0].id.should eq("legacy001")
      entries[0].preview.should eq("old session")
      entries[0].legacy?.should be_true
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "hides archived sessions by default" do
    home = temp_home
    begin
      ws = H2code::Session::Index.workspace_id("/repo")
      active = File.join(home, ".h2code", "sessions", ws, "a1" * 6)
      archived = File.join(home, ".h2code", "sessions", ws, "b2" * 6)
      [active, archived].each { |d| Dir.mkdir_p(d) }
      [active, archived].each do |d|
        File.write(File.join(d, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"x"}}))
      end
      am = H2code::Session::StateMeta.new("a1" * 6)
      File.write(File.join(active, "state.json"), am.to_json)
      bm = H2code::Session::StateMeta.new("b2" * 6)
      bm.archived = true
      File.write(File.join(archived, "state.json"), bm.to_json)

      idx = H2code::Session::Index.new(home)
      idx.list.size.should eq(1)
      idx.list(include_archived: true).size.should eq(2)
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "list(ws_id) isolates sessions by workspace, never mixing folders" do
    home = temp_home
    begin
      ws_a = H2code::Session::Index.workspace_id("/repo-a")
      ws_b = H2code::Session::Index.workspace_id("/repo-b")

      ["a" * 12, "b" * 12].each do |sid|
        dir = File.join(home, ".h2code", "sessions", ws_a, sid)
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"in A"}}))
        File.write(File.join(dir, "state.json"), H2code::Session::StateMeta.new(sid).to_json)
      end
      dir_b = File.join(home, ".h2code", "sessions", ws_b, "c" * 12)
      Dir.mkdir_p(dir_b)
      File.write(File.join(dir_b, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"in B"}}))
      File.write(File.join(dir_b, "state.json"), H2code::Session::StateMeta.new("c" * 12).to_json)

      idx = H2code::Session::Index.new(home)
      # Scoped to A: only A sessions, B is excluded.
      idx.list(ws_a).size.should eq(2)
      idx.list(ws_a).map(&.id).should_not contain("c" * 12)
      # Scoped to B: only the one B session.
      idx.list(ws_b).size.should eq(1)
      idx.list(ws_b)[0].id.should eq("c" * 12)
      # Unscoped: all three.
      idx.list.size.should eq(3)
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "hides empty sessions (no messages) by default" do
    home = temp_home
    begin
      ws = H2code::Session::Index.workspace_id("/repo")
      # A session with a real prompt.
      full = File.join(home, ".h2code", "sessions", ws, "full0001dead")
      Dir.mkdir_p(full)
      File.write(File.join(full, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"hello"}}))
      File.write(File.join(full, "state.json"), H2code::Session::StateMeta.new("full0001dead").to_json)

      # A session with only an assistant message.
      replied = File.join(home, ".h2code", "sessions", ws, "reply002beef")
      Dir.mkdir_p(replied)
      File.write(File.join(replied, "wire.jsonl"), %({"type":"assistant.text","data":{"content":"hi"}}))
      File.write(File.join(replied, "state.json"), H2code::Session::StateMeta.new("reply002beef").to_json)

      # An empty wire.jsonl (created but never used).
      empty1 = File.join(home, ".h2code", "sessions", ws, "empty003cafe")
      Dir.mkdir_p(empty1)
      File.write(File.join(empty1, "wire.jsonl"), "")
      File.write(File.join(empty1, "state.json"), H2code::Session::StateMeta.new("empty003cafe").to_json)

      # A wire.jsonl with only bookkeeping (no real conversation event).
      empty2 = File.join(home, ".h2code", "sessions", ws, "empty004babe")
      Dir.mkdir_p(empty2)
      File.write(File.join(empty2, "wire.jsonl"), %({"type":"context.apply_compaction","data":{"summary":"x"}}))
      File.write(File.join(empty2, "state.json"), H2code::Session::StateMeta.new("empty004babe").to_json)

      idx = H2code::Session::Index.new(home)
      ids = idx.list.map(&.id)
      ids.should contain("full0001dead")
      ids.should contain("reply002beef")
      ids.should_not contain("empty003cafe")
      ids.should_not contain("empty004babe")

      # include_empty surfaces them all.
      idx.list(include_empty: true).size.should eq(4)

      # get finds an empty session by id regardless of the filter.
      idx.get("empty003cafe").try(&.id).should eq("empty003cafe")
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "finds a session by id across layouts" do
    home = temp_home
    begin
      ws = H2code::Session::Index.workspace_id("/repo")
      dir = File.join(home, ".h2code", "sessions", ws, "deadbeefdead")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "wire.jsonl"), %({"type":"turn.prompt","data":{"prompt":"x"}}))
      File.write(File.join(dir, "state.json"), H2code::Session::StateMeta.new("deadbeefdead").to_json)

      idx = H2code::Session::Index.new(home)
      idx.get("deadbeefdead").should_not be_nil
      idx.get("nonexistent").should be_nil
    ensure
      FileUtils.rm_rf(home)
    end
  end
end

describe H2code::Session::Lifecycle do
  it "creates a workspace-aware session with state.json" do
    home = temp_home
    begin
      lc = H2code::Session::Lifecycle.new(home)
      store = lc.create("/my/repo", "test title")

      File.exists?(File.join(store.session_dir, "state.json")).should be_true
      meta = store.read_state || raise "read_state should not be nil"
      meta.id.should_not be_empty
      meta.cwd.should eq("/my/repo")
      meta.title.should eq("test title")
      meta.workspace_id.should eq(H2code::Session::Index.workspace_id("/my/repo"))
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "fork copies the wire log into a new session" do
    home = temp_home
    begin
      lc = H2code::Session::Lifecycle.new(home)
      src = lc.create("/repo", "original")
      src.append("turn.prompt", {"prompt" => JSON::Any.new("hello")})

      forked = lc.fork(src, "/repo")
      forked.session_dir.should_not eq(src.session_dir)
      File.exists?(File.join(forked.session_dir, "wire.jsonl")).should be_true
      forked.read_state.try(&.title).should eq("Fork of original")

      # Replaying the fork reconstructs the original prompt.
      mem = H2code::Context::Memory.new
      forked.replay(mem)
      mem.messages.first?.try(&.text).should eq("hello")
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "persists sandbox_folder in state.json and defaults it to empty" do
    home = temp_home
    begin
      lc = H2code::Session::Lifecycle.new(home)
      store = lc.create("/repo")
      store.read_state.try(&.sandbox_folder).should eq("")

      # Record the session↔sandbox link (as /fork does) and read it back.
      meta = store.read_state.not_nil!
      meta.sandbox_folder = "/sandbox/h2code-abc123"
      store.write_state(meta)
      store.read_state.try(&.sandbox_folder).should eq("/sandbox/h2code-abc123")

      # Clearing the link (/merge) round-trips as empty.
      meta = store.read_state.not_nil!
      meta.sandbox_folder = ""
      store.write_state(meta)
      store.read_state.try(&.sandbox_folder).should eq("")

      # state.json written before the field existed parses with "".
      parsed = H2code::Session::StateMeta.from_json(
        %({"id":"x","title":"t","cwd":"/repo"}))
      parsed.sandbox_folder.should eq("")
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "archive hides a session, restore brings it back" do
    home = temp_home
    begin
      lc = H2code::Session::Lifecycle.new(home)
      store = lc.create("/repo")
      id = store.read_state.try(&.id) || raise "read_state should not be nil"

      lc.archive(id)
      lc.index.list.size.should eq(0)
      lc.index.list(include_archived: true, include_empty: true).size.should eq(1)

      lc.restore(id)
      lc.index.list(include_empty: true).size.should eq(1)
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "rename updates the title" do
    home = temp_home
    begin
      lc = H2code::Session::Lifecycle.new(home)
      store = lc.create("/repo", "old")
      id = store.read_state.try(&.id) || raise "read_state should not be nil"

      lc.rename(id, "new title")
      entry = lc.index.get(id) || raise "index.get should not be nil"
      entry.title.should eq("new title")
    ensure
      FileUtils.rm_rf(home)
    end
  end
end

describe H2code::Session::Store do
  it ".new_workspace_session writes the v2 layout" do
    home = temp_home
    begin
      store = H2code::Session::Store.new_workspace_session(home, "/repo", "ws")
      File.exists?(File.join(store.session_dir, "state.json")).should be_true
      meta = store.read_state || raise "read_state should not be nil"
      meta.cwd.should eq("/repo")
      meta.workspace_id.should eq(H2code::Session::Index.workspace_id("/repo"))
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "read_state falls back to legacy meta.json" do
    home = temp_home
    begin
      dir = File.join(home, ".h2code", "sessions", "legacy01")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "meta.json"), %({"id":"legacy01","created_at":"2026-01-01T00:00:00Z"}))
      store = H2code::Session::Store.new(dir)
      meta = store.read_state || raise "read_state should not be nil"
      meta.id.should eq("legacy01")
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "replay restores assistant text and thinking from a new-format wire" do
    home = temp_home
    begin
      dir = File.join(home, ".h2code", "sessions", "ws01")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "wire.jsonl"), [
        %({"type":"turn.prompt","data":{"prompt":"hello"}}),
        %({"type":"assistant.text","data":{"content":"world","thinking":"let me think"}}),
      ].join('\n'))
      store = H2code::Session::Store.new(dir)

      mem = H2code::Context::Memory.new
      store.replay(mem)

      msgs = mem.messages
      msgs.size.should eq(2)
      msgs[0].role.should eq("user")
      msgs[0].text.should eq("hello")
      msgs[1].role.should eq("assistant")
      msgs[1].text.should eq("world")
      msgs[1].thinking.should eq("let me think")
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "replay reads legacy assistant.text without thinking (backwards compat)" do
    home = temp_home
    begin
      dir = File.join(home, ".h2code", "sessions", "legacy02")
      Dir.mkdir_p(dir)
      # Old format: content is a string, no thinking field.
      File.write(File.join(dir, "wire.jsonl"), [
        %({"type":"turn.prompt","data":{"prompt":"hi"}}),
        %({"type":"assistant.text","data":{"content":"old reply"}}),
      ].join('\n'))
      store = H2code::Session::Store.new(dir)

      mem = H2code::Context::Memory.new
      store.replay(mem)

      msgs = mem.messages
      msgs.size.should eq(2)
      msgs[1].role.should eq("assistant")
      msgs[1].text.should eq("old reply")
      msgs[1].thinking.should be_empty
    ensure
      FileUtils.rm_rf(home)
    end
  end

  describe "deleted session file handling" do
    it "open_existing! raises FileDeletedError when the session dir is gone" do
      home = temp_home
      begin
        dir = File.join(home, ".h2code", "sessions", "deleted01")
        # Neither the directory nor wire.jsonl exists.
        expect_raises(H2code::Session::FileDeletedError) do
          H2code::Session::Store.open_existing!(dir)
        end
      ensure
        FileUtils.rm_rf(home)
      end
    end

    it "open_existing! raises FileDeletedError when only wire.jsonl is gone" do
      home = temp_home
      begin
        dir = File.join(home, ".h2code", "sessions", "deleted02")
        Dir.mkdir_p(dir)
        expect_raises(H2code::Session::FileDeletedError) do
          H2code::Session::Store.open_existing!(dir)
        end
      ensure
        FileUtils.rm_rf(home)
      end
    end

    it "open_existing! returns a store for an intact session" do
      home = temp_home
      begin
        lc = H2code::Session::Lifecycle.new(home)
        created = lc.create("/repo", "ok")
        # Release the creator's lock first: a session has exactly one
        # owner, so open_existing! would otherwise (correctly) report it
        # as busy.
        created.unlock
        store = H2code::Session::Store.open_existing!(created.session_dir)
        store.wire_path.should eq(created.wire_path)
        store.unlock
      ensure
        FileUtils.rm_rf(home)
      end
    end

    it "append rebuilds the wire from the journal after a mid-session deletion" do
      home = temp_home
      begin
        store = H2code::Session::Store.new_workspace_session(home, "/repo", "t")
        store.append_simple("turn.prompt", "prompt", "hello")
        store.append("assistant.text", {"content" => JSON::Any.new("world")})

        recovered = false
        store.on_wire_recovered = -> { recovered = true; nil }

        File.delete(store.wire_path)
        store.append_simple("turn.prompt", "prompt", "after deletion")

        recovered.should be_true
        lines = File.read_lines(store.wire_path)
        lines.size.should eq(3)
        lines[0].should contain("hello")
        lines[1].should contain("world")
        lines[2].should contain("after deletion")
      ensure
        FileUtils.rm_rf(home)
      end
    end

    # Regression: the whole session directory can vanish mid-run (session GC,
    # tmp cleaners) — including in the window between the mkdir_p check and
    # the File.open. append must self-heal instead of raising
    # FileNotFoundError into the turn fiber.
    it "append recreates the session directory after it is deleted mid-session" do
      home = temp_home
      begin
        store = H2code::Session::Store.new_workspace_session(home, "/repo", "t")
        store.append_simple("turn.prompt", "prompt", "hello")

        FileUtils.rm_rf(store.session_dir)
        store.append_simple("assistant.text", "content", "world")

        lines = File.read_lines(store.wire_path)
        lines.size.should eq(2)
        lines[0].should contain("hello")
        lines[1].should contain("world")
      ensure
        FileUtils.rm_rf(home)
      end
    end

    it "append restores the full replayed history after the wire is deleted" do
      home = temp_home
      begin
        dir = File.join(home, ".h2code", "sessions", "ws02")
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "wire.jsonl"), [
          %({"type":"turn.prompt","data":{"prompt":"old question"}}),
          %({"type":"assistant.text","data":{"content":"old answer"}}),
        ].join('\n') + "\n")
        store = H2code::Session::Store.new(dir)

        # Resume: replay journals the prior history in memory.
        mem = H2code::Context::Memory.new
        store.replay(mem)

        File.delete(store.wire_path)
        store.append_simple("turn.prompt", "prompt", "new question")

        lines = File.read_lines(store.wire_path)
        lines.size.should eq(3)
        lines[0].should contain("old question")
        lines[1].should contain("old answer")
        lines[2].should contain("new question")
      ensure
        FileUtils.rm_rf(home)
      end
    end

    it "append recreates a fully deleted session directory" do
      home = temp_home
      begin
        store = H2code::Session::Store.new_workspace_session(home, "/repo", "t")
        store.append_simple("turn.prompt", "prompt", "one")

        FileUtils.rm_rf(store.session_dir)
        store.append_simple("turn.prompt", "prompt", "two")

        File.exists?(store.wire_path).should be_true
        lines = File.read_lines(store.wire_path)
        lines.size.should eq(2)
        lines[0].should contain("one")
        lines[1].should contain("two")
      ensure
        FileUtils.rm_rf(home)
      end
    end

    it "write_state recreates a deleted session directory" do
      home = temp_home
      begin
        store = H2code::Session::Store.new_workspace_session(home, "/repo", "t")
        meta = store.read_state || raise "read_state should not be nil"
        FileUtils.rm_rf(store.session_dir)

        store.write_state(meta)
        File.exists?(store.state_path).should be_true
      ensure
        FileUtils.rm_rf(home)
      end
    end

    it "adopt rebinds onto another session and reloads its journal" do
      home = temp_home
      begin
        lc = H2code::Session::Lifecycle.new(home)
        first = lc.create("/repo", "first")
        first.append_simple("turn.prompt", "prompt", "from first")

        second = lc.create("/repo", "second")
        second.append_simple("turn.prompt", "prompt", "from second")

        first.adopt(second)
        first.wire_path.should eq(second.wire_path)
        first.session_dir.should eq(second.session_dir)

        File.delete(second.wire_path)
        first.append_simple("turn.prompt", "prompt", "after adopt")

        lines = File.read_lines(second.wire_path)
        lines.size.should eq(2)
        lines[0].should contain("from second")
        lines[1].should contain("after adopt")
      ensure
        FileUtils.rm_rf(home)
      end
    end
  end
end
