require "file_utils"
require "./index"
require "./store"

module H2code
  module Session
    # Session lifecycle operations — create / fork / archive / restore /
    # rename. CLI- and TUI-only: there is no HTTP server, so every action
    # acts directly on the filesystem via `Session::Store` + `Session::Index`.
    #
    # Ref: plans/PLAN.md "Local session management (console-only)".
    class Lifecycle
      getter home : String
      getter index : Index

      def initialize(@home : String = (ENV["HOME"]? || "/tmp"))
        @index = Index.new(@home)
      end

      # Create a fresh session bound to `cwd`. Writes the v2 layout
      # (`<workspace>/<session>/state.json`) so the new Index can list it.
      def create(cwd : String, title : String = "") : Store
        ws_id = Index.workspace_id(cwd)
        session_id = Random::Secure.hex(12)
        dir = @index.session_dir(ws_id, session_id)
        Dir.mkdir_p(dir)
        store = Store.new(dir)
        # Own the fresh session (random new dir — the lock is always
        # free). Held until the process exits or the store is adopted.
        store.lock!
        meta = StateMeta.new(session_id)
        meta.cwd = cwd
        meta.title = title
        meta.workspace_id = ws_id
        meta.created_at = Time.utc.to_rfc3339
        meta.updated_at = meta.created_at
        store.write_state(meta)
        # Touch the wire log so the Index discovers the session before the
        # first event is appended (an empty session should still be pickable).
        store.ensure_wire
        store
      end

      # Fork an existing session: copy its wire log into a new session
      # directory under the same (or a new) workspace, then stamp a fresh
      # state.json. The original session is untouched.
      def fork(src : Store, cwd : String = "", title : String = "") : Store
        new_cwd = cwd.empty? ? current_cwd(src) : cwd
        ws_id = Index.workspace_id(new_cwd)
        session_id = Random::Secure.hex(12)
        dir = @index.session_dir(ws_id, session_id)
        Dir.mkdir_p(dir)

        # Copy the wire log so replay reconstructs the forked history.
        if File.exists?(src.wire_path)
          FileUtils.cp(src.wire_path, File.join(dir, "wire.jsonl"))
        end

        store = Store.new(dir)
        store.lock! # own the fresh fork (random new dir — always free)
        meta = StateMeta.new(session_id)
        meta.cwd = new_cwd
        base_title = title.empty? ? fork_title(src) : title
        meta.title = base_title
        meta.workspace_id = ws_id
        now = Time.utc.to_rfc3339
        meta.created_at = now
        meta.updated_at = now
        store.write_state(meta)
        store.ensure_wire
        store
      end

      # Mark a session as archived (hidden from the default list, but not
      # deleted — restorable via `restore`).
      def archive(entry : SessionEntry) : Nil
        toggle_archive(entry, true)
      end

      def archive(session_id : String) : Nil
        return unless entry = @index.get(session_id)
        archive(entry)
      end

      # Un-archive a previously archived session.
      def restore(entry : SessionEntry) : Nil
        toggle_archive(entry, false)
      end

      def restore(session_id : String) : Nil
        return unless entry = @index.get(session_id)
        restore(entry)
      end

      # Rename a session (sets its title).
      def rename(entry : SessionEntry, title : String) : Nil
        meta = Store.new(entry.path).read_state ||
               StateMeta.new(entry.id)
        meta.title = title
        meta.updated_at = Time.utc.to_rfc3339
        Store.new(entry.path).write_state(meta)
      end

      def rename(session_id : String, title : String) : Nil
        return unless entry = @index.get(session_id)
        rename(entry, title)
      end

      # ---- helpers --------------------------------------------------------

      private def toggle_archive(entry : SessionEntry, archived : Bool) : Nil
        store = Store.new(entry.path)
        meta = store.read_state || StateMeta.new(entry.id)
        meta.archived = archived
        meta.updated_at = Time.utc.to_rfc3339
        store.write_state(meta)
      end

      private def current_cwd(store : Store) : String
        if meta = store.read_state
          return meta.cwd unless meta.cwd.empty?
        end
        Dir.current
      end

      private def fork_title(src : Store) : String
        meta = src.read_state
        base = meta.try(&.title) || ""
        return "Fork of #{base}" unless base.empty?
        "Forked session"
      end
    end
  end
end
