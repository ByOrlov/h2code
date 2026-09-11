module H2code
  # Compares rolling-release version strings: "YYYY.MM.DD.N" releases and
  # post-commit auto-tags "YYYY.MM.DD-<secs since day begin>" (with optional
  # .N same-second collision suffix). Returns negative if a < b, zero if
  # equal, positive if a > b. Missing segments are treated as 0, so
  # "2026.07.31" sorts before "2026.07.31.1". Within one day an auto-tag
  # sorts after the bare date but before any .N release; auto-tags order
  # chronologically by their seconds component.
  module VersionCompare
    def self.compare(a : String, b : String) : Int32
      pa = parse(a)
      pb = parse(b)
      pa <=> pb
    end

    def self.newer?(candidate : String, current : String) : Bool
      compare(candidate, current) > 0
    end

    private def self.parse(v : String) : {Int32, Int32, Int32, Int32, Int32}
      secs = 0
      main = v
      if dash = v.index('-')
        main = v[0, dash]
        rest = v[(dash + 1)..]
        secs = rest.split('.').first?.try(&.to_i?) || 0
      end
      parts = main.split('.').map { |s| s.to_i? || 0 }
      {
        parts[0]? || 0, parts[1]? || 0, parts[2]? || 0, parts[3]? || 0, secs,
      }
    end
  end
end
