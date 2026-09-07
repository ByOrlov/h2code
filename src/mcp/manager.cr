require "json"
require "../tools/registry"
require "./client"
require "./config"
require "./proxy_tool"
require "./lazy_proxy_tool"
require "./tool_cache"
require "./tool_naming"
require "./http_transport"
require "./oauth"
require "./auth_tool"

module H2code
  module Mcp
    enum ServerStatus
      Pending
      Connected
      Failed
      Disabled
      NeedsAuth
    end

    struct ServerReport
      getter name : String
      getter status : ServerStatus
      getter message : String
      getter tool_count : Int32
      getter tool_names : Array(String)

      def initialize(@name : String, @status : ServerStatus, @message : String = "",
                     @tool_count : Int32 = 0, @tool_names : Array(String) = [] of String)
      end
    end

    # Internal per-server entry — mirrors JS `InternalEntry`.
    private class InternalEntry
      property name : String
      property config : McpServerConfig
      property status : ServerStatus = ServerStatus::Pending
      property tools : Array(Tools::Tool) = [] of Tools::Tool
      property client : Client? = nil
      property error : String? = nil
      property attempt_id : Int32 = 0

      def initialize(@name : String, @config : McpServerConfig)
      end
    end

    # Owns the lifecycle of every configured MCP server: connects them in
    # parallel (failures are isolated per server), registers each remote tool
    # as an `McpProxyTool`, and tears all connections down on shutdown.
    #
    # Mirrors JS `McpConnectionManager`:
    # - `enabled === false` servers are marked Disabled and skipped.
    # - `enabledTools` / `disabledTools` filters the registered tool set.
    # - Per-server `startupTimeoutMs` / `toolTimeoutMs` override defaults.
    # - Unexpected transport close flips the entry to Failed.
    # - HTTP servers without a static token that fail with 401 enter NeedsAuth;
    #   a synthetic `mcp__<server>__authenticate` tool is registered so the
    #   agent can drive the OAuth flow through the model.
    # - `reconnect(name)` tears down + reconnects one entry (used by the auth
    #   tool after tokens land).
    class Manager
      DEFAULT_STARTUP_TIMEOUT = 30.seconds

      getter reports : Array(ServerReport) = [] of ServerReport
      # Called with (server_name, auth_url) when an OAuth flow starts.
      property on_auth_request : ((String, String) -> Nil)?
      @home_dir : String
      @entries : Hash(String, InternalEntry) = {} of String => InternalEntry
      @connecting : Hash(String, Bool) = {} of String => Bool
      @registry : Tools::Registry?
      @mutex = Mutex.new
      @all_configs : Array(McpServerConfig) = [] of McpServerConfig
      @active_provider : String? = nil
      @global_attempt_counter = Atomic(Int32).new(0)

      def initialize(@home_dir : String = HomePort.home)
      end

      # Connect every configured server. By default this is non-blocking —
      # each server connects in its own fibre, registers its tools, and
      # reports status as it finishes, so application startup is not held up
      # by slow or unreachable servers. Pass `blocking: true` to wait for all
      # connections before returning (used by tests and the headless path
      # when tools must be ready before the first turn).
      #
      # Only servers whose `providers` match `active_provider` (or are global)
      # are connected; the rest are remembered in `@all_configs` so a later
      # `reconcile` can connect them when the provider changes.
      def connect_all(configs : Array(McpServerConfig), registry : Tools::Registry,
                      *, active_provider : String? = nil, blocking : Bool = false) : Nil
        @all_configs = configs
        @registry = registry
        @active_provider = active_provider
        applicable = configs.select { |c| c.matches_provider?(active_provider) }
        return if applicable.empty?

        done = Channel(Nil).new(applicable.size)
        applicable.each { |cfg| spawn_connect(cfg, done) }
        applicable.size.times { done.receive } if blocking
      end

      # Register cached tool definitions as lazy proxy tools without
      # connecting any server. Servers with no cache (first run) fall back
      # to an eager background connect. This is the primary startup path —
      # it returns immediately when all servers have a warm cache, avoiding
      # OpenSSL init and TLS handshakes (~3 MB heap).
      def register_from_cache(configs : Array(McpServerConfig), registry : Tools::Registry,
                              *, active_provider : String? = nil, blocking : Bool = false) : Nil
        @all_configs = configs
        @registry = registry
        @active_provider = active_provider
        applicable = configs.select { |c| c.matches_provider?(active_provider) }
        return if applicable.empty?

        uncached = [] of McpServerConfig
        done = Channel(Nil).new(applicable.size)

        applicable.each do |cfg|
          cached_defs = active_provider.try { |p| ToolCache.load?(p, cfg.name) }
          if cached_defs && !cached_defs.empty?
            # Warm cache: register lazy tools immediately, no connection.
            entry = InternalEntry.new(cfg.name, cfg)
            entry.status = ServerStatus::Pending
            allowed = cfg.allowed_tool_names(cached_defs.map(&.name))
            cached_defs.select { |d| allowed.includes?(d.name) }.each do |d|
              proxy = ToolNaming.proxy_name(cfg.name, cfg.aliased_tool_name(d.name))
              entry.tools << McpLazyProxyTool.new(proxy, cfg.name, d.name,
                d.description, d.input_schema, self,
                tool_timeout: cfg.effective_tool_timeout)
            end
            @mutex.synchronize { @entries[cfg.name] = entry }
            register_entry_tools(entry)
            rebuild_reports
            done.send(nil)
          else
            # No cache or stale: connect in background to discover + cache tools.
            uncached << cfg
            spawn_connect(cfg, done)
          end
        end

        done.receive if blocking && !uncached.empty?
      end

      # Connect a server on demand (called by McpLazyProxyTool on first
      # execute). Dedupes concurrent calls via a per-server channel.
      def ensure_connected(server_name : String) : Client
        entry = @mutex.synchronize { @entries[server_name]? }
        raise "MCP server '#{server_name}' is not configured" unless entry

        # Fast path: already connected.
        if client = entry.client
          return client if entry.status.connected?
        end

        # Dedup: if another fibre is already connecting, wait for it.
        loop do
          connecting = @mutex.synchronize { @connecting[server_name]? }
          unless connecting
            # We are the first caller — claim the slot and connect.
            @mutex.synchronize { @connecting[server_name] = true }
            begin
              connect_one(entry)
              register_entry_tools(entry)
              rebuild_reports
              client = entry.client
              raise entry.error || "MCP server '#{server_name}' failed to connect" unless client
              return client
            ensure
              @mutex.synchronize { @connecting.delete(server_name) }
            end
          end

          # Another fibre is connecting — poll until it finishes.
          if entry.status.connected? && (client = entry.client)
            return client
          end
          if entry.status.failed? || entry.status == ServerStatus::NeedsAuth
            raise entry.error || "MCP server '#{server_name}' failed to connect"
          end
          Fiber.yield
        end
      end

      # Force reconnect + refresh cache for one or all servers.
      def update_cache(server_name : String? = nil) : Nil
        if name = server_name
          reconnect(name)
        else
          applicable = @all_configs.select { |c| c.matches_provider?(@active_provider) }
          applicable.each { |cfg| reconnect(cfg.name) }
        end
      end

      # Reconcile connected servers against a new active provider: disconnect
      # servers whose provider no longer matches, and connect servers that now
      # match but were previously skipped. Non-blocking — connections happen in
      # background fibres, mirroring the interactive startup path.
      def reconcile(active_provider : String?) : Nil
        return if @registry.nil?
        @active_provider = active_provider

        # Disconnect entries that no longer match the active provider.
        to_disconnect = [] of InternalEntry
        @mutex.synchronize do
          @entries.each do |_, entry|
            unless entry.config.matches_provider?(active_provider)
              to_disconnect << entry
            end
          end
        end
        to_disconnect.each do |entry|
          disconnect_entry(entry)
          @mutex.synchronize { @entries.delete(entry.name) }
        end

        # Connect configs that now match but are not yet connected.
        connected_names = @mutex.synchronize { @entries.keys }
        done = Channel(Nil).new
        spawned = 0
        @all_configs.each do |cfg|
          next unless cfg.matches_provider?(active_provider)
          next if connected_names.includes?(cfg.name)
          spawn_connect(cfg, done)
          spawned += 1
        end
        spawned.times { done.receive } if spawned > 0

        rebuild_reports
      end

      private def spawn_connect(cfg : McpServerConfig, done : Channel(Nil)) : Nil
        entry = InternalEntry.new(cfg.name, cfg)
        entry.status = ServerStatus::Disabled unless cfg.enabled?
        @mutex.synchronize { @entries[cfg.name] = entry }

        spawn(name: "mcp-connect-#{cfg.name}") do
          connect_one(entry) if cfg.enabled?
          register_entry_tools(entry)
          rebuild_reports
          done.send(nil)
        end
      end

      # Reconnect a single server by name: close the old client, discover
      # tools fresh, and re-register. Used by the synthetic auth tool after
      # tokens are persisted.
      def reconnect(name : String) : Nil
        entry = @mutex.synchronize { @entries[name]? }
        return unless entry
        close_entry(entry)
        entry.status = ServerStatus::Pending
        entry.tools.clear
        entry.error = nil
        connect_one(entry)
        rebuild_reports
        register_entry_tools(entry)
      end

      def any_connected? : Bool
        @entries.any? { |_, e| e.status.connected? }
      end

      def get_remote_server_url(name : String) : String?
        entry = @entries[name]?
        return nil unless entry && entry.config.remote?
        entry.config.url
      end

      def status_text : String
        return "No MCP servers configured." if @entries.empty?
        String.build do |s|
          s << "MCP servers (#{@entries.size}):\n"
          @entries.each do |_, entry|
            tag = case entry.status
                  in ServerStatus::Connected then "✓"
                  in ServerStatus::Failed    then "✗"
                  in ServerStatus::Pending   then "…"
                  in ServerStatus::Disabled  then "⊘"
                  in ServerStatus::NeedsAuth then "🔒"
                  end
            s << "  #{tag} #{entry.name}"
            if entry.status.connected?
              s << " (#{entry.tools.size} tool#{entry.tools.size == 1 ? "" : "s"})"
            end
            s << "\n"
            if (msg = entry.error) && !msg.empty?
              if entry.status.needs_auth?
                s << "      Requires OAuth — the agent can call mcp__#{entry.name}__authenticate\n"
              else
                s << "      #{msg[0...200]}\n"
              end
            end
            entry.tools.each { |t| s << "      - #{t.name}\n" }
          end
        end.strip
      end

      def shutdown : Nil
        entries = @mutex.synchronize do
          list = @entries.values
          @entries.clear
          list
        end
        entries.each { |e| close_entry(e) }
      end

      # ------------------------------------------------------------------
      # Connection logic
      # ------------------------------------------------------------------

      private def connect_one(entry : InternalEntry) : Nil
        config = entry.config
        my_attempt = next_attempt_id(entry)

        if config.stdio?
          if config.command.empty?
            return if stale?(entry, my_attempt)
            entry.status = ServerStatus::Failed
            entry.error = "MCP server '#{config.name}' has no `command`"
            return
          end
        else
          if (config.url || "").empty?
            return if stale?(entry, my_attempt)
            entry.status = ServerStatus::Failed
            entry.error = "MCP server '#{config.name}' (#{config.type}) has no `url`"
            return
          end
        end

        # Resolve bearer token for remote servers.
        token = nil
        if config.remote?
          begin
            token = resolve_http_token(config)
          rescue ex
            if needs_auth_like?(ex, config)
              return if stale?(entry, my_attempt)
              entry.status = ServerStatus::NeedsAuth
              entry.error = ex.message || ex.class.to_s
              register_auth_tool(entry)
              return
            end
            raise ex
          end
        end

        client = Client.new(config, token)
        entry.client = client

        startup_timeout = config.effective_startup_timeout(DEFAULT_STARTUP_TIMEOUT)
        client.connect(timeout: startup_timeout)
        defs = client.list_tools(timeout: startup_timeout)

        # Bail if a newer attempt superseded this one before we finished.
        return if stale?(entry, my_attempt)

        # Persist tool definitions to the on-disk cache so subsequent
        # startups can register lazy tools without connecting.
        if ap = @active_provider
          ToolCache.save(ap, config.name, defs)
        end

        # Apply enabled/disabled tools filter.
        all_remote_names = defs.map(&.name)
        allowed = config.allowed_tool_names(all_remote_names)

        tools = [] of Tools::Tool
        defs.select { |d| allowed.includes?(d.name) }.each do |d|
          proxy = ToolNaming.proxy_name(config.name, config.aliased_tool_name(d.name))
          tools << McpProxyTool.new(proxy, config.name, d.name, d.description, d.input_schema, client,
            tool_timeout: config.effective_tool_timeout)
        end
        entry.tools = tools
        entry.status = ServerStatus::Connected
        watch_for_close(entry)
      rescue ex : RpcError
        return if my_attempt && stale?(entry, my_attempt)
        close_client(entry)
        cfg = entry.config
        if cfg.remote? && needs_auth_like?(ex, cfg) && !cfg.token_env
          entry.status = ServerStatus::NeedsAuth
          entry.error = ex.message || ex.class.to_s
          register_auth_tool(entry)
        else
          entry.status = ServerStatus::Failed
          entry.error = format_error(ex, entry)
        end
      rescue ex
        return if my_attempt && stale?(entry, my_attempt)
        close_client(entry)
        entry.status = ServerStatus::Failed
        entry.error = format_error(ex, entry)
      end

      # True when a newer connection attempt has superseded `my_attempt` on
      # this entry — the caller should bail without touching entry state.
      private def stale?(entry : InternalEntry, my_attempt : Int32) : Bool
        entry.attempt_id != my_attempt
      end

      # Atomically allocate a new attempt id and stamp it onto the entry.
      private def next_attempt_id(entry : InternalEntry) : Int32
        id = @global_attempt_counter.add(1) + 1
        entry.attempt_id = id
        id
      end

      # Detect unexpected transport close (stdio process exit, HTTP EOF)
      # and flip the entry to Failed.
      private def watch_for_close(entry : InternalEntry) : Nil
        client = entry.client
        return unless client
        spawn(name: "mcp-watch-#{entry.name}") do
          # Poll: if the rpc client reports closed while the entry is still
          # connected, the transport died unexpectedly.
          loop do
            sleep 2.seconds
            break unless entry.status.connected?
            break unless entry.client == client
            if client.rpc.closed?
              entry.status = ServerStatus::Failed
              stderr = client.stderr_tail
              entry.error = if stderr.empty?
                              "MCP server \"#{entry.name}\" closed unexpectedly"
                            else
                              "MCP server \"#{entry.name}\" closed unexpectedly\n#{stderr}"
                            end
              close_client(entry)
              rebuild_reports
              break
            end
          end
        end
      end

      # When a server is in NeedsAuth, register a synthetic authenticate tool
      # so the agent can drive the OAuth flow through the model.
      private def register_auth_tool(entry : InternalEntry) : Nil
        url = entry.config.url || ""
        tool = McpAuthTool.new(entry.name, url, self, @home_dir,
          oauth_client_id: entry.config.oauth_client_id,
          oauth_client_secret: entry.config.oauth_client_secret,
          oauth_scopes: entry.config.oauth_scopes)
        entry.tools = [tool.as(Tools::Tool)]
        register_entry_tools(entry)
      end

      # Register (or re-register) an entry's tools into the shared registry.
      private def register_entry_tools(entry : InternalEntry) : Nil
        return unless registry = @registry
        entry.tools.each { |t| registry.register(t) }
      end

      private def rebuild_reports : Nil
        @mutex.synchronize do
          @reports = @entries.values.map do |e|
            ServerReport.new(e.name, e.status, e.error || "",
              tool_count: e.tools.size,
              tool_names: e.tools.map(&.name))
          end
        end
      end

      # ------------------------------------------------------------------
      # Token resolution
      # ------------------------------------------------------------------

      private def resolve_http_token(config : McpServerConfig) : String?
        # If an Authorization header is already present in the config headers,
        # the transport will apply it directly — no token resolution needed.
        return nil if config.headers.any? { |k, _| k.downcase == "authorization" }

        if env_name = config.token_env
          return ENV[env_name]?
        end
        key = "MCP_#{config.name.upcase.gsub(/[^A-Z0-9]/, "_")}_TOKEN"
        if static = ENV[key]?
          return static
        end

        server_url = config.url || ""
        if stored = OAuth.load_tokens(config.name, server_url, @home_dir)
          return stored.access_token unless stored.expired?
          begin
            metadata = OAuth.discover_metadata(server_url)
            if refreshed = OAuth.refresh(config.name, server_url, @home_dir, stored, metadata)
              return refreshed.access_token
            end
          rescue
          end
        end

        # Full OAuth flow.
        OAuth.authorize(server_url, config.name, @home_dir,
          client_id: config.oauth_client_id,
          client_secret: config.oauth_client_secret,
          scopes: config.oauth_scopes.empty? ? nil : config.oauth_scopes) do |auth_url|
          if cb = @on_auth_request
            cb.call(config.name, auth_url)
          else
            STDERR.puts "[MCP] OAuth authorization required for '#{config.name}':"
            STDERR.puts "  #{auth_url}"
          end
        end.access_token
      end

      # ------------------------------------------------------------------
      # Helpers
      # ------------------------------------------------------------------

      private def needs_auth_like?(ex : Exception, config : McpServerConfig) : Bool
        return false if config.token_env
        # Skip the OAuth flow when the server already has a static Authorization
        # header — the server uses header-based auth, not OAuth. Mirrors JS
        # `shouldMarkNeedsAuth` (`connection-manager.ts:389`).
        return false if config.headers.any? { |k, _| k.downcase == "authorization" }
        msg = ex.message || ""
        msg.includes?("401") || msg.downcase.includes?("unauthorized")
      end

      private def format_error(ex : Exception, entry : InternalEntry? = nil) : String
        msg = ex.message || ex.class.to_s
        # Append stderr tail if available from a stdio client.
        if entry && (client = entry.client) && !client.stderr_tail.empty?
          tail = client.stderr_tail
          msg = "#{msg}\n#{tail}" unless tail.empty?
        end
        msg
      end

      private def close_entry(entry : InternalEntry) : Nil
        close_client(entry)
      end

      # Close the connection and unregister the entry's proxy tools from the
      # shared registry so the model no longer sees them.
      private def disconnect_entry(entry : InternalEntry) : Nil
        close_client(entry)
        if registry = @registry
          entry.tools.each { |t| registry.unregister(t.name) }
        end
        entry.tools.clear
        entry.status = ServerStatus::Disabled
      end

      private def close_client(entry : InternalEntry) : Nil
        if client = entry.client
          entry.client = nil
          client.close rescue nil
        end
      end
    end
  end
end
