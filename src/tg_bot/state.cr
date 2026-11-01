require "json"

module TgBot
  # Persistent bot state: `~/.h2code/tg/state.json` (H2CODE_HOME honoured).
  #
  #   {
  #     "names": {"<sid>": "Billing audit"},          // /rename, survives the session
  #     "sessions": [                                  // journal for 🕘 Recent
  #       {"sid": "…", "dir": "/srv/app", "name": "app-1a2b", "custom": true,
  #        "created": 1760000000, "last_active": 1760000900,
  #        "first_prompt": "fix the billing webhook"}
  #     ]
  #   }
  #
  # Written with a lock and a tmp+rename swap; read failures start empty —
  # a corrupt state file must never take the daemon down.
  class State
    class Entry
      getter sid : String
      getter dir : String
      property name : String
      property? custom : Bool
      property created : Int64
      property last_active : Int64
      property first_prompt : String

      def initialize(@sid, @dir, @name, @custom = false, @created = Time.utc.to_unix,
                     @last_active = Time.utc.to_unix, @first_prompt = "")
      end

      def when_short : String
        short_time(Time.unix(@last_active))
      end

      # "HH:MM" today, "HH:MM" yesterday-ish via short day name within a week,
      # otherwise "d.m" — the claude-tg-bot button convention.
      def self.short_time(t : Time) : String
        now = Time.local
        t = t.in(now.location)
        if t.year == now.year && t.month == now.month && t.day == now.day
          t.to_s("%H:%M")
        elsif (now - t).total_days < 7
          t.to_s("%a %H:%M")
        else
          t.to_s("%-d.%-m")
        end
      end

      def short_time(t : Time) : String
        Entry.short_time(t)
      end

      def self.from_json(node : JSON::Any) : Entry
        new(
          node["sid"]?.try(&.to_s) || "",
          node["dir"]?.try(&.to_s) || "",
          node["name"]?.try(&.to_s) || "",
          node["custom"]?.try(&.as_bool?) || false,
          node["created"]?.try(&.to_s.to_i64?) || Time.utc.to_unix,
          node["last_active"]?.try(&.to_s.to_i64?) || Time.utc.to_unix,
          node["first_prompt"]?.try(&.to_s) || "",
        )
      end
    end

    getter names = {} of String => String
    getter sessions = [] of Entry
    @lock = Mutex.new

    def initialize(@path : String)
      load
    end

    def self.default_path : String
      home = ENV["H2CODE_HOME"]? || File.join(ENV["HOME"]? || Dir.current, ".h2code")
      File.join(home, "tg", "state.json")
    end

    def load : Nil
      @lock.synchronize do
        @names.clear
        @sessions.clear
        return unless File.exists?(@path)
        root = JSON.parse(File.read(@path))
        if h = root["names"]?.try(&.as_h?)
          h.each { |sid, name| @names[sid.to_s] = name.to_s }
        end
        if a = root["sessions"]?.try(&.as_a?)
          a.each { |n| @sessions << Entry.from_json(n) }
        end
      rescue
        # Corrupt state is not fatal: start empty rather than refuse to run.
      end
    end

    def save : Nil
      @lock.synchronize do
        Dir.mkdir_p(File.dirname(@path))
        tmp = "#{@path}.tmp"
        File.write(tmp, to_json)
        File.rename(tmp, @path)
      end
    end

    # --- names (/rename) ---

    def name_of(sid : String) : String?
      @lock.synchronize { @names[sid]? }
    end

    # `/rename -` hands the automatic name back.
    def set_name(sid : String, name : String?) : Nil
      @lock.synchronize do
        if name.nil? || name.empty?
          @names.delete(sid)
        else
          @names[sid] = name
        end
        if e = @sessions.find { |s| s.sid == sid }
          e.name = name.to_s
          e.custom = !name.nil? && !name.empty?
        end
      end
      save
    end

    # --- session journal (🕘 Recent) ---

    def record_start(sid : String, dir : String, name : String, custom : Bool = false) : Nil
      @lock.synchronize do
        @sessions.reject! { |s| s.sid == sid }
        @sessions.unshift(Entry.new(sid, dir, name, custom))
        # Keep the journal bounded: a phone list pages through it, and years
        # of dead sessions help nobody.
        @sessions = @sessions.first(100)
      end
      save
    end

    def record_first_prompt(sid : String, prompt : String) : Nil
      changed = @lock.synchronize do
        if e = @sessions.find { |s| s.sid == sid }
          e.first_prompt = prompt unless prompt.empty?
          true
        end
      end
      save if changed
    end

    def touch(sid : String) : Nil
      changed = @lock.synchronize do
        if e = @sessions.find { |s| s.sid == sid }
          e.last_active = Time.utc.to_unix
          true
        end
      end
      save if changed
    end

    def entry(sid : String) : Entry?
      @lock.synchronize { @sessions.find { |s| s.sid == sid } }
    end

    # Closed sessions, newest first: journal entries whose sid is not among
    # the live ones.
    def closed(live_sids : Set(String)) : Array(Entry)
      @lock.synchronize { @sessions.select { |s| !live_sids.includes?(s.sid) } }
    end

    def to_json : String
      JSON.build(indent: "  ") do |j|
        j.object do
          j.field "names" do
            j.object do
              @names.each { |sid, name| j.field sid, name }
            end
          end
          j.field "sessions" do
            j.array do
              @sessions.each do |e|
                j.object do
                  j.field "sid", e.sid
                  j.field "dir", e.dir
                  j.field "name", e.name
                  j.field "custom", e.custom?
                  j.field "created", e.created
                  j.field "last_active", e.last_active
                  j.field "first_prompt", e.first_prompt
                end
              end
            end
          end
        end
      end
    end
  end
end
