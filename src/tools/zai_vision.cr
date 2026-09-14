require "./zai_vision_prompts"

module H2code
  module Tools
    # Native Crystal port of Z.AI's official Vision MCP server
    # (`@z_ai/mcp-server`, Apache-2.0, (c) Z.AI — see
    # https://docs.z.ai/devpack/mcp/vision-mcp-server). The npm server runs as
    # a local Node.js subprocess; here the same eight tools call the Z.AI
    # vision model (`glm-5.3-flash` by default) directly over
    # `<paas>/chat/completions`, so no Node runtime is needed.
    #
    # Registered on demand: only when the active provider is the Z.AI Coding
    # Plan (`zai-coding-plan`) and `config.zai_api_key` is set (the same key
    # the chat provider uses — see ZaiProvider). The GLM coding-plan chat
    # models are text-only (they reject `image_url` content parts with HTTP
    # 400), so these tools are the vision path for Coding Plan users: the
    # image goes to the multimodal `glm-5.3-flash` (covered by the
    # subscription on the coding endpoint) from this tool, and only the
    # model's textual analysis enters the chat context.
    #
    # Wire format mirrors the npm server's ChatService#visionCompletions with
    # Z.AI's recommended glm-5.3-flash settings (see
    # docs.z.ai/guides/vlm/glm-5.3-flash): messages = [system?] +
    # [{role:"user", content:[media..., {text}]}], `thinking` enabled,
    # temperature 1, top_p 0.95, reasoning_effort max, max_tokens 128K.
    module ZaiVision
      # One media content part resolved from a tool input field: either the
      # original remote URL or a `data:<mime>;base64,...` URL of a local file.
      struct MediaPart
        getter kind : String # "image" | "video"
        getter url : String

        def initialize(@kind : String, @url : String)
        end
      end

      # API client for the Z.AI vision model. Injectable transport for tests.
      class Service
        DEFAULT_MODEL    = "glm-5.3-flash"
        DEFAULT_BASE_URL = "https://api.z.ai/api/paas/v4"
        # Coding Plan endpoint: same key, but the vision model calls are
        # covered by the subscription. The pay-as-you-go PaaS base rejects
        # Coding Plan keys with 1113 (no PaaS balance).
        CODING_PLAN_BASE_URL = "https://api.z.ai/api/coding/paas/v4"
        # npm server defaults: 300s timeout, 2 retries with exponential
        # backoff starting at 1s.
        DEFAULT_TIMEOUT = 300.seconds
        DEFAULT_RETRIES = 2

        # Service wired for the active provider: Coding Plan routes vision
        # calls to the coding endpoint, everything else (pay-as-you-go zai)
        # uses the PaaS base like the npm server does.
        def self.for_provider(provider_name : String, api_key : String) : Service
          base = provider_name == "zai-coding-plan" ? CODING_PLAN_BASE_URL : DEFAULT_BASE_URL
          new(api_key: api_key, base_url: base)
        end

        getter base_url : String

        def initialize(@api_key : String,
                       base_url : String = DEFAULT_BASE_URL,
                       @model : String = DEFAULT_MODEL,
                       transport : ::H2code::HttpTransport? = nil,
                       timeout : Time::Span = DEFAULT_TIMEOUT,
                       @retries : Int32 = DEFAULT_RETRIES)
          @base_url = base_url.rstrip('/')
          @transport = transport || ::H2code::HttpTransport::RealHttpTransport.new(->(uri : URI) do
            client = HTTP::Client.new(uri)
            client.connect_timeout = 15.seconds
            client.read_timeout = timeout
            client
          end)
        end

        # Run one vision analysis. `media` may be empty (pure-text call).
        # Returns the model's textual answer; raises on HTTP/parse errors.
        def analyze(system_prompt : String?, media : Array(MediaPart),
                    user_prompt : String) : String
          body = JSON.build do |j|
            j.object do
              j.field "model", @model
              j.field "messages" do
                j.array do
                  if system_prompt
                    j.object do
                      j.field "role", "system"
                      j.field "content", system_prompt
                    end
                  end
                  j.object do
                    j.field "role", "user"
                    j.field "content" do
                      j.array do
                        media.each do |m|
                          field = m.kind == "video" ? "video_url" : "image_url"
                          j.object do
                            j.field "type", field
                            j.field field do
                              j.object do
                                j.field "url", m.url
                              end
                            end
                          end
                        end
                        j.object do
                          j.field "type", "text"
                          j.field "text", user_prompt
                        end
                      end
                    end
                  end
                end
              end
              j.field "thinking" do
                j.object do
                  j.field "type", "enabled"
                end
              end
              j.field "stream", false
              # Sampling defaults per the official GLM-5.3-Flash docs
              # (docs.z.ai/guides/vlm/glm-5.3-flash): temperature 1, top_p
              # 0.95, reasoning_effort max, thinking always enabled.
              j.field "temperature", 1.0
              j.field "top_p", 0.95
              j.field "reasoning_effort", "max"
              j.field "max_tokens", 131072
            end
          end

          response = with_retries { post_chat_completions(body) }
          extract_content(response)
        end

        private def post_chat_completions(body : String) : String
          headers = HTTP::Headers.new
          headers["Authorization"] = "Bearer #{@api_key}"
          headers["Content-Type"] = "application/json"
          headers["X-Title"] = "h2code-zai-vision"
          headers["Accept-Language"] = "en-US,en"

          uri = URI.parse("#{@base_url}/chat/completions")
          response = @transport.request("POST", uri, headers, body)
          unless response.status_code == 200
            raise Exception.new("HTTP #{response.status_code}: #{response.body}")
          end
          response.body
        end

        private def extract_content(body : String) : String
          json = JSON.parse(body)
          content = json.dig?("choices", 0, "message", "content")
          text =
            if content.nil?
              ""
            elsif s = content.as_s?
              s
            elsif parts = content.as_a?
              # Tolerate the array content shape some gateways return: join
              # the text parts.
              parts.map { |p| p["text"]?.try(&.to_s).to_s }.join
            else
              ""
            end
          raise Exception.new("Invalid API response: missing content") if text.empty?
          text
        end

        private def with_retries(&block : -> String) : String
          attempts = @retries
          last_error : Exception? = nil
          (attempts + 1).times do |attempt|
            begin
              return block.call
            rescue ex
              last_error = ex
              sleep(1.second * (2 ** attempt)) if attempt < attempts
            end
          end
          if error = last_error
            raise error
          end
          raise Exception.new("with_retries: no attempt executed")
        end
      end

      # One configured vision tool: a fixed JSON schema, the media input
      # fields it consumes, and two hooks — how the user prompt is enhanced
      # with optional hints and how the system prompt is resolved from the
      # input (ui_to_artifact picks one per `output_type`). The eight
      # instances below match the npm server's registrations 1:1 (names,
      # schemas, descriptions, prompts, prompt enhancements).
      class Tool < ::H2code::Tools::Tool
        getter media_fields : Array(NamedTuple(field: String, kind: String))

        @system_resolver : JSON::Any -> String?
        @prompt_enhancer : JSON::Any, String -> String

        def initialize(@tool_name : String, @tool_description : String,
                       @params : JSON::Any,
                       @media_fields : Array(NamedTuple(field: String, kind: String)),
                       system_resolver : (Proc(JSON::Any, String?) | Proc(JSON::Any, String)) = ->(_input : JSON::Any) { nil },
                       @prompt_enhancer : JSON::Any, String -> String = ->(_input : JSON::Any, prompt : String) { prompt })
          # Normalize the resolver to Proc(JSON::Any, String?) — Crystal procs
          # are not return-covariant, so a Proc(JSON::Any, String) cannot be
          # stored in the nilable-returning ivar directly.
          @system_resolver = Proc(JSON::Any, String?).new { |input| system_resolver.call(input) }
        end

        def name : String
          @tool_name
        end

        def description : String
          @tool_description
        end

        def parameters : JSON::Any
          @params
        end

        def execute(input : JSON::Any) : ToolResult
          service = self.class.service
          unless service
            return ToolResult.error("Z.AI vision tools are not available: no Z.AI API key is configured.")
          end

          prompt = input["prompt"]?.try(&.to_s) || ""
          if prompt.strip.empty?
            return ToolResult.error("Prompt is required for #{name}.")
          end

          media = [] of MediaPart
          @media_fields.each do |mf|
            source = input[mf[:field]]?.try(&.to_s) || ""
            if source.empty?
              return ToolResult.error("#{mf[:field]} is required for #{name}.")
            end
            begin
              media << resolve_media(source, mf[:kind])
            rescue ex
              return ToolResult.error(ex.message.to_s)
            end
          end

          system_prompt = @system_resolver.call(input)
          user_prompt = @prompt_enhancer.call(input, prompt)

          content = service.analyze(system_prompt, media, user_prompt)
          ToolResult.success(self.class.sanitize_output(content))
        rescue ex
          ToolResult.error("Z.AI vision analysis failed: #{ex.message}")
        end

        # ------------------------------------------------------------------
        # Media resolution (mirrors the npm FileService): remote http(s) URLs
        # and data: URLs pass through; local files are validated (existence,
        # size, extension) and inlined as base64 data URLs.
        # ------------------------------------------------------------------

        MAX_IMAGE_MB = 5
        MAX_VIDEO_MB = 8
        IMAGE_EXTS   = [".jpg", ".jpeg", ".png"]

        private def resolve_media(source : String, kind : String) : MediaPart
          return MediaPart.new(kind, source) if url?(source) || source.starts_with?("data:")

          unless File.exists?(source)
            raise Exception.new("File not found: #{source}")
          end

          size_mb = File.size(source).to_f / (1024 * 1024)
          if kind == "video"
            if size_mb > MAX_VIDEO_MB
              raise Exception.new("Video file too large: #{size_mb.round(2)}MB. Maximum allowed: #{MAX_VIDEO_MB}MB.")
            end
            mime = video_mime(source)
          else
            if size_mb > MAX_IMAGE_MB
              raise Exception.new("Image file too large: #{size_mb.round(2)}MB. Maximum allowed: #{MAX_IMAGE_MB}MB.")
            end
            ext = File.extname(source).downcase
            unless IMAGE_EXTS.includes?(ext)
              raise Exception.new("Unsupported image format: #{ext}. Supported formats: #{IMAGE_EXTS.join(", ")}")
            end
            mime = image_mime(ext)
          end

          data = File.open(source, "rb") { |f| Base64.strict_encode(f.getb_to_end) }
          MediaPart.new(kind, "data:#{mime};base64,#{data}")
        end

        private def url?(source : String) : Bool
          source.starts_with?("http://") || source.starts_with?("https://")
        end

        private def image_mime(ext : String) : String
          case ext
          when ".jpg", ".jpeg" then "image/jpeg"
          else                      "image/png"
          end
        end

        private def video_mime(path : String) : String
          case File.extname(path).downcase
          when ".avi"  then "video/x-msvideo"
          when ".mov"  then "video/quicktime"
          when ".wmv"  then "video/x-ms-wmv"
          when ".webm" then "video/webm"
          when ".m4v"  then "video/x-m4v"
          else              "video/mp4"
          end
        end

        # ------------------------------------------------------------------
        # Registry glue
        # ------------------------------------------------------------------

        # Global injected service. nil → tools answer with a clear error
        # instead of being registered (see the wiring in h2code.cr / ACP).
        @@service : Service?

        def self.service=(s : Service?) : Nil
          @@service = s
        end

        def self.service : Service?
          @@service
        end

        # Whether the vision tools should be wired up for this session. Only
        # the Coding Plan provider: its key covers glm-5.3-flash calls on the
        # coding endpoint (verified by `rake integration:zai_vision_mcp`),
        # while the chat models there are text-only — so this is the one
        # combination where the tools are both needed and covered.
        def self.available?(provider_name : String?, api_key : String) : Bool
          return false unless provider_name == "zai-coding-plan"
          !api_key.strip.empty?
        end

        # All eight tools, in the npm server's registration order.
        def self.all : Array(::H2code::Tools::Tool)
          # Optional-hint enhancers: append the same XML-tagged block the npm
          # services append when the optional parameter is present.
          language_hint = ->(input : JSON::Any, prompt : String) do
            v = optional_hint(input, "programming_language")
            v ? "#{prompt}\n\n<language_hint>The code is in #{v}.</language_hint>" : prompt
          end
          error_context = ->(input : JSON::Any, prompt : String) do
            v = optional_hint(input, "context")
            v ? "#{prompt}\n\n<error_context>This error occurred #{v}.</error_context>" : prompt
          end
          diagram_hint = ->(input : JSON::Any, prompt : String) do
            v = optional_hint(input, "diagram_type")
            v ? "#{prompt}\n\n<diagram_type_hint>This is a #{v} diagram.</diagram_type_hint>" : prompt
          end
          focus_hint = ->(input : JSON::Any, prompt : String) do
            v = optional_hint(input, "analysis_focus")
            v ? "#{prompt}\n\n<analysis_focus>Focus particularly on: #{v}.</analysis_focus>" : prompt
          end
          ui_artifact_resolver = ->(input : JSON::Any) do
            output_type = input["output_type"]?.try(&.to_s) || ""
            prompt = ZaiVisionPrompts::UI_TO_ARTIFACT_PROMPTS[output_type]?
            prompt || (raise Exception.new("Invalid output_type '#{output_type}'. Must be one of: code, prompt, spec, description"))
          end

          image = {field: "image_source", kind: "image"}
          ui_to_artifact_schema = schema(<<-JSON)
            {
              "type": "object",
              "properties": {
                "image_source": {"type": "string", "description": "Local file path or remote URL to the image"},
                "output_type": {"type": "string", "enum": ["code", "prompt", "spec", "description"], "description": "Type of output to generate. Options: 'code' (generate frontend code), 'prompt' (generate AI prompt for recreating this UI), 'spec' (generate design specification document), 'description' (natural language description of the UI)."},
                "prompt": {"type": "string", "description": "Detailed instructions describing what to generate from this UI image. Should clearly state the desired output and any specific requirements."}
              },
              "required": ["image_source", "output_type", "prompt"],
              "additionalProperties": false
            }
            JSON
          extract_text_schema = schema(<<-JSON)
            {
              "type": "object",
              "properties": {
                "image_source": {"type": "string", "description": "Local file path or remote URL to the image"},
                "prompt": {"type": "string", "description": "Instructions for text extraction. Specify what type of text to extract and any formatting requirements."},
                "programming_language": {"type": "string", "description": "Optional: specify the programming language if the screenshot contains code (e.g., 'python', 'javascript', 'java'). Leave empty for auto-detection or non-code text."}
              },
              "required": ["image_source", "prompt"],
              "additionalProperties": false
            }
            JSON
          diagnose_error_schema = schema(<<-JSON)
            {
              "type": "object",
              "properties": {
                "image_source": {"type": "string", "description": "Local file path or remote URL to the image"},
                "prompt": {"type": "string", "description": "Description of what you need help with regarding this error. Include any relevant context about when it occurred."},
                "context": {"type": "string", "description": "Optional: additional context about when the error occurred (e.g., 'during npm install', 'when running the app', 'after deployment'). Helps with more accurate diagnosis."}
              },
              "required": ["image_source", "prompt"],
              "additionalProperties": false
            }
            JSON
          diagram_schema = schema(<<-JSON)
            {
              "type": "object",
              "properties": {
                "image_source": {"type": "string", "description": "Local file path or remote URL to the image"},
                "prompt": {"type": "string", "description": "What you want to understand or extract from this diagram."},
                "diagram_type": {"type": "string", "description": "Optional: specify the diagram type if known (e.g., 'architecture', 'flowchart', 'uml', 'er-diagram', 'sequence'). Leave empty for auto-detection."}
              },
              "required": ["image_source", "prompt"],
              "additionalProperties": false
            }
            JSON
          data_viz_schema = schema(<<-JSON)
            {
              "type": "object",
              "properties": {
                "image_source": {"type": "string", "description": "Local file path or remote URL to the image"},
                "prompt": {"type": "string", "description": "What insights or information you want to extract from this visualization."},
                "analysis_focus": {"type": "string", "description": "Optional: specify what to focus on (e.g., 'trends', 'anomalies', 'comparisons', 'performance metrics'). Leave empty for comprehensive analysis."}
              },
              "required": ["image_source", "prompt"],
              "additionalProperties": false
            }
            JSON
          ui_diff_schema = schema(<<-JSON)
            {
              "type": "object",
              "properties": {
                "expected_image_source": {"type": "string", "description": "Local file path or remote URL to the image"},
                "actual_image_source": {"type": "string", "description": "Local file path or remote URL to the image"},
                "prompt": {"type": "string", "description": "Instructions for the comparison. Specify what aspects to focus on or what level of detail is needed."}
              },
              "required": ["expected_image_source", "actual_image_source", "prompt"],
              "additionalProperties": false
            }
            JSON
          analyze_image_schema = schema(<<-JSON)
            {
              "type": "object",
              "properties": {
                "image_source": {"type": "string", "description": "Local file path or remote URL to the image"},
                "prompt": {"type": "string", "description": "Detailed description of what you want to analyze, extract, or understand from the image. Be specific about your requirements."}
              },
              "required": ["image_source", "prompt"],
              "additionalProperties": false
            }
            JSON
          analyze_video_schema = schema(<<-JSON)
            {
              "type": "object",
              "properties": {
                "video_source": {"type": "string", "description": "Local file path or remote URL to the video (supports MP4, MOV, M4V)"},
                "prompt": {"type": "string", "description": "Detailed text prompt describing what to analyze, extract, or understand from the video"}
              },
              "required": ["video_source", "prompt"],
              "additionalProperties": false
            }
            JSON

          [
            Tool.new(Names::UI_TO_ARTIFACT, ZaiVisionPrompts::TOOL_DESCRIPTION_UI_TO_ARTIFACT,
              ui_to_artifact_schema, [image], ui_artifact_resolver),
            Tool.new(Names::EXTRACT_TEXT_FROM_SCREENSHOT, ZaiVisionPrompts::TOOL_DESCRIPTION_EXTRACT_TEXT_FROM_SCREENSHOT,
              extract_text_schema, [image],
              ->(_input : JSON::Any) { ZaiVisionPrompts::TEXT_EXTRACTION_PROMPT }, language_hint),
            Tool.new(Names::DIAGNOSE_ERROR_SCREENSHOT, ZaiVisionPrompts::TOOL_DESCRIPTION_DIAGNOSE_ERROR_SCREENSHOT,
              diagnose_error_schema, [image],
              ->(_input : JSON::Any) { ZaiVisionPrompts::ERROR_DIAGNOSIS_PROMPT }, error_context),
            Tool.new(Names::UNDERSTAND_TECHNICAL_DIAGRAM, ZaiVisionPrompts::TOOL_DESCRIPTION_UNDERSTAND_TECHNICAL_DIAGRAM,
              diagram_schema, [image],
              ->(_input : JSON::Any) { ZaiVisionPrompts::DIAGRAM_UNDERSTANDING_PROMPT }, diagram_hint),
            Tool.new(Names::ANALYZE_DATA_VISUALIZATION, ZaiVisionPrompts::TOOL_DESCRIPTION_ANALYZE_DATA_VISUALIZATION,
              data_viz_schema, [image],
              ->(_input : JSON::Any) { ZaiVisionPrompts::DATA_VIZ_ANALYSIS_PROMPT }, focus_hint),
            Tool.new(Names::UI_DIFF_CHECK, ZaiVisionPrompts::TOOL_DESCRIPTION_UI_DIFF_CHECK,
              ui_diff_schema,
              [{field: "expected_image_source", kind: "image"}, {field: "actual_image_source", kind: "image"}],
              ->(_input : JSON::Any) { ZaiVisionPrompts::UI_DIFF_CHECK_PROMPT }),
            Tool.new(Names::ANALYZE_IMAGE, ZaiVisionPrompts::TOOL_DESCRIPTION_ANALYZE_IMAGE,
              analyze_image_schema, [image],
              ->(_input : JSON::Any) { ZaiVisionPrompts::GENERAL_IMAGE_ANALYSIS_PROMPT }),
            Tool.new(Names::ANALYZE_VIDEO, ZaiVisionPrompts::TOOL_DESCRIPTION_ANALYZE_VIDEO,
              analyze_video_schema, [{field: "video_source", kind: "video"}]),
          ] of ::H2code::Tools::Tool
        end

        private def self.optional_hint(input : JSON::Any, key : String) : String?
          v = input[key]?.try(&.to_s) || ""
          v.strip.empty? ? nil : v
        end

        private def self.schema(json : String) : JSON::Any
          JSON.parse(json)
        end
      end
    end
  end
end
