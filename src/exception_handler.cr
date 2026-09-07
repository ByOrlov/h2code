require "file"
require "file_utils"
require "time"
require "random/secure"

require "./version"

module H2code
  # Crash-report collector: writes unhandled exceptions raised during agent
  # operation into `~/.h2code/exceptions/` so a developer can inspect them
  # after the fact. Every method is best-effort — the handler must never
  # raise itself and crash the process it was supposed to report on.
  module ExceptionHandler
    @@home : String?

    # Override the home base (mainly for tests). When unset the handler
    # resolves `H2CODE_HOME` → `~/.h2code`, matching Config.
    def self.home=(path : String?) : Nil
      @@home = path
    end

    def self.exceptions_dir : String
      base = @@home || ENV["H2CODE_HOME"]? || File.join(HomePort.home, ".h2code")
      File.join(base, "exceptions")
    end

    def self.ensure_dir : Nil
      Dir.mkdir_p(exceptions_dir) unless Dir.exists?(exceptions_dir)
    rescue
      # Best-effort.
    end

    # Write a crash report for *ex* caught in *context*. Returns the file
    # path, or nil when writing failed.
    def self.report(ex : Exception, context : String = "unhandled") : String?
      ensure_dir
      path = File.join(exceptions_dir, filename_for(ex))
      content = build_report(ex, context)
      File.write(path, content)
      path
    rescue
      # Never let the handler itself crash the process.
      nil
    end

    # Convenience: report and also print a short stderr hint so the user
    # knows a crash dump was saved.
    def self.report_and_notify(ex : Exception, context : String = "unhandled") : Nil
      if path = report(ex, context)
        STDERR.puts "Crash report saved: #{path}".colorize.yellow
      end
    rescue
      # Best-effort.
    end

    private def self.filename_for(ex : Exception) : String
      ts = Time.utc.to_s("%Y%m%d_%H%M%S")
      class_slug = ex.class.to_s.gsub("::", "_").gsub(/[^A-Za-z0-9_]/, "_")
      "#{ts}_#{class_slug}_#{Random::Secure.hex(4)}.log"
    end

    private def self.os_name : String
      `uname -s 2>/dev/null`.strip
    rescue
      "unknown"
    end

    private def self.build_report(ex : Exception, context : String) : String
      ts = Time.utc
      String.build do |s|
        s << "=== H2code Exception Report ===\n"
        s << "Time:    #{ts.to_rfc3339}\n"
        s << "Context: #{context}\n"
        s << "Version: #{VERSION}\n"
        s << "OS:      #{os_name}\n"
        s << "\n"
        s << "Exception: #{ex.class}: #{ex.message}\n"
        s << "\nBacktrace:\n"
        if (bt = ex.backtrace) && !bt.empty?
          bt.each { |line| s << "  #{line}\n" }
        else
          s << "  (no backtrace)\n"
        end
        if cause = ex.cause
          s << "\nCaused by:\n"
          s << "  #{cause.class}: #{cause.message}\n"
          if (cbt = cause.backtrace) && !cbt.empty?
            cbt.first(30).each { |line| s << "    #{line}\n" }
          end
        end
      end
    end
  end
end
