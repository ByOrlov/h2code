require "http/client"
require "http/server"
require "json"
require "uri"
require "base64"
require "random/secure"

require "../h2code_home"
require "digest/sha256"
require "file_utils"

module H2code
  module Mcp
    class OAuthError < Exception
    end

    # Persisted OAuth token set for one MCP server. Stored as JSON at
    # `~/.h2code/mcp-tokens/<server>.json` so reconnections reuse the same
    # access token until it expires (then refresh).
    struct OAuthTokens
      include JSON::Serializable

      property access_token : String
      @[JSON::Field(emit_null: false)]
      property refresh_token : String?
      @[JSON::Field(emit_null: false)]
      property token_type : String?
      property expires_at : Int64? # unix seconds
      @[JSON::Field(emit_null: false)]
      property scope : String?

      def initialize(@access_token : String, @refresh_token : String? = nil,
                     @token_type : String? = "Bearer", @expires_at : Int64? = nil,
                     @scope : String? = nil)
      end

      def expired? : Bool
        return false unless exp = @expires_at
        Time.utc.to_unix >= exp - 60
      end

      def bearer? : Bool
        (@token_type || "Bearer").downcase == "bearer"
      end
    end

    # Authorization server metadata (RFC 8414 + MCP-specific `resource_metadata`
    # from RFC 9728). Only the fields we consume are decoded.
    struct ServerMetadata
      getter authorization_endpoint : String?
      getter token_endpoint : String?
      getter registration_endpoint : String?
      getter revocation_endpoint : String?

      def initialize(@authorization_endpoint : String? = nil, @token_endpoint : String? = nil,
                     @registration_endpoint : String? = nil, @revocation_endpoint : String? = nil)
      end
    end

    # Full OAuth 2.1 Authorization Code + PKCE flow for MCP HTTP servers.
    #
    # Flow:
    #  1. Discover the resource metadata (RFC 9728) at the MCP server URL.
    #  2. Fetch the authorization server metadata (RFC 8414).
    #  3. Register a client dynamically (RFC 7591) if no client_id is provided.
    #  4. Generate a PKCE verifier/challenge pair.
    #  5. Start a localhost callback HTTP server.
    #  6. Emit the authorization URL for the user to open in a browser.
    #  7. Exchange the callback code for tokens.
    #  8. Persist tokens and return them.
    #
    # Reconnection reuses the stored tokens; if they expired, a refresh-token
    # grant runs automatically before prompting the user again.
    module OAuth
      CODE_VERIFIER_LEN = 64
      STATE_LEN         = 32

      # Try to load persisted tokens for `server_name` + `server_url` from the
      # h2code credentials dir. Mirrors JS `JsonFileStore.read`.
      def self.load_tokens(server_name : String, server_url : String, home_dir : String) : OAuthTokens?
        path = tokens_path(server_name, server_url, home_dir)
        return nil unless File.exists?(path)
        OAuthTokens.from_json(File.read(path))
      rescue ex
        nil
      end

      # Persist tokens via atomic write (temp → fsync → rename) at mode 0600,
      # under `<h2code_home>/credentials/mcp/` at mode 0700. Mirrors JS
      # `JsonFileStore.write`.
      def self.save_tokens(server_name : String, server_url : String,
                           home_dir : String, tokens : OAuthTokens) : Nil
        dir = credentials_dir(home_dir)
        ensure_credentials_dir(dir)
        target = tokens_path(server_name, server_url, home_dir)
        tmp = "#{target}.tmp.#{Process.pid}.#{Random::Secure.hex(4)}"

        File.open(tmp, "w", perm: 0o600) do |f|
          f << tokens.to_json
          f << '\n'
          f.flush
          f.fsync
        end
        # Best-effort chmod (POSIX only; Windows ignores).
        File.chmod(tmp, 0o600) rescue nil
        File.rename(tmp, target)
      rescue ex
        File.delete(tmp) rescue nil if tmp
        raise ex
      end

      # Clear persisted tokens (used on auth failure or server removal).
      def self.clear_tokens(server_name : String, server_url : String, home_dir : String) : Nil
        path = tokens_path(server_name, server_url, home_dir)
        File.delete(path) if File.exists?(path)
      rescue
      end

      private def self.credentials_dir(home_dir : String) : String
        File.join(H2codeHome.path_for(home_dir), "credentials", "mcp")
      end

      private def self.ensure_credentials_dir(dir : String) : Nil
        Dir.mkdir_p(dir)
        File.chmod(dir, 0o700) rescue nil
      end

      # Store key: `<safeName>-<sha256(serverName\0canonicalUrl)[0..23]>`.
      # Includes the URL so one server with two different URLs produces two
      # files. Mirrors JS `mcpOAuthStoreKey`.
      private def self.tokens_path(server_name : String, server_url : String, home_dir : String) : String
        key = store_key(server_name, server_url)
        File.join(credentials_dir(home_dir), "#{key}.json")
      end

      def self.store_key(server_name : String, server_url : String) : String
        safe = sanitize_store_key(server_name)
        canonical = canonical_url(server_url)
        digest = Digest::SHA256.hexdigest("#{server_name}\0#{canonical}")[0...24]
        "#{safe}-#{digest}"
      end

      private def self.sanitize_store_key(name : String) : String
        # Strip path-traversal segments, collapse underscores.
        safe = File.basename(name).gsub(/[^A-Za-z0-9_-]/, "_").gsub(/_+/, "_")
        safe.empty? || safe.starts_with?('.') ? "server" : safe
      end

      # Canonical URL: strip the hash fragment. Mirrors JS
      # `canonicalMcpOAuthResource`.
      private def self.canonical_url(server_url : String) : String
        uri = URI.parse(server_url)
        uri.fragment = nil
        uri.to_s
      rescue
        server_url
      end

      # Attempt a token refresh via the stored refresh_token. Returns the new
      # tokens on success, nil if the refresh failed (caller should re-auth).
      def self.refresh(server_name : String, server_url : String, home_dir : String,
                       tokens : OAuthTokens, metadata : ServerMetadata) : OAuthTokens?
        return nil unless refresh_tok = tokens.refresh_token
        return nil unless token_ep = metadata.token_endpoint

        body = URI::Params.encode({
          "grant_type"    => "refresh_token",
          "refresh_token" => refresh_tok,
        })

        resp = http_post_form(token_ep, body)
        return nil unless resp.status_code == 200

        data = JSON.parse(resp.body)
        new_tokens = build_tokens(data)
        save_tokens(server_name, server_url, home_dir, new_tokens)
        new_tokens
      rescue
        nil
      end

      # Run the full authorization-code + PKCE flow. `on_authorization` is
      # called with the URL the user must open in a browser. Blocks until the
      # user completes authorization (or times out / errors).
      #
      # The callback server binds a random free port (port 0) so two parallel
      # MCP OAuth flows never collide — mirrors JS `callback-server.ts`.
      def self.authorize(server_url : String, server_name : String, home_dir : String,
                         client_id : String? = nil, client_secret : String? = nil,
                         scopes : Array(String)? = nil,
                         &on_authorization : String ->) : OAuthTokens
        metadata = discover_metadata(server_url)

        unless metadata.authorization_endpoint && metadata.token_endpoint
          raise OAuthError.new("OAuth discovery failed: server '#{server_name}' did not return authorization_endpoint + token_endpoint")
        end

        # Start the callback server FIRST on a dynamic port, so the redirect_uri
        # is known before DCR and auth_url construction.
        state = random_hex(STATE_LEN)
        callback = start_callback_server(state)
        redirect_uri = callback.redirect_uri

        # Register a client dynamically if none was provided.
        registered_cid = client_id
        registered_secret = client_secret
        if registered_cid.nil?
          if reg_ep = metadata.registration_endpoint
            registered_cid, registered_secret = register_client(reg_ep, redirect_uri)
          end
        end

        # Clean up the callback server if we bail out before the flow completes.
        unless registered_cid
          callback.server.close rescue nil
          raise OAuthError.new("No client_id available (DCR failed or not supported)")
        end

        verifier = generate_code_verifier
        challenge = pkce_challenge(verifier)

        auth_params = URI::Params.new
        auth_params["response_type"] = "code"
        auth_params["client_id"] = registered_cid
        auth_params["redirect_uri"] = redirect_uri
        auth_params["code_challenge"] = challenge
        auth_params["code_challenge_method"] = "S256"
        auth_params["state"] = state
        if scopes && !scopes.empty?
          auth_params["scope"] = scopes.join(" ")
        end

        auth_url = "#{metadata.authorization_endpoint}?#{auth_params}"
        on_authorization.call(auth_url)

        code = wait_for_code(callback, state)

        # Exchange the authorization code for tokens.
        token_params = URI::Params.encode({
          "grant_type"    => "authorization_code",
          "code"          => code,
          "redirect_uri"  => redirect_uri,
          "client_id"     => registered_cid,
          "code_verifier" => verifier,
        })
        token_params += "&client_secret=#{URI.encode_www_form(registered_secret)}" if registered_secret

        unless token_ep = metadata.token_endpoint
          raise OAuthError.new("OAuth: no token_endpoint in server metadata")
        end
        resp = http_post_form(token_ep, token_params)
        unless resp.status_code == 200
          raise OAuthError.new("Token exchange failed (HTTP #{resp.status_code}): #{resp.body[0...500]}")
        end

        data = JSON.parse(resp.body)
        access_token = data["access_token"]?.try(&.as_s?)
        raise OAuthError.new("Token response missing access_token") unless access_token

        tokens = build_tokens(data)
        save_tokens(server_name, server_url, home_dir, tokens)
        tokens
      end

      # ------------------------------------------------------------------
      # Discovery (RFC 9728 + RFC 8414)
      # ------------------------------------------------------------------

      # Discover the authorization server metadata for an MCP resource server.
      # First tries RFC 9728 `/.well-known/oauth-protected-resource`, then
      # falls back to RFC 8414 `/.well-known/oauth-authorization-server` at the
      # resource origin.
      def self.discover_metadata(server_url : String) : ServerMetadata
        uri = URI.parse(server_url)
        origin = "#{uri.scheme}://#{uri.host}#{uri.port ? ":#{uri.port}" : ""}"

        # Try RFC 9728 protected-resource metadata.
        resource_meta_url = "#{origin}/.well-known/oauth-protected-resource"
        resp = http_get_json(resource_meta_url)

        auth_servers = [] of String
        if resp && resp.status_code == 200
          data = JSON.parse(resp.body)
          if arr = data["authorization_servers"]?.try(&.as_a?)
            auth_servers = arr.map(&.to_s)
          end
        end

        # The auth server to query. Prefer the first advertised; fall back to
        # the resource origin itself.
        auth_origin = auth_servers.first? || origin
        discover_server_metadata(auth_origin)
      end

      # Fetch RFC 8414 authorization-server metadata.
      private def self.discover_server_metadata(auth_origin : String) : ServerMetadata
        meta_url = "#{auth_origin}/.well-known/oauth-authorization-server"
        resp = http_get_json(meta_url)
        unless resp && resp.status_code == 200
          raise OAuthError.new("OAuth: cannot fetch authorization-server metadata from #{meta_url}")
        end
        data = JSON.parse(resp.body)
        ServerMetadata.new(
          authorization_endpoint: data["authorization_endpoint"]?.try(&.to_s),
          token_endpoint: data["token_endpoint"]?.try(&.to_s),
          registration_endpoint: data["registration_endpoint"]?.try(&.to_s),
          revocation_endpoint: data["revocation_endpoint"]?.try(&.to_s),
        )
      end

      # ------------------------------------------------------------------
      # Dynamic Client Registration (RFC 7591)
      # ------------------------------------------------------------------

      private def self.register_client(registration_endpoint : String,
                                       redirect_uri : String) : {String, String?}
        body = {
          "redirect_uris"              => [redirect_uri] of String,
          "token_endpoint_auth_method" => "none",
          "grant_types"                => ["authorization_code"] of String,
          "response_types"             => ["code"] of String,
        }.to_json

        uri = URI.parse(registration_endpoint)
        client = make_http_client(uri)
        headers = HTTP::Headers.new
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"

        resp = client.post(uri.request_target, headers: headers, body: body)
        client.close

        unless resp.status_code.in?(200, 201)
          raise OAuthError.new("Dynamic client registration failed (HTTP #{resp.status_code}): #{resp.body[0...500]}")
        end

        data = JSON.parse(resp.body)
        cid = data["client_id"]?.try(&.to_s)
        raise OAuthError.new("DCR response missing client_id") unless cid
        secret = data["client_secret"]?.try(&.to_s)
        {cid, secret}
      end

      # ------------------------------------------------------------------
      # PKCE (RFC 7636)
      # ------------------------------------------------------------------

      private def self.generate_code_verifier : String
        random_base64url(CODE_VERIFIER_LEN)
      end

      private def self.pkce_challenge(verifier : String) : String
        digest = Digest::SHA256.digest(verifier)
        Base64.strict_encode(digest)
          .gsub('+', '-')
          .gsub('/', '_')
          .gsub('=', "")
      end

      # ------------------------------------------------------------------
      # Callback HTTP server (dynamic port — mirrors JS callback-server.ts)
      # ------------------------------------------------------------------

      # Callback handle returned by `start_callback_server`.
      private struct CallbackHandle
        getter server : HTTP::Server
        getter redirect_uri : String
        getter code_ch : Channel(String)
        getter error_ch : Channel(String)
        getter expected_state : String

        def initialize(@server, @redirect_uri, @code_ch, @error_ch, @expected_state)
        end
      end

      # Bind a one-shot callback server on a random free port. `expected_state`
      # is validated against the `state` query param on each callback request.
      private def self.start_callback_server(expected_state : String) : CallbackHandle
        code_ch = Channel(String).new
        error_ch = Channel(String).new

        server = HTTP::Server.new do |context|
          params = context.request.query_params
          ctx_state = params["state"]?
          ctx_code = params["code"]?
          ctx_error = params["error"]?

          if ctx_error
            context.response.status_code = 400
            context.response.puts "Authorization error: #{ctx_error}"
            error_ch.send("Authorization error: #{ctx_error}") rescue nil
            next
          end

          if ctx_state != expected_state
            context.response.status_code = 400
            context.response.puts "State mismatch"
            error_ch.send("OAuth callback: state mismatch") rescue nil
            next
          end

          if ctx_code
            context.response.status_code = 200
            context.response << "Authorization complete. You can close this tab."
            code_ch.send(ctx_code) rescue nil
            next
          end

          context.response.status_code = 400
          context.response.puts "Missing code parameter"
        end

        # Bind on a random free port — the OS picks one.
        addr = server.bind_tcp("127.0.0.1", 0)
        redirect_uri = "http://127.0.0.1:#{addr.port}/callback"

        # Start listening in a background fiber.
        spawn(name: "mcp-oauth-callback") { server.listen }

        # Brief settle so the socket is ready.
        3.times { Fiber.yield }

        CallbackHandle.new(server, redirect_uri, code_ch, error_ch, expected_state)
      end

      # Block until the callback delivers a valid code (or timeout / error).
      private def self.wait_for_code(callback : CallbackHandle, expected_state : String) : String
        select
        when code = callback.code_ch.receive
          callback.server.close rescue nil
          code
        when err = callback.error_ch.receive
          callback.server.close rescue nil
          raise OAuthError.new(err)
        when timeout(5.minutes)
          callback.server.close rescue nil
          raise OAuthError.new("OAuth: timed out waiting for authorization callback")
        end
      end

      # ------------------------------------------------------------------
      # HTTP helpers
      # ------------------------------------------------------------------

      private def self.http_post_form(url : String, body : String) : HTTP::Client::Response
        uri = URI.parse(url)
        client = make_http_client(uri)
        headers = HTTP::Headers.new
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers["Accept"] = "application/json"
        resp = client.post(uri.request_target, headers: headers, body: body)
        client.close
        resp
      rescue ex : OAuthError
        raise ex
      rescue ex
        raise OAuthError.new("Network error: #{ex.message}")
      end

      private def self.http_get_json(url : String) : HTTP::Client::Response?
        uri = URI.parse(url)
        client = make_http_client(uri)
        headers = HTTP::Headers.new
        headers["Accept"] = "application/json"
        resp = client.get(uri.request_target, headers: headers)
        client.close
        resp
      rescue ex
        nil
      end

      private def self.make_http_client(uri : URI) : HTTP::Client
        tls = uri.scheme == "https" ? OpenSSL::SSL::Context::Client.new : nil
        client = HTTP::Client.new(uri, tls: tls)
        # Apply proxy: Crystal's HTTP::Client does not honour proxy env vars
        # automatically, so we wire it explicitly — same logic as
        # HttpTransport#proxy_client and OpenAiChatProvider.
        proxy = ENV["HTTPS_PROXY"]? || ENV["HTTP_PROXY"]? || ENV["ALL_PROXY"]?
        if (p = proxy) && !p.empty? && !bypass_proxy?(uri)
          client = proxy_client(uri, p)
        end
        client
      end

      private def self.bypass_proxy?(uri : URI) : Bool
        host = uri.host || ""
        loopback = {"localhost", "127.0.0.1", "::1"}
        return true if loopback.includes?(host)
        no_proxy = ENV["NO_PROXY"]? || ENV["no_proxy"]?
        if np = no_proxy
          np.split(',').each do |entry|
            entry = entry.strip
            next if entry.empty?
            return true if host == entry || host.ends_with?(".#{entry.lstrip('.')}")
          end
        end
        false
      end

      private def self.proxy_client(target : URI, proxy_url : String) : HTTP::Client
        proxy = URI.parse(proxy_url)
        proxy_host = proxy.host || "127.0.0.1"
        proxy_port = proxy.port || 8080

        if target.scheme == "https"
          target_host = target.host || "localhost"
          target_port = target.port || 443
          socket = TCPSocket.new(proxy_host, proxy_port)
          socket << "CONNECT #{target_host}:#{target_port} HTTP/1.1\r\nHost: #{target_host}:#{target_port}\r\n\r\n"
          socket.flush
          status_line = socket.gets || ""
          unless status_line.includes?(" 200 ")
            socket.close
            raise OAuthError.new("Proxy CONNECT failed: #{status_line.strip}")
          end
          while line = socket.gets
            break if line.strip.empty?
          end
          context = OpenSSL::SSL::Context::Client.new
          context.verify_mode = OpenSSL::SSL::VerifyMode::PEER
          tls = OpenSSL::SSL::Socket::Client.new(socket, context: context, sync_close: true, hostname: target_host)
          HTTP::Client.new(tls, host: target_host, port: target_port)
        else
          HTTP::Client.new(proxy_host, proxy_port)
        end
      end

      # ------------------------------------------------------------------
      # Token building
      # ------------------------------------------------------------------

      private def self.build_tokens(data : JSON::Any) : OAuthTokens
        access_token = data["access_token"].to_s
        refresh_token = data["refresh_token"]?.try(&.as_s?)
        token_type = data["token_type"]?.try(&.as_s?) || "Bearer"
        scope = data["scope"]?.try(&.as_s?)
        expires_at = nil
        if exp = data["expires_in"]?
          seconds = (exp.as_i? || exp.to_s.to_i? || 900).to_i64
          expires_at = Time.utc.to_unix + seconds
        end
        OAuthTokens.new(access_token, refresh_token, token_type, expires_at, scope)
      end

      # ------------------------------------------------------------------
      # Crypto helpers
      # ------------------------------------------------------------------

      private def self.random_hex(n : Int32) : String
        Random::Secure.hex(n)
      end

      private def self.random_base64url(n : Int32) : String
        bytes = Bytes.new(n)
        Random::Secure.random_bytes(bytes)
        Base64.strict_encode(bytes)
          .gsub('+', '-')
          .gsub('/', '_')
          .gsub('=', "")
      end
    end
  end
end
