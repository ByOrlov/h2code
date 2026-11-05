require "./index"
require "./lock"
require "./write_queue"

module H2code
  module Session
    # Raised when opening a session whose wire.jsonl no longer exists on
    # disk (the session directory was deleted under us). Plain `Store.new`
    # recreates the directory, which would silently resurrect the session
    # as an empty one — and the next save would lose the whole history for
    # good. Every "open an existing session by path" call site must use
    # `Store.open_existing!` instead so deletion is reported, not hidden.
    class FileDeletedError < Exception
      getter session_dir : String

      def initialize(@session_dir : String)
        super("Session file was deleted: #{File.join(@session_dir, "wire.jsonl")}")
      end
    end

    class Store
      property session_dir : String
      property wire_path : String
      property state_path : String

      # Notified whenever wire.jsonl disappeared mid-session and was
      # rebuilt from the in-memory journal, so the UI can surface it.
      property on_wire_recovered : (-> Nil)?

      # Disk-write queue shared by every store (see `WriteQueue`). All
      # wire appends and metadata replacements go through it; a failing
      # disk (ENOSPC, …) buffers and retries instead of raising here.
      getter write_queue : WriteQueue = WriteQueue.default

      # Raw wire lines seen by this process: everything replayed at open
      # plus every line appended since. Backs the automatic rebuild when
      # the wire file is deleted while the session is live.
      @journal : Array(String)?

      # Exclusive ownership lock over the session directory, held for the
      # store's (process's) lifetime. Nil for lock-free stores built via
      # the plain constructor (metadata-only use: rename, archive).
      @lock : Lock?

      # True once the wire file has been observed on disk; a later append
      # that finds it missing indicates mid-session deletion.
      @wire_seen : Bool = false

      def initialize(@session_dir : String)
        @wire_path = File.join(@session_dir, "wire.jsonl")
        # v2 layout uses state.json (richer metadata); the legacy flat
        # layout used meta.json. Both are supported on read.
        @state_path = File.join(@session_dir, "state.json")
        Dir.mkdir_p(@session_dir) unless Dir.exists?(@session_dir)
        @journal = nil
        @wire_seen = File.exists?(@wire_path)
      end

      # Open an existing session by directory, raising `FileDeletedError`
      # when its wire.jsonl is gone and `SessionBusyError` when another
      # live process already owns the session (see `Lock`). See the error
      # class doc for why the plain constructor must not be used on
      # "open" paths.
      def self.open_existing!(session_dir : String) : Store
        dir = session_dir.chomp("/")
        raise FileDeletedError.new(dir) unless File.exists?(File.join(dir, "wire.jsonl"))
        store = new(dir)
        store.lock!
        store
      end

      def self.new_session(home : String) : Store
        session_id = Random::Secure.hex(12)
        dir = File.join(home, ".h2code", "sessions", session_id)
        store = new(dir)
        store.write_meta({"id" => session_id, "created_at" => Time.utc.to_rfc3339})
        store
      end

      # Create a workspace-aware session (v2 layout). The session lands in
      # `<sessions>/<workspace_id>/<session_id>/` and is stamped with a
      # state.json so the Index can discover it.
      def self.new_workspace_session(home : String, cwd : String,
                                     title : String = "") : Store
        ws_id = Index.workspace_id(cwd)
        session_id = Random::Secure.hex(12)
        dir = File.join(home, ".h2code", "sessions", ws_id, session_id)
        store = new(dir)
        meta = StateMeta.new(session_id)
        meta.cwd = cwd
        meta.title = title
        meta.workspace_id = ws_id
        now = Time.utc.to_rfc3339
        meta.created_at = now
        meta.updated_at = now
        store.write_state(meta)
        store.ensure_wire
        store
      end

      def append(event_type : String, data : Hash(String, JSON::Any)) : Nil
        line = {
          "type"      => JSON::Any.new(event_type),
          "timestamp" => JSON::Any.new(Time.utc.to_rfc3339),
          "data"      => JSON::Any.new(data),
        }.to_json
        journal << line
        if @wire_seen && !File.exists?(@wire_path)
          # Mid-session deletion (tmp cleaners, manual `rm -rf`): rebuild
          # the wire from the journal. One queued replacement holding the
          # full journal (which already includes this line) supersedes any
          # appends still buffered from a failure episode, so history and
          # ordering are preserved without duplicating lines.
          content = journal.empty? ? "" : journal.join('\n') + '\n'
          first_rebuild = @write_queue.pending_replace(@wire_path).nil?
          @write_queue.enqueue_replace(@wire_path, @session_dir, content)
          @on_wire_recovered.try(&.call) if first_rebuild
        else
          @write_queue.enqueue_append(@wire_path, @session_dir, line)
        end
        @wire_seen = true
      end

      # Create an empty wire.jsonl if it does not exist yet, so the Index
      # can discover a freshly-created session before the first event.
      # Skipped when writes for the wire are already buffered — an empty
      # replacement would wipe them.
      def ensure_wire : Nil
        return if File.exists?(@wire_path)
        return if @write_queue.pending_for?(@wire_path)
        @write_queue.enqueue_replace(@wire_path, @session_dir, "")
      end

      def append_simple(event_type : String, key : String, value : String) : Nil
        append(event_type, {key => JSON::Any.new(value)})
      end

      def read_events : Array(NamedTuple(type: String, data: JSON::Any))
        return [] of NamedTuple(type: String, data: JSON::Any) unless File.exists?(@wire_path)

        reload_journal

        events = [] of NamedTuple(type: String, data: JSON::Any)

        journal.each do |line|
          begin
            parsed = JSON.parse(line)
            events << {
              type: parsed["type"].to_s,
              data: parsed["data"],
            }
          rescue JSON::ParseException
          end
        end

        events
      end

      # Rebind this store onto another session's location (TUI session
      # switch: new / resume / fork) and reload the recovery journal from
      # the target wire so a later mid-session deletion heals fully.
      # Lock ownership follows the switch: the previous session's lock is
      # released and the target's lock (acquired by its construction path,
      # e.g. `open_existing!` / `Lifecycle.create`) transfers to us.
      def adopt(other : Store) : Nil
        @session_dir = other.session_dir
        @wire_path = other.wire_path
        @state_path = other.state_path
        reload_journal
        unlock
        @lock = other.@lock
      end

      # Acquire this session's exclusive lock (see `Lock`). No-op when
      # already held by this store. Raises `SessionBusyError` when another
      # live process owns the session.
      def lock! : Nil
        @lock ||= Lock.acquire!(@session_dir)
      end

      # Release the session lock. The OS also releases it when the process
      # exits; this makes the handover explicit for in-process switches.
      def unlock : Nil
        @lock.try(&.release)
        @lock = nil
      end

      # Lazily-created append buffer; shared by `append` and `read_events`.
      private def journal : Array(String)
        @journal ||= [] of String
      end

      # (Re)load the raw non-empty wire lines from disk into the journal,
      # merging any lines still buffered in the write queue after a disk
      # failure so replay never misses the tail of the session.
      private def reload_journal : Nil
        raw = [] of String
        if content = @write_queue.pending_replace(@wire_path)
          # A queued rebuild supersedes whatever is (or isn't) on disk.
          content.each_line do |line|
            raw << line unless line.strip.empty?
          end
        elsif File.exists?(@wire_path)
          File.each_line(@wire_path) do |line|
            raw << line unless line.strip.empty?
          end
        end
        @write_queue.pending_appends(@wire_path).each do |line|
          raw << line unless line.strip.empty?
        end
        @journal = raw
        @wire_seen = File.exists?(@wire_path) || @write_queue.pending_for?(@wire_path)
      end

      def write_meta(meta : Hash(String, String)) : Nil
        atomic_write(meta_path, meta.to_json)
      end

      # Write the v2 state.json metadata document. Atomic and self-healing:
      # recreates the session directory if it was deleted mid-run instead
      # of crashing with FileNotFoundError.
      def write_state(meta : StateMeta) : Nil
        meta.updated_at = Time.utc.to_rfc3339
        atomic_write(@state_path, meta.to_json)
      end

      # Path of the legacy flat-layout meta.json.
      private def meta_path : String
        File.join(@session_dir, "meta.json")
      end

      def read_meta : JSON::Any?
        path = meta_path
        return nil unless (content = @write_queue.pending_replace(path)) || File.exists?(path)
        JSON.parse(content || File.read(path))
      rescue
        nil
      end

      # Read the v2 state.json, falling back to a StateMeta synthesised
      # from the legacy meta.json when only the flat layout exists.
      def read_state : StateMeta?
        if content = @write_queue.pending_replace(@state_path)
          return StateMeta.from_json(content)
        end
        if File.exists?(@state_path)
          return StateMeta.from_json(File.read(@state_path))
        end
        # Legacy fallback: rebuild a StateMeta from meta.json.
        legacy = read_meta
        return nil unless legacy
        state = StateMeta.new(legacy["id"]?.try(&.to_s) || File.basename(@session_dir))
        state.title = legacy["title"]?.try(&.to_s) || ""
        state.cwd = legacy["cwd"]?.try(&.to_s) || ""
        state.created_at = legacy["created_at"]?.try(&.to_s) || Time.utc.to_rfc3339
        state
      rescue JSON::ParseException
        nil
      end

      def meta_id? : String?
        read_meta.try(&.["id"]?).try(&.to_s)
      end

      def replay(memory : Context::Memory) : Nil
        read_events.each do |event|
          case event[:type]
          when "turn.prompt"
            if prompt = event[:data]["prompt"]?
              memory.add_user(prompt.to_s)
            end
          when "turn.steer"
            if prompt = event[:data]["prompt"]?
              memory.add_user(prompt.to_s)
            end
          when "assistant.text"
            content = event[:data]["content"]?.try(&.to_s) || ""
            thinking = event[:data]["thinking"]?.try(&.to_s)
            parts = [] of LLM::ContentPart
            parts << LLM::ThinkContent.new(thinking) if thinking && !thinking.empty?
            parts << LLM::TextContent.new(content) unless content.empty?
            memory.add_assistant_parts(parts) unless parts.empty?
          when "tool.call"
            tool_name = event[:data]["tool_name"]?.try(&.to_s) || ""
            args = event[:data]["arguments"]?.try(&.to_s) || "{}"
            id = event[:data]["tool_call_id"]?.try(&.to_s) || ""
            tool_call = LLM::ToolCall.new(id, LLM::ToolCallFunction.new(tool_name, args))
            memory.add_assistant("", [tool_call])
          when "tool.result"
            id = event[:data]["tool_call_id"]?
            content = event[:data]["content"]?
            if id && content
              memory.add_tool_result(id.to_s, content.to_s)
            end
          when "context.apply_compaction"
            if summary = event[:data]["summary"]?
              memory.apply_compaction(summary.to_s, [] of Context::ContextMessage)
            end
          end
        end
      end

      # ------------------------------------------------------------------
      # Persistence helpers for cron tasks and background-task metadata.
      # ------------------------------------------------------------------

      # Path to the cron-tasks persistence file for this session.
      def cron_path : String
        File.join(@session_dir, "cron.json")
      end

      # Load persisted cron tasks (array of JSON objects). Returns an empty
      # array when the file does not exist or is unreadable. A replacement
      # still buffered in the write queue takes precedence over the file.
      def read_cron_tasks : Array(JSON::Any)
        if (json = @write_queue.pending_replace(cron_path)) || File.exists?(cron_path)
          return JSON.parse(json || File.read(cron_path)).as_a
        end
        [] of JSON::Any
      rescue JSON::ParseException
        [] of JSON::Any
      end

      # Atomically persist the cron-tasks array. Writes to a temp file,
      # fsyncs, then renames into place so a crash mid-write cannot corrupt
      # the existing store.
      def write_cron_tasks(json : String) : Nil
        atomic_write(cron_path, json)
      end

      # Directory holding background-task metadata and output logs.
      def tasks_dir : String
        File.join(@session_dir, "tasks")
      end

      # Ensure the tasks directory exists, creating it if needed.
      def ensure_tasks_dir : Nil
        Dir.mkdir_p(tasks_dir) unless Dir.exists?(tasks_dir)
      end

      # Per-task metadata file (`<tasks_dir>/<task_id>.json`).
      def task_meta_path(task_id : String) : String
        File.join(tasks_dir, "#{task_id}.json")
      end

      # Per-task output log (`<tasks_dir>/<task_id>.log`).
      def task_output_path(task_id : String) : String
        File.join(tasks_dir, "#{task_id}.log")
      end

      # Load every persisted task metadata document. Skips files that fail
      # to parse (defensive against partial writes). Returns task_id → JSON.
      def read_task_metas : Array({String, JSON::Any})
        return [] of {String, JSON::Any} unless Dir.exists?(tasks_dir)
        results = [] of {String, JSON::Any}
        Dir.children(tasks_dir).each do |name|
          next unless name.ends_with?(".json")
          path = File.join(tasks_dir, name)
          task_id = name.rchop(".json")
          begin
            parsed = JSON.parse(File.read(path))
            results << {task_id, parsed}
          rescue JSON::ParseException
            # Skip corrupt files.
          end
        end
        results
      end

      # Read a single task's metadata document. Returns nil when the file
      # does not exist or is unreadable. A replacement still buffered in
      # the write queue takes precedence over the file.
      def read_task_meta(task_id : String) : JSON::Any?
        path = task_meta_path(task_id)
        return nil unless (content = @write_queue.pending_replace(path)) || File.exists?(path)
        JSON.parse(content || File.read(path))
      rescue JSON::ParseException
        nil
      end

      # Atomically persist a single task's metadata.
      def write_task_meta(task_id : String, json : String) : Nil
        ensure_tasks_dir
        atomic_write(task_meta_path(task_id), json)
      end

      # Delete a task's metadata file (used when a one-shot/stale task is
      # removed entirely). Best-effort; ignores a missing file.
      def delete_task_meta(task_id : String) : Nil
        path = task_meta_path(task_id)
        File.delete(path) if File.exists?(path)
      rescue
        # Best-effort.
      end

      # Queue a whole-file replacement: temp file in the same directory,
      # fsync, rename. Same-directory rename is atomic on POSIX; keeping
      # the temp file adjacent ensures the rename does not cross a
      # filesystem boundary. Execution is immediate on the happy path and
      # buffered/retried by the write queue when the disk errors.
      private def atomic_write(path : String, content : String) : Nil
        @write_queue.enqueue_replace(path, File.dirname(path), content)
      end

      def self.list_sessions(home : String) : Array(SessionInfo)
        sessions_dir = File.join(home, ".h2code", "sessions")
        return [] of SessionInfo unless Dir.exists?(sessions_dir)

        sessions = [] of SessionInfo

        Dir.children(sessions_dir).each do |dir_name|
          dir_path = File.join(sessions_dir, dir_name)
          next unless File.directory?(dir_path)

          wire = File.join(dir_path, "wire.jsonl")
          next unless File.exists?(wire)

          first_line = File.read_lines(wire).first?
          preview = ""
          if first_line
            begin
              parsed = JSON.parse(first_line)
              if data = parsed["data"]?
                if prompt = data["prompt"]?
                  preview = prompt.to_s[0...80]
                end
              end
            rescue
            end
          end

          sessions << SessionInfo.new(
            id: dir_name,
            path: dir_path,
            preview: preview,
            created_at: File.info(wire).modification_time,
          )
        end

        sessions.sort_by! { |s| -s.created_at.to_unix }
      end
    end

    struct SessionInfo
      property id : String
      property path : String
      property preview : String
      property created_at : Time

      def initialize(@id : String, @path : String, @preview : String, @created_at : Time)
      end
    end
  end
end
