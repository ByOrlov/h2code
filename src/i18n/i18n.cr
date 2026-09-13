require "i18n"

# Compile-time locale integrity guard: scripts/i18n_check.cr parses every
# locale YAML, checks key/placeholder parity with en.yml and duplicate keys.
# In "macro" mode the script always exits 0 (a non-zero exit would surface as
# a generic "Error executing run" without the report), so it prints "FAIL ..."
# instead and the raise below turns that into a compile error carrying the
# full report. The script re-runs on every compile, so edited locale files
# are always re-checked.
{% begin %}
  # Dot-relative on purpose: the compiler's `run` macro only treats "/"-prefixed
  # paths as absolute, so an absolute `__DIR__`-based path (e.g. "D:\...\src\i18n"
  # on Windows) falls through to a CRYSTAL_PATH lookup and fails. A "./" path is
  # resolved against this file's directory on every platform.
  {% report = run("./../../scripts/i18n_check.cr", "macro") %}
  {% if report.starts_with?("FAIL") %}{{ raise report }}{% end %}
{% end %}

# Embed each locale YAML as a compile-time string literal (via `read_file`).
# These live in the binary's read-only data segment — zero heap cost. At
# runtime only the active locale + "en" are parsed into the I18n catalog;
# the rest stay dormant in rodata until a language switch needs them.
#
# This replaces `I18n::Loader::YAML.embed`, which materialised all 10 locales
# as a single nested Hash in heap at startup (~1 MB). With lazy per-locale
# parsing, startup loads only 2 locales (~200 KB).
H2CODE_LOCALE_YAML_EN = {{ read_file("#{__DIR__}/locales/en.yml") }}
H2CODE_LOCALE_YAML_RU = {{ read_file("#{__DIR__}/locales/ru.yml") }}
H2CODE_LOCALE_YAML_ES = {{ read_file("#{__DIR__}/locales/es.yml") }}
H2CODE_LOCALE_YAML_ZH = {{ read_file("#{__DIR__}/locales/zh.yml") }}
H2CODE_LOCALE_YAML_JA = {{ read_file("#{__DIR__}/locales/ja.yml") }}
H2CODE_LOCALE_YAML_PT = {{ read_file("#{__DIR__}/locales/pt.yml") }}
H2CODE_LOCALE_YAML_HI = {{ read_file("#{__DIR__}/locales/hi.yml") }}
H2CODE_LOCALE_YAML_FA = {{ read_file("#{__DIR__}/locales/fa.yml") }}
H2CODE_LOCALE_YAML_UK = {{ read_file("#{__DIR__}/locales/uk.yml") }}
H2CODE_LOCALE_YAML_BE = {{ read_file("#{__DIR__}/locales/be.yml") }}

H2CODE_LOCALE_YAML_STRINGS = {
  "en" => H2CODE_LOCALE_YAML_EN,
  "ru" => H2CODE_LOCALE_YAML_RU,
  "es" => H2CODE_LOCALE_YAML_ES,
  "zh" => H2CODE_LOCALE_YAML_ZH,
  "ja" => H2CODE_LOCALE_YAML_JA,
  "pt" => H2CODE_LOCALE_YAML_PT,
  "hi" => H2CODE_LOCALE_YAML_HI,
  "fa" => H2CODE_LOCALE_YAML_FA,
  "uk" => H2CODE_LOCALE_YAML_UK,
  "be" => H2CODE_LOCALE_YAML_BE,
}

