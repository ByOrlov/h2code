# ACP Features — Kimi JS Implementation

**Source:** `@moonshot-ai/acp-adapter` v0.3.4 (`packages/acp-adapter/`)
**ACP SDK:** `@agentclientprotocol/sdk@^0.23.0` → spec v0.10.x, protocolVersion: 1
**Entry:** `kimi acp` subcommand (`apps/kimi-code/src/cli/sub/acp.ts`)

This document catalogs every user-facing feature, use case, and edge case in the
Kimi JS ACP adapter — to serve as a requirements baseline for the Crystal port.

---

## 1. Protocol Lifecycle

### 1.1 Initialize

**Feature:** Version negotiation + capability advertisement.

| Field | Value | Notes |
|---|---|---|
| `protocolVersion` | `1` | Negotiated via `negotiateVersion()` |
| `agentCapabilities.loadSession` | `true` | Supports `session/load` with history replay |
| `agentCapabilities.promptCapabilities.image` | `true` | Accepts base64 image content blocks |
| `agentCapabilities.promptCapabilities.audio` | `false` | Audio prompts not supported |
| `agentCapabilities.promptCapabilities.embeddedContext` | `true` | `resource`/`resource_link` blocks |
| `agentCapabilities.mcpCapabilities.http` | `true` | Forwards HTTP MCP servers from IDE |
| `agentCapabilities.mcpCapabilities.sse` | `true` | Forwards SSE MCP servers |
| `agentCapabilities.sessionCapabilities.list` | `{}` | Supports `session/list` |
| `authMethods` | `[{id:'login', type:'terminal'}]` | Terminal-based login flow |

**Use case:** IDE launches `kimi acp` as a subprocess, sends `initialize`, renders
UI based on capabilities (e.g., shows image upload button because
`promptCapabilities.image === true`).

**Edge cases:**
- Client protocol version < 1 (MIN_PROTOCOL_VERSION) → server returns its current
  version without refusing; client decides whether to disconnect.
- Client protocol version > 1 → server picks highest supported version ≤ client
  version (currently always 1).
- No match in SUPPORTED_VERSIONS → falls back to CURRENT_VERSION.
- `agentInfo` omitted entirely when not configured (no empty object on wire).

### 1.2 Authentication

**Feature:** Terminal-based auth method advertisement.

**Flow:**
1. Server advertises `authMethods: [{id:'login', type:'terminal', args:['--login']}]`.
2. IDE spawns `<binary> acp --login` as a subprocess (terminal-auth).
3. User completes login in the spawned terminal.
4. Token lands on disk.
5. IDE re-invokes `authenticate({methodId:'login'})` → server re-checks token
   validity, returns empty success or `authRequired (-32000)`.

**Edge cases:**
- `authenticate` with unknown `methodId` → `invalidParams (-32602)`.
- No OAuth flow over stdio (no TTY available). Auth is always out-of-band.
- Legacy clients (Zed without `AcpBetaFeatureFlag`, JetBrains plugin) use a
  `_meta['terminal-auth']` fallback: `{command: <binary>, args:['login']}` — they
  spawn `<binary> login` directly instead of `<binary> acp --login`.
- Sandbox/test setups can inject `KIMI_CODE_HOME` env into the advertised auth
  method so the login subprocess writes to the same data root.

---

## 2. Session Management

### 2.1 `session/new`

**Feature:** Create a new agent session.

**Parameters consumed:**
- `cwd` → work directory for the session
- `mcpServers` → MCP servers from IDE config (forwarded to kernel)

**Returns:** `{sessionId, configOptions[]}`

**Use case:** User opens a new chat tab in their IDE; IDE sends `session/new`
with the project root as `cwd` and any project-scoped MCP servers.

