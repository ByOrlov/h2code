require "json"
require "file"
require "file_utils"

require "../h2code_home"
require "./types"

module H2code
  module Plugin
    module Store
      struct InstalledFile
        property version : Int32
        property plugins : Array(InstalledRecord)

        def initialize(@version : Int32 = 1, @plugins : Array(InstalledRecord) = [] of InstalledRecord)
        end
      end

      struct InstalledRecord
        property id : String
        property root : String
        property source : String
        property? enabled : Bool
        property installed_at : String
        property updated_at : String?
        property original_source : String?
        property capabilities : PluginCapabilityState?
        property github : PluginGithubMetadata?

        def initialize(@id : String, @root : String, @source : String,
                       @enabled : Bool = true, @installed_at : String = Time.utc.to_rfc3339,
                       @updated_at : String? = nil, @original_source : String? = nil,
                       @capabilities : PluginCapabilityState? = nil,
                       @github : PluginGithubMetadata? = nil)
        end
      end

      def self.installed_path(home : String) : String
        File.join(H2codeHome.path_for(home), "plugins", "installed.json")
      end

      def self.read(home : String) : Array(InstalledRecord)
        path = installed_path(home)
        return [] of InstalledRecord unless File.file?(path)

        data = JSON.parse(File.read(path))
        plugins = data["plugins"]?.try(&.as_a?) || [] of JSON::Any

        plugins.map do |entry|
          h = entry.as_h
          record = InstalledRecord.new(
            id: h["id"].to_s,
            root: h["root"].to_s,
            source: h["source"].to_s,
            enabled: h["enabled"]?.try(&.as_bool?) != false,
            installed_at: h["installedAt"]?.try(&.to_s) || Time.utc.to_rfc3339,
            updated_at: h["updatedAt"]?.try(&.as_s?),
            original_source: h["originalSource"]?.try(&.as_s?),
          )

          if caps = h["capabilities"]?.try(&.as_h?)
            mcp = {} of String => PluginMcpServerState
            if mcp_h = caps["mcpServers"]?.try(&.as_h?)
              mcp_h.each do |srv, state|
                enabled = state.as_h?.try(&.["enabled"]?).try(&.as_bool?) != false
                mcp[srv] = PluginMcpServerState.new(enabled)
              end
            end
            record.capabilities = PluginCapabilityState.new(mcp) unless mcp.empty?
          end

          if gh = h["github"]?.try(&.as_h?)
            ref = nil
            if ref_h = gh["ref"]?.try(&.as_h?)
              ref = PluginGithubRef.new(
                ref_h["kind"]?.try(&.to_s) || "branch",
                ref_h["value"]?.try(&.to_s) || "",
              )
            end
            record.github = PluginGithubMetadata.new(
              owner: gh["owner"]?.try(&.to_s) || "",
              repo: gh["repo"]?.try(&.to_s) || "",
              ref: ref,
              installed_sha: gh["installedSha"]?.try(&.as_s?),
            )
          end

          record
        end
      rescue ex : JSON::ParseException
        raise Exception.new("Failed to parse #{installed_path(home)}: #{ex.message}")
      end

      def self.write(home : String, records : Array(InstalledRecord)) : Nil
        path = installed_path(home)
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)

        plugins_arr = records.map do |r|
          obj = {} of String => JSON::Any
          obj["id"] = JSON::Any.new(r.id)
          obj["root"] = JSON::Any.new(r.root)
          obj["source"] = JSON::Any.new(r.source)
          obj["enabled"] = JSON::Any.new(r.enabled?)
          obj["installedAt"] = JSON::Any.new(r.installed_at)
          obj["updatedAt"] = JSON::Any.new(r.updated_at) if r.updated_at
          obj["originalSource"] = JSON::Any.new(r.original_source) if r.original_source

          if caps = r.capabilities
            mcp_obj = {} of String => JSON::Any
            caps.mcp_servers.each do |srv, state|
              mcp_obj[srv] = JSON::Any.new({"enabled" => JSON::Any.new(state.enabled?)} of String => JSON::Any)
            end
            obj["capabilities"] = JSON::Any.new({"mcpServers" => JSON::Any.new(mcp_obj)} of String => JSON::Any)
          end

          if gh = r.github
            gh_obj = {} of String => JSON::Any
            gh_obj["owner"] = JSON::Any.new(gh.owner)
            gh_obj["repo"] = JSON::Any.new(gh.repo)
            if ref = gh.ref
              gh_obj["ref"] = JSON::Any.new({
                "kind"  => JSON::Any.new(ref.kind),
                "value" => JSON::Any.new(ref.value),
              } of String => JSON::Any)
            end
            gh_obj["installedSha"] = JSON::Any.new(gh.installed_sha) if gh.installed_sha
            obj["github"] = JSON::Any.new(gh_obj)
          end

          JSON::Any.new(obj)
        end

        data = {
          "version" => JSON::Any.new(1),
          "plugins" => JSON::Any.new(plugins_arr),
        } of String => JSON::Any

        json = data.to_json

        tmp = "#{path}.tmp"
        File.write(tmp, json)
        File.rename(tmp, path)
      end
    end
  end
end
