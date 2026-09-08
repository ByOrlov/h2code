require "base64"

module H2code
  module Tools
    # ReadMediaFile — чтение image/video файла как base64 data URL.
    #
    # Контракты перенесены 1:1 из
    # `packages/agent-core-v2/src/agent/media/tools/read-media.ts`.
    #
    # Тул регистрируется только для моделей с image_in или video_in.
    #
    # См. детальный план портирования в `md-tools/read-media-file.md`.
    module Media
      MAX_MEDIA_MEGABYTES    = 100
      MAX_MEDIA_BYTES        = MAX_MEDIA_MEGABYTES * 1024 * 1024
      MEDIA_SNIFF_BYTES      = 4096
      IMAGE_BYTE_BUDGET      = 6 * 1024 * 1024
      MAX_IMAGE_DECODE_BYTES = 50 * 1024 * 1024
      MAX_IMAGE_EDGE_PX      = 2048

      @@fs : MediaFileSystem?
      @@capabilities : ModelCapabilities?
      @@image_processor : ImageProcessor?

      def self.fs=(fs : MediaFileSystem?)
        @@fs = fs
      end

      def self.fs : MediaFileSystem?
        @@fs
      end

      def self.capabilities=(c : ModelCapabilities?)
        @@capabilities = c
      end

      def self.capabilities : ModelCapabilities?
        @@capabilities
      end

      def self.image_processor=(p : ImageProcessor?)
        @@image_processor = p
      end

      def self.image_processor : ImageProcessor?
        @@image_processor
      end
    end

    # ------------------------------------------------------------------
    # File type detection
    # ------------------------------------------------------------------

    # Extension: image?/video? predicates on enum.
    enum MediaKind
      Image
      Video
      Text
      Unknown

      def to_wire : String
        case self
        in Image   then "image"
        in Video   then "video"
        in Text    then "text"
        in Unknown then "unknown"
        end
      end

      def image? : Bool
        self == Image
      end

      def video? : Bool
        self == Video
      end

      def text? : Bool
        self == Text
      end

      def unknown? : Bool
        self == Unknown
      end
    end

    struct DetectedFileType
      getter kind : MediaKind
      getter mime_type : String?

      def initialize(@kind : MediaKind, @mime_type : String? = nil)
      end
    end

    # Magic-byte sniffing для常见 image/video/text форматов.
    # Бросает MediaError если header пустой/не читается.
    def self.detect_media_file_type(header : Bytes) : DetectedFileType
      return DetectedFileType.new(MediaKind::Unknown) if header.empty?

      # PNG: 89 50 4E 47 0D 0A 1A 0A
      if header.size >= 8 &&
         header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E &&
         header[3] == 0x47 && header[4] == 0x0D && header[5] == 0x0A &&
         header[6] == 0x1A && header[7] == 0x0A
        return DetectedFileType.new(MediaKind::Image, "image/png")
      end

      # JPEG: FF D8 FF
      if header.size >= 3 && header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF
        return DetectedFileType.new(MediaKind::Image, "image/jpeg")
      end

      # GIF: 47 49 46 38 (GIF8)
      if header.size >= 4 &&
         header[0] == 0x47 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x38
        return DetectedFileType.new(MediaKind::Image, "image/gif")
      end

      # WebP: RIFF....WEBP
      if header.size >= 12 &&
         header[0] == 0x52 && header[1] == 0x49 && header[2] == 0x46 &&
         header[3] == 0x46 && header[4] == 0x00 && header[8] == 0x57 &&
         header[9] == 0x45 && header[10] == 0x42 && header[11] == 0x50
        return DetectedFileType.new(MediaKind::Image, "image/webp")
      end

      # MP4: ftyp box at offset 4
      if header.size >= 12 &&
         header[4] == 0x66 && header[5] == 0x74 && header[6] == 0x79 &&
         header[7] == 0x70
        return DetectedFileType.new(MediaKind::Video, "video/mp4")
      end

      # WebM: 1A 45 DF A3
      if header.size >= 4 &&
         header[0] == 0x1A && header[1] == 0x45 && header[2] == 0xDF && header[3] == 0xA3
        return DetectedFileType.new(MediaKind::Video, "video/webm")
      end

      # Heuristic text detection: если все байты printable/whitespace,
      # считаем текстом.
      if looks_like_text?(header)
        return DetectedFileType.new(MediaKind::Text, "text/plain")
      end

      DetectedFileType.new(MediaKind::Unknown)
    end

    private def self.looks_like_text?(header : Bytes, sample_size : Int32 = 1024) : Bool
      return false if header.empty?
      n = Math.min(header.size, sample_size)
      n.times do |i|
        b = header[i]
        # Allow tab/newline/cr.
        next if b == 0x09 || b == 0x0A || b == 0x0D
        # Printable ASCII.
        return false if b < 0x20 || b > 0x7E
      end
      true
    end

    # ------------------------------------------------------------------
    # Image dimensions sniffing
    # ------------------------------------------------------------------

    struct ImageDimensions
      property width : Int32
      property height : Int32

      def initialize(@width : Int32, @height : Int32)
      end
    end

    def self.sniff_image_dimensions(data : Bytes) : ImageDimensions?
      return nil if data.size < 8

      # PNG: IHFD at offset 16, 4-byte BE width/height.
      if data.size >= 24 && data[0] == 0x89 && data[1] == 0x50
        width = (data[16].to_i32 << 24) | (data[17].to_i32 << 16) |
                (data[18].to_i32 << 8) | data[19].to_i32
        height = (data[20].to_i32 << 24) | (data[21].to_i32 << 16) |
                 (data[22].to_i32 << 8) | data[23].to_i32
        return ImageDimensions.new(width, height)
      end

      # JPEG: scan SOF0/SOF2 markers.
      if data.size >= 4 && data[0] == 0xFF && data[1] == 0xD8
        return sniff_jpeg_dimensions(data)
      end

      # GIF: logical screen at offset 6, 2-byte LE.
      if data.size >= 10 && data[0] == 0x47 && data[1] == 0x49
        width = data[6].to_i32 | (data[7].to_i32 << 8)
        height = data[8].to_i32 | (data[9].to_i32 << 8)
        return ImageDimensions.new(width, height)
      end

      # WebP: VP8/VP8L/VP8X — different layouts.
      if data.size >= 30 && data[0] == 0x52 && data[12] == 0x57
        return sniff_webp_dimensions(data)
      end

      nil
    end

    private def self.sniff_jpeg_dimensions(data : Bytes) : ImageDimensions?
      i = 2
      while i + 8 < data.size
        if data[i] != 0xFF
          i += 1
          next
        end
        marker = data[i + 1]
        # SOF0..SOF15 except SOF4/DHT/SOF8/JPG/SOF12/DAC/SOF14.
        if marker >= 0xC0 && marker <= 0xCF &&
           marker != 0xC4 && marker != 0xC8 && marker != 0xCC
          height = (data[i + 5].to_i32 << 8) | data[i + 6].to_i32
          width = (data[i + 7].to_i32 << 8) | data[i + 8].to_i32
          return ImageDimensions.new(width, height)
        end
        # Skip this marker segment.
        if i + 3 < data.size
          seg_len = (data[i + 2].to_i32 << 8) | data[i + 3].to_i32
          i += 2 + seg_len
        else
          return nil
        end
      end
      nil
    end

    private def self.sniff_webp_dimensions(data : Bytes) : ImageDimensions?
      # VP8 Lossy: dimensions at offset 26-29, 2-byte LE.
      if data.size >= 30 && data[12] == 0x56 && data[13] == 0x50 && data[14] == 0x38 && data[15] == 0x20
        width = (data[26].to_i32 | (data[27].to_i32 << 8)) & 0x3FFF
        height = (data[28].to_i32 | (data[29].to_i32 << 8)) & 0x3FFF
        return ImageDimensions.new(width, height)
      end
      # VP8L Lossless: signature at offset 21, 14-bit values packed.
      if data.size >= 25 && data[12] == 0x56 && data[13] == 0x50 && data[14] == 0x38 && data[15] == 0x4C
        b0 = data[21].to_i32
        b1 = data[22].to_i32
        b2 = data[23].to_i32
        b3 = data[24].to_i32
        width = 1 + (b0 | ((b1 & 0x3F) << 8))
        height = 1 + (((b1 >> 6) & 0x03) | (b2 << 2) | ((b3 & 0x0F) << 10))
        return ImageDimensions.new(width, height)
      end
      # VP8X Extended: canvas size at offset 24, 24-bit LE.
      if data.size >= 30 && data[12] == 0x56 && data[13] == 0x50 && data[14] == 0x38 && data[15] == 0x58
        width = 1 + (data[24].to_i32 | (data[25].to_i32 << 8) | (data[26].to_i32 << 16))
        height = 1 + (data[27].to_i32 | (data[28].to_i32 << 8) | (data[29].to_i32 << 16))
        return ImageDimensions.new(width, height)
      end
      nil
    end

    # ------------------------------------------------------------------
    # format_byte_size + error templates
    # ------------------------------------------------------------------

    def self.format_byte_size(n : Int32) : String
      if n < 1024
        "#{n}B"
      elsif n < 1024 * 1024
        "#{(n.to_f64 / 1024).round(1)}KiB"
      else
        "#{(n.to_f64 / (1024 * 1024)).round(1)}MiB"
      end
    end

    def self.image_delivery_limit_error(final_bytes : Int32, budget : Int32, max_edge : Int32) : String
      "Image is too large to send safely after compression (#{final_bytes} bytes; limit #{budget} bytes and #{max_edge}px on the longest edge). The original image was not sent to the model. Do not retry the same file unchanged. Use Bash or an available image-processing tool to create a smaller copy within both limits, then call ReadMediaFile on the smaller copy."
    end

    def self.image_decode_limit_error(final_bytes : Int32) : String
      "Image is too large to process safely for region or full_resolution (#{final_bytes} bytes; safe decode limit #{Media::MAX_IMAGE_DECODE_BYTES} bytes). The original image was not sent to the model. Do not retry the same file unchanged. Use Bash or an available image-processing tool to create a smaller copy or crop the needed region into a separate image, then call ReadMediaFile on the resulting file."
    end

    def self.full_resolution_limit_error(path : String, final_bytes : Int32) : String
      %("#{path}" is #{final_bytes} bytes (#{format_byte_size(final_bytes)}), over the #{Media::IMAGE_BYTE_BUDGET}-byte (#{format_byte_size(Media::IMAGE_BYTE_BUDGET)}) per-image limit, so full_resolution cannot be honored. Use region to view a crop at full fidelity instead.)
    end

    # ------------------------------------------------------------------
    # Service contracts
    # ------------------------------------------------------------------

    struct ModelCapabilities
      getter? image_in : Bool
      getter? video_in : Bool

      def initialize(@image_in : Bool = false, @video_in : Bool = false)
      end
    end

    abstract class MediaFileSystem
      abstract def read(path : String) : Bytes
      abstract def size(path : String) : Int64
      abstract def exists?(path : String) : Bool
    end

    class LocalMediaFileSystem < MediaFileSystem
      def read(path : String) : Bytes
        content = File.read(path).encode("UTF-8")
        content
      end

      def size(path : String) : Int64
        File.size(path).to_i64
      end

      def exists?(path : String) : Bool
        File.exists?(path)
      end
    end

    # Image processing outcome — resize/crop result fed back into the tool.
    # Processors: `ImageMagickImageProcessor` (real resize/crop via
    # shell-out), `PassThroughImageProcessor` (unchanged-data MVP fallback).
    struct ImageProcessOutcome
      getter data : Bytes
      getter mime_type : String
      getter width : Int32
      getter height : Int32
      getter original_width : Int32
      getter original_height : Int32
      getter? resized : Bool
      getter final_byte_length : Int32

      def initialize(@data : Bytes, @mime_type : String,
                     @width : Int32, @height : Int32,
                     @original_width : Int32, @original_height : Int32,
                     @resized : Bool, @final_byte_length : Int32)
      end
    end

    struct ImageRegion
      getter x : Int32
      getter y : Int32
      getter width : Int32
      getter height : Int32

      def initialize(@x : Int32, @y : Int32, @width : Int32, @height : Int32)
      end
    end

    abstract class ImageProcessor
      abstract def compress(data : Bytes, mime_type : String,
                            byte_budget : Int32, max_edge : Int32) : ImageProcessOutcome
      abstract def crop(data : Bytes, mime_type : String, region : ImageRegion,
                        skip_resize : Bool) : ImageProcessOutcome
    end

    # Pass-through processor — возвращает данные без изменений. MVP fallback.
    class PassThroughImageProcessor < ImageProcessor
      def compress(data : Bytes, mime_type : String,
                   byte_budget : Int32, max_edge : Int32) : ImageProcessOutcome
        dims = Tools.sniff_image_dimensions(data)
        w = dims.try(&.width) || 0
        h = dims.try(&.height) || 0
        ImageProcessOutcome.new(
          data: data,
          mime_type: mime_type,
          width: w,
          height: h,
          original_width: w,
          original_height: h,
          resized: false,
          final_byte_length: data.size.to_i32,
        )
      end

      def crop(data : Bytes, mime_type : String, region : ImageRegion,
               skip_resize : Bool) : ImageProcessOutcome
        dims = Tools.sniff_image_dimensions(data)
        w = dims.try(&.width) || 0
        h = dims.try(&.height) || 0
        ImageProcessOutcome.new(
          data: data,
          mime_type: mime_type,
          width: region.width,
          height: region.height,
          original_width: w,
          original_height: h,
          resized: false,
          final_byte_length: data.size.to_i32,
        )
      end
    end

    # ImageMagick-backed processor — shells out to `magick` (IM7) or
    # `convert` (IM6). `resolve` returns nil when neither binary is on
    # PATH; the tool then falls back to the pass-through behavior.
    class ImageMagickImageProcessor < ImageProcessor
      RUN_TIMEOUT_S = 30

      def self.resolve : ImageProcessor?
        binary = find_binary
        binary ? new(binary) : nil
      end

      def self.find_binary : String?
        ["magick", "convert"].each do |candidate|
          if path = Process.find_executable(candidate)
            return path
          end
        end
        nil
      end

      def initialize(@binary : String)
      end

      def compress(data : Bytes, mime_type : String,
                   byte_budget : Int32, max_edge : Int32) : ImageProcessOutcome
        dims = Tools.sniff_image_dimensions(data)
        w = dims.try(&.width) || 0
        h = dims.try(&.height) || 0

        # Already within both limits — deliver untouched.
        if data.size <= byte_budget && (w <= 0 || h <= 0 || Math.max(w, h) <= max_edge)
          return outcome(data, mime_type, w, h, w, h, resized: false)
        end

        bytes, out_mime, ow, oh, _fitted = fit_byte_budget(data, mime_type,
          byte_budget, max_edge, extra_pre_args: [] of String)
        if bytes.same?(data)
          # ImageMagick failed entirely — pass through; the tool's budget
          # check reports the oversized delivery.
          return outcome(data, mime_type, w, h, w, h, resized: false)
        end
        outcome(bytes, out_mime, ow, oh, w, h, resized: true)
      end

      def crop(data : Bytes, mime_type : String, region : ImageRegion,
               skip_resize : Bool) : ImageProcessOutcome
        dims = Tools.sniff_image_dimensions(data)
        w = dims.try(&.width) || 0
        h = dims.try(&.height) || 0
        crop_args = ["-crop", "#{region.width}x#{region.height}+#{region.x}+#{region.y}", "+repage"]

        if skip_resize
          encoded = run_magick(data, ext_for(mime_type), ext_for(mime_type), crop_args)
          if encoded && !encoded.empty?
            od = Tools.sniff_image_dimensions(encoded)
            ow = od.try(&.width) || region.width
            oh = od.try(&.height) || region.height
            return outcome(encoded, mime_type, ow, oh, w, h, resized: false)
          end
          # Fallback: uncropped pass-through (MVP behavior).
          return outcome(data, mime_type, region.width, region.height, w, h, resized: false)
        end

        bytes, out_mime, ow, oh, _fitted = fit_byte_budget(data, mime_type,
          Media::IMAGE_BYTE_BUDGET, Media::MAX_IMAGE_EDGE_PX, extra_pre_args: crop_args)
        if bytes.same?(data)
          return outcome(data, mime_type, region.width, region.height, w, h, resized: false)
        end
        outcome(bytes, out_mime, ow, oh, w, h, resized: true)
      end

      # ----------------------------------------------------------------
      # Helpers
      # ----------------------------------------------------------------

      private def outcome(data : Bytes, mime : String, w : Int32, h : Int32,
                          ow : Int32, oh : Int32, resized : Bool) : ImageProcessOutcome
        ImageProcessOutcome.new(
          data: data,
          mime_type: mime,
          width: w,
          height: h,
          original_width: ow,
          original_height: oh,
          resized: resized,
          final_byte_length: data.size.to_i32,
        )
      end

      # Downscale ladder: shrink the longest edge and re-encode, switching
      # to JPEG on the last rung, until the output fits `byte_budget`.
      # Returns the original `data` (same object) when ImageMagick could
      # not produce any output at all.
      private def fit_byte_budget(data : Bytes, mime : String, byte_budget : Int32,
                                  max_edge : Int32, extra_pre_args : Array(String))
        attempts = [
          {max_edge, 85, mime},
          {max_edge // 2, 70, mime},
          {max_edge // 4, 55, mime},
          {max_edge // 4, 40, "image/jpeg"},
        ]
        best : {Bytes, String, Int32, Int32}? = nil
        attempts.each do |(edge, quality, out_mime)|
          args = extra_pre_args.dup
          args.concat(["-auto-orient", "-resize", "#{edge}x#{edge}>", "-quality", quality.to_s])
          encoded = run_magick(data, ext_for(mime), ext_for(out_mime), args)
          next if encoded.nil? || encoded.empty?
          od = Tools.sniff_image_dimensions(encoded)
          ow = od.try(&.width) || 0
          oh = od.try(&.height) || 0
          best = {encoded, out_mime, ow, oh}
          return {encoded, out_mime, ow, oh, true} if encoded.size <= byte_budget
        end
        if b = best
          {b[0], b[1], b[2], b[3], false}
        else
          {data, mime, 0, 0, false}
        end
      end

      # Run the ImageMagick binary over a temp copy of `data`. Returns the
      # output bytes, or nil on failure/timeout. Temp files are always
      # cleaned up.
      private def run_magick(input : Bytes, in_ext : String, out_ext : String,
                             args : Array(String)) : Bytes?
        token = Random::Secure.hex(6)
        in_path = File.join(Dir.tempdir, "h2media-#{token}.#{in_ext}")
        out_path = File.join(Dir.tempdir, "h2media-#{token}.out.#{out_ext}")
        begin
          File.write(in_path, input)
          proc = Process.new(@binary, [in_path] + args + [out_path],
            input: Process::Redirect::Close,
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Pipe)
          status_ch = Channel(Process::Status).new
          spawn { status_ch.send(proc.wait) }
          status = select
          when s = status_ch.receive
            s
          when timeout(RUN_TIMEOUT_S.seconds)
            proc.terminate rescue nil
            status_ch.receive
          end
          return nil unless status.success?
          return nil unless File.exists?(out_path)
          size = File.size(out_path)
          bytes = Bytes.new(size)
          File.open(out_path) { |f| f.read(bytes) }
          bytes
        rescue
          nil
        ensure
          File.delete?(in_path)
          File.delete?(out_path)
        end
      end

      private def ext_for(mime : String) : String
        case mime
        when "image/png"  then "png"
        when "image/gif"  then "gif"
        when "image/webp" then "webp"
        when "image/bmp"  then "bmp"
        else                   "jpg"
        end
      end
    end

    class MediaError < Exception
    end

    # ------------------------------------------------------------------
    # Tool
    # ------------------------------------------------------------------

    class ReadMediaFile < Tool
      DESCRIPTION_HEAD = <<-TEXT
        Read media content from a file.

        **Tips:**
        - Make sure you follow the description of each tool parameter.
        - A `<system>` tag accompanies the media content; it summarizes the mime type, byte size and, for images, the original pixel dimensions, and states how the image was delivered (untouched, downsampled, cropped, or native resolution). When outputting coordinates, give relative coordinates first and compute absolute coordinates from the original image size. After generating or editing media via commands or scripts, read the result back before continuing.
        - Large images are downsampled by default when automatic compression can safely fit them within model limits, which can blur fine detail (small text, dense UI). Compute absolute coordinates from the original dimensions reported in the `<system>` block, never by measuring the displayed copy. When the `<system>` tag reports downsampling and you need that detail, call this tool again with the `region` parameter (original-image pixel coordinates) to view a crop at full fidelity, or set `full_resolution` to true when the whole file fits the per-image byte limit. Re-reading the same file without these parameters just reproduces the same downsampled image.
        - If automatic compression cannot safely produce an image within model limits, the tool returns an error and does not send the original image. Follow the error: use Bash or an available image-processing tool to create a smaller copy, then read that copy. Do not retry the unchanged file.
        - The system will notify you when there is anything wrong when reading the file.
        - This tool is a tool that you typically want to use in parallel. Always read multiple files in one response when possible.
        - This tool can only read image or video files. To read text files, use the Read tool. To list directories, use `ls` via Bash for a known directory, or Glob for pattern search.
        - If the file doesn't exist or path is invalid, an error will be returned.
        - The maximum size that can be read is 100MB. An error will be returned if the file is larger than this limit.
        - The media content will be returned in a form that you can directly view and understand.

        **Capabilities**
      TEXT

      def name : String
        Names::READ_MEDIA_FILE
      end

      def description : String
        String.build do |io|
          io << DESCRIPTION_HEAD
          io << "\n"
          io << build_capability_tail
        end
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Path to an image or video file. Relative paths resolve against the working directory; a path outside the working directory must be absolute. Directories and text files are not supported."
            },
            "region": {
              "type": "object",
              "properties": {
                "x": { "type": "integer", "minimum": 0, "description": "Left edge of the crop, in original-image pixels." },
                "y": { "type": "integer", "minimum": 0, "description": "Top edge of the crop, in original-image pixels." },
                "width": { "type": "integer", "minimum": 1, "description": "Crop width, in original-image pixels." },
                "height": { "type": "integer", "minimum": 1, "description": "Crop height, in original-image pixels." }
              },
              "required": ["x", "y", "width", "height"],
              "additionalProperties": false,
              "description": "Images only: view just this rectangle of the image (original-image pixel coordinates). Use after a downsampled full view to inspect fine detail — a region within the size limits is delivered at full fidelity."
            },
            "full_resolution": {
              "type": "boolean",
              "description": "Images only: skip the default downscaling and view at native resolution. Fails with an explicit error when the payload would exceed the per-image byte limit; use region for files that large."
            }
          },
          "required": ["path"],
          "additionalProperties": false
        }))
      end

      def build_capability_tail : String
        caps = Media.capabilities
        image_in = caps.try(&.image_in?) || false
        video_in = caps.try(&.video_in?) || false

        if image_in && video_in
          "- This tool supports image and video files for the current model."
        elsif image_in && !video_in
          "- This tool supports image files for the current model.\n- Video files are not supported by the current model."
        elsif !image_in && video_in
          "- This tool supports video files for the current model.\n- Image files are not supported by the current model."
        else
          "- This tool is not enabled for the current model."
        end
      end

      def execute(input : JSON::Any) : ToolResult
        path = input["path"]?.try(&.to_s) || ""
        if path.empty?
          return ToolResult.error("File path cannot be empty.")
        end

        fs = Media.fs
        return ToolResult.error("Media file system is not initialized.") if fs.nil?
        caps = Media.capabilities
        return ToolResult.error("Model capabilities are not initialized.") if caps.nil?

        svc = fs
        capabilities = caps

        unless svc.exists?(path)
          return ToolResult.error(%("#{path}" does not exist.))
        end

        size = svc.size(path)
        if size == 0
          return ToolResult.error(%("#{path}" is empty.))
        end
        if size > Media::MAX_MEDIA_BYTES
          return ToolResult.error(%("#{path}" is #{size} bytes, which exceeds the maximum 100MB for media files.))
        end

        # Sniff file type.
        data = svc.read(path)
        sniff = data[0, Math.min(data.size, Media::MEDIA_SNIFF_BYTES)]
        detected = Tools.detect_media_file_type(sniff)

        case detected.kind
        when MediaKind::Text
          return ToolResult.error(%("#{path}" is a text file. Use Read to read text files.))
        when MediaKind::Unknown
          return ToolResult.error(%("#{path}" is not a supported image or video file. Use Read for text files, or Bash or an MCP tool for other binary formats.))
        when MediaKind::Image
          unless capabilities.image_in?
            return ToolResult.error("The current model does not support image input. Tell the user to use a model with image input capability.")
          end
        when MediaKind::Video
          unless capabilities.video_in?
            return ToolResult.error("The current model does not support video input. Tell the user to use a model with video input capability.")
          end
        end

        # Parse optional region + full_resolution.
        region = parse_region(input["region"]?)
        full_resolution = input["full_resolution"]?.try(&.as_bool?) || false

        # Video vs image parameter checks.
        if detected.kind.video? && (region || full_resolution)
          return ToolResult.error("region and full_resolution apply only to image files.")
        end

        if detected.kind.image?
          if size > Media::MAX_IMAGE_DECODE_BYTES && (region || full_resolution)
            return ToolResult.error(Tools.image_decode_limit_error(size.to_i32))
          end
          if region.nil? && full_resolution && size > Media::IMAGE_BYTE_BUDGET
            return ToolResult.error(Tools.full_resolution_limit_error(path, size.to_i32))
          end
        end

        # Process image or pass video through.
        mime = detected.mime_type || "application/octet-stream"

        if detected.kind.image?
          process = Media.image_processor || PassThroughImageProcessor.new
          if r = region
            outcome = process.crop(data, mime, r, skip_resize: full_resolution)
            delivery_kind = full_resolution ? "crop_full" : "crop"
            delivery = Delivery.new(
              kind: delivery_kind,
              width: outcome.width,
              height: outcome.height,
              byte_length: outcome.final_byte_length,
              mime_type: outcome.mime_type,
              resized: outcome.resized?,
              region: r,
            )
            dims = ImageDimensions.new(outcome.original_width, outcome.original_height)
            body_bytes = outcome.data
            body_mime = outcome.mime_type
          elsif full_resolution
            outcome = process.compress(data, mime, byte_budget: Media::IMAGE_BYTE_BUDGET, max_edge: Media::MAX_IMAGE_EDGE_PX)
            delivery = Delivery.new(
              kind: "full",
              width: outcome.width,
              height: outcome.height,
              byte_length: outcome.final_byte_length,
              mime_type: outcome.mime_type,
            )
            dims = outcome.original_dimensions
            body_bytes = outcome.data
            body_mime = outcome.mime_type
          else
            outcome = process.compress(data, mime, byte_budget: Media::IMAGE_BYTE_BUDGET, max_edge: Media::MAX_IMAGE_EDGE_PX)
            delivery_kind = outcome.resized? ? "downsampled" : "untouched"
            delivery = Delivery.new(
              kind: delivery_kind,
              width: outcome.width,
              height: outcome.height,
              byte_length: outcome.final_byte_length,
              mime_type: outcome.mime_type,
              resized: outcome.resized?,
            )
            dims = ImageDimensions.new(outcome.original_width, outcome.original_height)
            body_bytes = outcome.data
            body_mime = outcome.mime_type
          end

          if delivery.byte_length > Media::IMAGE_BYTE_BUDGET && region.nil? && !full_resolution
            return ToolResult.error(Tools.image_delivery_limit_error(delivery.byte_length, Media::IMAGE_BYTE_BUDGET, Media::MAX_IMAGE_EDGE_PX))
          end
        else
          # Video — pass through as data URL.
          body_bytes = data
          body_mime = mime
          dims = nil
          delivery = Delivery.new(
            kind: "untouched",
            width: 0,
            height: 0,
            byte_length: data.size.to_i32,
            mime_type: mime,
          )
        end

        # Build output: <image|video path="..."> + base64 + closing tag + note.
        tag = detected.kind.image? ? "image" : "video"
        b64 = Base64.strict_encode(body_bytes)
        note = build_media_note(detected.kind, mime, size.to_i32, dims, delivery)

        output = String.build do |io|
          io << "<#{tag} path=\"#{path}\">\n"
          io << "data:#{body_mime};base64,#{b64}\n"
          io << "</#{tag}>\n"
          io << note
        end

        ToolResult.success(output)
      end

      private def parse_region(value : JSON::Any?) : ImageRegion?
        return nil if value.nil?
        obj = value.as_h?
        return nil if obj.nil?
        x = obj["x"]?.try(&.as_i?) || 0
        y = obj["y"]?.try(&.as_i?) || 0
        w = obj["width"]?.try(&.as_i?) || 0
        h = obj["height"]?.try(&.as_i?) || 0
        return nil if w < 1 || h < 1
        ImageRegion.new(x: x, y: y, width: w, height: h)
      end

      def build_media_note(kind : MediaKind, mime_type : String, byte_size : Int32,
                           dimensions : ImageDimensions?, delivery : Delivery) : String
        parts = [] of String
        parts << "Read #{kind.to_wire} file."
        parts << "Mime type: #{mime_type}."
        parts << "Size: #{byte_size} bytes."

        if kind.image? && dimensions
          parts << "Original dimensions: #{dimensions.width}x#{dimensions.height} pixels."
        end

        case delivery.kind
        when "downsampled"
          parts << "The attached image was downsampled to #{delivery.width}x#{delivery.height} pixels (#{delivery.mime_type}, #{Tools.format_byte_size(delivery.byte_length)}) to fit model limits; fine detail may be lost."
          parts << "To inspect fine detail, call ReadMediaFile again with the region parameter (original-image pixel coordinates) to view a crop at full fidelity."
        when "crop", "crop_full"
          resized_clause = delivery.resized? ? ", downsampled to #{delivery.width}x#{delivery.height} pixels" : " at native resolution"
          if r = delivery.region
            parts << "Showing region (x=#{r.x}, y=#{r.y}, width=#{r.width}, height=#{r.height}) of the original image#{resized_clause}."
            parts << "To output coordinates in original-image pixels, locate them within this crop and add the region offset (x=#{r.x}, y=#{r.y})."
          end
        when "full"
          parts << "Shown at native resolution; no downscaling applied."
        when "untouched"
          # Nothing.
        end

        if kind.image? && dimensions && delivery.kind != "crop" && delivery.kind != "crop_full"
          parts << "If you need to output coordinates, output relative coordinates first and compute absolute coordinates using the original image size."
        end

        parts << "If you generate or edit images or videos via commands or scripts, read the result back immediately before continuing."

        "<system>#{parts.join(' ')}</system>"
      end

      struct Delivery
        getter kind : String
        getter width : Int32
        getter height : Int32
        getter byte_length : Int32
        getter mime_type : String
        getter? resized : Bool
        getter region : ImageRegion?

        def initialize(@kind : String, @width : Int32, @height : Int32,
                       @byte_length : Int32, @mime_type : String,
                       @resized : Bool = false, @region : ImageRegion? = nil)
        end
      end
    end

    # Extension: original dimensions on outcome.
    struct ImageProcessOutcome
      def original_dimensions : ImageDimensions
        ImageDimensions.new(@original_width, @original_height)
      end
    end

    # Extension: video? / image? on enum for case-when.
    # (methods added to enum above)
  end
end
