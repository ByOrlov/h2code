require "spec"
require "file_utils"
require "../src/version"
require "../src/version_compare"
require "../src/home_port"
require "../src/i18n/i18n"
require "../src/upgrader"

H2code::I18n.init("en")

describe H2code::Upgrader do
  describe ".asset_name" do
    it "returns a non-empty asset name matching the platform pattern" do
      name = H2code::Upgrader.asset_name
      name.should match(/^h2code-(x86_64|aarch64)-(linux|darwin|windows)\.(tar\.gz|zip)$/)
    end
  end

  describe ".current_version" do
    it "returns the compile-time VERSION constant" do
      H2code::Upgrader.current_version.should eq(H2code::VERSION)
    end
  end

  describe ".run" do
    original = H2code::Upgrader.http_get

    after_each do
      H2code::Upgrader.http_get = original
    end

    it "reports up-to-date when latest equals current" do
      H2code::Upgrader.http_get = ->(url : String) {
        if url.includes?("/releases/latest")
          %({"tag_name": "#{H2code::VERSION}"})
        else
          ""
        end
      }
      ok, msg = H2code::Upgrader.run
      ok.should be_true
      msg.should contain(H2code::VERSION)
    end

    it "reports failure when GitHub API is unreachable" do
      H2code::Upgrader.http_get = ->(_url : String) {
        raise "network error"
      }
      ok, msg = H2code::Upgrader.run
      ok.should be_false
      msg.should_not be_empty
    end
  end

  describe "binary replacement" do
    original_http = H2code::Upgrader.http_get

    after_each do
      H2code::Upgrader.http_get = original_http
      H2code::Upgrader.current_executable = nil
    end

    it "installs bundled dylibs next to the upgraded binary" do
      tmp = File.join(Dir.tempdir, "h2code-upgrader-spec-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(tmp)
      target = File.join(tmp, "h2code")
      File.write(target, "old-bin")
      File.chmod(target, 0o755)

      # Fake release archive: h2code + a bundled dylib at the top level,
      # mirroring the macOS rebind_dylibs.sh layout.
      stage = File.join(tmp, "stage")
      Dir.mkdir_p(stage)
      File.write(File.join(stage, "h2code"), "new-bin")
      File.write(File.join(stage, "libssl.3.dylib"), "fake-dylib")
      archive = File.join(tmp, H2code::Upgrader.asset_name)
      status = Process.run(
        "tar -czf #{Process.quote(archive)} -C #{Process.quote(stage)} .",
        shell: true, output: Process::Redirect::Close, error: Process::Redirect::Close)
      status.success?.should be_true

      H2code::Upgrader.current_executable = target
      H2code::Upgrader.http_get = ->(url : String) {
        if url.includes?("/releases/latest/download/")
          File.read(archive)
        else
          %({"tag_name": "9999.99.99.99"})
        end
      }

      ok, _msg = H2code::Upgrader.run
      ok.should be_true
      File.read(target).should eq("new-bin")
      File.read(File.join(tmp, "libssl.3.dylib")).should eq("fake-dylib")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe ".latest_version" do
    it "parses tag_name from the GitHub releases JSON" do
      H2code::Upgrader.http_get = ->(_url : String) {
        %({"tag_name": "2026.07.31.3", "name": "2026.07.31.3"})
      }
      H2code::Upgrader.latest_version.should eq("2026.07.31.3")
    end

    it "returns nil on malformed JSON" do
      H2code::Upgrader.http_get = ->(_url : String) { "not json" }
      H2code::Upgrader.latest_version.should be_nil
    end
  end

  describe "update-check cache" do
    original_http = H2code::Upgrader.http_get
    original_now = H2code::Upgrader.now
    original_cache = H2code::Upgrader.cache_path
    tmp_dir = File.join(Dir.tempdir, "h2code-spec-#{Random::Secure.hex(4)}")

    after_each do
      H2code::Upgrader.http_get = original_http
      H2code::Upgrader.now = original_now
      H2code::Upgrader.cache_path = original_cache
      FileUtils.rm_rf(tmp_dir) if Dir.exists?(tmp_dir)
    end

    it "should_check? returns true when no cache file exists" do
      H2code::Upgrader.cache_path = -> { File.join(tmp_dir, "missing.json") }
      H2code::Upgrader.should_check?.should be_true
    end

    it "should_check? returns false within 24 hours" do
      path = File.join(tmp_dir, "recent.json")
      Dir.mkdir_p(tmp_dir)
      recent = (Time.utc - 1.hour).to_rfc3339
      File.write(path, %({"checked_at": "#{recent}", "latest": "1.0.0"}))
      H2code::Upgrader.cache_path = -> { path }
      H2code::Upgrader.should_check?.should be_false
    end

    it "should_check? returns true after 24 hours" do
      path = File.join(tmp_dir, "stale.json")
      Dir.mkdir_p(tmp_dir)
      stale = (Time.utc - 25.hours).to_rfc3339
      File.write(path, %({"checked_at": "#{stale}", "latest": "1.0.0"}))
      H2code::Upgrader.cache_path = -> { path }
      H2code::Upgrader.should_check?.should be_true
    end

    it "record_check writes a valid timestamp to the cache file" do
      path = File.join(tmp_dir, "written.json")
      Dir.mkdir_p(tmp_dir)
      fixed_time = Time.utc(2026, 1, 15, 12, 0, 0)
      H2code::Upgrader.cache_path = -> { path }
      H2code::Upgrader.now = -> { fixed_time }
      H2code::Upgrader.record_check("9.9.9")
      File.exists?(path).should be_true
      json = JSON.parse(File.read(path))
      json["checked_at"].as_s.should eq(fixed_time.to_rfc3339)
      json["latest"].as_s.should eq("9.9.9")
    end

    it "background_check returns nil and skips network when cache is fresh" do
      path = File.join(tmp_dir, "fresh_bg.json")
      Dir.mkdir_p(tmp_dir)
      recent = (Time.utc - 1.hour).to_rfc3339
      File.write(path, %({"checked_at": "#{recent}", "latest": "1.0.0"}))
      H2code::Upgrader.cache_path = -> { path }
      network_called = false
      H2code::Upgrader.http_get = ->(_url : String) { network_called = true; "" }
      H2code::Upgrader.background_check.should be_nil
      network_called.should be_false
    end

    it "background_check returns notification when newer version available" do
      path = File.join(tmp_dir, "notify.json")
      Dir.mkdir_p(tmp_dir)
      H2code::Upgrader.cache_path = -> { path }
      H2code::Upgrader.http_get = ->(_url : String) {
        %({"tag_name": "9999.99.99.99"})
      }
      result = H2code::Upgrader.background_check
      result.should_not be_nil
      (result || "").should contain("9999.99.99.99")
      # Cache file should have been written.
      File.exists?(path).should be_true
    end

    it "background_check returns nil when already up-to-date" do
      path = File.join(tmp_dir, "uptodate.json")
      Dir.mkdir_p(tmp_dir)
      H2code::Upgrader.cache_path = -> { path }
      H2code::Upgrader.http_get = ->(_url : String) {
        %({"tag_name": "#{H2code::VERSION}"})
      }
      H2code::Upgrader.background_check.should be_nil
    end
  end
end
