# ACP Implementation Plan — H2Code (Crystal)

**Goal:** Implement an ACP (Agent Client Protocol) server for H2Code so IDEs
(Zed, JetBrains, Neovim, any ACP client) can drive H2Code sessions over
JSON-RPC/stdio.

**Reference:** `ACP-Features-JS.md` — full feature/use-case/edge-case inventory
from the Kimi JS implementation.

**Protocol:** ACP spec v0.10.x, protocolVersion 1. JSON-RPC 2.0 over
newline-delimited UTF-8 on stdin/stdout.

---

## Architecture Overview

```
IDE (Zed / JetBrains / Neovim / ...)
  │
  │ stdin/stdout (newline-delimited JSON-RPC 2.0)
  │
  ▼
Acp::Server ──────────────────────────────────────────────┐
  │                                                        │
  ├─ Acp::JsonRpc (reader fiber + writer mutex)            │
  │    ├─ reads requests from STDIN                        │
  │    ├─ writes responses + notifications to STDOUT       │
  │    └─ sends reverse-RPC requests (permission, fs)      │
  │                                                        │
  ├─ Acp::SessionRouter                                    │
  │    └─ maps sessionId → Acp::Session                    │
  │                                                        │
  ├─ Acp::Session × N (one per session/new|load|resume)    │
  │    ├─ wraps Loop::Agent + Session::Store               │
  │    ├─ Acp::EventTranslator (Loop::Event → ACP notify)  │
  │    ├─ permission callback → reverse-RPC + Channel      │
  │    └─ prompt streaming via agent.run_goal_turn         │
  │                                                        │
  └─ Acp::Protocol (types, serialization)                  │
       ├─ InitializeRequest/Response                       │
       ├─ SessionNew/Load/Resume/Prompt/Cancel/List        │
       ├─ SessionUpdate notifications                      │
       ├─ RequestPermission reverse-RPC                    │
       └─ Config options                                   │
                                                           │
Entry: `h2code acp` subcommand ────────────────────────────┘
```

---

## File Layout

```
src/acp/
  server.cr           — Acp::Server: main orchestrator, JSON-RPC dispatch
  json_rpc.cr         — Acp::JsonRpc: reader fiber, writer mutex, request/response correlation
  session.cr          — Acp::Session: per-session wrapper around Loop::Agent
  event_translator.cr — Loop::Event → ACP session/update notification JSON
  protocol.cr         — ACP wire types (request/response/notification structs)
  approval.cr         — permission reverse-RPC + channel bridge
  convert.cr          — ACP content blocks → prompt parts, tool display → ACP content
  modes.cr            — ACP mode ↔ H2Code permission mode mapping
  auth.cr             — terminal-auth method advertisement + auth gate
  config_options.cr   — model/thinking/mode config option snapshots
  slash.cr            — slash command detection and routing
  version.cr          — protocol version negotiation
```

---

## Component Design

### 1. `json_rpc.cr` — JSON-RPC 2.0 Frame

**Responsibilities:**
- Read newline-delimited JSON from STDIN in a dedicated fiber.
- Write JSON-RPC messages to STDOUT behind a Mutex (STDOUT is shared between
  responses, notifications, and reverse-RPC requests — all must be serialized).
- Correlate outbound requests (permission, fs) with inbound responses via a
  `Hash(Int32, Channel(JSON::Any))` keyed by request id.
