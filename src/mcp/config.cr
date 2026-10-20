require "json"

require "../h2code_home"

module H2code
  module Mcp
    # One configured MCP server entry. Only the stdio transport is wired in
    # MVP; `type`, `url` and `token_env` are parsed and stored so Phase 2
    # (HTTP) can consume them without a config-format change.
    struct McpServerConfig
      property name : String
      property type : String        # "stdio" | "http" | "sse"
      property command : String     # stdio: executable
      property args : Array(String) # stdio: argv
      property env : Hash(String, String)
      property cwd : String?                  # stdio: working directory
      property url : String?                  # http/sse: endpoint
      property headers : Hash(String, String) # http/sse: extra HTTP headers
      # Indirect secret: bearer token looked up from `ENV[token_env]` at
      # connection time, never committed to config. Mirrors JS
      # `bearerTokenEnvVar`.
      property token_env : String?
      # OAuth fields (Phase 4). When `token_env` is unset and the server
      # requires authentication, these drive the Authorization Code + PKCE
      # flow. `oauth_client_id` is optional — when absent, Dynamic Client
      # Registration (RFC 7591) is attempted.
      property oauth_client_id : String?
      property oauth_client_secret : String?
      property oauth_scopes : Array(String)
      # Common fields (mirrors JS McpServerCommonFields).
      property? enabled : Bool = true
      property enabled_tools : Array(String)? = nil
      property disabled_tools : Array(String)? = nil
      property startup_timeout_ms : Int32? = nil
      property tool_timeout_ms : Int32? = nil
      # Provider affinity: when empty the server is global (loads on every
      # provider); otherwise it loads only when the active provider matches.
      property providers : Array(String) = [] of String
      # Map of remote tool names to nicer agent-facing names. The remote name
      # is still used when calling the MCP server; the alias only affects the
      # proxy tool name exposed to the model and the UI.
      property tool_aliases : Hash(String, String) = {} of String => String

      def initialize(@name : String, @command : String = "",
                     @args : Array(String) = [] of String,
                     @env : Hash(String, String) = {} of String => String,
                     @type : String = "stdio", @url : String? = nil,
                     @token_env : String? = nil,
                     @oauth_client_id : String? = nil,
                     @oauth_client_secret : String? = nil,
                     @oauth_scopes : Array(String) = [] of String,
                     @cwd : String? = nil,
                     @headers : Hash(String, String) = {} of String => String,
                     @enabled : Bool = true,
                     @enabled_tools : Array(String)? = nil,
                     @disabled_tools : Array(String)? = nil,
                     @startup_timeout_ms : Int32? = nil,
                     @tool_timeout_ms : Int32? = nil,
                     @providers : Array(String) = [] of String,
                     @tool_aliases : Hash(String, String) = {} of String => String)
      end

      # Effective agent-facing name for a remote tool, honouring aliases.
      def aliased_tool_name(remote : String) : String
        @tool_aliases[remote]? || remote
      end

      # True when this server should load for the given active provider.
      # Empty `providers` means global (always loads).
      def matches_provider?(active : String?) : Bool
        @providers.empty? || (active ? @providers.includes?(active) : false)
      end

      def stdio? : Bool
        @type == "stdio" || @type.empty?
      end

      def remote? : Bool
        @type == "http" || @type == "sse"
      end

      # True when OAuth fields are explicitly configured.
      def oauth_configured? : Bool
        !@oauth_client_id.nil? || !@oauth_scopes.empty?
      end

      # Effective startup timeout, falling back to the manager default.
      def effective_startup_timeout(default : Time::Span) : Time::Span
        (@startup_timeout_ms.try(&.milliseconds) || default)
      end

      # Effective per-tool-call timeout (nil = no explicit timeout).
      def effective_tool_timeout : Time::Span?
        @tool_timeout_ms.try(&.milliseconds)
      end

      # Compute the set of remote tool names that should be registered,
      # applying the enabled/disabled filters.
      def allowed_tool_names(all_names : Array(String)) : Set(String)
        allowed = Set(String).new
        enabled = @enabled_tools.try(&.to_set)
        disabled = @disabled_tools.try(&.to_set)
        all_names.each do |n|
          next if enabled && !enabled.includes?(n)
          next if disabled && disabled.includes?(n)
          allowed << n
        end
        allowed
      end
    end

    # Loader for the optional `~/.h2code/mcp.json` file and its project-local
    # overrides (`<project-root>/.mcp.json`, `<cwd>/.h2code/mcp.json`). Sources
    # are merged by server name; later files override earlier ones.
    module ConfigLoader
      # Load from three mcp.json files — user-global, project-root, and
      # project-local — mirroring JS `loadMcpServers`. Later files override
      # earlier ones with the same name.
      def self.load(home_dir : String, cwd : String = Dir.current) : Array(McpServerConfig)
        h2code_home = H2codeHome.path_for(home_dir)

        user_json = read_mcp_json_file(File.join(h2code_home, "mcp.json"))
        project_root_json = read_mcp_json_file(project_root_mcp_json(cwd))
        project_json = read_mcp_json_file(File.join(cwd, ".h2code", "mcp.json"))

        # Merge by name: user → project-root → project (later wins).
        merged = {} of String => McpServerConfig
        user_json.each { |c| merged[c.name] = c }
        project_root_json.each { |c| merged[c.name] = c }
        project_json.each { |c| merged[c.name] = c }
        merged.values
      end

      # Walk upward from `cwd` looking for a `.git` dir; fall back to `cwd`.
      private def self.project_root_mcp_json(cwd : String) : String
        current = cwd
        loop do
          return File.join(current, ".mcp.json") if Dir.exists?(File.join(current, ".git"))
          parent = File.dirname(current)
          return File.join(cwd, ".mcp.json") if parent == current
          current = parent
        end
      end

      # Convenience: parse `mcp.json` from a directory (joins `<dir>/mcp.json`).
      def self.parse_mcp_json(home_dir : String) : Array(McpServerConfig)
        read_mcp_json_file(File.join(home_dir, "mcp.json"))
      end

      # Parse a specific mcp.json file by full path. Relative stdio `cwd`
      # values are resolved against the file's directory, mirroring JS
      # `normalizeStdioCwd`.
      def self.read_mcp_json_file(path : String) : Array(McpServerConfig)
        return [] of McpServerConfig unless File.exists?(path)
        data = JSON.parse(File.read(path))
        base_dir = File.dirname(path)
        servers = data["mcpServers"]?.try(&.as_h?) || {} of String => JSON::Any
        servers.map do |name, spec|
          cfg = from_any_json(name, spec.as_h)
          # Resolve relative stdio cwd against the file's directory.
          if cfg.stdio? && (cwd = cfg.cwd) && !Path.new(cwd).absolute?
            cfg.cwd = File.expand_path(cwd, base_dir)
          end
          cfg
        end
      rescue ex
        STDERR.puts "[MCP] Failed to parse #{path}: #{ex.message}"
        [] of McpServerConfig
      end

      def self.from_any_json(name : String, h : Hash(String, JSON::Any)) : McpServerConfig
        cfg = McpServerConfig.new(name)
        cfg.type = h["transport"]?.try(&.to_s) || h["type"]?.try(&.to_s) || "stdio"
        cfg.command = h["command"]?.try(&.to_s) || ""
        cfg.args = (h["args"]?.try(&.as_a?) || [] of JSON::Any).map(&.to_s)
        if env_any = h["env"]?.try(&.as_h?)
          env = {} of String => String
          env_any.each { |k, v| env[k] = v.to_s }
          cfg.env = env
        end
        cfg.cwd = h["cwd"]?.try(&.as_s?)
        cfg.url = h["url"]?.try(&.as_s)
        if headers_any = h["headers"]?.try(&.as_h?)
          hdr = {} of String => String
          headers_any.each { |k, v| hdr[k] = v.to_s }
          cfg.headers = hdr
        end
        cfg.token_env = h["bearerTokenEnvVar"]?.try(&.as_s?) ||
                        h["token_env"]?.try(&.as_s)
        cfg.oauth_client_id = h["oauth_client_id"]?.try(&.as_s?)
        cfg.oauth_client_secret = h["oauth_client_secret"]?.try(&.as_s?)
        if scopes_any = h["oauth_scopes"]?.try(&.as_a?)
          cfg.oauth_scopes = scopes_any.map(&.to_s)
        end
        cfg.enabled = h["enabled"]?.try(&.as_bool?) != false
        if et = h["enabledTools"]?.try(&.as_a?)
          cfg.enabled_tools = et.map(&.to_s)
        end
        if dt = h["disabledTools"]?.try(&.as_a?)
          cfg.disabled_tools = dt.map(&.to_s)
        end
        cfg.startup_timeout_ms = h["startupTimeoutMs"]?.try(&.as_i?)
        cfg.tool_timeout_ms = h["toolTimeoutMs"]?.try(&.as_i?)
        cfg.providers = parse_providers_json(h)
        cfg.tool_aliases = parse_tool_aliases_json(h)
        cfg
      end

      private def self.parse_tool_aliases_json(h : Hash(String, JSON::Any)) : Hash(String, String)
        if aliases_any = h["toolAliases"]?.try(&.as_h?)
          aliases = {} of String => String
          aliases_any.each { |k, v| aliases[k] = v.to_s }
          aliases
        else
          {} of String => String
        end
      end

      private def self.parse_providers_json(h : Hash(String, JSON::Any)) : Array(String)
        if arr = h["providers"]?.try(&.as_a?)
          arr.map(&.to_s)
        elsif single = h["provider"]?.try(&.to_s)
          single.empty? ? [] of String : [single]
        else
          [] of String
        end
      end
    end
  end
end
