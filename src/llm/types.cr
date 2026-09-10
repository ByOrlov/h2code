module H2code
  module LLM
    alias StopReason = String

    enum Role
      System
      User
      Assistant
      Tool

      def to_s : String
        case self
        in System    then "system"
        in User      then "user"
        in Assistant then "assistant"
        in Tool      then "tool"
        end
      end
    end

    struct Usage
      include JSON::Serializable

      property prompt_tokens : Int32 = 0
      property completion_tokens : Int32 = 0
      property total_tokens : Int32 = 0

      def initialize(@prompt_tokens = 0, @completion_tokens = 0, @total_tokens = 0)
      end

      def +(other : Usage) : Usage
        Usage.new(
          prompt_tokens: @prompt_tokens + other.prompt_tokens,
          completion_tokens: @completion_tokens + other.completion_tokens,
          total_tokens: @total_tokens + other.total_tokens,
        )
      end
    end

    struct ToolCall
      include JSON::Serializable

      property id : String
      property type : String = "function"
      property function : ToolCallFunction

      def initialize(@id : String, @function : ToolCallFunction, @type : String = "function")
      end

      def name : String
        @function.name
      end

      def arguments : String
        @function.arguments
      end

      def profiled_bytes : Int64
        @id.profiled_bytes + @type.profiled_bytes + @function.profiled_bytes
      end
    end

    struct ToolCallFunction
      include JSON::Serializable

      property name : String
      property arguments : String

      def initialize(@name : String, @arguments : String = "")
      end

      def profiled_bytes : Int64
        @name.profiled_bytes + @arguments.profiled_bytes
      end
    end

    struct ToolDefinition
      include JSON::Serializable

      property type : String = "function"
      property function : ToolFunction

      def initialize(@function : ToolFunction, @type : String = "function")
      end

      def name : String
        @function.name
      end
    end

    struct ToolFunction
      include JSON::Serializable

      property name : String
      property description : String
      property parameters : JSON::Any

      def initialize(@name : String, @description : String, @parameters : JSON::Any)
      end
    end

    # Abstract base for a single content block within a Message. Mirrors the
    # kosong `ContentPart` union — text, reasoning, image, audio, video. Each
    # subclass carries its `type` discriminator so the JSON round-trip
    # (`use_json_discriminator`) restores the right class.
    abstract class ContentPart
      include JSON::Serializable
      use_json_discriminator "type", {
        text:      TextContent,
        think:     ThinkContent,
        image_url: ImageContent,
        audio_url: AudioContent,
        video_url: VideoContent,
      }

      property type : String

      # Concatenate all TextContent parts' text from a content array. Used by
      # `Message.text` and the token counter.
      def self.extract_text(parts : Array(ContentPart)) : String
        String.build do |io|
          parts.each do |p|
            io << p.text if p.is_a?(TextContent)
          end
        end
      end

      # Concatenate all ThinkContent parts' think text. Used by the TUI thinking
      # renderer and the token counter.
      def self.extract_thinking(parts : Array(ContentPart)) : String
        String.build do |io|
          parts.each do |p|
            io << p.think if p.is_a?(ThinkContent)
          end
        end
      end

      # Serialize this part to the OpenAI Chat Completions content-part wire
      # shape. Mirrors kosong's `convertContentPart`
      # (`providers/openai-common.ts`): text/image_url/audio_url/video_url map
      # 1:1; think parts are never sent here (they are lifted to the
      # message-level `reasoning_content` field by `Message#to_wire_json`).
      abstract def to_wire_json(json : JSON::Builder) : Nil

      # Map a data-URL (or remote URL) to the matching media ContentPart:
      # `data:image/...` / any http(s) image URL → ImageContent,
      # `data:video/...` → VideoContent, `data:audio/...` → AudioContent.
      # Returns nil for non-media URLs.
      def self.from_data_url(url : String) : ContentPart?
        return nil unless url.starts_with?("data:")
        if url.starts_with?("data:image/")
          ImageContent.new(ImageRef.new(url))
        elsif url.starts_with?("data:video/")
          VideoContent.new(VideoRef.new(url))
        elsif url.starts_with?("data:audio/")
          AudioContent.new(AudioRef.new(url))
        end
      end
    end

    class TextContent < ContentPart
      property text : String

      def initialize(@text : String)
        @type = "text"
      end

      def profiled_bytes : Int64
        @text.profiled_bytes + @type.profiled_bytes
      end

      def to_wire_json(json : JSON::Builder) : Nil
        json.object do
          json.field "type", "text"
          json.field "text", @text
        end
      end
    end

    class ThinkContent < ContentPart
      property think : String
      @[JSON::Field(emit_null: false)]
      property encrypted : String?

      def initialize(@think : String, @encrypted : String? = nil)
        @type = "think"
      end

      def profiled_bytes : Int64
        @think.profiled_bytes + @type.profiled_bytes + (@encrypted.try(&.profiled_bytes) || 0_i64)
      end

      # Never called: ThinkContent is stripped before wire serialization.
      def to_wire_json(json : JSON::Builder) : Nil
        raise "ThinkContent must not reach the wire (handled at message level)"
      end
    end

    # URL-style media references (data: URLs or remote URLs), matching the
    # OpenAI / kosong `image_url` shape: `{"url": "...", "id": "..."}`.

    struct ImageRef
      include JSON::Serializable
      property url : String
      @[JSON::Field(emit_null: false)]
      property id : String?

      def initialize(@url : String, @id : String? = nil)
      end

      def profiled_bytes : Int64
        @url.profiled_bytes + (@id.try(&.profiled_bytes) || 0_i64)
      end
    end

    struct AudioRef
      include JSON::Serializable
      property url : String
      @[JSON::Field(emit_null: false)]
      property id : String?

      def initialize(@url : String, @id : String? = nil)
      end

      def profiled_bytes : Int64
        @url.profiled_bytes + (@id.try(&.profiled_bytes) || 0_i64)
      end
    end

    struct VideoRef
      include JSON::Serializable
      property url : String
      @[JSON::Field(emit_null: false)]
      property id : String?

      def initialize(@url : String, @id : String? = nil)
      end

      def profiled_bytes : Int64
        @url.profiled_bytes + (@id.try(&.profiled_bytes) || 0_i64)
      end
    end

    class ImageContent < ContentPart
      property image_url : ImageRef

      def initialize(@image_url : ImageRef)
        @type = "image_url"
      end

      def profiled_bytes : Int64
        @image_url.profiled_bytes + @type.profiled_bytes
      end

      def to_wire_json(json : JSON::Builder) : Nil
        json.object do
          json.field "type", "image_url"
          json.field "image_url" do
            json.object do
              json.field "url", @image_url.url
              if id = @image_url.id
                json.field "id", id
              end
            end
          end
        end
      end
    end

    class AudioContent < ContentPart
      property audio_url : AudioRef

      def initialize(@audio_url : AudioRef)
        @type = "audio_url"
      end

      def profiled_bytes : Int64
        @audio_url.profiled_bytes + @type.profiled_bytes
      end

      def to_wire_json(json : JSON::Builder) : Nil
        json.object do
          json.field "type", "audio_url"
          json.field "audio_url" do
            json.object do
              json.field "url", @audio_url.url
              if id = @audio_url.id
                json.field "id", id
              end
            end
          end
        end
      end
    end

    class VideoContent < ContentPart
      property video_url : VideoRef

      def initialize(@video_url : VideoRef)
        @type = "video_url"
      end

      def profiled_bytes : Int64
        @video_url.profiled_bytes + @type.profiled_bytes
      end

      def to_wire_json(json : JSON::Builder) : Nil
        json.object do
          json.field "type", "video_url"
          json.field "video_url" do
            json.object do
              json.field "url", @video_url.url
              if id = @video_url.id
                json.field "id", id
              end
            end
          end
        end
      end
    end

    struct Message
      include JSON::Serializable

      property role : String
      property content : Array(ContentPart)
      @[JSON::Field(emit_null: false)]
      property tool_calls : Array(ToolCall)?
      @[JSON::Field(emit_null: false)]
      property tool_call_id : String?

      def initialize(@role : String, @content : Array(ContentPart),
                     @tool_calls : Array(ToolCall)? = nil,
                     @tool_call_id : String? = nil)
      end

      # Convenience: create a Message with a plain text content block. The
      # string is wrapped in a single-element `[TextContent]` array.
      def self.new(role : String, content : String,
                   tool_calls : Array(ToolCall)? = nil,
                   tool_call_id : String? = nil)
        parts = content.empty? ? [] of ContentPart : [TextContent.new(content)] of ContentPart
        new(role, parts, tool_calls, tool_call_id)
      end

      def self.system(content : String) : Message
        new("system", content)
      end

      def self.user(content : String) : Message
        new("user", content)
      end

      def self.user(parts : Array(ContentPart)) : Message
        new("user", parts)
      end

      def self.assistant(content : String? = nil, tool_calls : Array(ToolCall)? = nil) : Message
        new("assistant", content || "", tool_calls)
      end

      # Build an assistant message from content parts directly (text + thinking,
      # or media blocks). Used by the agent loop when persisting reasoning.
      def self.assistant_parts(parts : Array(ContentPart), tool_calls : Array(ToolCall)? = nil) : Message
        new("assistant", parts, tool_calls)
      end

      def self.tool(content : String, tool_call_id : String) : Message
        new("tool", content, nil, tool_call_id)
      end

      # Build a tool-role message from explicit content parts — the multi-part
      # tool result shape (e.g. text + ImageContent media delivered by
      # ReadMediaFile). Mirrors the JS ContentPart[] tool result output.
      def self.tool_parts(parts : Array(ContentPart), tool_call_id : String) : Message
        new("tool", parts, nil, tool_call_id)
      end

      # Build a tool-role message pairing a text result with media data-URLs:
      # [TextContent(content)] + one media ContentPart per URL. Falls back to
      # a plain text tool message when no URL maps to a media part.
      def self.tool_with_media(content : String, media : Array(String), tool_call_id : String) : Message
        media_parts = media.compact_map { |url| ContentPart.from_data_url(url) }
        return tool(content, tool_call_id) if media_parts.empty?
        parts = [TextContent.new(content)] of ContentPart
        parts.concat(media_parts)
        tool_parts(parts, tool_call_id)
      end

      # Placeholder inserted by `without_media` when a message's content was
      # nothing but media blocks — keeps the message shape valid for
      # text-only endpoints.
      MEDIA_REMOVED_PLACEHOLDER = "[media content removed: this model only accepts text]"

      # A copy of this message with image/audio/video content parts removed.
      # Some models (e.g. GLM coding-plan endpoints) accept only
      # `{"type":"text"}` content blocks and reject anything else with
      # HTTP 400 ("messages.content.type is invalid, allowed values:
      # ['text']"). When every non-think part is media, a short text
      # placeholder keeps the message valid. ThinkContent is left in place —
      # it is lifted to `reasoning_content` at wire serialization and never
      # appears inside `content`.
      def without_media : Message
        has_media = @content.any? { |p| p.is_a?(ImageContent) || p.is_a?(AudioContent) || p.is_a?(VideoContent) }
        return self unless has_media
        kept = @content.reject { |p| p.is_a?(ImageContent) || p.is_a?(AudioContent) || p.is_a?(VideoContent) }
        kept = [TextContent.new(MEDIA_REMOVED_PLACEHOLDER)] of ContentPart if kept.empty?
        copy = self
        copy.content = kept
        copy
      end

      # Concatenated text of all TextContent parts. Equivalent to the kosong
      # `extractText(message)` — the plain-string view of the message for code
      # that doesn't care about thinking or media.
      def text : String
        ContentPart.extract_text(@content)
      end

      # Concatenated reasoning text of all ThinkContent parts. Empty when the
      # message has no thinking blocks.
      def thinking : String
        ContentPart.extract_thinking(@content)
      end

      def profiled_bytes : Int64
        total = @role.profiled_bytes
        total += @content.sum(&.profiled_bytes)
        total += @tool_calls.try(&.sum(&.profiled_bytes)) || 0_i64
        total += @tool_call_id.try(&.profiled_bytes) || 0_i64
        total
      end

      # Serialize this message to the OpenAI Chat Completions wire shape,
      # mirroring kosong's `convertMessage` (`providers/openai-legacy.ts` and
      # `providers/kimi.ts`). ThinkContent is stripped from `content` and its
      # concatenated text is emitted as a top-level `reasoning_content` field;
      # servers that don't understand the field ignore it, reasoners that do
      # round-trip the thinking. A single text-only part serializes `content`
      # as a plain string (the pre-multimodal shape); otherwise it is an array
      # of typed parts. An assistant message whose only content is empty text
      # alongside tool_calls omits `content` entirely.
      def to_wire_json(json : JSON::Builder) : Nil
        reasoning_content = String.build do |io|
          @content.each do |part|
            io << part.think if part.is_a?(ThinkContent)
          end
        end
        non_think_parts = @content.reject(ThinkContent)
        has_reasoning = !reasoning_content.empty?

        json.object do
          json.field "role", @role

          has_tool_calls = @tool_calls.try(&.empty?.!) || false
          empty_text_only = non_think_parts.all? do |p|
            p.is_a?(TextContent) && p.text.strip.empty?
          end
          omit_content = @role == "assistant" && has_tool_calls && empty_text_only &&
                         !non_think_parts.empty?

          unless omit_content
            if non_think_parts.size == 1 && (first = non_think_parts[0]).is_a?(TextContent)
              json.field "content", first.text
            elsif non_think_parts.size > 0
              json.field "content" do
                json.array do
                  non_think_parts.each(&.to_wire_json(json))
                end
              end
            end
          end

          if tcs = @tool_calls
            unless tcs.empty?
              json.field "tool_calls" do
                json.array do
                  tcs.each(&.to_json(json))
                end
              end
            end
          end

          if id = @tool_call_id
            json.field "tool_call_id", id
          end

          # Round-trip thinking content back to the server. Default to the de
          # facto `reasoning_content` field (DeepSeek / Qwen / Kimi). Servers
          # that don't understand the field ignore it.
          if has_reasoning
            json.field "reasoning_content", reasoning_content
          end
        end
      end
    end

    # How a provider transmits the reasoning-effort hint on the wire. Each
    # backend speaks a different dialect, so the chosen shape is per-provider
    # (mirrors the TS kosong adapters):
    #
    #   Moonshot        — top-level `thinking:{type, effort?}` object
    #                     (Moonshot-proprietary). `effort` only when the model
    #                     declares it in its `think_efforts.valid_efforts`.
    #   ReasoningEffort — top-level `reasoning_effort` string
    #                     (OpenAI / ZAI / Zhipu GLM). Plain value, no object.
    #   None            — backend has no effort control; nothing is sent.
    enum ThinkingWire
      None
      Moonshot
      ReasoningEffort
    end

    # Moonshot-proprietary thinking control, sent as a top-level `thinking`
    # object on the Chat Completions request body. `type: "enabled"` enables
    # reasoning; `effort` (low/high/max) scales the reasoning budget. `effort`
    # is only emitted when the model actually supports it — sending an
    # unsupported value (e.g. "medium" to the boolean-only `kimi-for-coding`)
    # is rejected with HTTP 400 by the endpoint.
    struct ThinkingConfig
      include JSON::Serializable

      property type : String
      @[JSON::Field(emit_null: false)]
      property effort : String?

      def initialize(@type : String, @effort : String? = nil)
      end
    end

    struct ChatRequest
      include JSON::Serializable

      property model : String
      property messages : Array(Message)
      property tools : Array(ToolDefinition)?
      property? stream : Bool = true
      property temperature : Float64?
      property max_tokens : Int32?
      # Preferred over the legacy `max_tokens` alias on the wire (matches the
      # Moonshot API contract). When both are set `max_completion_tokens`
      # is emitted and `max_tokens` is dropped.
      property max_completion_tokens : Int32?
      # Session affinity: the stable key under which the provider caches the
      # prompt prefix. Without it every step reprocesses the full, growing
      # context from scratch (O(N^2) over a sequential read loop).
      property prompt_cache_key : String?
      property thinking : ThinkingConfig?
      # OpenAI / ZAI / GLM reasoning-effort token (top-level string). Sent
      # instead of `thinking` for backends whose wire dialect is
      # `reasoning_effort` (see ThinkingWire::ReasoningEffort). `off`/`on` have
      # no wire encoding on these endpoints and are omitted.
      property reasoning_effort : String?
      # OpenAI-compatible parameter that lets the model emit multiple tool calls
      # in a single response. Without it some backends default to one call per
      # turn, which serialises multi-file reads.
      property parallel_tool_calls : Bool?
      # Provider-specific built-in tool definitions (e.g. Z.AI's
      # `{"type":"web_search","web_search":{"enable":true}}`) appended to the
      # `tools` array on the wire. Unlike `tools`, these are not function-call
      # tools that the client executes — the model uses them internally.
      property extra_tools : Array(JSON::Any)?

      def initialize(@model : String, @messages : Array(Message),
                     @tools : Array(ToolDefinition)? = nil,
                     @stream : Bool = true,
                     @temperature : Float64? = nil,
                     @max_tokens : Int32? = nil,
                     @max_completion_tokens : Int32? = nil,
                     @prompt_cache_key : String? = nil,
                     @parallel_tool_calls : Bool? = nil,
                     @extra_tools : Array(JSON::Any)? = nil)
      end

      # Disable any previously applied thinking hint. Provider-specific effort
      # resolution now lives on the provider (it needs model metadata), but this
      # keeps a request's thinking state clearable.
      def clear_thinking : Nil
        @thinking = nil
        @reasoning_effort = nil
      end

      def to_json(io : IO) : Nil
        JSON.build(io) do |json|
          json.object do
            json.field "model", @model
            json.field "messages" do
              json.array do
                @messages.each(&.to_wire_json(json))
              end
            end
            tools = @tools
            extra = @extra_tools
            has_tools = tools.try(&.empty?.!) || false
            has_extra = extra.try(&.empty?.!) || false
            if has_tools || has_extra
              json.field "tools" do
                json.array do
                  tools.try(&.each(&.to_json(json)))
                  extra.try(&.each(&.to_json(json)))
                end
              end
            end
            json.field "stream", @stream
            if temp = @temperature
              json.field "temperature", temp
            end
            if mct = @max_completion_tokens
              json.field "max_completion_tokens", mct
            elsif mt = @max_tokens
              json.field "max_tokens", mt
            end
            if key = @prompt_cache_key
              json.field "prompt_cache_key", key
            end
            if re = @reasoning_effort
              json.field "reasoning_effort", re
            end
            if ptc = @parallel_tool_calls
              json.field "parallel_tool_calls", ptc
            end
            if @stream
              json.field "stream_options" do
                json.object do
                  json.field "include_usage", true
                end
              end
            end
            if t = @thinking
              json.field "thinking" do
                json.object do
                  json.field "type", t.type
                  if e = t.effort
                    json.field "effort", e
                  end
                end
              end
            end
          end
        end
      end

      def to_json : String
        String.build { |io| to_json(io) }
      end
    end

    struct StreamChunk
      include JSON::Serializable

      property id : String?
      property object : String?
      property model : String?
      property choices : Array(StreamChoice) = [] of StreamChoice
      property usage : Usage?

      def initialize
      end
    end

    struct StreamChoice
      include JSON::Serializable

      property index : Int32 = 0
      property delta : Delta?
      property finish_reason : String?
      # Moonshot proprietary: usage may appear inside the first choice
      # instead of the top-level `usage` field. Mirrors the TS extractor
      # `extractUsageFromChunk` (kimi.ts:222).
      property usage : Usage?

      def initialize
      end
    end

    struct Delta
      include JSON::Serializable

      property role : String?
      property content : String?
      property reasoning_content : String?
      property tool_calls : Array(DeltaToolCall)?

      def initialize
      end
    end

    struct DeltaToolCall
      include JSON::Serializable

      property index : Int32 = 0
      property id : String?
      property type : String?
      property function : DeltaToolCallFunction?

      def initialize
      end
    end

    struct DeltaToolCallFunction
      include JSON::Serializable

      property name : String?
      property arguments : String?

      def initialize
      end
    end

    enum MessagePartType
      Text
      Think
      ToolCall
      Usage
      Finish
    end

    abstract class MessagePart
      property type : MessagePartType

      def initialize(@type : MessagePartType)
      end
    end

    class TextPart < MessagePart
      property text : String

      def initialize(@text : String)
        super(MessagePartType::Text)
      end
    end

    class ThinkPart < MessagePart
      property text : String

      def initialize(@text : String)
        super(MessagePartType::Think)
      end
    end

    class ToolCallPart < MessagePart
      property id : String
      property name : String
      property arguments : String

      def initialize(@id : String, @name : String, @arguments : String)
        super(MessagePartType::ToolCall)
      end
    end

    class UsagePart < MessagePart
      property usage : Usage

      def initialize(@usage : Usage)
        super(MessagePartType::Usage)
      end
    end

    class FinishPart < MessagePart
      property reason : String

      def initialize(@reason : String)
        super(MessagePartType::Finish)
      end
    end

    struct StepResult
      property stop_reason : String
      property text : String
      property thinking : String
      property tool_calls : Array(ToolCall)
      property usage : Usage

      def initialize(@stop_reason : String = "end_turn",
                     @text : String = "",
                     @thinking : String = "",
                     @tool_calls : Array(ToolCall) = [] of ToolCall,
                     @usage : Usage = Usage.new)
      end

      def tool_use? : Bool
        @stop_reason == "tool_use" || (@tool_calls.size > 0 && @stop_reason != "end_turn")
      end
    end

    struct TurnResult
      property stop_reason : String
      property steps : Int32
      property usage : Usage

      def initialize(@stop_reason : String = "end_turn",
                     @steps : Int32 = 0,
                     @usage : Usage = Usage.new)
      end
    end

    # Error returned by the upstream chat-completions endpoint.
    # Carries the HTTP status code and a precomputed `retryable?` flag so the
    # agent loop can decide whether to back off (transient) or fail fast
    # (e.g. 401/403/404 — retrying won't help).
    class ApiError < Exception
      getter status_code : Int32
      getter? retryable : Bool

      def initialize(@status_code : Int32, message : String, @retryable : Bool = true)
        super(message)
      end

      def self.retryable_status?(status_code : Int32) : Bool
        status_code == 408 || status_code == 429 || status_code >= 500
      end

      # True when the backend rejected the request because the message
      # history contained non-text content parts — text-only chat endpoints
      # answer with HTTP 400 and a body like "messages.content.type is
      # invalid, allowed values: ['text']". The agent loop intercepts this
      # to mark the model text-only (persisted in the user config), strip
      # media from history, and retry. The allowed-list check is anchored to
      # a text-only list so endpoints that accept text + images (their list
      # is `['text', 'image_url']`) are not misclassified.
      def text_only_rejection? : Bool
        return false unless @status_code == 400
        msg = message.to_s
        msg.includes?("content.type") && !!(msg =~ /allowed values:?\s*\[\s*'text'\s*\]/)
      end

      # Builds a human-readable error message from a raw HTTP response body.
      #
      # Backends usually wrap the message in `{"error":{"message":...,"type":...}}`
      # (OpenAI/Moonshot/Z.AI), but some return a bare `{"error":"..."}` or
      # `{"message":"..."}` / `{"detail":"..."}`. This strips the JSON envelope
      # and returns `<prefix>: <clean message>`. When the body is not JSON or
      # has no recognized field, the original body is returned unchanged so the
      # caller never loses information.
      def self.extract_message(prefix : String, body : String) : String
        return prefix if body.empty?
        clean = parse_error_message(body)
        clean ? "#{prefix}: #{clean}" : "#{prefix}: #{body}"
      end

      private def self.parse_error_message(body : String) : String?
        return nil unless body.starts_with?('{')

        json = JSON.parse(body) rescue nil
        return nil unless json

        if err = json["error"]?
          if h = err.as_h?
            return h["message"]?.try(&.as_s?)
          elsif s = err.as_s?
            return s
          end
        end
        json["message"]?.try(&.as_s?) ||
          json["detail"]?.try(&.as_s?)
      end
    end

    # Raised when an in-flight request is aborted by the user. Lets the
    # streaming worker unwind so the agent loop can surface a cancellation.
    class AbortedError < Exception
      def initialize(message : String = "request aborted")
        super(message)
      end
    end

    # Raised when the provider goes silent mid-request: either no first byte
    # within the stall timeout (server accepted the connection but never
    # started answering) or the SSE stream stalled after partial output.
    # Retryable by the agent loop's `RetryPolicy` — the request is re-issued,
    # which is exactly what a hung connection needs.
    class StreamTimeoutError < Exception
      def initialize(timeout_seconds : Number)
        super("Provider stalled: no data for #{timeout_seconds.to_i}s, aborting request")
      end
    end
  end
end
