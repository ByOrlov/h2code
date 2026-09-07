require "json"

# Startup tips ("советы") — short one-liners shown under the welcome box at
# startup, rendered in the active-zone green with a `│` bar (no indent).
#
# Tips are DATA, not code: they live as JSON files on disk, one per locale
# (`en.json`, `ru.json`, …), each an array of `{"code": …, "text": …}`
# objects. They are never compiled into the binary, so they can be edited,
# extended or translated without a rebuild. `rake tips:check` (see
# scripts/tips_check.cr) validates that every locale file carries the same
# set of tip codes.
#
# Lookup order for the tips directory:
#   1. `$H2CODE_HOME/tips` (default `~/.h2code/tips`) — the install location
#      next to config.json, written by install.sh / install.ps1;
#   2. `tips/` next to the executable (dev checkout: binary in repo root);
#   3. `tips/` in the current directory (covers `crystal run` / rake).
# Locale fallback: `<locale>.json`, then `en.json`. Any missing or malformed
# file is silently skipped — the tip is cosmetic and must never break startup.
module H2code
  module Tips
    struct Tip
      getter code : String
      getter text : String

      def initialize(@code : String, @text : String)
      end
    end

    # Candidate tips directories, most specific first.
    def self.search_dirs : Array(String)
      dirs = [] of String
      home = ENV["H2CODE_HOME"]? || File.join(HomePort.home, ".h2code")
      dirs << File.join(home, "tips")
      if exe = Process.executable_path
        dirs << File.join(File.dirname(exe), "tips")
      end
      dirs << File.join(Dir.current, "tips")
      dirs.uniq!
    end

    # Loads tips for a locale (falls back to "en"). Returns nil when no valid
    # tips file exists anywhere.
    def self.load(locale : String, dirs : Array(String) = search_dirs) : Array(Tip)?
      dirs.each do |dir|
        if tips = read_tips(File.join(dir, "#{locale}.json"))
          return tips
        end
        if tips = read_tips(File.join(dir, "en.json"))
          return tips
        end
      end
      nil
    end

    # A random tip text for the locale, or nil when tips are unavailable.
    def self.random_tip(locale : String, dirs : Array(String) = search_dirs) : String?
      tips = load(locale, dirs)
      return nil if tips.nil? || tips.empty?
      tips.sample.text
    end

    private def self.read_tips(path : String) : Array(Tip)?
      return nil unless File.exists?(path)
      entries = JSON.parse(File.read(path)).as_a
      tips = entries.map do |entry|
        obj = entry.as_h
        Tip.new(obj["code"]?.try(&.as_s.to_s) || "", obj["text"]?.try(&.as_s.to_s) || "")
      end
      # Entries without a code or text are malformed — skip the whole file
      # only when nothing usable remains.
      tips = tips.reject { |t| t.code.empty? || t.text.empty? }
      tips.empty? ? nil : tips
    rescue
      nil
    end
  end
end
