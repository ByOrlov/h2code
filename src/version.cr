module H2code
  # Rolling-release version: "YYYY.MM.DD.N" releases (e.g. "2026.07.31.1")
  # or post-commit auto-tags "YYYY.MM.DD-<secs>" (e.g. "2026.09.11-53466").
  # Set at build time via the H2CODE_VERSION env var (CI injects the git tag;
  # Rake tasks resolve it from `git describe --tags` for local builds).
  # Builds without the var fall back to "0.0.0-dev".
  VERSION = {{ (env("H2CODE_VERSION") || "0.0.0-dev") }}
  # Build timestamp. Crystal has no compile-time -D flag like C, so we read
  # it from the SOURCE_DATE_EPOCH env var at build time when present (repro
  # builds set this); otherwise fall back to "dev".
  BUILD_DATE = (::ENV["SOURCE_DATE_EPOCH"]?).try { |s| Time.unix(s.to_i).to_s("%Y-%m-%d") } || "dev"

  # Compile-time OS identity — the single source of truth for "which system
  # is this build for". Replaces the former `uname -s` shell spawn (no shell
  # is guaranteed to exist on Windows, and spawning one from a crash handler
  # is a liability on every platform).
  OS_NAME = {% if flag?(:linux) %}
              "Linux"
            {% elsif flag?(:darwin) %}
              "macOS"
            {% elsif flag?(:win32) %}
              "Windows"
            {% else %}
              "Unknown"
            {% end %}

  def self.build_date : String?
    BUILD_DATE == "dev" ? nil : BUILD_DATE
  end
end