- Log all I/O to STDERR (never STDOUT — that's the protocol channel).

**Design:**

```crystal
class Acp::JsonRpc
  @writer_lock = Mutex.new
  @pending = {} of Int32 => Channel(JSON::Any)
  @next_id = Atomic(Int32).new(1)
  @input_io : IO
  @output_io : IO

  def initialize(@input_io = STDIN, @output_io = STDOUT)
  end

  # Main read loop. Spawns a fiber that reads lines from STDIN,
  # parses JSON-RPC, and dispatches:
  # - Requests (has "id" + "method") → yield to handler block
  # - Responses (has "id", no "method") → deliver to pending channel
  # - Notifications (no "id") → yield to handler block
  def run(&handler : JsonRpcMessage -> Nil) : Nil
  end

  # Send a response to a request
  def send_response(id : Int32, result : JSON::Any) : Nil
  end

  # Send an error response
  def send_error(id : Int32, code : Int32, message : String, data : JSON::Any? = nil) : Nil
  end

  # Send a notification (no id, no response expected)
  def send_notification(method : String, params : JSON::Any) : Nil
  end

  # Send a request and block until the response arrives.
  # Used for reverse-RPC (session/request_permission, fs/read_text_file).
  def request(method : String, params : JSON::Any) : JSON::Any
  end
end
```

**Edge cases handled:**
- Malformed JSON line → log to stderr, skip (don't crash the server).
- Response for unknown id → log warning, drop.
- STDOUT corruption from stray prints → all output goes through `send_*` methods
  only. `STDERR` is used for all logging.
- STDIN EOF → signal shutdown.

### 2. `server.cr` — Main Orchestrator

**Responsibilities:**
- Owns `JsonRpc`, session router, shared config/provider.
- Dispatches each ACP method to the appropriate handler.
- Manages graceful shutdown (SIGINT/SIGTERM/EOF).

**Method dispatch table:**

| ACP Method | Handler | Notes |
|---|---|---|
| `initialize` | `handle_initialize` | Version negotiation, capability advertisement |
| `authenticate` | `handle_authenticate` | Auth gate: check provider token |
| `session/new` | `handle_session_new` | Create store + agent + Acp::Session |
| `session/load` | `handle_session_load` | Resume + replay history |
| `session/resume` | `handle_session_resume` | Resume without replay |
| `session/prompt` | `handle_session_prompt` | Forward to Acp::Session |
| `session/cancel` | `handle_session_cancel` | Forward to Acp::Session |
| `session/list` | `handle_session_list` | Query Session::Index |
| `session/set_mode` | `handle_set_mode` | Map ACP mode → permission mode |
| `session/set_config_option` | `handle_set_config_option` | Unified dispatcher |
| `unstable_setSessionModel` (session/set_model) | `handle_set_model` | Model swap |
| (any other) | — | `methodNotFound (-32601)` |

**Shared setup:** Reuses the config/provider/tools/memory wiring from
`CLI.run` (lines 245-403 of `h2code.cr`). This should be factored into a
`CLI::SessionContext` builder that both headless and ACP modes call.

```crystal
class Acp::Server
  def initialize(
    @config : Config::Config,
    @provider : LLM::Provider,
    @home : String,
    @oauth : LLM::OAuthCredentials?
  )
    @rpc = Acp::JsonRpc.new
    @sessions = {} of String => Acp::Session
    @sessions_lock = Mutex.new
    @shutdown = Channel(Nil).new
  end

  def run : Nil
    # Redirect any stray STDOUT to STDERR
    # (Crystal doesn't have console redirection, but we control all output)

    Signal::INT.trap { @shutdown.close }
    Signal::TERM.trap { @shutdown.close }

    @rpc.run do |msg|
      dispatch(msg)
    end

    # Graceful shutdown
    @sessions.each_value(&.close)
  rescue ex
    STDERR.puts "ACP server error: #{ex}"
    exit(1)
  end

  private def dispatch(msg : JsonRpcMessage) : Nil
    case msg.method
    when "initialize"         then handle_initialize(msg)
    when "authenticate"       then handle_authenticate(msg)
    when "session/new"        then handle_session_new(msg)
    # ... etc
    else
      @rpc.send_error(msg.id, -32601, "Method not found: #{msg.method}") unless msg.notification?
    end
  end
end
```

### 3. `session.cr` — Per-Session Wrapper

**Responsibilities:**
- Owns a `Loop::Agent`, `Session::Store`, and permission callback.
- Translates `session/prompt` into `agent.run_goal_turn`.
- Streams events back as `session/update` notifications.
- Handles cancellation, mode/model changes.

```crystal
class Acp::Session
  getter id : String
  getter agent : Loop::Agent
  getter store : Session::Store
  getter rpc : Acp::JsonRpc

  @current_turn_id : Int32 = 0
  @model_id : String = ""
  @mode_id : String = "default"  # default|plan|auto|yolo
  @thinking_enabled : Bool = false
  @prompt_channel : Channel(PromptResult)?
  @abort_token : Acp::AbortToken?

  def prompt(blocks : Array(JSON::Any)) : PromptResult
    # 1. Convert ACP content blocks → prompt string/parts
    # 2. Detect slash commands
    # 3. Spawn agent.run_goal_turn in a fiber
    # 4. Stream events via EventTranslator
    # 5. Return PromptResult when turn ends
  end

  def cancel : Nil
    @abort_token.try(&.cancel)
    agent.cancel
  end

  def set_mode(mode_id : String) : Nil
    # Map ACP mode → H2Code permission mode + plan mode
  end

  def set_model(model_id : String) : Nil
    # Swap provider via CLI.build_named_provider
  end

  def replay_history : Nil
    # Walk store.read_events → emit session/update for each
  end
end
```

**Prompt lifecycle:**

```
session/prompt(blocks)
  │
  ├─ acp_blocks_to_prompt(blocks) → String
  ├─ detect_slash(prompt) → skill | builtin | passthrough | unknown
  │
  ├─ if passthrough:
  │    store.append("turn.prompt", {prompt: text})
  │    spawn fiber:
  │      agent.run_goal_turn(text, system_prompt) do |event|
  │        translated = EventTranslator.map(event, self)
  │        translated.each { |n| rpc.send_notification("session/update", n) }
  │        # Also persist to wire log
  │        persist_event(event, store)
  │      end
  │    # Fiber resolves → return PromptResult
  │
  └─ if skill/builtin:
       handle locally (emit agent_message_chunk, return end_turn)
```

### 4. `event_translator.cr` — Loop::Event → ACP Notifications

This is the heart of the streaming layer. Each `Loop::Event` maps to zero or
more ACP `session/update` notification params.

| Loop::Event | ACP session/update kind | Notes |
|---|---|---|
| `TextDelta` | `agent_message_chunk` | Text delta in content |
| `ThinkingDelta` | `agent_thought_chunk` | Reasoning text delta |
| `AssistantText` | (not sent — checkpoint only) | Persisted to wire, not streamed |
| `ToolCallStart` | `tool_call` (CREATE) | Title, kind, status `in_progress`, rawInput |
| `ToolCallDelta` | `tool_call_update` | Cumulative args (REPLACE) |
| `ToolResult` | `tool_call_update` | Status `completed`/`failed`, content, rawOutput |
| `StepBegin` | (internal — no ACP notification) | Step counter |
| `StepEnd` | (internal — usage tracking) | Token usage |
| `TurnEnd` | (resolves the prompt promise) | stopReason mapping |
| `Info` | `agent_message_chunk` (optional) | Info messages |
| `Error` | (logged to stderr; doesn't emit) | Error handling |
| `CompactionStarted/Completed` | `agent_message_chunk` (info) | Compaction status |
| `Subagent*` | (filtered — main agent only) | Subagent events not streamed |
| `Exception` | (logged; turn fails) | Error handling |

**Tool call wire IDs:** `"#{turn_id}:#{tool_call_id}"` — disambiguates across turns.

**Tool kind inference:**
```crystal
def self.infer_tool_kind(name : String) : String
  case name
  when "Read", "Glob", "Grep"             then "read"
  when "Write", "Edit"                     then "edit"
  when "Bash"                              then "execute"
  when "FetchURL", "WebSearch"             then "fetch"
  else                                          "other"
  end
end
```

**Stop reason mapping:**

| Turn result | ACP stopReason |
|---|---|
| Completed normally | `end_turn` |
| Cancelled | `cancelled` |
| Failed (provider filter) | `refusal` |
| Failed (other) | `end_turn` (error logged to stderr) |

### 5. `approval.cr` — Permission Reverse-RPC

**Design:** Sets `permission.approval_callback` to a proc that:
1. Builds permission options (3 canonical: approve_once, approve_always, reject).
2. Sends `session/request_permission` reverse-RPC to the IDE.
3. Blocks on a `Channel(ApprovalChoice)`.
4. The reader fiber delivers the response → channel.send.
5. Returns the `ApprovalChoice`.

```crystal
class Acp::ApprovalBridge
  def initialize(@rpc : Acp::JsonRpc, @session_id : String)
  end

  def callback : (String, String, String?) -> Permission::ApprovalChoice
    ->(tool_name : String, args : String, danger : String?) do
      options = build_options
      tool_call_update = build_tool_call_update(tool_name, args, danger)

      response = @rpc.request("session/request_permission", {
        "sessionId"  => JSON::Any.new(@session_id),
        "options"    => options,
        "toolCall"   => tool_call_update,
      })

      map_response(response)
    end
  end

  private def map_response(response : JSON::Any) : Permission::ApprovalChoice
    behavior = response["behavior"]?.try(&.to_s) || "deny"
    case behavior
    when "allow"        then Permission::ApprovalChoice::ApproveOnce
    when "allow-always" then Permission::ApprovalChoice::ApproveSession
    else                     Permission::ApprovalChoice::Deny
    end
  end
end
```

**Edge cases:**
- RPC fails / client disconnects → return `Deny` (safer than approving).
- Timeout → return `Deny` after configurable timeout (default 120s).
- Plan review options → expanded option set (approve/revise/reject-and-exit).

### 6. `convert.cr` — Content Block Conversion

**ACP content blocks → prompt:**

| ACP block type | H2Code handling |
|---|---|
| `text` | Extract text; check for leading `/` (slash command) |
| `image` | Convert data URL → base64; pass to provider if it supports images |
| `resource` (text) | Wrap as `<resource uri="...">text</resource>` |
| `resource_link` (`file:` URI) | Project to filesystem text reference |
| `resource_link` (other) | Wrap as `<resource_link uri="..."/>` |
| `audio` | Drop (not supported) |
| Unknown | Drop with warning |

**ToolDisplay → ACP content:**

| Display kind | ACP content |
|---|---|
| `diff` | `{type: "diff", path, oldText, newText}` |
| `file_io` (before + after) | Diff shape |
| `file_io` (operation only) | Text description |
| `plan_review` | `{type: "content", content: {type: "text", text}}` |
| nil | No extra content |

### 7. `modes.cr` — Mode Mapping

```crystal
module Acp::Modes
  ACP_MODES = ["default", "plan", "auto", "yolo"]

  def self.to_toggles(mode_id : String) : {Bool, Permission::Mode}
    case mode_id
    when "default" then {false, Permission::Mode::Manual}
    when "plan"    then {true,  Permission::Mode::Manual}
    when "auto"    then {false, Permission::Mode::Auto}
    when "yolo"    then {false, Permission::Mode::Yolo}
    else                {false, Permission::Mode::Manual}
    end
  end
end
```

### 8. `auth.cr` — Auth Gate

```crystal
module Acp::Auth
  # Auth method advertised in initialize response
  def self.terminal_auth_method(binary_path : String) : JSON::Any
    JSON.parse(%({
      "id": "login",
      "type": "terminal",
      "name": "Login with H2Code account",
      "args": ["--login"]
    }))
  end

  # Check if any provider has a usable token
  def self.authed?(config : Config::Config, oauth : LLM::OAuthCredentials?) : Bool
    config.provider_configured? || (oauth.try(&.valid?) || false)
  end
end
```

### 9. `config_options.cr` — Config Snapshots

Builds `SessionConfigOption[]` for:
- `model` — one row per available model from `LLM::Provider.providers`
- `thinking` — shown only when the current model supports it (off/on select)
- `mode` — 4 rows (default/plan/auto/yolo)

Pushed as `config_option_update` notification after each change.

### 10. `slash.cr` — Slash Command Routing

Detects leading `/` in the first text block and routes:
- Built-in: `/compact`, `/status`, `/usage`, `/mcp`, `/tasks`, `/help`
- Unknown: local error message (don't send to model)
- Passthrough: everything else → `agent.run_goal_turn`

### 11. `version.cr` — Protocol Negotiation

```crystal
module Acp::Version
  PROTOCOL_VERSION = 1
  SPEC_TAG         = "v0.10.x"

  def self.negotiate(client_version : Int32) : Int32
    return PROTOCOL_VERSION if client_version < PROTOCOL_VERSION
    PROTOCOL_VERSION  # only version 1 supported
  end
end
```

---

## Entry Point: `h2code acp` Subcommand

**In `src/h2code.cr`, at the top of `CLI.run`:**

```crystal
def self.run(argv : Array(String)) : Nil
  # Subcommand dispatch: `h2code acp` starts the ACP server
  if argv.first? == "acp"
    return run_acp(argv[1..])
  end

  # ... existing flag parsing ...
end
```

**`run_acp` method:**

```crystal
private def self.run_acp(rest_argv : Array(String)) : Nil
  config = Config::Config.load
  H2code::I18n.init(H2code::I18n.resolve_locale(config.language))
  config.ensure_h2code_home

  # Handle --login flag (terminal-auth pivot)
  if rest_argv.includes?("--login")
    return run_login_flow(config)
  end

  # Provider gate (same as headless)
  unless config.provider_name && config.provider_configured?
    STDERR.puts H2code.t("errors.no_provider")
    exit(2)
  end

  home = ENV["HOME"]? || "/tmp"
  oauth_path = File.join(home, ".kimi-code", "credentials", "kimi-code.json")
  oauth = LLM::OAuthCredentials.load(oauth_path)

  provider = build_provider(config, oauth)

  server = Acp::Server.new(config, provider, home, oauth)
  server.run
end
```

---

## Shared Setup Refactor

Lines 245-403 of `h2code.cr` (config load → provider build → memory/tools/permission
→ MCP connect → session store → agent) are shared between headless and
interactive modes. The ACP server needs the same setup.

**Plan:** Extract a `CLI::SessionContext` struct:

```crystal
struct CLI::SessionContext
  property config : Config::Config
  property provider : LLM::Provider
  property memory : Context::Memory
  property tools : Tools::Registry
  property permission : Permission::Manager
  property mcp_manager : Mcp::Manager
  property store : Session::Store
  property agent : Loop::Agent
  property system_prompt : String
  property home : String
end
```

Both `run_headless`, `run_interactive`, and `run_acp` call
`CLI.build_session_context(config, provider, ...)` to get a fully-wired context.

**This refactor is optional but recommended** — the ACP server can also inline
the setup like `run_headless` does.

---

## Implementation Phases

### Phase 1: JSON-RPC Frame + Subcommand Entry
**Files:** `src/acp/json_rpc.cr`, `src/acp/server.cr`, `src/acp/protocol.cr`,
`src/h2code.cr` (subcommand dispatch)

- [ ] Implement `Acp::JsonRpc` with reader fiber, writer mutex, request/response correlation
- [ ] Implement `Acp::JsonRpcMessage` struct (id, method, params, result, error)
- [ ] Add `acp` subcommand dispatch in `CLI.run`
- [ ] Implement `handle_initialize` (version negotiation, capability advertisement)
- [ ] Implement graceful shutdown (SIGINT/SIGTERM/EOF → close sessions)
- [ ] Log to stderr only

**Test:** `echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | h2code acp`
should return a valid `InitializeResponse`.

### Phase 2: Session Lifecycle
**Files:** `src/acp/session.cr`, `src/acp/server.cr`

- [ ] Implement `handle_session_new` (create store + agent + Acp::Session)
- [ ] Implement `handle_session_list` (query `Session::Index`)
- [ ] Implement `handle_session_load` (resume + replay history)
- [ ] Implement `handle_session_resume` (resume without replay)
- [ ] Implement auth gate in session/new/load/resume

**Test:** Create session, list sessions, load session, verify configOptions returned.

### Phase 3: Prompt Streaming
**Files:** `src/acp/event_translator.cr`, `src/acp/convert.cr`, `src/acp/session.cr`

- [ ] Implement `acp_blocks_to_prompt` (content blocks → text)
- [ ] Implement `EventTranslator.map` for all Loop::Event types
- [ ] Implement `handle_session_prompt` with streaming
- [ ] Implement wire log persistence (turn.prompt, assistant.text, tool.call, tool.result)
- [ ] Implement stop reason mapping
- [ ] Filter subagent events (main agent only)

**Test:** Send a prompt, receive streaming `session/update` notifications with
`agent_message_chunk` and `tool_call`.

### Phase 4: Permission Reverse-RPC
**Files:** `src/acp/approval.cr`, `src/acp/session.cr`

- [ ] Implement `Acp::ApprovalBridge` with channel-based blocking
- [ ] Wire `permission.approval_callback` in session setup
- [ ] Map ACP permission response → `Permission::ApprovalChoice`
- [ ] Handle RPC failure → `Deny`
- [ ] Implement plan review option set

**Test:** Send a prompt that triggers a tool call, verify
`session/request_permission` is sent, respond with allow, verify tool executes.

### Phase 5: Cancel + Modes
**Files:** `src/acp/session.cr`, `src/acp/modes.cr`, `src/acp/server.cr`

- [ ] Implement `handle_session_cancel`
- [ ] Implement `handle_set_mode` (ACP mode → permission mode + plan mode)
- [ ] Implement `handle_set_config_option` (unified dispatcher)
- [ ] Implement `handle_set_model` (model swap)
- [ ] Push `config_option_update` after changes

**Test:** Start a prompt, send cancel, verify prompt resolves with `cancelled`.
Switch mode to `yolo`, verify tools auto-approved.

### Phase 6: Slash Commands + Config Options + Auth
**Files:** `src/acp/slash.cr`, `src/acp/config_options.cr`, `src/acp/auth.cr`

- [ ] Implement slash command detection (passthrough/skill/builtin/unknown)
- [ ] Implement builtin handlers (compact/status/usage/mcp/tasks/help)
- [ ] Build config option snapshots (model/thinking/mode)
- [ ] Implement `handle_authenticate`
- [ ] Push `available_commands_update` after session creation

**Test:** Send `/status` prompt, verify local response. Send `authenticate`,
verify auth gate.

### Phase 7: History Replay
**Files:** `src/acp/session.cr`

- [ ] Implement `replay_history` — walk `store.read_events`
- [ ] Emit `user_message_chunk` / `agent_message_chunk` / `tool_call` for each historical event
- [ ] Await each push (unlike live streaming)
- [ ] Skip tool results with no matching call

**Test:** Create session, exchange messages, load session, verify history replayed.

### Phase 8: MCP Forwarding + Polish
**Files:** `src/acp/server.cr`, `src/acp/convert.cr`

- [ ] Forward `mcpServers` from `session/new` params to MCP manager
- [ ] Map ACP MCP transport types (stdio/http/sse) to H2Code config
- [ ] Drop unsupported transport types with warning
- [ ] Stdout hygiene audit (ensure no stray prints)
- [ ] Error response standardization (JSON-RPC error codes)

**Test:** Launch with IDE MCP servers configured, verify they connect.

---

## Error Response Codes

| Code | Meaning | When |
|---|---|---|
| -32700 | Parse error | Malformed JSON |
| -32600 | Invalid request | Not valid JSON-RPC 2.0 |
| -32601 | Method not found | Unknown/unimplemented method |
| -32602 | Invalid params | Bad params, unknown sessionId/modeId/configId |
| -32603 | Internal error | Unexpected failure |
| -32000 | Auth required | No provider token |

---

## Stdout Hygiene

**Critical rule:** STDOUT is the JSON-RPC channel. Nothing else may write to it.

- All logging → STDERR.
- Crystal's `puts`/`print` → must not be called in ACP mode.
- Provider SSE parsing logs → STDERR.
- Exception backtraces → STDERR.
- The `run_acp` entry method should set a global flag that suppresses any
  non-RPC stdout output (belt-and-suspenders).

---

## What's Explicitly Out of Scope (MVP)

These Kimi features are deferred for the initial Crystal implementation:

1. **File I/O reverse-RPC** (`fs/read_text_file`, `fs/write_text_file`) — H2Code
   always reads/writes locally; bridging through the IDE is a later enhancement.
2. **Terminal reverse-RPC** (`terminal/*`) — not implemented in Kimi JS either.
3. **Image compression** — H2Code's providers handle image sizing; input-stage
   compression can be added later.
4. **Audio input** — not supported (`promptCapabilities.audio: false`).
5. **`session/close` / `logout`** — return `methodNotFound`.
6. **Unstable methods** (18 of 19) — return `methodNotFound`.
7. **Telemetry** — H2Code has no telemetry system.
8. **ACP `resource`/`resource_link` with blob content** — dropped.

---

## Testing Strategy

### Unit Tests (`spec/acp/`)
- `json_rpc_spec.cr` — read/write/correlate, malformed JSON, EOF
- `event_translator_spec.cr` — each Loop::Event → correct notification JSON
- `modes_spec.cr` — all 4 modes, invalid mode
- `convert_spec.cr` — content block conversion
- `approval_spec.cr` — option building, response mapping
- `version_spec.cr` — negotiation
- `config_options_spec.cr` — snapshot building

### Integration Tests
- Mock ACP client that sends JSON-RPC over a pipe:
  - initialize → session/new → session/prompt → verify streaming
  - session/cancel mid-prompt
  - permission round-trip
  - session/load → history replay
  - mode/model switching

### Manual Tests
- Zed configuration (5-line settings.json)
- JetBrains AI Chat plugin
- Direct stdio pipe (`echo` + `jq`)

---

## IDE Configuration

### Zed (`~/.config/zed/settings.json`)
```json
{
  "agent_servers": {
    "H2Code": {
      "type": "custom",
      "command": "h2code",
      "args": ["acp"],
      "env": {}
    }
  }
}
```

### JetBrains (AI Chat → Configure ACP agents)
```json
{
  "agent_servers": {
    "H2Code": {
      "command": "/absolute/path/to/h2code",
      "args": ["acp"],
      "env": {}
    }
  }
}
```
