module H2code
  module Tools
    # select_tools — progressive tool disclosure loader.
    #
    # Контракты перенесены 1:1 из
    # `packages/agent-core-v2/src/agent/toolSelect/tools/select-tools.ts`.
    #
    # Единственный тул со snake_case-именем (исторически сложилось в MCP).
    #
    # См. детальный план портирования в `md-tools/select-tools.md`.
    module ToolSelect
      @@service : ToolSelectService?

      def self.service=(s : ToolSelectService?)
        @@service = s
      end

      def self.service : ToolSelectService?
        @@service
      end
    end

    struct LoadToolsResult
      property to_load : Array(String)
      property already_available : Array(String)
      property unknown : Array(String)

      def initialize(@to_load : Array(String) = [] of String,
                     @already_available : Array(String) = [] of String,
                     @unknown : Array(String) = [] of String)
      end
    end

    abstract class ToolSelectService
      abstract def enabled? : Bool
      abstract def load(names : Array(String)) : LoadToolsResult

      # Provider-visible tool shaping: when disclosure is enabled, MCP tool
      # definitions that have not been loaded yet are dropped from the
      # top-level tools[] (the model selects them via select_tools first).
      abstract def shape_tools(defs : Array(LLM::ToolDefinition)) : Array(LLM::ToolDefinition)

      # Announcement block describing currently loadable tools, or nil when
      # there is nothing to announce. Appended to the system prompt at each
      # step, so it is stateless and always reflects the live registry.
      abstract def announcement(defs : Array(LLM::ToolDefinition)) : String?
    end

    # Experimental flag — mirrors JS `tool-select` (off by default). Enabled
    # via H2CODE_EXPERIMENTAL_TOOL_SELECT=1/true or the master
    # H2CODE_EXPERIMENTAL_FLAG switch. Read at startup.
    def self.tool_select_enabled_from_env? : Bool
      case ENV["H2CODE_EXPERIMENTAL_TOOL_SELECT"]?
      when "1", "true", "yes" then return true
      end
      case ENV["H2CODE_EXPERIMENTAL_FLAG"]?
      when "1", "true", "yes" then return true
      end
      false
    end

    # Простейшая in-memory реализация для тестов и MVP.
    # Содержит набор "loadable" имён; активный set пуст по умолчанию.
    class InMemoryToolSelectService < ToolSelectService
      @enabled : Bool = true
      @loadable : Set(String)
      @active : Set(String)

      def initialize(@enabled : Bool = true,
                     loadable : Array(String) = [] of String,
                     active : Array(String) = [] of String)
        @loadable = Set.new(loadable)
        @active = Set.new(active)
      end

      def enabled? : Bool
        @enabled
      end

      def disable! : Nil
        @enabled = false
      end

      def enable! : Nil
        @enabled = true
      end

      def loadable!(name : String) : Nil
        @loadable << name
      end

      def active!(name : String) : Nil
        @active << name
      end

      def load(names : Array(String)) : LoadToolsResult
        result = LoadToolsResult.new
        names.each do |name|
          if @active.includes?(name)
            result.already_available << name
          elsif @loadable.includes?(name)
            @active << name
            result.to_load << name
          else
            result.unknown << name
          end
        end
        result
      end

      def shape_tools(defs : Array(LLM::ToolDefinition)) : Array(LLM::ToolDefinition)
        return defs unless @enabled
        defs.select do |d|
          !d.name.starts_with?(Mcp::ToolNaming::PREFIX) || @active.includes?(d.name)
        end
      end

      def announcement(defs : Array(LLM::ToolDefinition)) : String?
        return nil unless @enabled
        loadable = defs.select(&.name.starts_with?(Mcp::ToolNaming::PREFIX))
          .map(&.name)
          .reject { |n| @active.includes?(n) }
          .sort!
        return nil if loadable.empty?
        render_announcement(loadable)
      end

      private def render_announcement(loadable : Array(String)) : String?
        %(<tools_loadable>
#{loadable.join('\n')}
</tools_loadable>
Use the select_tools tool with exact names to load full tool definitions before calling them.)
      end
    end

    # Production service: gates on the experimental flag, keeps the
    # loaded-tool ledger for the session, and shapes the provider-visible
    # tool list per request. Registered once from the app setup when the
    # flag is on; the per-step shaping itself is driven by each loop's own
    # tool definitions, so subagent loops shape their own registries.
    class AgentToolSelectService < ToolSelectService
      @loaded = Set(String).new

      def initialize(@registry : Registry, @enabled : Bool = Tools.tool_select_enabled_from_env?)
      end

      def enabled? : Bool
        @enabled
      end

      def load(names : Array(String)) : LoadToolsResult
        result = LoadToolsResult.new
        return result unless @enabled
        loadable = loadable_names
        names.each do |name|
          if @loaded.includes?(name)
            result.already_available << name
          elsif loadable.includes?(name)
            @loaded << name
            result.to_load << name
          else
            result.unknown << name
          end
        end
        result.to_load.sort!
        result
      end

      def shape_tools(defs : Array(LLM::ToolDefinition)) : Array(LLM::ToolDefinition)
        return defs unless @enabled
        defs.select do |d|
          !d.name.starts_with?(Mcp::ToolNaming::PREFIX) || @loaded.includes?(d.name)
        end
      end

      def announcement(defs : Array(LLM::ToolDefinition)) : String?
        return nil unless @enabled
        loadable = defs.select(&.name.starts_with?(Mcp::ToolNaming::PREFIX))
          .map(&.name)
          .reject { |n| @loaded.includes?(n) }
          .sort!
        return nil if loadable.empty?
        %(<tools_loadable>
#{loadable.join('\n')}
</tools_loadable>
Use the select_tools tool with exact names to load full tool definitions before calling them.)
      end

      def loaded?(name : String) : Bool
        @loaded.includes?(name)
      end

      private def loadable_names : Array(String)
        @registry.names.select(&.starts_with?(Mcp::ToolNaming::PREFIX)).sort!
      end
    end

    class SelectTools < Tool
      DESCRIPTION = <<-TEXT
        Load one or more tools by name so you can call them. All available tool names are listed in the <tools_added>/<tools_removed> announcements in the system context — fold them in order to get the current list. Pass the exact name(s) you need; their full definitions become available immediately, so you can call them directly in your next tool call.
      TEXT

      def name : String
        Names::SELECT_TOOLS
      end

      def description : String
        DESCRIPTION
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "names": {
              "type": "array",
              "items": { "type": "string" },
              "minItems": 1,
              "description": "Exact tool names to load, taken from the latest announced tool list."
            }
          },
          "required": ["names"],
          "additionalProperties": false
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        service = ToolSelect.service
        return ToolResult.error("Tool-select service is not initialized.") if service.nil?

        svc = service
        unless svc.enabled?
          return ToolResult.error("select_tools is not available for the current model.")
        end

        names = parse_names(input["names"]?)
        if names.empty?
          return ToolResult.error("`names` must be a non-empty array of tool names.")
        end

        result = svc.load(names)

        lines = [] of String
        if !result.to_load.empty?
          lines << "Loaded: #{result.to_load.join(", ")}"
        end
        if !result.already_available.empty?
          lines << "Already available: #{result.already_available.join(", ")}"
        end
        result.unknown.each do |name|
          lines << "Unknown tool: #{name}. Pick from the latest announced tools list."
        end

        is_error = result.to_load.empty? && result.already_available.empty?
        body = lines.empty? ? "No tools loaded." : lines.join('\n')

        is_error ? ToolResult.error(body) : ToolResult.success(body)
      end

      private def parse_names(value : JSON::Any?) : Array(String)
        return [] of String if value.nil?
        arr = value.as_a?
        return [] of String if arr.nil?
        names = [] of String
        arr.each do |v|
          if s = v.as_s?
            names << s unless s.empty?
          end
        end
        names
      end
    end
  end
end
