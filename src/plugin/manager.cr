require "json"
require "file"
require "file_utils"

require "./types"
require "./store"
require "./source"
require "./manifest"
require "./archive"
require "./github_resolver"
require "./commands"
require "../tools/skill"

module H2code
  module Plugin
    class PluginRecord
      property id : String
      property root : String
      property source : PluginSource
      property? enabled : Bool
      property installed_at : String
      property updated_at : String?
      property original_source : String?
      property capabilities : PluginCapabilityState?
      property github : PluginGithubMetadata?

      property manifest : PluginManifest?
      property manifest_kind : PluginManifestKind?
      property manifest_path : String?
      property shadowed_manifest_path : String?
      property diagnostics : Array(PluginDiagnostic)
      property skill_instructions : String?

      def initialize(@id : String, @root : String, @source : PluginSource,
                     @enabled : Bool = true, @installed_at : String = Time.utc.to_rfc3339,
                     @updated_at : String? = nil, @original_source : String? = nil,
                     @capabilities : PluginCapabilityState? = nil,
                     @github : PluginGithubMetadata? = nil)
        @diagnostics = [] of PluginDiagnostic
      end

      def state : PluginState
        has_error = @diagnostics.any? { |d| d.severity.error? } || @manifest.nil?
        has_error ? PluginState::Error : PluginState::Ok
      end

      def ok? : Bool
        enabled? && state.ok? && !@manifest.nil?
      end

      def skill_count : Int32
        @manifest.try(&.skills.size) || 0
      end

      def mcp_server_count : Int32
        @manifest.try(&.mcp_servers.size) || 0
      end

      def hook_count : Int32
        @manifest.try(&.hooks.size) || 0
      end

      def command_count : Int32
        @manifest.try(&.commands.size) || 0
      end

      def display_name : String
        @manifest.try(&.interface).try(&.display_name) ||
          @manifest.try(&.name) || @id
      end

      def version : String?
        @manifest.try(&.version)
      end

      def description : String?
        @manifest.try(&.description) ||
          @manifest.try(&.interface).try(&.short_description)
      end

      def has_errors? : Bool
        @diagnostics.any? { |d| d.severity.error? }
      end
    end

    class Manager
      @kimi_home : String
      @records = {} of String => PluginRecord

      def initialize(@kimi_home : String, @tmp_dir : String? = nil)
      end

      def load : Nil
        installed = Store.read(@kimi_home)
        @records.clear
        installed.each do |entry|
          begin
            record = materialize(entry)
            @records[record.id] = record
          rescue ex
            record = PluginRecord.new(entry.id, entry.root, source_from_string(entry.source),
              enabled: entry.enabled?, installed_at: entry.installed_at)
            record.diagnostics << PluginDiagnostic.new(DiagnosticSeverity::Error,
              "Failed to materialize: #{ex.message}")
            @records[record.id] = record
          end
        end
      end

      def list : Array(PluginRecord)
        @records.values.sort_by!(&.id)
      end

      def get(id : String) : PluginRecord?
        @records[normalize_id(id)]?
      end

      def installed?(id : String) : Bool
        @records.has_key?(normalize_id(id))
      end

      def install(source : String) : PluginRecord
        resolved = SourceResolver.resolve(source)
        id, normalized_root, parsed, source_type, github, original_source =
          case resolved.kind
          in ResolvedSourceKind::LocalPath
            path = resolved.path || raise "path required for LocalPath"
            install_from_local_path(path)
          in ResolvedSourceKind::ZipUrl
            path = resolved.path || raise "path required for ZipUrl"
            install_from_zip(path, source.strip)
          in ResolvedSourceKind::Github
            github = resolved.github || raise "github required for Github"
            install_from_github(github, source.strip)
          end

        existing = @records[id]?
        now = Time.utc.to_rfc3339

        record = build_record(
          id: id,
          root: normalized_root,
          source: source_type,
          enabled: existing.try(&.enabled?) || true,
          installed_at: existing.try(&.installed_at) || now,
          updated_at: now,
          original_source: original_source,
          capabilities: existing.try(&.capabilities),
          github: github,
          parsed: parsed,
        )

        @records[id] = record
        persist
        record
      end

      def set_enabled(id : String, enabled : Bool) : Nil
        key = normalize_id(id)
        record = @records[key]?
        raise "Plugin \"#{id}\" is not installed" unless record
        return if record.enabled? == enabled
        record.enabled = enabled
        record.updated_at = Time.utc.to_rfc3339
        persist
      end

      def set_mcp_server_enabled(id : String, server : String, enabled : Bool) : Nil
        key = normalize_id(id)
        record = @records[key]?
        raise "Plugin \"#{id}\" is not installed" unless record
        manifest = record.manifest
        raise "Plugin \"#{id}\" does not declare MCP server \"#{server}\"" unless manifest && manifest.mcp_servers.has_key?(server)

        caps = record.capabilities || PluginCapabilityState.new
        caps.mcp_servers[server] = PluginMcpServerState.new(enabled)
        record.capabilities = caps
        record.updated_at = Time.utc.to_rfc3339
        persist
      end

      def remove(id : String) : Nil
        key = normalize_id(id)
        raise "Plugin \"#{id}\" is not installed" unless @records.delete(key)
        persist
      end

      def reload : ReloadSummary
        prev_ids = Set(String).new(@records.keys)
        load
        next_ids = Set(String).new(@records.keys)

        added = (next_ids - prev_ids).to_a.sort
        removed = (prev_ids - next_ids).to_a.sort
        errors = [] of {id: String, message: String}

        @records.each do |rid, rec|
          next unless rec.has_errors?
          msg = rec.diagnostics.find(&.severity.error?).try(&.message) || "error"
          errors << {id: rid, message: msg}
        end

        ReloadSummary.new(added, removed, errors)
      end

      # --- Capability queries (called at startup) ---

      def plugin_skills : Array(H2code::Tools::SkillDefinition)
        skills = [] of H2code::Tools::SkillDefinition
        @records.each_value do |record|
          next unless record.ok?
          manifest = record.manifest || next
          manifest.skills.each do |skill_dir|
            discovered = H2code::Tools::SkillDiscovery.discover_from_dir(skill_dir, "plugin")
            discovered.each { |s| skills << s }
          end
        end
        skills
      end

      def enabled_session_starts : Array(EnabledPluginSessionStart)
        result = [] of EnabledPluginSessionStart
        @records.each_value do |record|
          next unless record.ok?
          skill = record.manifest.try(&.session_start).try(&.skill)
          next if skill.nil? || skill.empty?
          result << EnabledPluginSessionStart.new(record.id, skill)
        end
        result
      end

      def enabled_mcp_servers : Array(Mcp::McpServerConfig)
        result = [] of Mcp::McpServerConfig
        @records.each_value do |record|
          next unless record.ok?
          manifest = record.manifest || next
          manifest.mcp_servers.each do |name, config|
            next unless mcp_server_enabled?(record, name, config)
            runtime_name = "plugin-#{record.id}:#{name}"
            cfg = config.dup
            cfg.name = runtime_name
            cfg.enabled = true
            if cfg.stdio?
              cfg.env = cfg.env.dup
              cfg.env["KIMI_CODE_HOME"] = h2code_home_path
              cfg.env["KIMI_PLUGIN_ROOT"] = record.root
              cfg.cwd = cfg.cwd || record.root
            end
            result << cfg
          end
        end
        result
      end

      def enabled_hooks : Array(H2code::Hooks::HookDef)
        result = [] of H2code::Hooks::HookDef
        @records.each_value do |record|
          next unless record.ok?
          manifest = record.manifest || next
          manifest.hooks.each do |hook|
            env = {} of String => String
            env["KIMI_CODE_HOME"] = h2code_home_path
            env["KIMI_PLUGIN_ROOT"] = record.root
            result << H2code::Hooks::HookDef.new(
              hook.event, hook.command, hook.matcher, hook.timeout,
              cwd: record.root, env: env,
            )
          end
        end
        result
      end

      def enabled_commands : Array(PluginCommandDef)
        result = [] of PluginCommandDef
        @records.each_value do |record|
          next unless record.ok?
          manifest = record.manifest || next
          manifest.commands.each do |entry|
            cmd = CommandLoader.load(entry.path, record.id, entry.name)
            result << cmd if cmd
          end
        end
        result
      end

      # --- Internal helpers ---

      private def install_from_local_path(source_path : String)
        source_root = File.realpath(source_path)
        raise "Plugin root is not a directory: #{source_root}" unless Dir.exists?(source_root)

        parsed = ManifestParser.parse(source_root)
        raise "Cannot install plugin at #{source_root}: #{first_error(parsed)}" unless parsed.manifest

        id = normalize_id((parsed.manifest || raise "manifest required").name)
        managed_root = copy_to_managed(id, source_root)
        re_parsed = ManifestParser.parse(managed_root)

        {id, managed_root, re_parsed, PluginSource::LocalPath, nil, source_path}
      end

      private def install_from_zip(zip_url : String, original_source : String)
        buffer = Archive.download_zip(zip_url)
        tmp_dir = File.join(tmpdir, "h2code-plugin-zip-#{Random::Secure.hex(6)}")
        begin
          detected_root = Archive.extract_zip(buffer, tmp_dir)
          parsed = ManifestParser.parse(detected_root)
          raise "Cannot install plugin from #{original_source}: #{first_error(parsed)}" unless parsed.manifest

          id = normalize_id((parsed.manifest || raise "manifest required").name)
          managed_root = copy_to_managed(id, detected_root)
          re_parsed = ManifestParser.parse(managed_root)

          {id, managed_root, re_parsed, PluginSource::ZipUrl, nil, original_source}
        ensure
          FileUtils.rm_r(tmp_dir) if Dir.exists?(tmp_dir)
        end
      end

      private def install_from_github(source : GithubSource, original_source : String)
        resolution = GithubResolver.resolve(source)
        buffer = Archive.download_zip(resolution.tarball_url)
        tmp_dir = File.join(tmpdir, "h2code-plugin-zip-#{Random::Secure.hex(6)}")
        begin
          detected_root = Archive.extract_zip(buffer, tmp_dir)
          parsed = ManifestParser.parse(detected_root)
          raise "Cannot install plugin from #{original_source}: #{first_error(parsed)}" unless parsed.manifest

          id = normalize_id((parsed.manifest || raise "manifest required").name)
          managed_root = copy_to_managed(id, detected_root)
          re_parsed = ManifestParser.parse(managed_root)

          gh = PluginGithubMetadata.new(source.owner, source.repo, resolution.ref)
          {id, managed_root, re_parsed, PluginSource::Github, gh, original_source}
        ensure
          FileUtils.rm_r(tmp_dir) if Dir.exists?(tmp_dir)
        end
      end

      private def copy_to_managed(id : String, source_root : String) : String
        managed_dir = File.join(h2code_home_path, "plugins", "managed")
        FileUtils.mkdir_p(managed_dir)
        managed_root = File.join(managed_dir, id)
        staging = File.join(managed_dir, "#{id}-#{Random::Secure.hex(4)}")

        FileUtils.cp_r(source_root, staging)
        FileUtils.rm_r(managed_root) if Dir.exists?(managed_root)
        File.rename(staging, managed_root)

        File.realpath(managed_root)
      end

      private def materialize(entry : Store::InstalledRecord) : PluginRecord
        parsed = ManifestParser.parse(entry.root)
        build_record(
          id: entry.id,
          root: entry.root,
          source: source_from_string(entry.source),
          enabled: entry.enabled?,
          installed_at: entry.installed_at,
          updated_at: entry.updated_at,
          original_source: entry.original_source,
          capabilities: entry.capabilities,
          github: entry.github,
          parsed: parsed,
        )
      end

      private def build_record(id : String, root : String, source : PluginSource,
                               enabled : Bool, installed_at : String,
                               updated_at : String?, original_source : String?,
                               capabilities : PluginCapabilityState?,
                               github : PluginGithubMetadata?,
                               parsed : ParsedManifestResult) : PluginRecord
        record = PluginRecord.new(
          id: id, root: root, source: source,
          enabled: enabled, installed_at: installed_at,
          updated_at: updated_at, original_source: original_source,
          capabilities: capabilities, github: github,
        )
        record.manifest = parsed.manifest
        record.manifest_kind = parsed.manifest_kind
        record.manifest_path = parsed.manifest_path
        record.shadowed_manifest_path = parsed.shadowed_manifest_path
        record.diagnostics = parsed.diagnostics
        record.skill_instructions = parsed.manifest.try(&.skill_instructions)
        record
      end

      private def mcp_server_enabled?(record : PluginRecord, name : String,
                                      config : Mcp::McpServerConfig) : Bool
        caps = record.capabilities
        state = caps.try(&.mcp_servers[name]?)
        return config.enabled? if state.nil?
        state.enabled?
      end

      private def persist : Nil
        records = @records.values.map do |r|
          Store::InstalledRecord.new(
            id: r.id, root: r.root, source: r.source.to_s,
            enabled: r.enabled?, installed_at: r.installed_at,
            updated_at: r.updated_at, original_source: r.original_source,
            capabilities: r.capabilities, github: r.github,
          )
        end
        Store.write(@kimi_home, records)
      end

      private def h2code_home_path : String
        ENV["H2CODE_HOME"]? || File.join(@kimi_home, ".h2code")
      end

      private def tmpdir : String
        # Dir.tempdir resolves /tmp on Unix and %TEMP% on Windows; a hardcoded
        # "/tmp" does not exist on Windows and broke plugin extraction.
        @tmp_dir || Dir.tempdir
      end

      private def source_from_string(s : String) : PluginSource
        PluginSource.parse?(s) || PluginSource::LocalPath
      end

      private def first_error(parsed : ParsedManifestResult) : String
        parsed.diagnostics.find(&.severity.error?).try(&.message) || "no manifest"
      end

      private def normalize_id(name : String) : String
        Plugin.normalize_id(name)
      end
    end
  end
end
