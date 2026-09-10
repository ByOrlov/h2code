require "file_utils"

module H2code
  module Session
    # Manual cleanup of aged-out local data: session directories and voice
    # message files. Driven by the `/cleanup` slash command — the user picks
    # a minimum age (week / month / 6 months / year) and everything older
    # is deleted. There is deliberately no period shorter than a week:
    # deleting fresh data is never worth the risk of a misclick.
    #
    # Safety rules:
    #   * the current session is never deleted (skip_session_ids);
    #   * a session whose flock is held by a live process is skipped, not
    #     deleted — the owner keeps writing to its wire.jsonl;
    #   * voice files are swept by mtime only (names carry no timestamps).
    class Cleanup
      # Age periods accepted by /cleanup, in days. The order matches the
      # selector presented to the user (shortest → longest).
      PERIODS = {
        "week"    => 7,
        "month"   => 30,
        "6months" => 182,
        "year"    => 365,
      }

      # A class (not struct): the run helpers mutate it through a shared
      # reference while accumulating counts.
      class Result
        property sessions_removed : Int32 = 0
        property sessions_skipped : Int32 = 0 # locked by another process
        property voice_files_removed : Int32 = 0
      end

      # Per-period removal preview shown in the /cleanup picker: how many
      # sessions and voice files each option would delete right now. The
      # session counts include sessions currently locked by other processes
      # (those get skipped by #run and reported afterwards).
      class PeriodCounts
        property sessions : Int32 = 0
        property voice_files : Int32 = 0
      end

      getter home : String

      def initialize(@home : String = HomePort.home)
      end

      def self.period_days(period : String) : Int32?
        PERIODS[period]?
      end

      # Preview counts for every period, excluding the given (current)
      # session ids. One scan of the session index + voice dir, bucketed
      # per cutoff — cheap enough to run each time the picker opens.
      def counts(skip_session_ids : Array(String) = [] of String) : Hash(String, PeriodCounts)
        entries = Index.new(@home)
          .list(include_archived: true, include_empty: true)
          .reject { |e| skip_session_ids.includes?(e.id) }

        voice_times = [] of Time
        if Dir.exists?(voice_root)
          Dir.children(voice_root).each do |name|
            path = File.join(voice_root, name)
            if File.file?(path) && (info = File.info?(path))
              voice_times << info.modification_time
            end
          end
        end

        PERIODS.each_with_object(Hash(String, PeriodCounts).new) do |(period, days), result|
          cutoff = Time.utc - days.days
          pc = PeriodCounts.new
          pc.sessions = entries.count { |e| e.updated_at < cutoff }
          pc.voice_files = voice_times.count { |t| t < cutoff }
          result[period] = pc
        end
      end

      # Voice message clips live here (written by the external voice stack):
      # `<home>/.h2code/voice/<uuid>.webm|.bin` — flat, mtime carries the age.
      def voice_root : String
        File.join(@home, ".h2code", "voice")
      end

      # Delete every session and voice file whose last activity is older
      # than `period`. Returns a Result with the removal counts.
      def run(period : String, skip_session_ids : Array(String) = [] of String) : Result
        days = self.class.period_days(period) || raise "Unknown cleanup period: #{period}"
        cutoff = Time.utc - days.days
        result = Result.new

        cleanup_sessions(cutoff, skip_session_ids, result)
        cleanup_voice(cutoff, result)
        result
      end

      private def cleanup_sessions(cutoff : Time, skip_ids : Array(String), result : Result) : Nil
        entries = Index.new(@home).list(include_archived: true, include_empty: true)
        entries.each do |entry|
          next if entry.updated_at >= cutoff
          next if skip_ids.includes?(entry.id)
          # Probe the flock: a live owner means the session is in use.
          begin
            lock = Lock.acquire!(entry.path)
            lock.release
          rescue SessionBusyError
            result.sessions_skipped += 1
            next
          end
          begin
            FileUtils.rm_r(entry.path)
            result.sessions_removed += 1
          rescue File::Error | ArgumentError
            result.sessions_skipped += 1
          end
        end
      end

      private def cleanup_voice(cutoff : Time, result : Result) : Nil
        return unless Dir.exists?(voice_root)
        Dir.children(voice_root).each do |name|
          path = File.join(voice_root, name)
          next unless File.file?(path)
          if (info = File.info?(path)) && info.modification_time < cutoff
            begin
              File.delete(path)
              result.voice_files_removed += 1
            rescue File::Error
              # In-flight recording or permission issue — leave it alone.
            end
          end
        end
      end
    end
  end
end
