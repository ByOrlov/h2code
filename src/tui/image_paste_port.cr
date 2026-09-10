require "uri"
require "../tools/read_media"

module H2code
  module TUI
    # Media read from the system clipboard: either raw image bytes (a
    # screenshot-style clipboard) or a file path (a file copied in a file
    # manager). Mirrors the JS `ClipboardMedia` union from
    # `utils/clipboard/clipboard-image.ts`.
    struct ClipboardMedia
      enum Kind
        Image
        VideoFile
      end

      property kind : Kind
      # Image payload (Kind::Image only).
      property bytes : Bytes
      property mime : String
      # Source file path (Kind::VideoFile, and image files copied by path).
      property source_path : String?

      def self.image(bytes : Bytes, mime : String) : ClipboardMedia
        new(Kind::Image, bytes, mime, nil)
      end

      def self.video_file(path : String, mime : String) : ClipboardMedia
        new(Kind::VideoFile, Bytes.empty, mime, path)
      end

      def initialize(@kind : Kind, @bytes : Bytes, @mime : String, @source_path : String?)
      end

      def image? : Bool
        @kind.image?
      end

      def video_file? : Bool
        @kind.video_file?
      end
    end

    # Reads media (image bytes or copied media files) from the system
    # clipboard with graceful platform fallbacks. Port of the JS
    # `readClipboardMedia` lookup:
    #
    #   env override (H2CODE_CLIPBOARD_FILE) → read the file directly
    #   Linux Wayland → wl-paste --list-types / --type <mime>
    #   Linux X11     → xclip -selection clipboard -t TARGETS -o
    #   WSL           → powershell.exe Get-Image → temp PNG
    #   macOS         → osascript (JXA) file URLs
    #   Win32         → powershell Get-Image → temp PNG
    #
    # Returns nil when no supported media is available or every fallback
    # fails — never raises, so the paste key handler can silently no-op.
    #
    # The command runner is injectable (`runner`) so specs can emulate
    # wl-paste/xclip without a desktop clipboard.
    class ImagePastePort
      SUPPORTED_IMAGE_MIME = ["image/png", "image/jpeg", "image/webp", "image/gif"]

      LIST_TIMEOUT_MS = 1_000
      READ_TIMEOUT_MS = 3_000
      PS_TIMEOUT_MS   = 5_000
      MAX_READ_BYTES  = 50 * 1024 * 1024
      MAX_VIDEO_BYTES = 100 * 1024 * 1024

      VIDEO_MIME_BY_EXT = {
        ".mp4" => "video/mp4", ".mpg" => "video/mpeg", ".mpeg" => "video/mpeg",
        ".mkv" => "video/x-matroska", ".avi" => "video/x-msvideo",
        ".mov" => "video/quicktime", ".ogv" => "video/ogg",
        ".wmv" => "video/x-ms-wmv", ".webm" => "video/webm",
        ".m4v" => "video/x-m4v", ".flv" => "video/x-flv",
        ".3gp" => "video/3gpp", ".3g2" => "video/3gpp2",
      }

      alias Runner = String, Array(String), Int32 -> {Bool, Bytes}

      # Default runner: binary-safe shell-out with a hard timeout. Process.run
      # has no timeout parameter on this Crystal, so the child runs in a fiber
      # and the select abandons it (leaking until exit) once the deadline hits.
      def self.default_run(command : String, args : Array(String), timeout_ms : Int32) : {Bool, Bytes}
        channel = Channel({Bool, Bytes}).new
        spawn do
          out_io = IO::Memory.new
          begin
            status = Process.run(command, args, output: out_io, error: IO::Memory.new)
            channel.send({status.success?, out_io.to_slice.dup})
          rescue
            channel.send({false, Bytes.empty})
          end
        end
        select
        when result = channel.receive
          result
        when timeout(timeout_ms.milliseconds)
          {false, Bytes.empty}
        end
      end

      DEFAULT_RUNNER = ->ImagePastePort.default_run(String, Array(String), Int32)

      def initialize(@runner : Runner = DEFAULT_RUNNER)
      end

      def read_clipboard_media : ClipboardMedia?
        # Deterministic override for tests and demos: point the "clipboard"
        # at a file on disk.
        if path = ENV["H2CODE_CLIPBOARD_FILE"]?
          return read_media_path(path.strip)
        end

        {% if flag?(:linux) %}
          wayland = ENV["WAYLAND_DISPLAY"]? || ENV["XDG_SESSION_TYPE"]? == "wayland"
          wsl = wsl?

          if wayland || wsl
            file_media = read_file_media_via_wl_paste || read_file_media_via_xclip
            return file_media if file_media

            image = read_image_via_wl_paste || read_image_via_xclip
            image ||= read_image_via_powershell if wsl
            return validate_image(image)
          end

          unless wayland
            file_media = read_file_media_via_xclip
            return file_media if file_media
            return validate_image(read_image_via_xclip)
          end
          nil
        {% elsif flag?(:darwin) %}
          # File URLs via JXA first; image bytes need a native module in JS —
          # here we only support copied media files on macOS.
          read_media_from_paths(mac_file_paths)
        {% elsif flag?(:win32) %}
          validate_image(read_image_via_powershell_native)
        {% else %}
          nil
        {% end %}
      end

      # ------------------------------------------------------------------
      # Shared helpers
      # ------------------------------------------------------------------

      private def validate_image(image : ClipboardMedia?) : ClipboardMedia?
        return nil unless image
        return nil unless SUPPORTED_IMAGE_MIME.includes?(base_mime(image.mime))
        image
      end

      private def base_mime(raw : String) : String
        raw.split(';')[0]?.try(&.strip.downcase) || raw.downcase
      end

      private def run(command : String, args : Array(String), timeout_ms : Int32 = READ_TIMEOUT_MS) : {Bool, Bytes}
        @runner.call(command, args, timeout_ms)
      end

      # Run a child with extra env and a hard deadline; yields (success?,
      # captured stdout) to the block. Used by the PowerShell paths where the
      # runner isn't enough (env injection + success check on text output).
      private def run_with_env_timeout(command : String, args : Array(String),
                                       env : Hash(String, String)?, timeout_ms : Int32,
                                       &block : Bool, IO::Memory -> Bool) : Bool
        channel = Channel(Bool).new
        spawn do
          out_io = IO::Memory.new
          begin
            status = Process.run(command, args, output: out_io, error: IO::Memory.new, env: env)
            channel.send(block.call(status.success?, out_io))
          rescue
            channel.send(false)
          end
        end
        select
        when result = channel.receive
          result
        when timeout(timeout_ms.milliseconds)
          false
        end
      end

      private def run_text(command : String, args : Array(String), timeout_ms : Int32 = READ_TIMEOUT_MS) : String?
        ok, bytes = run(command, args, timeout_ms)
        return nil unless ok
        String.new(bytes)
      rescue
        nil
      end

      private def parse_target_list(output : String?) : Array(String)
        return [] of String if output.nil?
        output.split(/\r?\n/).map(&.strip).reject(&.empty?)
      end

      # Select the best image mime from advertised clipboard types, preferring
      # the pipeline's supported formats in a fixed order.
      private def select_image_mime(types : Array(String)) : String?
        normalized = types.map { |t| {t, base_mime(t)} }
        SUPPORTED_IMAGE_MIME.each do |preferred|
          match = normalized.find { |_, base| base == preferred }
          return match[0] if match
        end
        normalized.find { |_, base| base.starts_with?("image/") }.try(&.[0])
      end

      # ------------------------------------------------------------------
      # File-path reading (uri-list / osascript)
      # ------------------------------------------------------------------

      private def read_file_media_via_wl_paste : ClipboardMedia?
        list = run_text("wl-paste", ["--list-types"], LIST_TIMEOUT_MS)
        return nil unless list
        uri_type = parse_target_list(list).find { |t| base_mime(t) == "text/uri-list" }
        return nil unless uri_type
        uris = run_text("wl-paste", ["--type", uri_type, "--no-newline"])
        uris ? read_media_from_text(uris) : nil
      end

      private def read_file_media_via_xclip : ClipboardMedia?
        targets = run_text("xclip", ["-selection", "clipboard", "-t", "TARGETS", "-o"], LIST_TIMEOUT_MS)
        return nil unless targets
        candidates = parse_target_list(targets)
        uri_type = candidates.find { |t| base_mime(t) == "text/uri-list" }
        return nil unless uri_type
        uris = run_text("xclip", ["-selection", "clipboard", "-t", uri_type, "-o"])
        uris ? read_media_from_text(uris) : nil
      end

      private def read_media_from_text(text : String) : ClipboardMedia?
        read_media_from_paths(parse_clipboard_paths(text))
      end

      # Parse a uri-list payload into absolute file paths (file:// URIs
      # decoded, non-absolute and comment lines dropped).
      private def parse_clipboard_paths(text : String) : Array(String)
        text.split(/[\r\n\0]/).map(&.strip).reject do |line|
          line.empty? || line.starts_with?('#')
        end.map do |line|
          if line.starts_with?("file://")
            decode_file_uri(line)
          else
            line
          end
        end.reject do |path|
          path.empty? || !Path.new(path).absolute?
        end
      end

      private def decode_file_uri(uri : String) : String
        raw = uri[7..]
        decoded = URI.decode(raw)
        # A file:// URI may carry a host part before the path — strip it.
        decoded = "/#{decoded.split('/', 2)[1]?}" if decoded.includes?('/') && !decoded.starts_with?('/')
        decoded
      rescue
        ""
      end

      private def read_media_from_paths(paths : Array(String)) : ClipboardMedia?
        paths.each do |path|
          media = read_media_path(path)
          return media if media
        end
        nil
      end

      # Read one path as media: video by extension first (never opened as an
      # image), then sniffed image bytes.
      def read_media_path(path : String) : ClipboardMedia?
        if mime = video_mime_from_path(path)
          if File.file?(path)
            size = File.size(path)
            return nil if size == 0
            return ClipboardMedia.video_file(path, mime)
          end
        end

        return nil unless File.file?(path)
        bytes = File.open(path) do |f|
          header = Bytes.new(Math.min(f.size, 4096).to_i32)
          read = f.read(header)
          detected = Tools.detect_media_file_type(header[0, read])
          return nil unless detected.kind.image?
          f.seek(0)
          full = Bytes.new(f.size)
          read_full = f.read(full)
          read_full == f.size ? full : full[0, read_full]
        end
        return nil if bytes.empty? || bytes.size > MAX_READ_BYTES

        detected = Tools.detect_media_file_type(bytes[0, Math.min(bytes.size, 4096)])
        return nil unless detected.kind.image?
        mime = detected.mime_type
        return nil unless mime
        ClipboardMedia.image(bytes, mime)
      rescue
        nil
      end

      private def video_mime_from_path(path : String) : String?
        ext = File.extname(path).downcase
        VIDEO_MIME_BY_EXT[ext]?
      end

      # ------------------------------------------------------------------
      # Image-bytes reading (wl-paste / xclip / powershell)
      # ------------------------------------------------------------------

      private def read_image_via_wl_paste : ClipboardMedia?
        list = run_text("wl-paste", ["--list-types"], LIST_TIMEOUT_MS)
        return nil unless list
        selected = select_image_mime(parse_target_list(list))
        return nil unless selected

        ok, bytes = run("wl-paste", ["--type", selected, "--no-newline"])
        return nil unless ok
        return nil if bytes.empty?
        clipboard_image(bytes, base_mime(selected))
      end

      private def read_image_via_xclip : ClipboardMedia?
        targets = run_text("xclip", ["-selection", "clipboard", "-t", "TARGETS", "-o"], LIST_TIMEOUT_MS)
        candidates = targets ? parse_target_list(targets) : [] of String
        preferred = candidates.empty? ? nil : select_image_mime(candidates)

        try_types = SUPPORTED_IMAGE_MIME.dup
        try_types.unshift(preferred) if preferred
        try_types.each do |mime|
          ok, bytes = run("xclip", ["-selection", "clipboard", "-t", mime, "-o"])
          next if !ok || bytes.empty?
          # xclip serves whatever it holds for an unmatched target request:
          # a text clipboard returns its text under `-t image/png` too. Sniff
          # the payload and only accept it when it really is the image
          # format we asked for (integration spec covers this).
          image = clipboard_image(bytes, base_mime(mime))
          return image if image
        end
        nil
      end

      # Validate raw clipboard bytes as the requested image mime; nil when
      # the payload doesn't sniff as that image format.
      private def clipboard_image(bytes : Bytes, mime : String) : ClipboardMedia?
        detected = Tools.detect_media_file_type(bytes[0, Math.min(bytes.size, 4096)])
        return nil unless detected.kind.image?
        detected_mime = detected.mime_type
        return nil if detected_mime.nil?
        return nil unless detected_mime == mime
        ClipboardMedia.image(bytes, detected_mime)
      end

      # Windows clipboard images (Win+Shift+S) don't bridge into the WSL
      # Linux clipboard. PowerShell reaches the Windows clipboard directly;
      # we round-trip via a temp PNG because binary stdout is unreliable
      # across the WSL interop boundary.
      private def read_image_via_powershell : ClipboardMedia?
        tmp = File.tempname("h2code-clip", ".png")
        win_path = run_text("wslpath", ["-w", tmp], LIST_TIMEOUT_MS)
        return nil if win_path.nil? || win_path.strip.empty?

        ps_script = [
          "Add-Type -AssemblyName System.Windows.Forms",
          "Add-Type -AssemblyName System.Drawing",
          "$path = $env:H2CODE_CLIPBOARD_IMAGE_PATH",
          "$img = [System.Windows.Forms.Clipboard]::GetImage()",
          "if ($img) { $img.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); Write-Output 'ok' } else { Write-Output 'empty' }",
        ].join("; ")

        env = {"H2CODE_CLIPBOARD_IMAGE_PATH" => win_path.strip}
        begin
          ok = run_with_env_timeout("powershell.exe", ["-NoProfile", "-Command", ps_script],
            env, PS_TIMEOUT_MS) do |status, output|
            status && output.to_s.strip == "ok"
          end

          return nil unless ok && File.exists?(tmp) && File.size(tmp) > 0
          bytes = Bytes.new(File.size(tmp))
          File.open(tmp) { |f| f.read(bytes) }
          ClipboardMedia.image(bytes, "image/png")
        ensure
          File.delete?(tmp)
        end
      end

      # Win32 native: same PowerShell dance without the wslpath hop.
      private def read_image_via_powershell_native : ClipboardMedia?
        tmp = File.tempname("h2code-clip", ".png")
        ps_script = [
          "Add-Type -AssemblyName System.Windows.Forms",
          "Add-Type -AssemblyName System.Drawing",
          "$path = '#{tmp.gsub('\'', "''")}'",
          "$img = [System.Windows.Forms.Clipboard]::GetImage()",
          "if ($img) { $img.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); Write-Output 'ok' } else { Write-Output 'empty' }",
        ].join("; ")

        begin
          ok = run_with_env_timeout("powershell", ["-NoProfile", "-Command", ps_script],
            nil, PS_TIMEOUT_MS) do |status, output|
            status && output.to_s.strip == "ok"
          end
          return nil unless ok

          return nil unless File.exists?(tmp) && File.size(tmp) > 0
          bytes = Bytes.new(File.size(tmp))
          File.open(tmp) { |f| f.read(bytes) }
          ClipboardMedia.image(bytes, "image/png")
        ensure
          File.delete?(tmp)
        end
      end

      private def wsl? : Bool
        return true if ENV["WSL_DISTRO_NAME"]? || ENV["WSLENV"]?
        version = File.read("/proc/version") rescue nil
        !!(version =~ /microsoft|wsl/i)
      rescue
        false
      end

      # macOS: file URLs from the pasteboard via JXA (port of
      # MACOS_FILE_PATH_SCRIPT). Image bytes are not read natively here.
      private def mac_file_paths : Array(String)
        script = <<-JXA
          ObjC.import('AppKit');
          ObjC.import('Foundation');
          const out = [];
          const pb = $.NSPasteboard.generalPasteboard;
          if (String(pb) !== '[id nil]') {
            try {
              const options = $.NSMutableDictionary.dictionary;
              options.setObjectForKey($.NSNumber.numberWithBool(true), $.NSPasteboardURLReadingFileURLsOnlyKey);
              const urls = pb.readObjectsForClassesOptions([$.NSURL], options);
              const count = urls ? urls.count : 0;
              for (let i = 0; i < count; i++) {
                const value = urls.objectAtIndex(i).path;
                const path = value ? ObjC.unwrap(value) : '';
                if (path) out.push(path);
              }
            } catch (error) {}
          }
          out.join('\\n');
          JXA
        result = run_text("osascript", ["-l", "JavaScript", "-e", script], LIST_TIMEOUT_MS)
        result ? parse_clipboard_paths(result) : [] of String
      end
    end
  end
end
