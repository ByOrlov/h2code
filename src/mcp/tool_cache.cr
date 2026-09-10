require "json"
require "./types"

module H2code
  module Mcp
    # On-disk cache of MCP tool definitions, keyed by provider → server.
    # Avoids a network round-trip at startup: cached tools are registered
    # immediately as lazy proxy tools, and the server connects only when a
    # tool is actually called. Written after every successful `list_tools`
    # so the cache stays warm.
    module ToolCache
      CACHE_TTL = 7.days

      # Returns cached tool definitions for the given provider + server, or
      # nil when no cache exists or the entry is stale.
      def self.load?(provider : String, server_name : String) : Array(ToolDefinition)?
        data = read_cache
        return nil unless data

        provider_h = data[provider]?
        return nil unless provider_h && (ph = provider_h.as_h?)

        entry = ph[server_name]?
        return nil unless entry && (eh = entry.as_h?)

        cached_at = eh["cached_at"]?.try(&.as_i?) || 0
        return nil if Time.unix(cached_at) < (Time.utc - CACHE_TTL)

        tools_any = eh["tools"]?.try(&.as_a?) || [] of JSON::Any
        tools_any.map do |t|
          h = t.as_h
          ToolDefinition.new(
            h["name"]?.try(&.as_s) || "",
            h["description"]?.try(&.as_s) || "",
            h["input_schema"]? || JSON.parse("{}"),
          )
        end
      end

      # Writes tool definitions for a provider + server into the cache file.
      def self.save(provider : String, server_name : String, defs : Array(ToolDefinition)) : Nil
        data = read_cache || JSON.parse("{}")
        root = data.as_h

        provider_entry = root[provider]?.try(&.as_h) || {} of String => JSON::Any
        tools_array = JSON::Any.new(defs.map do |d|
          JSON::Any.new({
            "name"         => JSON::Any.new(d.name),
            "description"  => JSON::Any.new(d.description),
            "input_schema" => d.input_schema,
          } of String => JSON::Any)
        end)

        provider_entry[server_name] = JSON::Any.new({
          "tools"     => tools_array,
          "cached_at" => JSON::Any.new(Time.utc.to_unix.to_i64),
        } of String => JSON::Any)
        root[provider] = JSON::Any.new(provider_entry)

        write_cache(JSON::Any.new(root))
      end

      # Removes one server (or all servers for a provider) from the cache.
      def self.clear(provider : String, server_name : String? = nil) : Nil
        data = read_cache
        return unless data
        root = data.as_h

        if server_name
          provider_entry = root[provider]?.try(&.as_h)
          if provider_entry && provider_entry[server_name]?
            provider_entry.delete(server_name)
            root[provider] = JSON::Any.new(provider_entry)
            write_cache(JSON::Any.new(root))
          end
        else
          if root[provider]?
            root.delete(provider)
            write_cache(JSON::Any.new(root))
          end
        end
      end

      # ------------------------------------------------------------------
      # Internal
      # ------------------------------------------------------------------

      private def self.cache_path : String
        home = HomePort.home
        h2code_home = ENV["H2CODE_HOME"]? || File.join(home, ".h2code")
        File.join(h2code_home, "mcp_cache.json")
      end

      private def self.read_cache : JSON::Any?
        path = cache_path
        return nil unless File.exists?(path)
        JSON.parse(File.read(path))
      rescue ex
        nil
      end

      private def self.write_cache(data : JSON::Any) : Nil
        path = cache_path
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        File.write(path, data.to_json)
      end
    end
  end
end
