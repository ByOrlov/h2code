require "json"
require "../tools/tool"
require "./oauth"
require "./tool_naming"

module H2code
  module Mcp
    # Synthetic `mcp__<server>__authenticate` tool. When a remote MCP server
    # lands in the `needs-auth` state (401 without a static bearer token), the
    # Manager registers this tool instead of the real MCP tools. Calling it:
    #
    #  1. Runs OAuth discovery (RFC 9728/8414) + DCR (RFC 7591) + PKCE.
    #  2. Returns the authorization URL so the model can show it to the user.
    #  3. Blocks on the localhost callback listener until the user authorizes.
    #  4. Persists tokens and triggers a manager `reconnect`, swapping this
    #     synthetic tool for the real MCP tools.
    #
    # Mirrors JS `auth-tool.ts`.
    class McpAuthTool < Tools::Tool
      AUTH_TOOL_NAME = "authenticate"

      @home_dir : String
      @oauth_client_id : String?
      @oauth_client_secret : String?
      @oauth_scopes : Array(String)
      @captured_auth_url : String? = nil

      def initialize(server_name : String, server_url : String,
                     manager : Manager, home_dir : String,
                     oauth_client_id : String? = nil,
                     oauth_client_secret : String? = nil,
                     oauth_scopes : Array(String) = [] of String)
        @server_name = server_name
        @server_url = server_url
        @manager = manager
        @home_dir = home_dir
        @oauth_client_id = oauth_client_id
        @oauth_client_secret = oauth_client_secret
        @oauth_scopes = oauth_scopes
      end

      def name : String
        ToolNaming.proxy_name(@server_name, AUTH_TOOL_NAME)
      end

      def description : String
        "Authenticate with MCP server \"#{@server_name}\" via OAuth.\n\n" \
        "This server requires an OAuth login that has not yet been completed. " \
        "Calling this tool starts the authorization flow:\n" \
        "1. The tool prints an authorization URL.\n" \
        "2. You must show that URL to the user verbatim and ask them to open it.\n" \
        "3. The tool blocks (up to 15 minutes) until the browser redirects back.\n" \
        "4. On success, kimi-code reconnects the MCP server and the real tools " \
        "replace this synthetic tool."
      end

      def parameters : JSON::Any
        JSON.parse(%({"type":"object","properties":{}}))
      end

      def execute(input : JSON::Any) : Tools::ToolResult
        @captured_auth_url = nil
        OAuth.authorize(@server_url, @server_name, @home_dir,
          client_id: @oauth_client_id,
          client_secret: @oauth_client_secret,
          scopes: @oauth_scopes.empty? ? nil : @oauth_scopes) do |auth_url|
          @captured_auth_url = auth_url
          STDERR.puts "[MCP] OAuth authorization required for '#{@server_name}':"
          STDERR.puts "  #{auth_url}"
        end

        # Tokens persisted — reconnect to swap this tool for the real ones.
        @manager.reconnect(@server_name)
        url_note = if url = @captured_auth_url
                     " Authorized via #{url}."
                   else
                     ""
                   end
        Tools::ToolResult.success(
          "MCP server \"#{@server_name}\" authenticated successfully.#{url_note} " \
          "The real MCP tools have replaced this synthetic authenticate tool.")
      rescue ex
        url_hint = ""
        if url = @captured_auth_url
          url_hint = "\n\nAuthorization URL (may still be valid): #{url}"
        end
        Tools::ToolResult.error(
          "OAuth flow for MCP server \"#{@server_name}\" did not complete: #{ex.message}#{url_hint}")
      end
    end
  end
end
