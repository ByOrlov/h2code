require "json"
require "../mcp/config"

module H2code
  module Config
    # Explicit web-search service configuration. Mirrors the JS
    # `[services.moonshot_search]` section: when present it wins over the
    # provider-derived search backend.
    struct MoonshotServiceConfig
      include JSON::Serializable

      property base_url : String?
      property api_key : String?
      property custom_headers : Hash(String, String) = {} of String => String

      def initialize(@base_url : String? = nil,
                     @api_key : String? = nil,
                     @custom_headers : Hash(String, String) = {} of String => String)
      end
    end

    struct ServicesConfig
      include JSON::Serializable

      property moonshot_search : MoonshotServiceConfig? = nil

      def initialize(@moonshot_search : MoonshotServiceConfig? = nil)
      end
    end

    # Global cloud-sync settings (`sync` section of config.json) — the
    # `/sync on` TUI command and `h2code sync` both flip `enabled`; the
    # pairing code itself lives in `~/.h2code/remote/code` (see
    # src/remote/, plans/CloudSync.md in the hibechat repo).
    struct SyncConfig
      include JSON::Serializable

      property? enabled : Bool = false
      # Relay the h2code-remote daemon connects to in cloud mode. Default is
      # the LAN address of this machine (resolved at read time) so the
      # pairing QR works from a phone — localhost would point the phone at
      # itself. Override explicitly via config.json when a public relay
      # exists.
      property relay_url : String = ""

      def initialize(@enabled : Bool = false,
                     @relay_url : String = "",
                     @email : String = "")
      end
    end

    # Voice transcription settings (`transcription` section of config.json)
    # — the TUI's Ctrl+R voice messages (and h2code-remote's inbound APK
    # voice clips) are recorded/transcribed by the local h2voice server over
    # a Unix socket. The socket path keeps its literal `~` here; callers
    # expand it at the use site. H2CODE_VOICE_SOCKET (and the server's own
    # H2VOICE_VOICE_SOCKET) override it.
    struct TranscriptionConfig
      include JSON::Serializable

      # Enabled by default: voice recording works out of the box whenever
      # the h2voice server is present; `"enabled": false` opts out.
      property? enabled : Bool = true
      property socket : String = "~/.h2voice/voice.sock"
      property engine : String = "auto"
      # Default voice language ("auto" = detect on the server; detection can
      # misfire on short/noisy clips). Set via /voicelang.
      property language : String = "auto"
      property max_duration_sec : Int32 = 120

      def initialize(@enabled : Bool = true,
                     @socket : String = "~/.h2voice/voice.sock",
                     @engine : String = "auto",
                     @language : String = "auto",
                     @max_duration_sec : Int32 = 120)
      end
    end

    class Config
      property model : String? = nil
      property provider_name : String? = nil
      property thinking_effort : String = "medium"
      property permission_mode : String = "manual"
      # App-wide sudo permission mode for Bash ("off", "request", "always").
      # Set via `/sudo` and persisted so it applies to every chat/instance.
      property sudo_mode : String = "off"
      property api_key : String? = nil
      property endpoint : String? = nil
      property zai_api_key : String = ""
      property zai_endpoint : String = "https://api.z.ai/api/paas/v4"
      property zai_model : String = "glm-4.6"
      property zai_coding_plan_endpoint : String = "https://api.z.ai/api/coding/paas/v4"
      property zai_coding_plan_model : String = "glm-5.2"
      property ollama_endpoint : String? = nil
      property ollama_model : String? = nil
      property lmstudio_endpoint : String? = nil
      property lmstudio_model : String? = nil
      property deepseek_api_key : String = ""
      property deepseek_endpoint : String = "https://api.deepseek.com/v1"
      property deepseek_model : String = "deepseek-chat"
      property groq_api_key : String = ""
      property groq_endpoint : String = "https://api.groq.com/openai/v1"
      property groq_model : String = "llama-3.3-70b-versatile"
      property openrouter_api_key : String = ""
      property openrouter_endpoint : String = "https://openrouter.ai/api/v1"
      property openrouter_model : String = "anthropic/claude-3.5-sonnet"
      property xai_api_key : String = ""
      property xai_endpoint : String = "https://api.x.ai/v1"
      property xai_model : String = "grok-4"
      property cerebras_api_key : String = ""
      property cerebras_endpoint : String = "https://api.cerebras.ai/v1"
      property cerebras_model : String = "llama-3.3-70b"
      property fireworks_api_key : String = ""
      property fireworks_endpoint : String = "https://api.fireworks.ai/inference/v1"
      property fireworks_model : String = "accounts/fireworks/models/llama-v3p1-70b-instruct"
      property together_api_key : String = ""
      property together_endpoint : String = "https://api.together.xyz/v1"
      property together_model : String = "meta-llama/Llama-3.3-70B-Instruct-Turbo"
      # GitHub API token for CI observation: with it, observers poll
      # api.github.com directly and skip the gh CLI entirely. Config
      # `github.token`; GITHUB_TOKEN / GH_TOKEN env vars override.
      property github_token : String = ""
      # GitLab API token for CI observation (private projects need it;
      # public ones are polled anonymously). Config `gitlab.token`;
      # GITLAB_TOKEN / GITLAB_PRIVATE_TOKEN env vars override.
      property gitlab_token : String = ""
      # Self-hosted GitLab base URL (e.g. "https://gitlab.example.com"):
      # remotes on that host are observed as GitLab CI. Config
      # `gitlab.endpoint`; the GITLAB_HOST env var overrides.
      property gitlab_endpoint : String = ""
      property max_steps : Int32 = 150
      property max_context_tokens : Int32 = 262144
      property temperature : Float64? = nil
      property proxy : String? = nil
      property language : String? = nil
      property? debug_zones : Bool = false
      # Show a random tip under the welcome box at startup (see H2code::Tips).
      # Toggled via `/tips on|off`.
      property? show_tips : Bool = true
      # --- Поведенческие флаги (раньше читались из ENV напрямую) ---
      property? debug : Bool = false
      property? cron_enabled : Bool = true
      property? cron_no_stale : Bool = false
      property subagent_timeout_ms : Int32? = nil
      property experimental_flag : String? = nil
      property mock_script : String? = nil
      property editor : String? = nil
      property tmp_dir : String? = nil
      property git_terminal_prompt : String? = nil
      property shell : String? = nil
      # Verified/explicit bash.exe location for the Windows shell port
      # (set by /bash detect or /bash patch). nil = auto (existence scan).
      property bash_available : String? = nil
      property notifications : Notify::Config = Notify::Config.default
      property sync : SyncConfig = SyncConfig.new
      property hooks : Array(Hooks::HookDef) = [] of Hooks::HookDef
      property mcp_servers : Array(Mcp::McpServerConfig) = [] of Mcp::McpServerConfig
      property services : ServicesConfig = ServicesConfig.new
      property transcription : TranscriptionConfig = TranscriptionConfig.new

      def initialize
      end

      def self.load(path : String? = nil) : Config
        config = Config.new

        config_path = path || default_config_path

        if File.exists?(config_path)
          content = File.read(config_path)
          config = parse_json(content)
        end

        if key = ENV["MOONSHOT_API_KEY"]?
          config.api_key = key
        end
        if key = ENV["ZAI_API_KEY"]?
          config.zai_api_key = key
        end
        if key = ENV["ZHIPU_API_KEY"]?
          config.zai_api_key = key
        end
        if ep = ENV["MOONSHOT_ENDPOINT"]?
          config.endpoint = ep
        end
        if ep = ENV["ZAI_ENDPOINT"]?
          config.zai_endpoint = ep
        end
        if ep = ENV["ZAI_CODING_PLAN_ENDPOINT"]?
          config.zai_coding_plan_endpoint = ep
        end
        if ep = ENV["OLLAMA_ENDPOINT"]?
          config.ollama_endpoint = ep
        end
        if model = ENV["OLLAMA_MODEL"]?
          config.ollama_model = model
        end
        if ep = ENV["LMSTUDIO_ENDPOINT"]?
          config.lmstudio_endpoint = ep
        end
        if model = ENV["LMSTUDIO_MODEL"]?
          config.lmstudio_model = model
        end
        if key = ENV["DEEPSEEK_API_KEY"]?
          config.deepseek_api_key = key
        end
        if ep = ENV["DEEPSEEK_ENDPOINT"]?
          config.deepseek_endpoint = ep
        end
        if model = ENV["DEEPSEEK_MODEL"]?
          config.deepseek_model = model
        end
        if key = ENV["GROQ_API_KEY"]?
          config.groq_api_key = key
        end
        if ep = ENV["GROQ_ENDPOINT"]?
          config.groq_endpoint = ep
        end
        if model = ENV["GROQ_MODEL"]?
          config.groq_model = model
        end
        if key = ENV["OPENROUTER_API_KEY"]?
          config.openrouter_api_key = key
        end
        if ep = ENV["OPENROUTER_ENDPOINT"]?
          config.openrouter_endpoint = ep
        end
        if model = ENV["OPENROUTER_MODEL"]?
          config.openrouter_model = model
        end
        if key = ENV["XAI_API_KEY"]?
          config.xai_api_key = key
        end
        if ep = ENV["XAI_ENDPOINT"]?
          config.xai_endpoint = ep
        end
        if model = ENV["XAI_MODEL"]?
          config.xai_model = model
        end
        if key = ENV["CEREBRAS_API_KEY"]?
          config.cerebras_api_key = key
        end
        if ep = ENV["CEREBRAS_ENDPOINT"]?
          config.cerebras_endpoint = ep
        end
        if model = ENV["CEREBRAS_MODEL"]?
          config.cerebras_model = model
        end
        if key = ENV["FIREWORKS_API_KEY"]?
          config.fireworks_api_key = key
        end
        if ep = ENV["FIREWORKS_ENDPOINT"]?
          config.fireworks_endpoint = ep
        end
        if model = ENV["FIREWORKS_MODEL"]?
          config.fireworks_model = model
        end
        if key = ENV["TOGETHER_API_KEY"]?
          config.together_api_key = key
        end
        if ep = ENV["TOGETHER_ENDPOINT"]?
          config.together_endpoint = ep
        end
        if model = ENV["TOGETHER_MODEL"]?
          config.together_model = model
        end
        if model = ENV["MOONSHOT_MODEL"]?
          config.model = model
        end
        if model = ENV["ZAI_MODEL"]?
          config.zai_model = model
        end
        if model = ENV["ZAI_CODING_PLAN_MODEL"]?
          config.zai_coding_plan_model = model
        end
        if provider = ENV["H2CODE_PROVIDER"]?
          config.provider_name = provider
        end
        if key = ENV["GITHUB_TOKEN"]? || ENV["GH_TOKEN"]?
          config.github_token = key
        end
        if key = ENV["GITLAB_TOKEN"]? || ENV["GITLAB_PRIVATE_TOKEN"]?
          config.gitlab_token = key
        end
        if host = ENV["GITLAB_HOST"]?
          config.gitlab_endpoint = host.starts_with?("http") ? host : "https://#{host}"
        end
        if lang = ENV["H2CODE_LANG"]?
          config.language = lang
        end
        # H2CODE_SOUND=1 forces sound notifications on at startup (for demos /
        # testing) without editing config.json.
        if ENV["H2CODE_SOUND"]? == "1"
          config.notifications.sound_enabled = true
        end
        # Same env soroka-server reads — keeps both sides on one socket.
        if sock = ENV["H2CODE_VOICE_SOCKET"]?
          config.transcription.socket = sock
        end
        if vol = ENV["H2CODE_VOLUME"]?.try(&.to_i?)
          config.notifications.sound_volume = vol.clamp(0, 100)
        end
        if proxy = ENV["HTTP_PROXY"]? || ENV["HTTPS_PROXY"]? || ENV["ALL_PROXY"]?
          config.proxy = proxy
        end

        # --- Поведенческие флаги: единственная точка чтения из ENV ---
        config.debug = ENV.has_key?("H2CODE_DEBUG")
        config.cron_enabled = !ENV.has_key?("H2CODE_DISABLE_CRON")
        config.cron_no_stale = ENV.has_key?("H2CODE_CRON_NO_STALE")
        if v = ENV["H2CODE_SUBAGENT_TIMEOUT_MS"]?.try(&.to_i?)
          config.subagent_timeout_ms = v if v >= 1
        end
        config.experimental_flag = ENV["H2CODE_EXPERIMENTAL_FLAG"]?
        config.mock_script = ENV["H2CODE_MOCK_SCRIPT"]?
        config.editor = ENV["EDITOR"]? || ENV["VISUAL"]?
        config.tmp_dir = ENV["TMPDIR"]?
        config.git_terminal_prompt = ENV["GIT_TERMINAL_PROMPT"]?
        config.shell = ENV["SHELL"]?

        config
      end

      def self.default_config_path : String
        home = HomePort.home
        h2code_home = ENV["H2CODE_HOME"]? || File.join(home, ".h2code")
        File.join(h2code_home, "config.json")
      end

      def self.parse_json(content : String) : Config
        config = Config.new
        root = JSON.parse(content)

        if model = root["model"]?.try(&.as_h?)
          config.model = model["default"]?.try(&.as_s?)
          config.thinking_effort = model["thinking_effort"]?.try(&.as_s?) || "medium"
        end

        if perm = root["permission"]?.try(&.as_h?)
          config.permission_mode = perm["mode"]?.try(&.as_s?) || "manual"
          if sudo = perm["sudo_mode"]?.try(&.as_s?)
            config.sudo_mode = sudo if sudo.in?("off", "request", "always")
          end
        end

        if provider = root["provider"]?.try(&.as_h?)
          config.provider_name = provider["default"]?.try(&.as_s?)
          if moonshot = provider["moonshot"]?.try(&.as_h?)
            config.api_key = moonshot["api_key"]?.try(&.as_s?)
            config.endpoint = moonshot["endpoint"]?.try(&.as_s?)
          end
          if zai = provider["zai"]?.try(&.as_h?)
            config.zai_api_key = zai["api_key"]?.try(&.as_s?) || ""
            config.zai_endpoint = zai["endpoint"]?.try(&.as_s?) || config.zai_endpoint
            config.zai_model = zai["model"]?.try(&.as_s?) || config.zai_model
          end
          if zcp = provider["zai-coding-plan"]?.try(&.as_h?)
            config.zai_coding_plan_endpoint = zcp["endpoint"]?.try(&.as_s?) || config.zai_coding_plan_endpoint
            config.zai_coding_plan_model = zcp["model"]?.try(&.as_s?) || config.zai_coding_plan_model
          end
          if ollama = provider["ollama"]?.try(&.as_h?)
            config.ollama_endpoint = ollama["endpoint"]?.try(&.as_s?)
            config.ollama_model = ollama["model"]?.try(&.as_s?)
          end
          if lmstudio = provider["lmstudio"]?.try(&.as_h?)
            config.lmstudio_endpoint = lmstudio["endpoint"]?.try(&.as_s?)
            config.lmstudio_model = lmstudio["model"]?.try(&.as_s?)
          end
          if deepseek = provider["deepseek"]?.try(&.as_h?)
            config.deepseek_api_key = deepseek["api_key"]?.try(&.as_s?) || ""
            config.deepseek_endpoint = deepseek["endpoint"]?.try(&.as_s?) || config.deepseek_endpoint
            config.deepseek_model = deepseek["model"]?.try(&.as_s?) || config.deepseek_model
          end
          if groq = provider["groq"]?.try(&.as_h?)
            config.groq_api_key = groq["api_key"]?.try(&.as_s?) || ""
            config.groq_endpoint = groq["endpoint"]?.try(&.as_s?) || config.groq_endpoint
            config.groq_model = groq["model"]?.try(&.as_s?) || config.groq_model
          end
          if openrouter = provider["openrouter"]?.try(&.as_h?)
            config.openrouter_api_key = openrouter["api_key"]?.try(&.as_s?) || ""
            config.openrouter_endpoint = openrouter["endpoint"]?.try(&.as_s?) || config.openrouter_endpoint
            config.openrouter_model = openrouter["model"]?.try(&.as_s?) || config.openrouter_model
          end
          if xai = provider["xai"]?.try(&.as_h?)
            config.xai_api_key = xai["api_key"]?.try(&.as_s?) || ""
            config.xai_endpoint = xai["endpoint"]?.try(&.as_s?) || config.xai_endpoint
            config.xai_model = xai["model"]?.try(&.as_s?) || config.xai_model
          end
          if cerebras = provider["cerebras"]?.try(&.as_h?)
            config.cerebras_api_key = cerebras["api_key"]?.try(&.as_s?) || ""
            config.cerebras_endpoint = cerebras["endpoint"]?.try(&.as_s?) || config.cerebras_endpoint
            config.cerebras_model = cerebras["model"]?.try(&.as_s?) || config.cerebras_model
          end
          if fireworks = provider["fireworks"]?.try(&.as_h?)
            config.fireworks_api_key = fireworks["api_key"]?.try(&.as_s?) || ""
            config.fireworks_endpoint = fireworks["endpoint"]?.try(&.as_s?) || config.fireworks_endpoint
            config.fireworks_model = fireworks["model"]?.try(&.as_s?) || config.fireworks_model
          end
          if together = provider["together"]?.try(&.as_h?)
            config.together_api_key = together["api_key"]?.try(&.as_s?) || ""
            config.together_endpoint = together["endpoint"]?.try(&.as_s?) || config.together_endpoint
            config.together_model = together["model"]?.try(&.as_s?) || config.together_model
          end
        end

        if github = root["github"]?.try(&.as_h?)
          config.github_token = github["token"]?.try(&.as_s?) || ""
        end

        if gitlab = root["gitlab"]?.try(&.as_h?)
          config.gitlab_token = gitlab["token"]?.try(&.as_s?) || ""
          config.gitlab_endpoint = gitlab["endpoint"]?.try(&.as_s?) || ""
        end

        if services = root["services"]?.try(&.as_h?)
          if ms = services["moonshot_search"]?.try(&.as_h?)
            custom_headers = {} of String => String
            if ch = ms["custom_headers"]?.try(&.as_h?)
              ch.each do |k, v|
                custom_headers[k] = v.to_s
              end
            end
            config.services = ServicesConfig.new(
              moonshot_search: MoonshotServiceConfig.new(
                base_url: ms["base_url"]?.try(&.as_s?),
                api_key: ms["api_key"]?.try(&.as_s?),
                custom_headers: custom_headers,
              ),
            )
          end
        end

        if agent = root["agent"]?.try(&.as_h?)
          config.max_steps = agent["max_steps"]?.try(&.as_i?) || 150
          config.max_context_tokens = agent["max_context_tokens"]?.try(&.as_i?) || 262144
          config.temperature = agent["temperature"]?.try(&.as_f?)
        end

        if shell_cfg = root["shell"]?.try(&.as_h?)
          config.bash_available = shell_cfg["bash_available"]?.try(&.as_s?)
        end

        if ui = root["ui"]?.try(&.as_h?)
          config.language = ui["language"]?.try(&.as_s?)
          config.debug_zones = ui["debug_zones"]?.try(&.as_bool?) || false
          # Explicit `false` must survive; a missing key keeps the default
          # (enabled). See the transcription `enabled` note above.
          unless (v = ui["show_tips"]?.try(&.as_bool?)).nil?
            config.show_tips = v
          end
        end

        if sync = root["sync"]?.try(&.as_h?)
          config.sync.enabled = sync["enabled"]?.try(&.as_bool?) || false
          config.sync.relay_url = sync["relay_url"]?.try(&.as_s?) || config.sync.relay_url
        end

        if tr = root["transcription"]?.try(&.as_h?)
          config.transcription.socket = tr["socket"]?.try(&.as_s?) || config.transcription.socket
          config.transcription.engine = tr["engine"]?.try(&.as_s?) || config.transcription.engine
          config.transcription.language = tr["language"]?.try(&.as_s?) || config.transcription.language
          config.transcription.max_duration_sec = tr["max_duration_sec"]?.try(&.as_i?) || config.transcription.max_duration_sec
          # Explicit `false` must survive; a missing key keeps the default
          # (enabled). An `if v = ...` guard would drop the explicit false —
          # in Crystal `false` is falsey — so test for nil instead.
          unless (v = tr["enabled"]?.try(&.as_bool?)).nil?
            config.transcription.enabled = v
          end
        end

        if notif = root["notifications"]?.try(&.as_h?)
          config.notifications.enabled = notif["enabled"]?.try(&.as_bool?) || config.notifications.enabled?
          config.notifications.condition = notif["condition"]?.try(&.as_s?) || config.notifications.condition
          if sound = notif["sound"]?.try(&.as_h?)
            config.notifications.sound_enabled = sound["enabled"]?.try(&.as_bool?) || config.notifications.sound_enabled?
            config.notifications.sound_volume = sound["volume"]?.try(&.as_i?) || config.notifications.sound_volume
            config.notifications.sound_done = sound["done"]?.try(&.as_s?) || ""
            config.notifications.sound_input_required = sound["input_required"]?.try(&.as_s?) || ""
            config.notifications.sound_working = sound["working"]?.try(&.as_s?) || ""
          end
          if term = notif["terminal"]?.try(&.as_h?)
            config.notifications.terminal_enabled = term["enabled"]?.try(&.as_bool?) || config.notifications.terminal_enabled?
          end
          if webhook = notif["webhook"]?.try(&.as_h?)
            config.notifications.webhook_enabled = webhook["enabled"]?.try(&.as_bool?) || config.notifications.webhook_enabled?
            config.notifications.webhook_url = webhook["url"]?.try(&.as_s?) || ""
            config.notifications.webhook_method = webhook["method"]?.try(&.as_s?) || "POST"
            config.notifications.webhook_timeout_ms = webhook["timeout_ms"]?.try(&.as_i?) || 5000
            config.notifications.webhook_secret = webhook["secret"]?.try(&.as_s?) || ""
          end
        end

        config.hooks = parse_hooks_array(root["hooks"]?.try(&.as_a?))

        # MCP servers: load from mcp.json sources (user-global, project-root,
        # project-local) and merge by name.
        home = HomePort.home
        config.mcp_servers = Mcp::ConfigLoader.load(home, cwd: Dir.current)

        config
      end

      def save(path : String? = nil) : Nil
        config_path = path || Config.default_config_path
        dir = File.dirname(config_path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)

        root = JSON.build(indent: 2) do |json|
          json.object do
            json.field("model") do
              json.object do
                if m = @model
                  json.field("default", m)
                end
                json.field("thinking_effort", @thinking_effort)
              end
            end

            json.field("permission") do
              json.object do
                json.field("mode", @permission_mode)
                json.field("sudo_mode", @sudo_mode)
              end
            end

            json.field("shell") do
              json.object do
                json.field("bash_available", @bash_available)
              end
            end

            json.field("provider") do
              json.object do
                if pn = @provider_name
                  json.field("default", pn)
                end
                if @api_key || @endpoint
                  json.field("moonshot") do
                    json.object do
                      if k = @api_key
                        json.field("api_key", k)
                      end
                      if ep = @endpoint
                        json.field("endpoint", ep)
                      end
                    end
                  end
                end
                json.field("zai") do
                  json.object do
                    json.field("api_key", @zai_api_key)
                    json.field("endpoint", @zai_endpoint)
                    json.field("model", @zai_model)
                  end
                end
                json.field("zai-coding-plan") do
                  json.object do
                    json.field("endpoint", @zai_coding_plan_endpoint)
                    json.field("model", @zai_coding_plan_model)
                  end
                end
                if @ollama_endpoint || @ollama_model
                  json.field("ollama") do
                    json.object do
                      if ep = @ollama_endpoint
                        json.field("endpoint", ep)
                      end
                      if m = @ollama_model
                        json.field("model", m)
                      end
                    end
                  end
                end
                if @lmstudio_endpoint || @lmstudio_model
                  json.field("lmstudio") do
                    json.object do
                      if ep = @lmstudio_endpoint
                        json.field("endpoint", ep)
                      end
                      if m = @lmstudio_model
                        json.field("model", m)
                      end
                    end
                  end
                end
                json.field("deepseek") do
                  json.object do
                    json.field("api_key", @deepseek_api_key)
                    json.field("endpoint", @deepseek_endpoint)
                    json.field("model", @deepseek_model)
                  end
                end
                json.field("groq") do
                  json.object do
                    json.field("api_key", @groq_api_key)
                    json.field("endpoint", @groq_endpoint)
                    json.field("model", @groq_model)
                  end
                end
                json.field("openrouter") do
                  json.object do
                    json.field("api_key", @openrouter_api_key)
                    json.field("endpoint", @openrouter_endpoint)
                    json.field("model", @openrouter_model)
                  end
                end
                json.field("xai") do
                  json.object do
                    json.field("api_key", @xai_api_key)
                    json.field("endpoint", @xai_endpoint)
                    json.field("model", @xai_model)
                  end
                end
                json.field("cerebras") do
                  json.object do
                    json.field("api_key", @cerebras_api_key)
                    json.field("endpoint", @cerebras_endpoint)
                    json.field("model", @cerebras_model)
                  end
                end
                json.field("fireworks") do
                  json.object do
                    json.field("api_key", @fireworks_api_key)
                    json.field("endpoint", @fireworks_endpoint)
                    json.field("model", @fireworks_model)
                  end
                end
                json.field("together") do
                  json.object do
                    json.field("api_key", @together_api_key)
                    json.field("endpoint", @together_endpoint)
                    json.field("model", @together_model)
                  end
                end
              end
            end

            json.field("services") do
              json.object do
                if ms = @services.moonshot_search
                  json.field("moonshot_search") do
                    json.object do
                      if bu = ms.base_url
                        json.field("base_url", bu)
                      end
                      if ak = ms.api_key
                        json.field("api_key", ak)
                      end
                      unless ms.custom_headers.empty?
                        json.field("custom_headers") do
                          json.object do
                            ms.custom_headers.each do |k, v|
                              json.field(k, v)
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end

            json.field("github") do
              json.object do
                json.field("token", @github_token)
              end
            end unless @github_token.empty?

            json.field("gitlab") do
              json.object do
                json.field("token", @gitlab_token)
                json.field("endpoint", @gitlab_endpoint) unless @gitlab_endpoint.empty?
              end
            end unless @gitlab_token.empty? && @gitlab_endpoint.empty?

            json.field("agent") do
              json.object do
                json.field("max_steps", @max_steps)
                json.field("max_context_tokens", @max_context_tokens)
                if temp = @temperature
                  json.field("temperature", temp)
                end
              end
            end

            json.field("ui") do
              json.object do
                if lang = @language
                  json.field("language", lang)
                end
                json.field("debug_zones", @debug_zones)
                json.field("show_tips", @show_tips)
              end
            end

            json.field("sync") do
              json.object do
                json.field("enabled", @sync.enabled?)
                json.field("relay_url", @sync.relay_url)
              end
            end

            json.field("transcription") do
              json.object do
                json.field("enabled", @transcription.enabled?)
                json.field("socket", @transcription.socket)
                json.field("engine", @transcription.engine)
                json.field("language", @transcription.language)
                json.field("max_duration_sec", @transcription.max_duration_sec)
              end
            end

            json.field("notifications") do
              json.object do
                json.field("enabled", @notifications.enabled?)
                json.field("condition", @notifications.condition)
                json.field("sound") do
                  json.object do
                    json.field("enabled", @notifications.sound_enabled?)
                    json.field("volume", @notifications.sound_volume)
                    json.field("done", @notifications.sound_done)
                    json.field("input_required", @notifications.sound_input_required)
                    json.field("working", @notifications.sound_working)
                  end
                end
                json.field("terminal") do
                  json.object do
                    json.field("enabled", @notifications.terminal_enabled?)
                  end
                end
                json.field("webhook") do
                  json.object do
                    json.field("enabled", @notifications.webhook_enabled?)
                    json.field("url", @notifications.webhook_url)
                    json.field("method", @notifications.webhook_method)
                    json.field("timeout_ms", @notifications.webhook_timeout_ms)
                    json.field("secret", @notifications.webhook_secret)
                  end
                end
              end
            end
          end
        end

        File.write(config_path, root + "\n")
      end

      def ensure_h2code_home : Nil
        home = HomePort.home
        h2code_home = ENV["H2CODE_HOME"]? || File.join(home, ".h2code")
        Dir.mkdir_p(h2code_home) unless Dir.exists?(h2code_home)
        sessions_dir = File.join(h2code_home, "sessions")
        Dir.mkdir_p(sessions_dir) unless Dir.exists?(sessions_dir)
        exceptions_dir = File.join(h2code_home, "exceptions")
        Dir.mkdir_p(exceptions_dir) unless Dir.exists?(exceptions_dir)
      end

      # Returns true when the current provider_name + credentials are sufficient
      # to attempt a connection. Used to decide whether the setup wizard runs.
      # Does NOT validate the key — only that one is present.
      def provider_configured? : Bool
        provider_configured?(provider_name)
      end

      # Same check for an arbitrary provider name — used to decide whether a
      # runtime /provider switch needs to launch the setup wizard.
      def provider_configured?(name : String?) : Bool
        case name
        when "moonshot"        then !api_key.to_s.empty? || oauth_credentials_present?
        when "zai"             then !zai_api_key.empty?
        when "zai-coding-plan" then !zai_api_key.empty?
        when "ollama"          then true
        when "lmstudio"        then true
        when "deepseek"        then !deepseek_api_key.empty?
        when "groq"            then !groq_api_key.empty?
        when "openrouter"      then !openrouter_api_key.empty?
        when "xai"             then !xai_api_key.empty?
        when "cerebras"        then !cerebras_api_key.empty?
        when "fireworks"       then !fireworks_api_key.empty?
        when "together"        then !together_api_key.empty?
        when "mock"            then true
        when nil               then false
        else                        !api_key.to_s.empty?
        end
      end

      # OAuth token presence — loaded from ~/.kimi-code/credentials by the
      # entry point and stored on the provider, not the config. The config
      # only knows whether an api_key is set, so this is a best-effort check.
      private def oauth_credentials_present? : Bool
        home = HomePort.home
        path = File.join(home, ".kimi-code", "credentials", "kimi-code.json")
        File.exists?(path)
      end

      # Provider-specific MCP servers generated from the active provider's
      # credentials. For Z.AI Coding Plan the official Web Search capability is
      # exposed as a remote MCP server (`webSearchPrime`); the legacy direct
      # `/web_search` REST endpoint is unreliable on Coding Plan (returns 1113
      # when no pay-as-you-go balance is present).
      def auto_mcp_servers : Array(Mcp::McpServerConfig)
        servers = [] of Mcp::McpServerConfig

        if provider_name == "zai-coding-plan" && !zai_api_key.empty?
          servers << Mcp::McpServerConfig.new(
            name: "zai-web-search",
            type: "http",
            url: "https://api.z.ai/api/mcp/web_search_prime/mcp",
            headers: {"Authorization" => "Bearer #{zai_api_key}"},
            providers: ["zai-coding-plan"],
            tool_aliases: {"web_search_prime" => Tools::Names::WEB_SEARCH}
          )
        end

        servers
      end

      private def self.parse_hooks_array(arr : Array(JSON::Any)?) : Array(Hooks::HookDef)
        return [] of Hooks::HookDef unless arr
        arr.map do |entry|
          h = entry.as_h
          Hooks::HookDef.new(
            event: h["event"]?.try(&.as_s?) || "",
            command: h["command"]?.try(&.as_s?) || "",
            matcher: h["matcher"]?.try(&.as_s?) || "",
            timeout: h["timeout"]?.try(&.as_i?) || 30,
          )
        end
      end
    end
  end
end
