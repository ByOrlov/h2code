require "http/client"
require "file_utils"
require "json"

module H2code
  # Self-update: downloads the latest GitHub release asset that matches the
  # current binary's target and replaces the running executable in place.
  # Triggered by the `/upgrade` TUI command.
  module Upgrader
    REPO = "ByOrlov/H2Code"

    # Minimum interval between background update checks.
    CHECK_INTERVAL = 24.hours

    # Injectable so specs can stub the network. Returns the raw response body.
    @@http_get : Proc(String, String) = ->(url : String) { real_http_get(url) }

    def self.http_get : Proc(String, String)
      @@http_get
    end

    def self.http_get=(proc : Proc(String, String))
      @@http_get = proc
    end

    # Injectable so specs can control the clock.
    @@now : Proc(Time) = -> { Time.utc }

    def self.now : Proc(Time)
      @@now
    end

    def self.now=(proc : Proc(Time))
      @@now = proc
    end

    # Asset name for the binary's own platform, baked at compile time.
    def self.asset_name : String
      os = {{ flag?(:darwin) ? "darwin" : flag?(:win32) ? "windows" : "linux" }}
      arch = {{ flag?(:aarch64) ? "aarch64" : "x86_64" }}
      ext = {{ flag?(:win32) ? "zip" : "tar.gz" }}
      "h2code-#{arch}-#{os}.#{ext}"
    end

    def self.current_version : String
      H2code::VERSION
    end

    # Returns the latest release tag (e.g. "2026.07.31.3"), or nil on error.
    def self.latest_version : String?
      body = @@http_get.call("https://api.github.com/repos/#{REPO}/releases/latest")
      json = JSON.parse(body)
      json["tag_name"]?.try(&.as_s)
    rescue ex
      nil
    end

    # --- Background update check with 24h cache --------------------------------

    # Path to the cache file storing the timestamp of the last check.
    private def self.cache_file_path : String
      home = HomePort.home
      h2code_home = ENV["H2CODE_HOME"]? || File.join(home, ".h2code")
      File.join(h2code_home, "update_check.json")
    end

    # Injectable so specs can point at a temp file.
    @@cache_path : Proc(String) = -> { cache_file_path }

    def self.cache_path : Proc(String)
      @@cache_path
    end

    def self.cache_path=(proc : Proc(String))
      @@cache_path = proc
    end

    # Returns true if no check has been performed in the last `CHECK_INTERVAL`.
    def self.should_check? : Bool
      data = read_cache
      return true unless data
      checked_at = data["checked_at"]?
      return true unless checked_at
      last = Time.parse_rfc3339(checked_at.as_s)
      @@now.call - last >= CHECK_INTERVAL
    rescue
      true
    end

    # Persists the current timestamp (and latest version) to the cache file.
    def self.record_check(latest : String?) : Nil
      data = {
        "checked_at" => JSON::Any.new(@@now.call.to_rfc3339),
        "latest"     => latest ? JSON::Any.new(latest) : JSON::Any.new(nil),
      } of String => JSON::Any
      dir = File.dirname(@@cache_path.call)
      Dir.mkdir_p(dir) rescue nil
      File.write(@@cache_path.call, data.to_json)
    rescue
      # Cache write failure is non-fatal — next startup will just re-check.
    end

    # Reads and parses the cache file. Returns nil on any error.
    private def self.read_cache : JSON::Any?
      path = @@cache_path.call
      return nil unless File.exists?(path)
      JSON.parse(File.read(path))
    rescue
      nil
    end

    # Background check entry point: returns a notification message if a newer
    # version is available, or nil. Respects the 24h cache so most startups
    # are a no-op. Always records the timestamp when it actually hits the network.
    def self.background_check : String?
      return nil unless should_check?
      latest = latest_version
      record_check(latest)
      return nil if latest.nil?
      return nil unless VersionCompare.newer?(latest, current_version)
      H2code.t("ui.upgrade_available", current: current_version, latest: latest)
    end

    # Runs the full check → download → replace flow.
    # Returns a human-readable status message; success is reflected in the
    # first element of the returned tuple.
    def self.run : {Bool, String}
      latest = latest_version
      if latest.nil?
        return {false, H2code.t("ui.upgrade_fetch_failed")}
      end

      if !VersionCompare.newer?(latest, current_version)
        return {true, H2code.t("ui.upgrade_uptodate", version: current_version)}
      end

      asset = asset_name
      url = "https://github.com/#{REPO}/releases/latest/download/#{asset}"
      begin
        data = @@http_get.call(url)
      rescue ex
        return {false, H2code.t("ui.upgrade_download_failed", error: ex.message || ex.to_s)}
      end

      begin
        replace_binary(data)
      rescue ex
        return {false, H2code.t("ui.upgrade_install_failed", error: ex.message || ex.to_s)}
      end

      {true, H2code.t("ui.upgrade_done", version: latest)}
    end

    # --- Binary replacement -------------------------------------------------

    private def self.replace_binary(archive_bytes : String) : Nil
      cur = current_executable
      tmp_dir = make_staging_dir(cur)

      begin
        archive_name = asset_name
        archive_path = File.join(tmp_dir, archive_name)
        File.write(archive_path, archive_bytes)

        # Extract: tar handles both .tar.gz and .zip on modern systems.
        bin_name = {{ flag?(:win32) ? "h2code.exe" : "h2code" }}
        if archive_name.ends_with?(".zip")
          # Windows: use built-in tar (Windows 10 1803+) which reads zip.
          run_shell("tar -xf #{Process.quote(archive_path)} -C #{Process.quote(tmp_dir)}")
        else
          run_shell("tar -xzf #{Process.quote(archive_path)} -C #{Process.quote(tmp_dir)}")
        end

        new_bin = File.join(tmp_dir, bin_name)
        unless File.exists?(new_bin)
          raise "extracted binary not found at #{new_bin}"
        end

        {% if flag?(:win32) %}
          # Windows cannot overwrite a running .exe — move the old one aside.
          old = cur + ".old"
          File.delete(old) if File.exists?(old)
          File.rename(cur, old)
          move_across_fs(new_bin, cur)
        {% else %}
          # Unix: rename over the running binary (inode stays valid for the
          # active process; new invocations pick up the new file). Renaming
          # is allowed; only opening the live binary for write is not.
          File.chmod(new_bin, 0o755)
          move_across_fs(new_bin, cur)
        {% end %}
      ensure
        FileUtils.rm_rf(tmp_dir)
      end
    end

    # Stages the upgrade next to the running binary so the final replace is an
    # atomic rename within one filesystem. A cross-filesystem rename fails with
    # EXDEV, and the copy fallback would open the running binary for write,
    # which the kernel rejects with ETXTBSY ("Text file busy"). Falls back to
    # the system temp dir only when the install dir is not writable (e.g. a
    # read-only /usr/local/bin), where the rename-aside path in
    # `move_across_fs` keeps the update working.
    private def self.make_staging_dir(target : String) : String
      dst_dir = File.dirname(target)
      candidate = File.join(dst_dir, ".h2code-upgrade-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(candidate)
      candidate
    rescue ex : File::Error
      candidate = File.join(Dir.tempdir, "h2code-upgrade-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(candidate)
      candidate
    end

    def self.current_executable : String
      {% if flag?(:linux) %}
        File.readlink("/proc/self/exe")
      {% else %}
        File.realpath(PROGRAM_NAME)
      {% end %}
    rescue
      PROGRAM_NAME
    end

    private def self.run_shell(cmd : String) : Nil
      status = Process.run(cmd, shell: true, output: Process::Redirect::Close, error: Process::Redirect::Inherit)
      raise "extraction command failed: #{cmd}" unless status.success?
    end

    # Moves src to dst, transparently crossing filesystem boundaries.
    # File.rename fails with EXDEV when src and dst live on different mounts
    # (e.g. staging dir vs /usr/local/bin). The naive copy fallback would open
    # dst for write — but dst may be the running binary, which the kernel
    # refuses with ETXTBSY. So before copying, we move dst aside via a same-fs
    # rename (allowed even for a running executable), then copy, then delete
    # the moved-aside file. Its inode stays alive for the current process.
    private def self.move_across_fs(src : String, dst : String) : Nil
      File.rename(src, dst)
    rescue ex : File::Error
      raise ex unless ex.os_error == Errno::EXDEV

      aside = nil.as(String?)
      begin
        if File.exists?(dst)
          aside = File.join(File.dirname(dst), ".#{File.basename(dst)}.old-#{Random::Secure.hex(2)}")
          File.rename(dst, aside)
        end
        File.copy(src, dst)
        File.chmod(dst, 0o755)
        File.delete(src)
      ensure
        File.delete(aside) if aside && File.exists?(aside)
      end
    end

    # Real HTTP GET — follows redirects, returns the body as a string.
    private def self.real_http_get(url : String) : String
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.tls.verify_mode = OpenSSL::SSL::VerifyMode::PEER if uri.scheme == "https"
      response = client.get(uri.request_target)
      if (300..399).includes?(response.status_code)
        location = response.headers["Location"]?
        client.close
        raise "redirect without Location" unless location
        return real_http_get(location)
      end
      raise "HTTP #{response.status_code}" unless response.status.success?
      body = response.body
      client.close
      body
    end
  end
end
