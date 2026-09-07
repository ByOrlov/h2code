module H2code
  module Auth
    # OAuth device-code flow for Moonshot (Kimi Code).
    #
    # Implements RFC 8628 Device Authorization Grant against the Kimi Code
    # auth endpoint. The user opens a browser URL, authorizes, and this flow
    # polls until tokens arrive. Mirrors
    # `packages/oauth/src/oauth.ts` (requestDeviceAuthorization +
    # pollDeviceToken).
    #
    # Tokens are stored as `LLM::OAuthCredentials` (JSON) at the standard
    # kimi-code credentials path so they are interchangeable with the TS CLI.
    module OAuth
      DEFAULT_OAUTH_HOST       = "https://auth.kimi.com"
      DEFAULT_CLIENT_ID        = "17e5f671-d194-4dfb-9706-5516cb48c098"
      DEFAULT_CREDENTIALS_PATH = File.join(HomePort.home, ".kimi-code", "credentials", "kimi-code.json")

      # Result of the device-authorization request.
      struct DeviceAuthorization
        getter user_code : String
        getter device_code : String
        getter verification_uri : String
        getter verification_uri_complete : String
        getter interval : Int32

        def initialize(@user_code : String, @device_code : String,
                       @verification_uri : String,
                       @verification_uri_complete : String,
                       @interval : Int32 = 5)
        end
      end

      class OAuthError < Exception
      end

      # Request device authorization. Returns the user code + verification URL
      # the user must open in a browser.
      def self.request_device_authorization(
        oauth_host : String = DEFAULT_OAUTH_HOST,
        client_id : String = DEFAULT_CLIENT_ID,
      ) : DeviceAuthorization
        url = "#{oauth_host.chomp('/')}/api/oauth/device_authorization"
        body = "client_id=#{URI.encode_path(client_id)}"

        response = http_post_form(url, body)
        unless response.status_code == 200
          raise OAuthError.new("Device authorization failed (HTTP #{response.status_code}): #{response.body}")
        end

        data = JSON.parse(response.body)
        user_code = data["user_code"]?.try(&.as_s?)
        device_code = data["device_code"]?.try(&.as_s?)
        verification_complete = data["verification_uri_complete"]?.try(&.as_s?)

        raise OAuthError.new("Device authorization response missing user_code") if user_code.nil? || user_code.empty?
        raise OAuthError.new("Device authorization response missing device_code") if device_code.nil? || device_code.empty?
        raise OAuthError.new("Device authorization response missing verification_uri_complete") if verification_complete.nil? || verification_complete.empty?

        verification_uri = data["verification_uri"]?.try(&.as_s?) || ""
        interval = data["interval"]?.try(&.as_i?) || 5

        DeviceAuthorization.new(user_code, device_code, verification_uri, verification_complete, interval)
      end

      # Polling result variants.
      enum PollResultKind
        Success
        Pending
        Expired
        Denied
      end

      struct PollResult
        getter kind : PollResultKind
        getter credentials : LLM::OAuthCredentials?
        getter description : String

        def initialize(@kind : PollResultKind,
                       @credentials : LLM::OAuthCredentials? = nil,
                       @description : String = "")
        end

        def success? : Bool
          @kind == PollResultKind::Success
        end

        def pending? : Bool
          @kind == PollResultKind::Pending
        end
      end

      # Poll once for the device token. Call this on an interval until it
      # returns Success, Expired, or Denied.
      def self.poll_device_token(
        device_code : String,
        oauth_host : String = DEFAULT_OAUTH_HOST,
        client_id : String = DEFAULT_CLIENT_ID,
      ) : PollResult
        url = "#{oauth_host.chomp('/')}/api/oauth/token"
        body = "client_id=#{URI.encode_path(client_id)}&device_code=#{URI.encode_path(device_code)}&grant_type=urn:ietf:params:oauth:grant-type:device_code"

        response = http_post_form(url, body)

        if response.status_code == 200
          data = JSON.parse(response.body)
          access_token = data["access_token"]?.try(&.as_s?)
          if access_token
            creds = parse_token_response(data)
            return PollResult.new(PollResultKind::Success, creds)
          end
        end

        if response.status_code >= 500
          raise OAuthError.new("Device token polling server error (HTTP #{response.status_code}): #{response.body}")
        end

        data = JSON.parse(response.body) rescue JSON::Any.new({} of String => JSON::Any)
        error_code = data["error"]?.try(&.as_s?) || "unknown_error"
        description = data["error_description"]?.try(&.as_s?) || ""

        case error_code
        when "authorization_pending", "slow_down"
          PollResult.new(PollResultKind::Pending, description: description)
        when "expired_token"
          PollResult.new(PollResultKind::Expired)
        when "access_denied"
          PollResult.new(PollResultKind::Denied, description: description)
        else
          raise OAuthError.new("Device token polling failed (HTTP #{response.status_code}): #{error_code} #{description}")
        end
      end

      # Run the full device-code flow: request authorization, poll until the
      # user authorizes (or it expires/is denied), save credentials.
      #
      # `on_authorization` is called with the DeviceAuthorization so the UI
      # can show the verification URL to the user before polling starts.
      # `on_pending` is called on each poll attempt (for a progress spinner).
      # Returns the saved credentials.
      def self.login(
        oauth_host : String = DEFAULT_OAUTH_HOST,
        client_id : String = DEFAULT_CLIENT_ID,
        credentials_path : String = DEFAULT_CREDENTIALS_PATH,
        max_attempts : Int32 = 60,
        &on_authorization : DeviceAuthorization ->
      ) : LLM::OAuthCredentials
        auth = request_device_authorization(oauth_host, client_id)
        on_authorization.call(auth)

        interval = auth.interval
        max_attempts.times do
          result = poll_device_token(auth.device_code, oauth_host, client_id)
          case result.kind
          when PollResultKind::Success
            creds = result.credentials || raise "credentials required for Success"
            creds.save(credentials_path)
            return creds
          when PollResultKind::Pending
            sleep interval.seconds
          when PollResultKind::Expired
            raise OAuthError.new("Device authorization expired. Run /login again.")
          when PollResultKind::Denied
            raise OAuthError.new("Authorization denied: #{result.description}")
          end
        end

        raise OAuthError.new("Timed out waiting for authorization after #{max_attempts} attempts.")
      end

      # Parse the token response JSON into OAuthCredentials.
      private def self.parse_token_response(data : JSON::Any) : LLM::OAuthCredentials
        access_token = data["access_token"].as_s
        refresh_token = data["refresh_token"]?.try(&.as_s?) || ""
        expires_in = data["expires_in"]?.try(&.as_i?) || data["expires_in"]?.try(&.as_s?).try(&.to_i?) || 900
        token_type = data["token_type"]?.try(&.as_s?) || "Bearer"
        expires_at = Time.utc.to_unix + expires_in

        LLM::OAuthCredentials.new(
          access_token: access_token,
          refresh_token: refresh_token,
          expires_at: expires_at,
          token_type: token_type,
          expires_in: expires_in,
        )
      end

      private def self.http_post_form(url : String, body : String) : HTTP::Client::Response
        uri = URI.parse(url)
        tls = uri.scheme == "https" ? OpenSSL::SSL::Context::Client.new : nil
        client = HTTP::Client.new(uri, tls: tls)

        headers = HTTP::Headers.new
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers["Accept"] = "application/json"

        response = client.post(uri.request_target, headers: headers, body: body)
        client.close
        response
      rescue ex : OAuthError
        raise ex
      rescue ex
        raise OAuthError.new("Network error during OAuth request to #{url}: #{ex.message}")
      end
    end
  end
end
