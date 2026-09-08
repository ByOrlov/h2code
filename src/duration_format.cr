# Formats durations as compact clock-style strings for UI lines.
module DurationFormat
  # "mm:ss" under an hour, "hh:mm:ss" from an hour up:
  # 0 -> "00:00", 45 -> "00:45", 125 -> "02:05", 3725 -> "01:02:05".
  def self.hms(total_seconds : Int) : String
    total_seconds = total_seconds.clamp(0..)
    h = total_seconds // 3600
    m = (total_seconds % 3600) // 60
    s = total_seconds % 60
    if h > 0
      "#{h.to_s.rjust(2, '0')}:#{m.to_s.rjust(2, '0')}:#{s.to_s.rjust(2, '0')}"
    else
      "#{m.to_s.rjust(2, '0')}:#{s.to_s.rjust(2, '0')}"
    end
  end
end