**Edge cases:**
- Not authenticated → `authRequired (-32000)`.
- MCP servers with `type: 'acp'` → silently dropped with a `log.warn`.
- MCP servers with `type: 'http'` or `'sse'` → forwarded with URL + headers.
- MCP servers without `type` field → treated as `stdio` (command + args + env).
- Duplicate MCP server names → last-write-wins (matches kernel merge behavior).
- `available_commands_update` notification scheduled (deferred to next tick via
  `setTimeout(0)`) so the IDE can populate its slash-command palette.

### 2.2 `session/load`

**Feature:** Restore a session from disk and replay history.

**Returns:** `{configOptions[]}`

**Key behavior:** Calls `replayHistory()` which walks the session's stored
context and emits `session/update` notifications for each historical message
(user messages, assistant messages, tool calls, tool results). Every push is
**awaited** so `loadSession` resolves only after replay is complete.

**Use case:** User picks a previous session from the IDE's session list; IDE
sends `session/load` and renders the full conversation history.

**Edge cases:**
- Unknown session id → `invalidParams (-32602)` with `'Unknown sessionId: ...'`.
- Tool result in history with no matching tool call → logged warning, skipped.
- Tool result with no `toolCallId` → logged warning, skipped.
- Individual replay push fails → caught and logged (doesn't truncate replay).
- `available_commands_update` deferred after replay.

### 2.3 `session/resume`

**Feature:** Restore a session without replaying history.

**Returns:** `{configOptions[]}`

**Key difference from `load`:** Skips `replayHistory()` — the IDE is expected to
already have the transcript (e.g., it was the original client).

**Edge cases:** Same as `session/load` except no replay.

### 2.4 `session/list`

**Feature:** Enumerate available sessions for a workspace.

**Parameters:** `cwd` (workspace filter), `cursor` (pagination — ignored).

**Returns:** `{sessions: SessionInfo[], nextCursor: null}`

**SessionInfo fields:** `id`, `cwd`, `title` (null when empty), `updatedAt` (ISO
8601 or null on invalid date).

**Edge cases:**
- `nextCursor` always `null` — no pagination implemented.
- Empty `title` → normalized to `null`.
- Invalid `updatedAt` epoch → `null` instead of `Invalid Date`.

---

## 3. Prompt Streaming

### 3.1 `session/prompt`

**Feature:** Send user input and stream the agent's response.

**Input content blocks:**
- `text` → passed as-is (or intercepted if it starts with `/` — see Slash Commands)
- `image` → base64 data URL; compressed before sending to model
- `audio` → dropped with `log.warn` (not supported)
- `resource` (text) → wrapped as `<resource uri="...">text</resource>`
- `resource_link` → if `file:` URI, projected to filesystem text reference; else
  wrapped as `<resource_link uri="..."/>`
- Unknown block types → warn + drop

**Streaming output (`session/update` notifications):**

| Event | Notification kind | Content |
|---|---|---|
| Assistant text delta | `agent_message_chunk` | Text delta |
| Thinking/reasoning delta | `agent_thought_chunk` | Text delta |
| Tool call created | `tool_call` (CREATE) | Title, kind, status `in_progress`, rawInput, display content |
| Tool call lazy-created from delta | `tool_call` (CREATE) | Title, status `pending`, first args fragment |
| Tool call args streaming | `tool_call_update` | REPLACE content = cumulative args |
| Tool call started (after lazy create) | `tool_call_update` | Upgrade: canonical title/kind/rawInput, status `in_progress` |
| Tool progress (status kind) | `tool_call_update` | Title refresh |
| Tool result | `tool_call_update` | Status `completed`/`failed`, content, rawOutput |
| TodoList display | `plan` | Entries with priority + status |

**Stop reasons:**
- `completed` → `end_turn`
- `cancelled` → `cancelled`
- `failed` + `provider.filtered` → `refusal`
- `failed` (other) → `end_turn` (error logged separately)
- `blocked` → `refusal`

**Use case:** User types a coding question in the IDE chat; IDE sends
`session/prompt` and renders streaming text, tool call cards, and diffs in
real-time.

### 3.2 Image Compression

**Feature:** Input images are compressed before sending to the model.

**Flow:**
1. Drop unsupported MIME types, canonicalize aliases (`image/jpg` → `image/jpeg`).
2. For each `image_url` part: parse data URL, compress via `compressBase64ForModel`
   with `maxEdge` from harness config.
3. If image changed: persist original to `originalsDir` (so `ReadMediaFile` can
   recover fine detail), prepend caption text describing the original, then
   re-encoded image.
4. Uncompressible parts pass through unchanged.

**Edge cases:**
- If `session/cancel` arrives during image compression → short-circuit to
  `{stopReason: 'cancelled'}` (via `pendingPromptAborts` token).
- Original image persistence is best-effort — falls back to temp dir.

### 3.3 `session/cancel`

**Feature:** Interrupt the current turn.

**Edge cases:**
- If prompt is mid-image-compression (no turn yet) → `pendingPromptAborts` tokens
  flipped, prompt returns `{stopReason: 'cancelled'}`.
- `session.cancel()` is idempotent at the RPC layer.
- Cancel for unknown sessionId → logged warning, returns silently (notifications
  cannot return JSON-RPC errors per spec).
- Cancel handler error → caught, logged, swallowed.

---

## 4. Tool Approvals

### 4.1 Canonical Approval Flow

**Feature:** IDE handles permission prompts for tool calls.

**Flow:**
1. Agent's permission system requests approval for a tool call.
2. ACP adapter sends `session/request_permission` reverse-RPC to the IDE with:
   - 3 options: `approve_once`, `approve_always`, `reject`
   - `toolCallUpdate` with diff/plan_review content + "Requesting approval to {action}"
3. IDE shows UI, user selects.
4. Response mapped:
   - `approve_once` / legacy `'approve'` → `{decision: 'approved'}`
   - `approve_always` / legacy `'approve_for_session'` → `{decision: 'approved', scope: 'session'}` (installs session-runtime allow rule)
   - `reject` → `{decision: 'rejected'}`
   - `cancelled` → `{decision: 'cancelled'}`
   - Unknown → `{decision: 'rejected'}` (defensive — reject is safer than approve)

**Edge cases:**
- Permission RPC fails / times out / client disconnects → log + `{decision: 'rejected'}`
  (rejecting is strictly safer than approving when intent is unconfirmed).
- Legacy option IDs (`'approve'`, `'approve_for_session'`) accepted for backward compat.
- `selectedLabel` stitched onto the approval response from the matched option's
  display name (so downstream policies can branch on it).

### 4.2 Plan Review Flow

**Feature:** Exit-plan-mode approval with variable selectable options.

**Options built:** `plan_opt_<i>` (allow_once) for each option when ≥2 options,
else single `plan_approve`. Always appends `plan_revise` and `plan_reject_and_exit`
(reject_once).

**Edge cases:**
- Plan review with <2 options → single `plan_approve` + revise + reject-and-exit.
- `plan_*` namespace avoids collision with `approve_*` and `q{n}_*` question
  namespaces.
- Labels pre-attached inside the mapper (no post-hoc label stitching needed).

---

## 5. AskUserQuestion Bridge

**Feature:** `AskUserQuestion` tool responses are surfaced to the IDE via the
same `session/request_permission` surface (ACP has no dedicated question method).

**Option namespace:** `q{questionIndex}_opt_{optionIndex}` (one `allow_once` per
option) + `q{questionIndex}_skip` (reject_once "Skip").

**Response mapping:**
- `cancelled` → `null` (SDK treats as dismissed)
- `q0_skip` → `null` (explicit dismissal)
- `q0_opt_<i>` → `{[question.question]: selected.label}`
- Out-of-bounds / unknown → `null`

**Edge cases:**
- Empty `questions` array → log + return `null` (dismissed).
- `questions.length > 1` → degrade to first question only; telemetry
  `question_degraded {reason:'multi_question', dropped: N}`.
- `multiSelect === true` → still single-select; telemetry
  `question_degraded {reason:'multi_select'}`.
- Question RPC fails → log + `null` (canonical "user dismissed" branch).
- `questionIndex` prefix is wired for future multi-question support without a
  wire-format change (currently always 0).

---

## 6. Configuration Management

### 6.1 `session/set_config_option`

**Feature:** Unified model / thinking / mode picker.

**Config IDs:**
- `model` → `setModel(value)` — selects model from catalog
- `thinking` → `setThinking(value === 'on')` — strict equality; any other string
  reads as "off"
- `mode` → `setMode(value)` — one of `default`, `plan`, `auto`, `yolo`

**Returns:** Fresh `configOptions[]` snapshot.

**Edge cases:**
- Unknown `configId` → `invalidParams` before any SDK call.
- Config option update notifications emitted by the underlying setter methods
  (no double-emit from the dispatcher).

### 6.2 Model Selection

**Feature:** Models listed from the harness catalog.

Each model entry: `{id, name, description?, thinkingSupported, alwaysThinking?,
defaultThinkingEffort}`.

**Thinking derivation:**
- Declared `capabilities` includes `thinking`/`always_thinking` → true
- Name matches `/thinking|reason/i` → true
- Name in `TOGGLEABLE_THINKING_MODELS` (`kimi-for-coding`, `kimi-code`) → true
- `alwaysThinking`: capability-only (`always_thinking`), not name heuristics

**Thinking config option visibility:**
- Only shown when `currentModelEntry.thinkingSupported === true`.
- `alwaysThinking` models → single locked `'on'` entry (wire-level greyed-out).
- Otherwise: 2-entry select (`off`/`on`).
- Changed from `boolean` to `select` type because Zed's chip strip only renders
  `select` (booleans show "Unknown").

**Legacy compatibility:**
- `kimi-v2,thinking` suffix → split into bare model id + thinking-on.
- Bare model id does NOT turn thinking off — model and thinking are orthogonal.

### 6.3 Permission Modes

| ACP Mode | Plan | Permission | Description |
|---|---|---|---|
| `default` | false | `manual` | Standard mode, approve each tool call |
| `plan` | true | `manual` | Read-only, planning mode |
| `auto` | false | `auto` | Auto-approve read-only tools |
| `yolo` | false | `yolo` | Auto-approve everything |

**Edge cases:**
- Unknown `modeId` → `invalidParams` before any SDK call.
- No idempotency optimization — re-asserting the current mode still fires both
  SDK calls (`setPlanMode` + `setPermission`).
- The `never` fallthrough in the exhaustive switch makes adding a 5th mode a
  typecheck error (compile-time safety).

### 6.4 `config_option_update` Notifications

**Feature:** Pushed whenever model/mode/thinking changes.

Contains a full fresh `SessionConfigOption[]` snapshot (not a delta).

---

## 7. Slash Commands

### 7.1 Built-in Commands

**Advertised via `available_commands_update` after session creation:**

| Command | Description | Input hint |
|---|---|---|
| `/compact` | Compact context | Optional summary instruction |
| `/status` | Show session status | — |
| `/usage` | Show token usage | — |
| `/mcp` | Show MCP server status | — |
| `/tasks` | Show background tasks | — |
| `/help` | Show available commands | — |

### 7.2 Skill Commands

**Feature:** Plugin/session skills advertised as slash commands.

Merged from `session.listSkills()` on session creation. Failures degrade to
builtins-only.

### 7.3 Slash Routing

**Detection:** `detectLeadingSlashIntent` examines only the first text block.

| Intent | Behavior |
|---|---|
| `passthrough` | Not a slash command → send to `session.prompt()` |
| `skill` | Route to `session.activateSkill(name, args)` |
| `builtin` | Local handler (compact/status/usage/mcp/tasks/help) |
| `unknown` | Local error message (don't send to model) |

**Edge cases:**
- Names containing `/` are rejected (grammar rule).
- Skill activation routing happens at the adapter boundary so `/skill:name`
  inputs don't fall back to model-driven Bash exploration of `~/.kimi-code/skills/`.
- Builtin handlers emit a local `agent_message_chunk` and return
  `{stopReason: 'end_turn'}`.

---

## 8. MCP Server Forwarding

**Feature:** IDE-configured MCP servers forwarded to the agent.

| ACP type | Kimi transport | Fields forwarded |
|---|---|---|
| (none — stdio) | `stdio` | `command`, `args`, `env` |
| `http` | `http` | `url`, `headers` |
| `sse` | `sse` | `url`, `headers` |
| `acp` | dropped | `log.warn` |

**Edge cases:**
- Headers array `[{name, value}]` → record `{name: value}`.
- Env array `[{name, value}]` → record `{name: value}`.
- Conversion is purely structural — no URL or command validation.
- Duplicate server names → last-write-wins.

---

## 9. File I/O Reverse-RPC

**Feature:** When the IDE advertises `fs.readTextFile`/`writeTextFile`
capabilities, file reads/writes are routed through the IDE instead of the local
filesystem.

**Methods:**
- `readText(path)` → `conn.readTextFile({sessionId, path})` → returns content
- `readTextPreview(path, n)` → ACP read + slice to n chars
- `readLines(path)` → ACP read full text + split on `\n`
- `writeText(path, data, {mode})` → mode `'a'` emulated via read-then-write;
  mode `'w'` → `conn.writeTextFile`
- `writeBytes(path, data)` → UTF-8 interpretation (lossy for non-UTF-8)

**Edge cases:**
- ACP has no native append — mode `'a'` emulated via read-then-write.
- ENOENT during append's read phase → tolerated (treated as empty existing content).
- `toClientPath` on win32 → replaces `/` with `\\` (ACP requires absolute paths).
- Binary I/O (readBytes, exec, stat, glob, mkdir) → always delegated to local
  `LocalKaos`, never bridged.
- `persistenceKaos` is always a plain `LocalKaos` so session persistence writes to
  real local disk even when user-visible FS is client-mediated.

---

## 10. History Replay

**Feature:** `session/load` replays full conversation history.

**Replay order:**
1. `user` → `user_message_chunk` per text part
2. `assistant` → bumps synthetic turnId; replays content parts (text →
   `agent_message_chunk`, think → `agent_thought_chunk`); then `tool_call` CREATE
   per toolCalls entry
3. `tool` → `tool_call_update` with `completed`/`failed`; looks up turnId via map
4. `system`/unknown → skipped

**Edge cases:**
- Synthetic monotonically-increasing `turnId` starting at 1 (not the original).
- Tool result with no matching call → logged warning, skipped.
- Tool result with no `toolCallId` → logged warning, skipped.
- Every push is **awaited** (unlike live streaming which is fire-and-forget).
- Per-message failures caught and logged — a single bad message doesn't truncate
  the entire replay.

---

## 11. Streaming Architecture Details

### 11.1 Fire-and-forget Pattern

All live `sessionUpdate` calls are fire-and-forget with `.catch(log.warn)` to keep
the single-producer/single-consumer pipeline pumping. Awaiting each flush would
force the next delta to wait for the previous flush.

### 11.2 Tool Call Wire IDs

`acpToolCallId(turnId, toolCallId)` → `${turnId}:${toolCallId}` — disambiguates
across turns within a session where the model may reuse raw ids.

### 11.3 Tool Kind Inference

Heuristic map from tool name to kind:
- Read/Glob/Grep → `read`
- Write/Edit → `edit`
- Bash/Terminal → `execute`
- WebFetch/WebSearch → `fetch`
- Think → `think`
- default → `other`

### 11.4 Subagent Event Filtering

`runTurnBody` filters on `isFromMainAgent(event)` (agentId === undefined || ===
'main') so subagent events don't settle the parent prompt. Only main-agent
events drive `session/update` notifications.

---

## 12. Shutdown & Signal Handling

**Feature:** Graceful shutdown on stdin EOF, SIGINT, SIGTERM.

**Flow:**
1. `redirectConsoleToStderr()` called first — stdout is the JSON-RPC channel;
   any stray `console.log` corrupts it.
2. Idempotent `cleanup()` latch (check-and-set `cleanedUp`).
3. SIGINT/SIGTERM handlers installed via `.once` (injectable for tests).
4. On signal → `cleanup()` calls `harness.close()`.
5. `finally` block: uninstalls signal listeners (so a second Ctrl-C falls through
   to default handler and force-kills), calls `cleanup()`.

**Edge cases:**
- `harness.close()` throws during shutdown → logged at `error`, process exits anyway.
- Second Ctrl-C → default handler (force kill) because listeners were uninstalled.
- stdin EOF → `AgentSideConnection.closed` resolves → same cleanup path.

---

## 13. Telemetry

**Feature:** PII-free telemetry breadcrumbs from ACP interactions.

**Events tracked:**
- `acp_skill_activated` — skill used via slash command
- `question_degraded` — multi-question or multi-select degradation
- `question_dismissed` / `question_answered`
- `plan_review` option counts

**Edge cases:**
- Telemetry sink missing or throws → swallowed; telemetry never crashes a
  reverse-RPC handler.
- `harness.track` absent → `makeTelemetryTrack` returns `undefined`.

---

## 14. Console Hygiene

**Feature:** `redirectConsoleToStderr()` rebinds `console.log/info/warn` to
`process.stderr`.

**Rationale:** stdout is the JSON-RPC channel. Any stray `console.log` from a
dependency corrupts the protocol stream. `console.error` is left alone (already
stderr).

**Edge cases:**
- Idempotent — calling twice is safe.
- Returns a restore function (for testing).

---

## 15. Comprehensive Edge Cases & Error Handling Summary

### 15.1 Authentication Errors

| Scenario | Behavior |
|---|---|
| `session/new` / `load` / `resume` without auth | `authRequired (-32000)` |
| `authenticate` without token | `authRequired (-32000)` |
| `authenticate` with unknown methodId | `invalidParams (-32602)` |
| Auth expires mid-prompt (turn.ended with AUTH_LOGIN_REQUIRED) | Reject PromptResponse with `authRequired()` → client triggers re-auth UX |
| Auth expires mid-prompt (session.prompt() rejection) | Same `authRequired()` rejection |

### 15.2 Session Errors

| Scenario | Behavior |
|---|---|
| `session/prompt` for unknown sessionId | `invalidParams (-32602)` |
| `session/resume` for unknown session id | `invalidParams (-32602)` with `'Unknown sessionId: ...'` |
| Session creation fails (harness.createSession rejection) | Propagates as-is (SDK error → JSON-RPC layer) |
| `session/cancel` for unknown sessionId | Logged warning, returns silently |
| `session/cancel` handler error | Caught, logged, swallowed |
| `session/close` / `logout` | Not implemented → `methodNotFound` |

### 15.3 Prompt Errors

| Scenario | Behavior |
|---|---|
| Auth error during prompt | `authRequired()` (two detection paths) |
| Other prompt failure | `internalError('session prompt failed')`; stack logged, NOT exposed on wire |
| `TURN_AGENT_BUSY` before own turn started | `invalidRequest()` with structured error |
| Turn ended with reason `failed` + non-auth | `end_turn` (error logged separately) |
| Turn ended with reason `blocked` | `refusal` |
| Turn ended with `provider.filtered` | `refusal` |

### 15.4 Reverse-RPC Errors

| Scenario | Behavior |
|---|---|
| Tool approval RPC fails/times out/disconnects | `{decision: 'rejected'}` (safer than approving) |
| Question RPC fails | `null` (canonical "user dismissed") |
| Telemetry sink missing/throws | Swallowed |
| Config option update push fails | Caught, logged at `warn` |
| `available_commands_update` push fails | Caught, logged |

### 15.5 File I/O Errors

| Scenario | Behavior |
|---|---|
| ACP readTextFile fails | Wrapped in `KaosError` with `.cause` preserved |
| ACP writeTextFile append-mode ENOENT | Tolerated (treated as empty existing content) |
| Non-UTF-8 in writeBytes | Lossy UTF-8 interpretation |

### 15.6 Protocol Errors

| Scenario | Behavior |
|---|---|
| Unknown method | `methodNotFound` |
| `ext/*` methods | Stubbed → `methodNotFound` (uniform failure shape) |
| Unknown configId in set_config_option | `invalidParams` before any SDK call |
| Unknown modeId in set_mode | `invalidParams` before any SDK call |
| 18 of 19 unstable methods | Not implemented → `methodNotFound` |

### 15.7 Tool Call Streaming Edge Cases

| Scenario | Behavior |
|---|---|
| Delta arrives before started event | Lazy-create tool_call (status `pending`); downgrade started to `tool_call_update` upgrade |
| Tool result for unobserved id | Emitted normally (SDK guarantees ordering) |
| Progress with kind != 'status' | Folded into eventual result, no separate notification |
| ToolDisplay with diff | Prepended to tool_call content as diff block |
| ToolDisplay with plan_review | Emitted as content text block |
| Tool output containing `HideOutputMarker` | Empty content array (suppress double-rendering) |
| Tool output null/undefined/empty string | Empty content array (status transition still emitted) |

### 15.8 Image/Input Edge Cases

| Scenario | Behavior |
|---|---|
| Cancel during image compression | `{stopReason: 'cancelled'}` via pendingPromptAborts token |
| Uncompressible image | Pass through unchanged |
| Unsupported MIME type | Dropped with warning |
| `image/jpg` alias | Canonicalized to `image/jpeg` |
| Audio content block | Dropped with `log.warn` |
| Blob resource | Dropped with `log.warn` |

### 15.9 Mode/Model Edge Cases

| Scenario | Behavior |
|---|---|
| Re-asserting current mode | Still fires both SDK calls (no idempotency optimization) |
| Bare model id (no thinking suffix) | Does NOT turn thinking off (orthogonal axes) |
| `alwaysThinking` model | Config option collapsed to single locked `'on'` entry |
| Empty model catalog | Falls back to '' with `log.warn` |
| Partial-stub harness (test) | Tolerant fallbacks on every model/thinking resolution path |

### 15.10 Session List Edge Cases

| Scenario | Behavior |
|---|---|
| Empty title | Normalized to `null` |
| Invalid updatedAt epoch | `null` instead of `Invalid Date` |
| nextCursor | Always `null` (no pagination) |

---

## 16. Method Coverage Summary

### Stable agent-side: 10/12 (83%)

| Method | Status |
|---|---|
| `initialize` | ✅ |
| `authenticate` | ✅ |
| `session/new` | ✅ |
| `session/load` | ✅ |
| `session/resume` | ✅ |
| `session/prompt` | ✅ |
| `session/cancel` | ✅ |
| `session/list` | ✅ |
| `session/set_mode` | ✅ |
| `session/set_config_option` | ✅ |
| `session/close` | ❌ methodNotFound |
| `logout` | ❌ methodNotFound |

### Stable client-side reverse-RPC: 4/9 (44%)

| Method | Status |
|---|---|
| `session/update` | ✅ |
| `session/request_permission` | ✅ |
| `fs/read_text_file` | ✅ |
| `fs/write_text_file` | ✅ |
| `terminal/*` (5 methods) | ❌ Not wired |

### Unstable: 1/19 (5%)

| Method | Status |
|---|---|
| `session/set_model` (unstable_setSessionModel) | ✅ |
| Other 18 unstable methods | ❌ methodNotFound |
