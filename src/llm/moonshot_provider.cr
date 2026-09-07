module H2code
  module LLM
    class OAuthCredentials
      include JSON::Serializable

      property access_token : String
      property refresh_token : String
      property expires_at : Int64 = 0
      property token_type : String = "Bearer"
      property expires_in : Int32 = 900

      def initialize(@access_token : String, @refresh_token : String,
                     @expires_at : Int64 = 0, @token_type : String = "Bearer",
                     @expires_in : Int32 = 900)
      end

      def self.load(path : String) : OAuthCredentials?
        return nil unless File.exists?(path)
        from_json(File.read(path))
      rescue ex
        STDERR.puts "Warning: failed to load OAuth credentials: #{ex.message}"
        nil
      end

      def save(path : String) : Nil
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        File.write(path, to_json)
      end

      def expired? : Bool
        Time.unix(@expires_at) - Time.utc < 60.seconds
      end

      def refresh!(oauth_host : String, client_id : String,
                   transport : HttpTransport? = nil) : Nil
        form = "grant_type=refresh_token&refresh_token=#{URI.encode_path(@refresh_token)}&client_id=#{client_id}"
        headers = HTTP::Headers.new
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers["Accept"] = "application/json"

        # OAuth refresh uses a plaintext POST and does not go through the
        # OpenAIChatProvider transport; proxy support here is intentionally
        # minimal. Users behind a corporate proxy should refresh tokens via
        # `h2code --login` on a network path that does not require it, or set
        # the tokens manually.
        uri = URI.parse("#{oauth_host}/api/oauth/token")
        t = transport || HttpTransport::RealHttpTransport.new(->(u : URI) { HTTP::Client.new(u) })
        response = t.request("POST", uri, headers, form)
        if response.status_code == 200
          data = JSON.parse(response.body)
          @access_token = data["access_token"].to_s
          @refresh_token = data["refresh_token"].to_s
          @expires_in = data["expires_in"].to_s.to_i? || 900
          @expires_at = (Time.utc.to_unix + @expires_in)
          @token_type = data["token_type"]?.try(&.to_s) || "Bearer"
        else
          raise "Token refresh failed (#{response.status_code}): #{response.body}"
        end
      end

      def bearer_token : String
        @access_token
      end
    end

    # Moonshot (Kimi) backend over the OpenAI Chat Completions protocol.
    # Auth is either an API key or a refreshable OAuth token created by the
    # managed `kimi-code` login.
    class MoonshotProvider < OpenAIChatProvider
      DEFAULT_ENDPOINT = "https://api.kimi.com/coding/v1"
      property oauth_host : String = "https://auth.kimi.com"
      property oauth_client_id : String = "17e5f671-d194-4dfb-9706-5516cb48c098"
      property oauth : OAuthCredentials?

      def initialize(model : String,
                     endpoint : String = DEFAULT_ENDPOINT,
                     @oauth : OAuthCredentials? = nil,
                     api_key : String = "",
                     temperature : Float64? = nil,
                     max_tokens : Int32? = nil)
        super(model, endpoint, api_key, temperature, max_tokens)
        # Moonshot speaks the top-level `thinking:{type,effort?}` object
        # for reasoning control, so this backend resolves effort through the
        # Moonshot wire dialect.
        @thinking_wire = ThinkingWire::Moonshot
        # Moonshot transport speaks `max_completion_tokens` (not the legacy alias).
        @uses_max_completion_tokens = true
      end

      def name : String
        "moonshot"
      end

      def token : String
        if oauth = @oauth
          if oauth.expired?
            oauth.refresh!(@oauth_host, @oauth_client_id)
            oauth.save(credentials_path) if File.exists?(credentials_path)
          end
          return oauth.bearer_token
        end
        @api_key
      end

      private def credentials_path : String
        home = HomePort.home
        File.join(home, ".kimi-code", "credentials", "kimi-code.json")
      end
    end

    Provider.register("moonshot", "Moonshot — Chat Completions (default)",
      label: "Moonshot (Kimi)", needs_key: true,
      default_endpoint: "https://api.kimi.com/coding/v1",
      default_model: "kimi-for-coding",
      key_hint: "Get a key at https://www.kimi.com/code/console") do |config, oauth|
      if oauth.nil? && config.api_key.to_s.empty?
        raise ProviderConfigError.new(
          "No Moonshot credentials found. Either:\n" \
          "  1. Login with Moonshot's kimi-code CLI (creates ~/.kimi-code/credentials/kimi-code.json)\n" \
          "  2. Set MOONSHOT_API_KEY environment variable")
      end
      MoonshotProvider.new(
        model: config.model || "kimi-for-coding",
        endpoint: config.endpoint || MoonshotProvider::DEFAULT_ENDPOINT,
        oauth: oauth,
        api_key: config.api_key.to_s,
        temperature: config.temperature,
      )
    end
  end
end
