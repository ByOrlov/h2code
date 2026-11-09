module H2code
  module Tools
    # WebSearch — поиск в интернете через настроенный провайдер (по умолчанию
    # Moonshot). Тул регистрируется только если провайдер сконфигурирован.
    #
    # Контракт перенесён 1:1 из
    # `packages/agent-core-v2/src/app/auth/webSearch/tools/web-search.ts`.
    #
    # См. детальный план портирования в `md-tools/web-search.md`.
    class WebSearch < Tool
      MAX_CHARS          = 50_000
      TRUNCATION_MARKER  = "[...truncated]"
      TRUNCATION_MESSAGE = "Output is truncated to fit in the message."
      NO_RESULTS_MESSAGE = "No search results found."
      CITE_REMINDER      = "When you rely on a result in your answer, cite its source URL so the user can verify it."

      DESCRIPTION = <<-TEXT
        Search the web for information. Use this when you need up-to-date information from the internet.

        Each result includes its title, its URL, and a snippet, plus its source site and publication date when available. Results are short summaries, not full pages — when a result looks relevant, call the FetchURL tool on its URL to read the full page content. Fetch only the few URLs you actually need. Prefer specific queries, and refine the query if the results don't contain what you need.

        When you rely on a result in your answer, cite its source URL so the user can verify it.
      TEXT

      # Глобальный инжекченный сервис. nil → тул не регистрируется.
      @@service : WebSearchProviderService?

      def self.service=(s : WebSearchProviderService?) : Nil
        @@service = s
      end

      def self.service : WebSearchProviderService?
        @@service
      end

      def name : String
        Names::WEB_SEARCH
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "query": {
              "type": "string",
              "description": "The query text to search for."
            }
          },
          "required": ["query"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        query = input["query"]?.try(&.to_s) || ""

        service = @@service
        provider = service.try(&.get_web_search_provider)
        if provider.nil?
          reason = service.try(&.last_error)
          return ToolResult.error(reason ? "WebSearch is not available: #{reason}." : "WebSearch is not available: no search provider is configured.")
        end

        results = begin
          provider.search(query, nil, nil)
        rescue ex : AbortError
          raise ex
        rescue ex
          return ToolResult.error(classify_search_error(ex))
        end

        format_results(results)
      end

      # ------------------------------------------------------------------
      # Рендер
      # ------------------------------------------------------------------

      def format_results(results : Array(WebSearchResult)) : ToolResult
        return ToolResult.success(NO_RESULTS_MESSAGE) if results.empty?

        body = String.build do |io|
          results.each_with_index do |r, idx|
            io << "\n---\n\n" if idx > 0
            io << "Title: " << r.title << "\n"
            if site = r.site_name
              io << "Site: " << site << "\n" unless site.empty?
            end
            if date = r.date
              io << "Date: " << date << "\n" unless date.empty?
            end
            io << "URL: " << r.url << "\n"
            io << "Snippet: " << r.snippet << "\n"
          end
          io << "\n" << CITE_REMINDER
        end

        truncated, final = truncate_to_budget(body, MAX_CHARS)

        res = ToolResult.success(final)
        res.truncated = true if truncated
        res
      end

      def truncate_to_budget(text : String, max_chars : Int32) : {Bool, String}
        return {false, text} if text.size <= max_chars
        cut = max_chars - TRUNCATION_MARKER.size - TRUNCATION_MESSAGE.size - 2
        cut = 1 if cut < 1
        final = text[0, cut] + TRUNCATION_MARKER + ". " + TRUNCATION_MESSAGE
        {true, final}
      end

      def classify_search_error(ex : Exception) : String
        message = ex.message || ex.to_s
        name = ex.class.name

        # AbortError / abort.
        if name.includes?("AbortError") || message.downcase.includes?("abort")
          return "Search cancelled: #{message}"
        end

        # Timeout.
        if name.includes?("TimeoutError") ||
           message.downcase.includes?("timed out") ||
           message.downcase.includes?("timeout")
          return "Search timed out: #{message}"
        end

        down = message.downcase
        if down.includes?("401") || down.includes?("unauthorized") || down.includes?("auth")
          return "Search failed (authentication): #{message}"
        end

        if down.includes?("http ") || down.includes?("network") || down.includes?("fetch") ||
           name.includes?("TypeError")
          return "Search failed (network): #{message}"
        end

        "Search failed: #{message}"
      end
    end

    # --------------------------------------------------------------------
    # WebSearchProvider contract
    # --------------------------------------------------------------------

    struct WebSearchResult
      getter title : String
      getter url : String
      getter snippet : String
      getter date : String?
      getter site_name : String?

      def initialize(@title : String,
                     @url : String,
                     @snippet : String,
                     @date : String? = nil,
                     @site_name : String? = nil)
      end
    end

    abstract class WebSearchProvider
      abstract def search(query : String,
                          tool_call_id : String? = nil,
                          signal : AbortController? = nil) : Array(WebSearchResult)
    end

    abstract class WebSearchProviderService
      abstract def get_web_search_provider : WebSearchProvider?

      # Reason the last get_web_search_provider call returned nil because of
      # a failure (as opposed to "not configured"). Consumed by the CLI to
      # surface the problem in the TUI message log instead of only stderr.
      property last_error : String? = nil
    end

    # Конфигурируемый провайдер поиска через Moonshot API.
    # Поддерживает API-key или OAuth-token provider (для managed Kimi login).
    class MoonshotWebSearchProvider < WebSearchProvider
      @base_url : String
      @api_key : String?
      @token_provider : (-> String)?
      @default_headers : Hash(String, String)
      @custom_headers : Hash(String, String)
      @transport : HttpTransport

      def initialize(@base_url : String,
                     api_key : String? = nil,
                     token_provider : (-> String)? = nil,
                     @default_headers : Hash(String, String) = {} of String => String,
                     @custom_headers : Hash(String, String) = {} of String => String,
                     transport : HttpTransport? = nil)
        # trim; пустой → nil
        @api_key = api_key.try(&.strip).try { |s| s.empty? ? nil : s }
        @token_provider = token_provider
        @transport = transport || HttpTransport::RealHttpTransport.new(->(uri : URI) { HTTP::Client.new(uri) })
      end

      def search(query : String,
                 tool_call_id : String? = nil,
                 signal : AbortController? = nil) : Array(WebSearchResult)
        token = resolve_api_key
        body_json = %({"text_query":#{query.to_json}})

        headers = HTTP::Headers.new
        @default_headers.each { |k, v| headers[k] = v }
        headers["Authorization"] = "Bearer #{token}"
        headers["Content-Type"] = "application/json"
        headers["X-Msh-Tool-Call-Id"] = tool_call_id if tool_call_id && !tool_call_id.empty?
        @custom_headers.each { |k, v| headers[k] = v }

        uri = URI.parse(@base_url)

        response = @transport.request("POST", uri, headers, body_json)
        status = response.status_code
        detail = response.body

        if status == 401
          raise Exception.new("Moonshot search request failed: HTTP 401 (auth/unauthorized). #{detail}".strip)
        elsif status != 200
          raise Exception.new("Moonshot search request failed: HTTP #{status}. #{detail}".strip)
        end

        parse_results(response.body)
      end

      def parse_results(body : String) : Array(WebSearchResult)
        json = JSON.parse(body)
        raw = json["search_results"]?.try(&.as_a?) || [] of JSON::Any
        raw.map do |item|
          title = string_or(item["title"]?, "")
          url = string_or(item["url"]?, "")
          snippet = string_or(item["snippet"]?, "")
          date = optional_string(item["date"]?)
          site = optional_string(item["site_name"]?)
          WebSearchResult.new(title, url, snippet, date, site)
        end
      end

      private def resolve_api_key : String
        if tp = @token_provider
          return tp.call
        end
        if key = @api_key
          return key
        end
        raise Exception.new("Moonshot search service is not configured: missing API key or token provider.")
      end

      private def string_or(v : JSON::Any?, fallback : String) : String
        return fallback if v.nil?
        v.to_s
      end

      private def optional_string(v : JSON::Any?) : String?
        return nil if v.nil?
        s = v.to_s
        s.empty? ? nil : s
      end
    end

    # Composite service: config-managed провайдер, иначе nil.
    class ConfigWebSearchService < WebSearchProviderService
      @provider : WebSearchProvider?

      def initialize(base_url : String? = nil,
                     api_key : String? = nil,
                     default_headers : Hash(String, String) = {} of String => String,
                     custom_headers : Hash(String, String) = {} of String => String)
        if base_url && !base_url.empty?
          @provider = MoonshotWebSearchProvider.new(
            base_url: base_url,
            api_key: api_key,
            default_headers: default_headers,
            custom_headers: custom_headers)
        else
          @provider = nil
        end
      end

      def initialize(@provider : WebSearchProvider?)
      end

      def get_web_search_provider : WebSearchProvider?
        @provider
      end
    end

    # Provider-backed web search service: derives the search backend from the
    # active LLM provider. Z.AI / Zhipu search is intentionally not handled here
    # — Coding Plan uses the official remote MCP server configured in
    # Config#auto_mcp_servers, and the legacy direct `/web_search` REST endpoint
    # is unreliable on Coding Plan (returns 1113 without pay-as-you-go balance).
    #
    # For Moonshot the search URL is derived from the provider endpoint as
    # `<endpoint>/search` and the provider's live auth token (API key or OAuth)
    # is reused, mirroring the TS `ManagedWebSearchService`.
    class ProviderWebSearchService < WebSearchProviderService
      def initialize(@provider : LLM::Provider)
      end

      def get_web_search_provider : WebSearchProvider?
        return nil unless @provider.name == "moonshot"
        base = @provider.base_url
        return nil if base.nil? || base.empty?
        token = @provider.auth_token
        return nil if token.to_s.empty?

        provider = @provider
        search_url = base.rstrip('/') + "/search"
        MoonshotWebSearchProvider.new(
          base_url: search_url,
          token_provider: -> {
            provider.auth_token || raise Exception.new("Moonshot auth token became unavailable")
          },
        )
      rescue ex
        # This runs as a capability probe at CLI startup, before the main
        # begin/rescue of CLI.run: a failed OAuth refresh here means "web
        # search unavailable this session", not a crash. Record the reason
        # (the CLI surfaces it in the TUI message log) and keep it visible
        # on stderr; if the credentials are truly dead the same failure
        # surfaces loudly on the first real LLM request.
        @last_error = ex.message.to_s
        STDERR.puts "Warning: web search unavailable: #{ex.message}".colorize.yellow
        nil
      end
    end

    # Composite web search service: explicit config wins, otherwise fall back to
    # the provider-derived backend. Mirrors the TS `CompositeWebSearchService`.
    class CompositeWebSearchService < WebSearchProviderService
      def initialize(@config_service : WebSearchProviderService,
                     @provider_service : WebSearchProviderService)
      end

      def get_web_search_provider : WebSearchProvider?
        @config_service.get_web_search_provider || @provider_service.get_web_search_provider
      end

      def last_error : String?
        @provider_service.last_error
      end
    end
  end
end
