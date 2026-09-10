require "../llm/types"

module H2code
  module TUI
    # One media item pasted into the input box. The user sees the rendered
    # `placeholder` in the editor; on submit `MediaAttachmentStore.extract_parts`
    # expands image placeholders into native image content parts and video
    # placeholders into file-path tags for ReadMediaFile. Port of the JS
    # `ImageAttachment` / `VideoAttachment` / `ImageAttachmentStore`
    # (`src/tui/utils/image-attachment-store.ts`).
    struct MediaAttachment
      enum Kind
        Image
        Video
      end

      property id : Int32
      property kind : Kind
      # Image payload (Kind::Image only).
      property bytes : Bytes
      property mime : String
      property width : Int32
      property height : Int32
      # Source file path (Kind::Video).
      property source_path : String?
      property label : String
      property placeholder : String

      def self.image(id : Int32, bytes : Bytes, mime : String, width : Int32, height : Int32) : MediaAttachment
        new(id, Kind::Image, bytes, mime, width, height, nil, "image",
          "[image ##{id} (#{width}×#{height})]")
      end

      def self.video(id : Int32, source_path : String, mime : String, label : String) : MediaAttachment
        sanitized = sanitize_label(label.empty? ? mime : label)
        new(id, Kind::Video, Bytes.empty, mime, 0, 0, source_path, sanitized,
          "[video ##{id} #{sanitized}]")
      end

      def initialize(@id : Int32, @kind : Kind, @bytes : Bytes, @mime : String,
                     @width : Int32, @height : Int32, @source_path : String?,
                     @label : String, @placeholder : String)
      end

      def image? : Bool
        @kind.image?
      end

      def video? : Bool
        @kind.video?
      end

      # `[` / `]` and control chars would break the placeholder round-trip.
      private def self.sanitize_label(raw : String) : String
        sanitized = String.build do |io|
          raw.each_char do |char|
            code = char.ord
            io << (code < 0x20 || code == 0x7f || char == '[' || char == ']' ? '_' : char)
          end
        end.strip
        sanitized.empty? ? "video" : sanitized
      end
    end

    # Registry for media pasted into the input box. Scope is per-TUI
    # instance; `/new` and `/clear` reset it so ids restart from 1 and stale
    # attachments are dropped. Attachments are intentionally NOT persisted
    # across sessions (same as the JS original — `--resume` wouldn't know
    # how to materialize the bytes anyway).
    class MediaAttachmentStore
      PLACEHOLDER_REGEX = /\[(image|video) #(\d+)(?: \([^\)]*\)| [^\]]*)?\]/

      @next_id : Int32 = 1
      @by_id = {} of Int32 => MediaAttachment

      def add_image(bytes : Bytes, mime : String, width : Int32, height : Int32) : MediaAttachment
        attachment = MediaAttachment.image(@next_id, bytes, mime, width, height)
        @by_id[@next_id] = attachment
        @next_id += 1
        attachment
      end

      def add_video(source_path : String, mime : String, label : String = "") : MediaAttachment
        attachment = MediaAttachment.video(@next_id, source_path, mime,
          label.empty? ? File.basename(source_path) : label)
        @by_id[@next_id] = attachment
        @next_id += 1
        attachment
      end

      def get(id : Int32) : MediaAttachment?
        @by_id[id]?
      end

      def clear : Nil
        @by_id.clear
        @next_id = 1
      end

      def size : Int32
        @by_id.size
      end

      # Scan submitted text for media placeholders and build the user
      # message content parts: image placeholders expand to native
      # `ImageContent` parts (the prompt reaches the provider without a tool
      # call), video placeholders expand to `<video path="…">` file tags the
      # model opens via ReadMediaFile. Port of `extractMediaAttachments`
      # (`src/tui/utils/image-placeholder.ts`).
      #
      # Rules (as in JS):
      #   - Only placeholders resolving against this store are extracted; a
      #     literal `[image #999 …]` the user typed stays in the text.
      #   - Order is preserved; whitespace-only text segments between media
      #     parts drop out.
      #
      # Returns `{parts, matched_ids}`; `parts` is nil when nothing matched
      # (caller keeps the plain-text path).
      def extract_parts(text : String) : {Array(LLM::ContentPart)?, Array(Int32)}
        parts = [] of LLM::ContentPart
        matched = [] of Int32
        cursor = 0

        text.scan(PLACEHOLDER_REGEX) do |match|
          kind = match[1]
          id = match[2].to_i?
          next if id.nil?
          attachment = @by_id[id]?
          # Stale or user-typed — leave the literal in the text.
          next if attachment.nil? || attachment.kind.to_s.downcase != kind

          if begin_pos = match.begin
            push_text(parts, text[cursor...begin_pos])
          end
          if attachment.image?
            data_url = "data:#{attachment.mime};base64,#{Base64.strict_encode(attachment.bytes)}"
            parts << LLM::ImageContent.new(LLM::ImageRef.new(data_url))
          else
            push_text(parts, %(<video path="#{attachment.source_path}"></video>))
          end
          matched << id
          if end_pos = match.end
            cursor = end_pos
          end
        end

        return {nil, [] of Int32} if matched.empty?
        push_text(parts, text[cursor..])
        {parts, matched}
      end

      private def push_text(parts : Array(LLM::ContentPart), segment : String) : Nil
        return if segment.strip.empty?
        last = parts.last?
        if last.is_a?(LLM::TextContent)
          parts[-1] = LLM::TextContent.new(last.text + segment)
        else
          parts << LLM::TextContent.new(segment)
        end
      end
    end
  end
end