module H2code
  # `I18n` domain — interface translation layer.
  #
  # Wraps the `crystal-i18n` shard: locale YAML is embedded into the binary at
  # compile time (so there are no external files to ship), the active locale is
  # selected from config / env / system at startup, and the `#t` shortcut is
  # exposed app-wide as `H2code.t(...)`.
  #
  # Only the active locale + "en" are parsed into the catalog at startup. A
  # language switch (`/language`) lazy-loads the requested locale on first use.
  module I18n
    SUPPORTED_LOCALES = {"en", "ru", "es", "zh", "ja", "pt", "hi", "fa", "uk", "be"}

    @@initialized = false
    @@loaded_locales = Set(String).new

    # Initializes the I18n module and activates the given locale. Only the
    # requested locale + "en" are parsed into the catalog — the other locales
    # stay as dormant rodata strings until a language switch needs them.
    def self.init(locale : String = "en") : Nil
      unless @@initialized
        loc = SUPPORTED_LOCALES.includes?(locale) ? locale : "en"
        ::I18n.config.default_locale = :en
        add_locale_loader("en")
        add_locale_loader(loc) unless loc == "en"
        ::I18n.init
        @@initialized = true
        @@loaded_locales << "en"
        @@loaded_locales << loc unless loc == "en"
      end
      activate(locale)
    end

    # Activates a locale by name (e.g. "en", "ru"). Falls back to :en when the
    # requested locale is not supported. If the locale wasn't loaded at startup,
    # it is lazy-loaded here via a catalog re-init.
    def self.activate(locale : String) : Nil
      return unless @@initialized
      loc = SUPPORTED_LOCALES.includes?(locale) ? locale : "en"
      unless @@loaded_locales.includes?(loc)
        reinit_with_locale(loc)
      end
      # crystal-i18n keeps a per-fiber catalog (Fiber.current.i18n_catalog)
      # built lazily from config on first use in each fiber. Activating only
      # the current fiber would leave every fiber spawned later — each turn
      # runs in a fresh fiber that renders tool headers — on the old locale,
      # which is why a runtime /language switch didn't reach new tool entries.
      # Updating default_locale makes every lazily built catalog resolve to
      # the new locale; ::I18n.activate below covers the current fiber.
      ::I18n.config.default_locale = loc
      begin
        ::I18n.activate(loc)
      rescue ::I18n::Errors::InvalidLocale
        ::I18n.activate(:en)
      end
    end

    def self.available_locales : Array(String)
      SUPPORTED_LOCALES.to_a
    end

    # Translates a key with optional interpolation params. Returns the key
    # itself (rather than raising) when the translation is missing, so a bad
    # key never crashes the UI.
    def self.t(key : String, **kwargs) : String
      ::I18n.t!(key, **kwargs)
    rescue ::I18n::Errors::MissingTranslation
      key
    end

    def self.t(key : String, params : Hash | NamedTuple | Nil = nil) : String
      ::I18n.t!(key, params)
    rescue ::I18n::Errors::MissingTranslation
      key
    end

    # Resolves the locale to use, in priority order: explicit override, env
    # `H2CODE_LANG`, system `LANG`/`LC_ALL`, fallback "en".
    def self.resolve_locale(config_lang : String? = nil, env = ENV) : String
      if lang = config_lang
        return lang if SUPPORTED_LOCALES.includes?(lang)
      end
      if env_lang = env["H2CODE_LANG"]?
        resolved = parse_lang(env_lang)
        return resolved if SUPPORTED_LOCALES.includes?(resolved)
      end
      {"LC_ALL", "LC_MESSAGES", "LANG"}.each do |var|
        if val = env[var]?
          resolved = parse_lang(val)
          return resolved if SUPPORTED_LOCALES.includes?(resolved)
        end
      end
      "en"
    end

    # ------------------------------------------------------------------
    # Internal: locale loading
    # ------------------------------------------------------------------

    # Adds a loader for a single locale to `I18n.config.loaders` by parsing
    # the embedded YAML string at runtime.
    private def self.add_locale_loader(name : String) : Nil
      yaml = H2CODE_LOCALE_YAML_STRINGS[name]?
      return unless yaml
      translations = ::I18n::Loader::YAML.normalize_raw_translations([yaml])
      ::I18n.config.loaders << ::I18n::Loader::YAML.new(translations)
    end

    # Re-initializes the catalog with "en" + the new locale. Called on first
    # switch to a locale that wasn't loaded at startup.
    private def self.reinit_with_locale(name : String) : Nil
      ::I18n.config.loaders.clear
      add_locale_loader("en")
      add_locale_loader(name) unless name == "en"
      ::I18n.init
      @@loaded_locales = Set{"en", name}
    end

    private def self.parse_lang(raw : String) : String
      # Handles "ru", "ru_RU", "ru.UTF-8", "ru_RU.UTF-8".
      raw.split('.')[0].split('_')[0].downcase
    end
  end
end

# Top-level shortcut so call sites stay short: `H2code.t("status.done")`.
module H2code
  def self.t(key : String, **kwargs) : String
    I18n.t(key, **kwargs)
  end

  def self.t(key : String, params : Hash | NamedTuple | Nil = nil) : String
    I18n.t(key, params)
  end
end
