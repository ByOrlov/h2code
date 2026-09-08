module H2code
  module TUI
    struct CommandInfo
      property name : String
      property usage : String
      # Translation key into the `commands.*` namespace, e.g. "help" resolves
      # via `H2code.t("commands.help")`. Empty falls back to `@description`.
      property description_key : String
      @description : String

      def initialize(@name : String, description : String, @usage : String = "", @description_key : String = "")
        @description = description
      end

      # Resolves the localized description lazily so a locale switch at
      # runtime is reflected on the next render without rebuilding COMMANDS.
      def description : String
        return @description if @description_key.empty?
        H2code.t("commands.#{@description_key}")
      end
    end

    class CommandRegistry
      COMMANDS = [
        CommandInfo.new("/help", "Show available commands", description_key: "help"),
        CommandInfo.new("/exit", "Exit the application", description_key: "exit"),
        CommandInfo.new("/quit", "Exit the application", description_key: "quit"),
        CommandInfo.new("/new", "Start a new session", description_key: "new"),
        CommandInfo.new("/sessions", "List and resume a session", description_key: "sessions"),
        CommandInfo.new("/resume", "Resume a session (alias for /sessions)", description_key: "resume"),
        CommandInfo.new("/fork", "Fork the current session", description_key: "fork"),
        CommandInfo.new("/archive", "Archive the current session", description_key: "archive"),
        CommandInfo.new("/restore", "Restore an archived session", description_key: "restore"),
        CommandInfo.new("/search", "Search sessions across all workspaces", description_key: "search"),
        CommandInfo.new("/rename", "Rename the current session", "<title>", "rename"),
        CommandInfo.new("/title", "Set session title (alias for /rename)", "<title>", "title"),
        CommandInfo.new("/clear", "Clear conversation history", description_key: "clear"),
        CommandInfo.new("/compact", "Summarize context to free space", description_key: "compact"),
        CommandInfo.new("/model", "Switch model", description_key: "model"),
        CommandInfo.new("/provider", "Switch LLM provider", description_key: "provider"),
        CommandInfo.new("/status", "Show session status", description_key: "status"),
        CommandInfo.new("/undo", "Undo last turn", description_key: "undo"),
        CommandInfo.new("/yolo", "Toggle persistent YOLO auto-approve mode", "on|off", "yolo"),
        CommandInfo.new("/auto", "Set permission mode to auto", description_key: "auto"),
        CommandInfo.new("/manual", "Set permission mode to manual", description_key: "manual"),
        CommandInfo.new("/export-md", "Export session to markdown file", "[<path>]", "export_md"),
        CommandInfo.new("/add-dir", "Add working directory", "<path>", "add_dir"),
        CommandInfo.new("/theme", "Switch theme", "dark|light", "theme"),
        CommandInfo.new("/version", "Show version information", description_key: "version"),
        CommandInfo.new("/usage", "Show token usage and context", description_key: "usage"),
        CommandInfo.new("/queue", "Show or clear the queued messages", "[clear]", "queue"),
        CommandInfo.new("/todos", "Show or clear the agent todo list", "[clear]", "todos"),
        CommandInfo.new("/editor", "Open $EDITOR to compose a message", description_key: "editor"),
        CommandInfo.new("/copy", "Copy last assistant message to clipboard", description_key: "copy"),
        CommandInfo.new("/permission", "Switch permission mode", "manual|auto|yolo", "permission"),
        CommandInfo.new("/effort", "Show thinking effort", "low|medium|high", "effort"),
        CommandInfo.new("/plan", "Toggle plan mode", description_key: "plan"),
        CommandInfo.new("/swarm", "Toggle swarm mode or run a swarm task", "[on|off|<prompt>]", "swarm"),
        CommandInfo.new("/sudo", "Set sudo permission mode", "off|request|always", "sudo"),
        CommandInfo.new("/debug", "Dump full session transcript to stdout", description_key: "debug"),
        CommandInfo.new("/debugzones", "Toggle TUI zone sizes debug overlay", description_key: "debugzones"),
        CommandInfo.new("/feedback", "Send feedback to the team", "<message>", "feedback"),
        CommandInfo.new("/reload", "Reload config.json and session state", description_key: "reload"),
        CommandInfo.new("/web", "Print session URL for the Web UI", description_key: "web"),
        CommandInfo.new("/sync", "Cloud sync with the PWA", "[on|off|code|email <addr>]", "sync"),
        CommandInfo.new("/settings", "Show current configuration", description_key: "settings"),
        CommandInfo.new("/init", "Analyze the codebase and generate AGENTS.md", description_key: "init"),
        CommandInfo.new("/export-debug-zip", "Export session debug bundle (.tar.gz)", description_key: "export_debug_zip"),
        CommandInfo.new("/experiments", "Show experimental feature flags", description_key: "experiments"),
        CommandInfo.new("/mcp", "Show MCP server status", "[status|update [server]|configure|help]", "mcp"),
        CommandInfo.new("/plugins", "Show plugin status", description_key: "plugins"),
        CommandInfo.new("/login", "Show how to configure credentials", description_key: "login"),
        CommandInfo.new("/logout", "Clear credentials from config", description_key: "logout"),
        CommandInfo.new("/tasks", "Browse background tasks", description_key: "tasks"),
        CommandInfo.new("/memory", "Show memory profile of live collections", description_key: "memory"),
        CommandInfo.new("/telemetry", "Toggle render-quality telemetry", "on|off", "telemetry"),
        CommandInfo.new("/goal", "Show goal status", "[status|pause|resume|cancel]", "goal"),
        CommandInfo.new("/language", "Switch interface language", "[en|ru|es|zh|ja|pt|hi|fa|uk|be]", "language"),
        CommandInfo.new("/sounds", "Toggle sound notifications", "on|off", "sounds"),
        CommandInfo.new("/tips", "Toggle startup tips", "on|off", "tips"),
        CommandInfo.new("/volume", "Set sound volume", "0-100", "volume"),
        CommandInfo.new("/voicelang", "Default voice message language", "ru|en|…|auto", "voicelang"),
        CommandInfo.new("/upgrade", "Update h2code to the latest release", description_key: "upgrade"),
        CommandInfo.new("/cleanup", "Delete old sessions and voice messages", "[week|month|6months|year]", "cleanup"),
      ]

      def self.names : Array(String)
        COMMANDS.map(&.name)
      end

      def self.find(name : String) : CommandInfo?
        COMMANDS.find { |c| c.name == name }
      end

      def self.match(prefix : String) : Array(CommandInfo)
        return [] of CommandInfo if prefix.empty?
        COMMANDS.select { |c| c.name.starts_with?(prefix) }
      end

      struct ParseResult
        property command : String
        property args : String

        def initialize(@command : String, @args : String = "")
        end
      end

      def self.parse(input : String) : ParseResult?
        return nil unless input.starts_with?('/')
        parts = input.split(' ', 2)
        cmd = parts[0]
        args = parts[1]? || ""
        ParseResult.new(cmd, args.strip)
      end
    end
  end
end
