require "./home_port"

module H2code
  # Single resolution point for h2code's per-user data directory — the place
  # config.json, ci.json, sessions, exceptions, caches and plugin state live.
  #
  # Resolution order:
  #   1. `H2CODE_HOME` env — portable installs, CI, subprocess-based specs
  #      (the env is the only channel a child process can be redirected
  #      through);
  #   2. `fallback` — the spec-suite seam: spec_helper points it at a
  #      per-run temp dir so no spec ever touches the real `~/.h2code`
  #      (a spec that saves a default Config had been wiping the
  #      developer's config.json this way);
  #   3. `~/.h2code` via HomePort — the default.
  #
  # Never resolve this path inline at call sites; a dozen copies of the
  # `ENV["H2CODE_HOME"]? || ~/.h2code` expression once drifted out of sync
  # with test isolation.
  module H2codeHome
    @@fallback : String? = nil

    # Test seam: used only when `H2CODE_HOME` is unset. Nil in production.
    def self.fallback : String?
      @@fallback
    end

    def self.fallback=(path : String?) : Nil
      @@fallback = path
    end

    def self.path : String
      ENV["H2CODE_HOME"]? || fallback || File.join(HomePort.home, ".h2code")
    end

    # Variant for call sites that received the user's home directory through
    # dependency injection (constructor argument): the H2CODE_HOME escape
    # hatch still wins, the injected home is the default. The spec-suite
    # `fallback` deliberately does NOT apply — an explicitly injected home is
    # already isolated by whoever injected it.
    def self.path_for(home_dir : String) : String
      ENV["H2CODE_HOME"]? || File.join(home_dir, ".h2code")
    end
  end
end
