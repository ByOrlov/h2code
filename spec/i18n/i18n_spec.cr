require "../spec_helper"
require "yaml"

def collect_keys(hash, prefix = "") : Array(String)
  keys = [] of String
  hash.each do |k, v|
    full_key = prefix.empty? ? k.to_s : "#{prefix}.#{k}"
    if v.is_a?(Hash)
      keys.concat(collect_keys(v, full_key))
    else
      keys << full_key
    end
  end
  keys
end

describe H2code::I18n do
  describe "locale files" do
    locale_dir = File.join(__DIR__, "..", "..", "src", "i18n", "locales")

    it "contains en.yml and ru.yml" do
      File.exists?(File.join(locale_dir, "en.yml")).should be_true
      File.exists?(File.join(locale_dir, "ru.yml")).should be_true
    end

    it "has parity between en and ru keys" do
      en_data = YAML.parse(File.read(File.join(locale_dir, "en.yml"))).as_h["en"].as_h
      ru_data = YAML.parse(File.read(File.join(locale_dir, "ru.yml"))).as_h["ru"].as_h

      en_keys = collect_keys(en_data).sort
      ru_keys = collect_keys(ru_data).sort

      missing_in_ru = en_keys - ru_keys
      missing_in_en = ru_keys - en_keys

      missing_in_ru.should be_empty, "Keys missing in ru.yml: #{missing_in_ru.inspect}"
      missing_in_en.should be_empty, "Keys missing in en.yml: #{missing_in_en.inspect}"
    end

    it "places the /cleanup keys under ui: and commands: in every locale" do
      ui_keys = {"select_cleanup", "cleanup_period_week", "cleanup_period_month",
                 "cleanup_period_6months", "cleanup_period_year", "cleanup_usage",
                 "cleanup_unknown_period", "cleanup_running", "cleanup_done",
                 "cleanup_skipped", "cleanup_word_sessions", "cleanup_word_voice"}
      Dir.glob(File.join(locale_dir, "*.yml")).each do |path|
        locale = File.basename(path, ".yml")
        data = YAML.parse(File.read(path)).as_h[locale].as_h
        ui = data["ui"]?.try(&.as_h) || Hash(YAML::Any, YAML::Any).new
        ui.should_not be_empty, "#{locale}: no ui section"
        ui_keys.each do |k|
          ui.has_key?(k).should be_true, "#{locale}: missing ui.#{k}"
        end
        commands = data["commands"]?.try(&.as_h) || Hash(YAML::Any, YAML::Any).new
        commands.should_not be_empty, "#{locale}: no commands section"
        commands.has_key?("cleanup").should be_true, "#{locale}: missing commands.cleanup"
      end
    end
  end

  describe ".resolve_locale" do
    it "returns config language when supported" do
      H2code::I18n.resolve_locale("ru").should eq("ru")
      H2code::I18n.resolve_locale("en").should eq("en")
    end

    it "falls back when config language is unsupported" do
      H2code::I18n.resolve_locale("fr", {"LANG" => "en_US"}).should eq("en")
    end

    it "reads H2CODE_LANG env" do
      env = {"H2CODE_LANG" => "ru"}
      H2code::I18n.resolve_locale(nil, env).should eq("ru")
    end

    it "parses LANG with region and encoding" do
      H2code::I18n.resolve_locale(nil, {"LANG" => "ru_RU.UTF-8"}).should eq("ru")
      H2code::I18n.resolve_locale(nil, {"LANG" => "en_US.UTF-8"}).should eq("en")
    end

    it "defaults to en for unsupported system locale" do
      H2code::I18n.resolve_locale(nil, {"LANG" => "fr_FR.UTF-8"}).should eq("en")
    end

    it "defaults to en with no env" do
      H2code::I18n.resolve_locale(nil, {} of String => String).should eq("en")
    end
  end

  describe ".available_locales" do
    it "includes en and ru" do
      locales = H2code::I18n.available_locales
      locales.should contain("en")
      locales.should contain("ru")
    end
  end

  describe ".t" do
    it "translates keys after init" do
      H2code::I18n.init("en")
      H2code.t("status.turn_complete").should eq("Turn complete")

      H2code::I18n.activate("ru")
      H2code.t("status.turn_complete").should eq("Ход завершён")
    end

    it "propagates a runtime locale switch to fibers spawned later" do
      # crystal-i18n builds a per-fiber catalog lazily from config; a runtime
      # /language switch must update config.default_locale so every future
      # fiber (each turn runs in a fresh one) resolves the new locale.
      H2code::I18n.init("en")
      H2code::I18n.activate("ru")

      ch = Channel(String).new
      spawn { ch.send H2code.t("tools.used") }
      ch.receive.should eq("Использовал")
    end

    it "returns the key for missing translations" do
      H2code::I18n.init("en")
      H2code.t("nonexistent.key").should eq("nonexistent.key")
    end

    it "interpolates params" do
      H2code::I18n.init("en")
      H2code.t("errors.generic", message: "boom").should eq("Error: boom")
    end

    it "resolves the /cleanup picker keys instead of returning them raw" do
      H2code::I18n.init("en")
      H2code.t("ui.select_cleanup").should_not eq("ui.select_cleanup")
      H2code.t("ui.cleanup_period_week").should_not eq("ui.cleanup_period_week")
      H2code.t("ui.cleanup_period_6months").should_not eq("ui.cleanup_period_6months")
      H2code.t("ui.cleanup_word_sessions").should_not eq("ui.cleanup_word_sessions")
    end
  end
end
