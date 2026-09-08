# h2code.cr — Crystal reimplementation of kimi-code agent

## Goal

Rewrite the kimi-code CLI agent in Crystal to achieve **8-10x lower memory usage**,
enabling the operation of dozens of concurrent agents on a single machine.

Target: full TUI parity with the TypeScript version's core features. Provider
support is staged — see "5g. Runtime provider switching":
  - Moonshot — default backend (in place).
  - Z.AI / Zhipu (GLM) — runtime switching, the immediate next target.
  - Anthropic / OpenAI / Google — OPTIONAL, not required now (future work).

---

## Memory Targets

| Scenario            | Node.js (current) | h2code.cr (target) |
|---------------------|--------------------|-------------------|
| 1 agent             | 80-150 MB          | 5-15 MB           |
| 50 agents (process) | 4-7.5 GB           | 250-750 MB        |
| 50 agents (fibers)  | 200-400 MB         | 30-80 MB          |

---

## Why Crystal

- Single-threaded with fibers (cooperative concurrency) — same model as Node's event loop
- Boehm GC — lightweight, starts at ~1 MB
- LLVM-compiled native binary — no JIT, no V8 heap
- Statically typed, Ruby-like syntax — fast to write
- Fibers cost ~8 KB stack each — run 50 agents in one process
- Stdlab covers HTTP, JSON, YAML, Process, File, IO, Channel

---

## Architecture

### Source structure

```
h2code.cr/
├── PLAN.md
├── shard.yml
├── src/
│   ├── h2code.cr                    # entry point
│   │
│   ├── llm/
│   │   ├── provider.cr            # ChatProvider abstraction
│   │   ├── stream.cr              # SSE parser → Channel(MessagePart)
│   │   ├── moonshot_provider.cr       # Moonshot Chat Completions API
│   │   ├── token_counter.cr       # token estimation
│   │   └── types.cr               # Message, ContentPart, ToolCall, Usage
│   │
│   ├── loop/
│   │   ├── agent.cr               # Agent — composition root + run_turn()
│   │   ├── step.cr                # execute_step() — one LLM call
│   │   ├── tool_batch.cr          # run_tool_batch() — parallel tool execution
│   │   ├── retry.cr               # chat_with_retry() — rate limit / error retry
│   │   ├── dedup.cr              # tool-call deduplication (anti-loop, streak→force-stop)
│   │   ├── abort.cr              # abort signal propagation + grace timeout (2s)
│   │   └── events.cr              # Event types + dispatcher
│   │
│   ├── tools/
│   │   ├── tool.cr                # abstract Tool + ToolExecution
│   │   ├── bash.cr                # Process.run, timeout, stdout/stderr capture
│   │   ├── read.cr                # File.read, offset/limit, encoding detection
│   │   ├── write.cr               # File.write
│   │   ├── edit.cr                # string replacement (oldString → newString)
│   │   ├── glob.cr                # Dir.glob / pattern matching
│   │   ├── grep.cr                # ripgrep wrapper (Process.run)
│   │   ├── todo_list.cr           # in-memory task tracking
│   │   └── registry.cr            # tool registration + lookup
│   │
│   ├── context/
│   │   ├── memory.cr              # ContextMemory — message history + token tracking
│   │   ├── projector.cr           # project ContextMessage[] → provider Message[]
│   │   ├── compaction.cr          # LLM-based summarization on context overflow
│   │   ├── overflow.cr            # 413 recovery: media-degrade → media-strip → compaction
│   │   ├── undo.cr               # walk-back history, stop at compaction boundary
│   │   └── budget.cr             # tool result truncation (>50k chars → file + preview)
│   │
│   ├── permission/
│   │   ├── manager.cr             # PermissionManager + policies
│   │   ├── policies.cr            # rule matching (path globs, command patterns)
│   │   ├── danger.cr              # danger detection (rm -rf, sudo, pipe-to-shell, chmod 777, etc.)
│   │   └── modes.cr               # manual / auto / yolo
│   │
│   ├── session/
│   │   ├── store.cr               # JSONL append-only persistence
│   │   ├── replay.cr              # resume from JSONL event log
│   │   ├── index.cr               # local session registry: list/get/filter + workspace-aware paths
│   │   ├── lifecycle.cr           # create/fork/archive/restore/child (CLI-only, no HTTP server)
│   │   └── queue.cr               # message queue (type-ahead while agent runs)
│   │
│   ├── config/
│   │   ├── config.cr              # TOML config struct (H2codeConfig)
│   │   ├── paths.cr               # ~/.h2code/ path resolution, XDG, HOME expansion
│   │   ├── provider_config.cr     # API key, endpoint, model aliases
│   │   └── proxy.cr               # HTTP/SOCKS proxy support (HTTP_PROXY, ALL_PROXY env)
│   │
│   ├── prompt/
│   │   ├── system_prompt.cr       # assemble system prompt from multiple sources
│   │   ├── agents_md.cr           # hierarchical AGENTS.md discovery + merge
│   │   ├── workspace.cr           # cwd file tree (2 levels), platform info
│   │   └── template.cr            # simple {{var}} templating (throw on undefined)
│   │
│   ├── auth/
│   │   └── oauth.cr               # Moonshot OAuth / device-code flow
│   │
│   ├── hooks/
│   │   └── engine.cr              # PreToolUse/PostToolUse/Stop/UserPromptSubmit hooks
│   │
│   ├── notify/                    # NEW (no TS equivalent for sound/webhook)
│   │   ├── status.cr              # AgentStatus enum + transition tracker
│   │   ├── dispatcher.cr          # fan-out one transition → all channels
│   │   ├── terminal.cr            # OSC 9 desktop notification + BEL fallback (port of TS)
│   │   ├── player.cr              # cross-platform mp3/wav playback via OS-native players
│   │   └── webhook.cr             # custom POST request on transition
│   │
│   └── tui/
│       ├── terminal.cr            # raw mode (termios), ANSI escape sequences
│       ├── renderer.cr            # frame buffer + line-based diff
│       ├── input.cr               # keyboard input parser (esc sequences, kitty protocol)
│       │
│       ├── components/
│       │   ├── component.cr       # abstract Component (render, handle_input)
│       │   ├── container.cr       # vertical stack container
│       │   ├── text.cr            # styled text (bold, dim, color)
│       │   ├── editor.cr          # multiline input editor
│       │   ├── markdown.cr        # streaming markdown renderer
│       │   ├── tool_card.cr       # tool call card (header + result preview)
│       │   ├── diff.cr            # clustered diff renderer
│       │   ├── shell_block.cr     # $ command + output block
│       │   ├── transcript.cr      # scrollable message history
│       │   ├── footer.cr          # status bar (model, context%, permission mode)
│       │   ├── spinner.cr         # braille spinner animation
│       │   ├── select_list.cr     # generic up/down/enter selector
│       │   ├── todo_panel.cr      # todo list display
│       │   ├── approval_panel.cr  # tool approval dialog (with danger labels)
│       │   ├── queue_pane.cr      # queued messages display (type-ahead)
│       │   └── resize.cr          # SIGWINCH handler + cache invalidation
│       │
│       ├── dialogs/
│       │   ├── model_selector.cr
│       │   ├── permission_selector.cr
│       │   ├── effort_selector.cr
│       │   ├── session_picker.cr
│       │   └── theme_selector.cr
│       │
│       ├── commands/
│       │   ├── registry.cr        # slash command registration
│       │   ├── dispatch.cr        # parse + dispatch
│       │   └── handlers.cr        # /model, /new, /compact, /help, /exit, etc.
│       │
│       ├── theme.cr               # color palette (20 semantic tokens)
│       ├── state.cr               # TUIState — global mutable state
│       ├── streaming.cr           # StreamingController — 50ms flush coalescing
│       └── app.cr                 # main TUI controller (layout, event routing)
│
└── spec/                          # tests (Crystal spec)
    ├── llm/
    ├── loop/
    ├── tools/
    ├── context/
    ├── session/
    └── tui/
```

### Core agent loop (from agent-core/src/loop/)

The TS version's loop is already stateless. Direct mapping:

```
TS: runTurn() → executeLoopStep() → runToolCallBatch() → loop
Crystal: Agent#run_turn() → execute_step() → run_tool_batch() → loop
```

```
Agent#run_turn(prompt)
  └── while true
        ├── execute_step()
        │     ├── build messages from context
        │     ├── call LLM (streaming via Channel)
        │     ├── accumulate response (text + tool_calls)
        │     └── return StepResult
        ├── if stop_reason != tool_use → break
        ├── run_tool_batch(step.tool_calls)
        │     ├── for each tool_call:
        │     │     ├── resolve tool from registry
        │     │     ├── check permission (policy or ask user)
        │     │     ├── execute tool
        │     │     └── append result to context
        │     └── results drained in order
        └── continue loop
```

### Concurrency model

Crystal fibers + Channel(T) replace JS Promise + AsyncIterable:

```
LLM streaming:   HTTP response body → fiber reads SSE lines → Channel(MessagePart)
Tool execution:  each tool runs in its own fiber → results via Channel(ToolResult)
TUI updates:     events from agent fiber → Channel(Event) → TUI render fiber
```

The fiber-per-tool model is fully implemented in Phase 2.5. Phase 1 uses a
sequential baseline so the rest of the loop can be tested before concurrency
is introduced.

### Composition instead of DI

No VSCode-style decorator container. Simple composition root:

```crystal
class Agent
  getter llm : LLM::MoonshotProvider
  getter context : Context::Memory
  getter tools : Tool::Registry
  getter permission : Permission::Manager

  def initialize(@llm, @context, @tools, @permission)
  end
end
```

---

## Moonshot Provider

Only Moonshot Chat Completions API. Based on `packages/kosong/src/providers/kimi.ts`.

- Endpoint: `https://api.moonshot.ai/v1/chat/completions` (or configurable)
- Streaming: SSE (Server-Sent Events) via HTTP::Client
- Auth: Bearer token (OAuth or API key)
- Features: tool_calls, system prompt, streaming text/thinking

```crystal
class MoonshotProvider < LLM::Provider
  def generate(messages, tools, system_prompt) : Channel(MessagePart)
    channel = Channel(MessagePart).new
    spawn do
      response = HTTP::Client.post(endpoint) do |req|
        req.headers["Authorization"] = "Bearer #{token}"
        req.headers["Content-Type"] = "application/json"
        req.body = build_request(messages, tools, system_prompt).to_json
      end
      # Parse SSE stream
      response.body_io.each_line do |line|
        next unless line.starts_with?("data: ")
        data = line[6..]
        break if data == "[DONE]"
        chunk = Chunk.from_json(data)
        parse_delta(chunk, channel)
      end
      channel.close
    end
    channel
  end
end
```

---

## Built-in Tools

Based on `packages/agent-core/src/tools/builtin/`.

| Tool   | Crystal impl                              | Approval rule                |
|--------|-------------------------------------------|------------------------------|
| Bash   | `Process.run(cmd, shell: true)` + timeout | Always ask (unless yolo)     |
| Read   | `File.read(path)` + offset/limit          | Auto-approve                 |
| Write  | `File.write(path, content)`               | Ask                          |
| Edit   | String replace (oldString → newString)    | Ask                          |
| Glob   | `Dir.glob(pattern)`                       | Auto-approve                 |
| Grep   | `Process.run("rg", ...)`                  | Auto-approve                 |
| TodoList | in-memory array                         | Auto-approve                 |

Each tool implements:

```crystal
abstract class Tool
  abstract def name : String
  abstract def description : String
  abstract def parameters : JSON::Schema    # or manual validation
  abstract def execute(input, ctx) : ToolResult
end
```

---

## Critical Infrastructure (must-have, not optional)

These features are invisible to the user but the tool **breaks without them**.
Each maps 1:1 to existing TS logic.

### 1. System prompt assembly

The agent is useless without workspace context. The system prompt is assembled
from multiple sources at session start and re-rendered after compaction:

```
SystemPrompt =
  base_instructions          # from prompt/system_prompt.md template
  + H2CODE_OS / H2CODE_SHELL     # platform info
  + H2CODE_WORK_DIR_LS         # cwd file tree (2 levels deep)
  + H2CODE_AGENTS_MD           # hierarchical AGENTS.md merge:
                              #   ~/.h2code/AGENTS.md (user-level)
                              #   → project root AGENTS.md
                              #   → ... down to cwd AGENTS.md
  + H2CODE_ADDITIONAL_DIRS     # /add-dir directory listings
  + tool_descriptions         # auto-generated from tool schemas
```

AGENTS.md discovery: walk from git root → cwd, find `AGENTS.md` and
`.h2code/AGENTS.md` at each level, deduplicate, concatenate with path annotations.
Soft 32 KB budget (warn, don't truncate).

Template engine: simple `{{var}}` replacement. **Must throw on undefined var**
(not silently leak `{{placeholder}}` into the prompt).

Ref: `packages/agent-core/src/profile/context.ts`, `profile/resolve.ts`

### 2. Tool result budgeting

Tool outputs > 50,000 chars are truncated:

```
1. Write full output to ~/.h2code/tool-results/<tool>-<id>-<uuid>.txt
2. Replace model-facing result with:
   "[Output truncated. N chars total. Use Read with output_path to view full output.]"
   + 2,000-char preview
3. Set truncated: true flag (prevents re-budgeting)
```

Without this, reading one large file fills the context window.

Ref: `packages/agent-core/src/agent/turn/tool-result-budget.ts`

### 3. Tool-call deduplication (anti-loop)

Prevents infinite tool-call loops. Tracks consecutive identical calls
(same tool + canonical args):

```
streak 3  → inject reminder ("state what new info you expect")
streak 5  → force decision menu (falsify / ask user / conclude)
streak 8  → final hand-off instruction
streak 12 → FORCE-STOP the turn
```

Also deduplicates within a single step (identical calls in same response
reuse the first result).

Ref: `packages/agent-core/src/agent/turn/tool-dedup.ts`

### 4. Abort signal propagation

Ctrl+C must stop everything cleanly:

```
TUI (Ctrl+C / Esc)
  → Agent.abort_turn()
    → HTTP stream cancellation (close connection)
    → Each running tool gets abort signal
      → Tools that ignore signal: 2-second grace timeout → kill
    → Subagents (if any): cascade abort via linked signals
    → Compaction: abort its LLM call
```

`UserCancellationError` is distinct from generic abort — reports
"the user interrupted this" to the model context, not a system error.

Ref: `packages/agent-core/src/utils/abort.ts`, `loop/tool-call.ts`

### 5. Message queue (type-ahead)

When the agent is running, user input is queued, not lost:

```
User types while agent works
  → message pushed to queue
  → queue pane shows: "↑ to edit · Ctrl+S to steer immediately"
  → on turn end: drain one queued message → start new turn

Ctrl+S (steer): inject queued message into the running turn immediately
  (doesn't wait for turn to finish)
```

Without this, the editor must be disabled while the agent works —
terrible UX.

Ref: `apps/kimi-code/src/tui/kimi-tui.ts:1211`, `tui-state.ts:54`

#### 5.1 How the original kimi-code (TS) implements it

Three flags gate the queue (`tui-state.ts:54`, `kimi-tui.ts:306`):

- `streamingPhase` — `'idle'` when no turn is running; anything else
  means the agent is mid-turn.
- `isCompacting` — true during context compaction (queue, don't send).
- `deferUserMessages` — set `true` by `/init` and other meta-commands
  (`commands/session.ts:167`) so prompts typed during the command queue
  instead of racing it; reset on turn end (`streaming-ui.ts:554`).

Queued item shape (`tui/types.ts:199`):

```
QueuedMessage { text, agentId?, parts?, imageAttachmentIds?, mode? }
  // mode 'bash' = queued shell command, 'prompt' (omitted) = message
```

Enqueue vs send (`kimi-tui.ts:1340` `sendMessage`):

```
if deferUserMessages || streamingPhase != 'idle' || isCompacting:
    enqueueMessage(text)        // push + track 'input_queue'
else:
    sendMessageInternal(text)   // send now
```

Steer = inject into the *running* turn, don't wait (`kimi-tui.ts:1352`
`steerMessage`, Ctrl+S):

```
if deferUserMessages || isCompacting:   enqueue (can't steer mid-compaction)
elif streamingPhase == 'idle':          send immediately (no turn to steer)
else:                                   append to transcript + session.steer(text)
                                        // engine appends as a user turn *now*
```

`session.steer()` is the SDK primitive — it pushes the text into the
active turn's context so the model sees it on its *next* step, without
ending the current turn. This is the key difference from the queue: a
queued message starts a *new* turn; a steered message joins the
*current* one.

Drain on turn end (`streaming-ui.ts:551` `finalizeTurn`):

```
shift one queued message (FIFO)
if next:
    queuedMessageDispatchPending = true      // guard the gap below
    streamingPhase = 'idle'
    setTimeout(() => {                       // next macrotask
        queuedMessageDispatchPending = false
        sendQueued(next)                     // starts a fresh turn
    }, 0)
```

`queuedMessageDispatchPending` covers the window between "shifted out of
the array" and "actually sent": without it, a queued-goal promoter sees
an empty queue + idle phase and starts a goal ahead of the message.

Queue management ops (`kimi-tui.ts`):

- `shiftQueuedMessage()` (1398) — FIFO shift (drain)
- `recallLastQueued()` (1200)   — LIFO pop (`↑` to edit the last queued item)
- `clearQueuedMessages()` (1394)— wipe all (on cancel / `/new`)

UI: `components/panes/queue-pane.ts` lists each queued item; the hint is
context-sensitive — "↑ to edit · will send after current task" /
"…after compaction" / "…ctrl-s to steer immediately".

#### 5.2 Current Crystal state (broken stub)

A partial queue already exists in `src/tui/app.cr` but is effectively
non-functional — this is why you "can't type the next message while the
agent works":

- `@queue : Array(String)` — line 66. Stores only text (no agent/mode).
- Ctrl+S handler (361-367) only *queues*; there is no `session.steer`
  injection, so "steer immediately" is not implemented.
- Drain (509-522) shifts **one** message, then the inner `spawn` never
  re-checks the queue — queueing 3 messages runs only 2, the rest stall
  forever. There is no loop / recursion.
- No persistence: queued messages bypass `store.append`; `store.cr:80`
  has a dead `turn.steer` replay case waiting for events that never come.
- No cancel cleanup: Ctrl+C / Esc / `show_interrupted` don't clear
  `@queue`, so cancelled turns leak queued messages into the next turn.
- No `QueuePane` component, no `/queue` command, no recall/clear.

#### 5.3 Crystal implementation plan

1. **Drain loop.** Factor `submit_message` into a `run_next_turn(msg)`
   whose completion fiber calls itself: `while next = @queue.shift?; …`.
   Fixes the one-message stall.
2. **`TurnEnd` event.** Add `TurnEnd` to `loop/events.cr`; emit from
   `Agent#run_turn` (`agent.cr:42`, `69`) so the TUI drains from
   `on_event` instead of inside a closure.
3. **Steer.** Add `Agent#steer(text)` that pushes into the running turn
   context (mirror `session.steer`). Wire Ctrl+S: idle→send,
   busy→steer, compacting→queue.
4. **State parity.** `@queue` → `Array(QueuedMessage)` with `mode`; add
   `@defer_user_messages`, `@is_compacting`; mirror the three-flag
   enqueue gate.
5. **Persistence.** Write `turn.steer` / `turn.prompt` via `store.append`
   so drain survives resume (the `store.cr:80` case already exists).
6. **Cancel cleanup.** Clear `@queue` in cancel / interrupt paths.
7. **UI.** `TUI::QueuePane` (Phase 2 checklist) + `/queue` command.

### 6. Context overflow recovery (413)

When the API rejects the request as too large:

```
Path A (media too large):
  retry with media-degraded projection (compress base64 images)
  → if still 413: media-stripped (replace all images with text markers)
  → stick to degraded/stripped for rest of turn

Path B (token count overflow):
  estimated_tokens >= max_context * 0.9
  → trigger compaction (LLM summarizes old history)
  → compaction itself retries on 413 (strip media, shrink history)
  → learn the real context limit from the error
```

Without this, sessions with images or long histories crash irrecoverably.

Ref: `packages/agent-core/src/loop/turn-step.ts:190-315`, `compaction/full.ts`

### 7. Proxy support

```
HTTP_PROXY / HTTPS_PROXY / ALL_PROXY env vars
  → HTTP proxy via HTTP::Client proxy support
  → SOCKS proxy (socks5://) via custom connector
  → NO_PROXY bypass (loopback always exempt: localhost, 127.0.0.1, ::1)
  → child processes (hooks, MCP) inherit proxy env
```

Without this, users behind corporate proxies or VPN (Clash/V2Ray)
get silent connection failures.

Ref: `packages/agent-core/src/utils/proxy.ts`

### 8. Undo

Walks backward through message history:

```
undo(count)
  → remove messages backward, skip injection-origin messages
  → STOP at compaction_summary boundary (cannot undo past compaction)
  → clear pending tool results, deferred messages
  → if count exceeds undoable → throw undo_limit error
  → record context.undo in JSONL for persistence
```

Ref: `packages/agent-core/src/agent/context/index.ts:253-311`

### 9. Danger detection (in approval)

Pattern matching on tool args before showing approval:

```
rm with -r/-R/-f/--recursive  → "Dangerous: recursive delete"
sudo                          → "Dangerous: elevated privileges"
curl ... | sh                 → "Dangerous: pipe to shell"
chmod 777                     → "Dangerous: world-writable"
dd ... of=                    → "Dangerous: raw device write"
mkfs                          → "Dangerous: filesystem format"
fork bomb pattern             → "Dangerous: fork bomb"
```

Label renders in bold red above the command in the approval panel.

Ref: `packages/agent-core/src/agent/permission/policies/` + approval adapter

### 10. Terminal resize (SIGWINCH)

```
Signal::SIGWINCH handler
  → re-read terminal columns/rows
  → invalidate all component render caches
  → force full re-render
  → re-clamp scroll positions
```

Without this, resizing the terminal corrupts the display.

Ref: `packages/pi-tui/src/terminal.ts:134-167`

---

## Session Persistence

Based on `packages/agent-core/src/agent/records/`.

Format: **JSONL append-only** (one JSON object per line), compatible with TS version.

```
~/.h2code/sessions/<workspace_id>/<session_id>/
  ├── wire.jsonl          # event log
  └── state.json          # session metadata (title, cwd, archived, custom)
```

This mirrors the v2 (`agent-core-v2`) on-disk layout. A legacy fallback reads
old flat layout `~/.h2code/sessions/<session_id>/meta.json` + `wire.jsonl` when
no v2 directory exists, so sessions created by earlier h2code.cr builds remain
resumable.

There is **no HTTP server** and no `/sessions` REST API. Session management is
exposed only through CLI flags and TUI slash commands.

Event types (subset, sufficient for round-trip):

- `turn.prompt` — user message
- `turn.steer` — steering message
- `tool.call` — tool invocation
- `tool.result` — tool output
- `context.apply_compaction` — compaction summary
- `config.update` — config changes
- `permission.set_mode` — permission mode change
- `usage.record` — token usage

Replay reads the JSONL sequentially and rebuilds `ContextMemory`.

### Local session management (console-only)

No HTTP server. The kap-server `/sessions` REST surface is replaced by local
CLI flags and TUI slash commands acting directly on `Session::Index` /
`Session::Lifecycle`.

| TS server endpoint                | `h2code.cr` equivalent                          |
|-----------------------------------|-----------------------------------------------|
| `POST /sessions`                  | `h2code.cr --new` or TUI `/new`                 |
| `GET /sessions`                   | `h2code.cr --list` or TUI `/sessions`           |
| `GET /sessions/{id}`              | `h2code.cr -s <id>`                             |
| `POST /sessions/{id}:fork`        | TUI `/fork`                                   |
| `POST /sessions/{id}:archive`     | TUI `/archive`                                |
| `POST /sessions/{id}:restore`     | TUI `/restore`                                |
| `POST /sessions/{id}:undo`        | TUI `/undo`                                   |
| `POST /sessions/{id}/profile`     | TUI `/rename`                                 |
| `GET /sessions/{id}/children`     | Deferred (no child sessions in console MVP)   |
| `GET /sessions/{id}/status`       | Status line in TUI footer                     |

---

## Config

Based on `packages/agent-core/src/config/` and `apps/kimi-code`.

TOML format, compatible with existing kimi-code config:

```toml
[model]
default = "kimi-k2"
thinking_effort = "medium"

[permission]
mode = "manual"

[provider.moonshot]
api_key = ""
endpoint = "https://api.moonshot.ai/v1"
```

Crystal TOML shard: `crystal-community/toml.cr`.

Path resolution: `~/.h2code/config.toml`, XDG-aware, `H2CODE_HOME` env override.

---

## Notifications (system + sound + webhook) — NEW feature

This is a **net-new feature** with no direct TS equivalent. The TS version
only emits terminal-desktop notifications (OSC 9 + BEL fallback) on a few
hard-coded events — see `apps/kimi-code/src/tui/utils/terminal-notification.ts`.
h2code.cr generalises this into a status-driven notification system with three
independent delivery channels, plus first-class agent-status tracking.

### Agent status model

A single `AgentStatus` enum replaces today's scattered boolean/string hints
(`@agent_busy` at `tui/app.cr:69`, `@status : String` at `:63`, and the
`@approval_pending` flag at `:97`):

```crystal
enum AgentStatus
  Idle           # no turn running; awaiting the next user prompt (rest state)
  Working        # a turn is running (LLM call, tool execution, compaction)
  Done           # a turn just finished; results delivered to the user
  InputRequired  # blocked waiting for the user (tool approval / question)
end
```

A `StatusTracker` owns the current value and exposes `transition!(next)`.
It computes the `(prev, next)` edge and fans it out to all channels. Only
**transitions** fire notifications — staying in `Working` across many steps
emits nothing, which keeps long tool-heavy turns quiet.

Notification-triggering transitions:

| Transition                 | Meaning                          | Default channels |
|----------------------------|----------------------------------|------------------|
| `Working → Done`           | turn completed                   | sound + terminal + webhook |
| `* → InputRequired`        | approval/question blocking       | sound + terminal + webhook |
| `Idle → Working`           | turn started                     | webhook only (no sound)    |
| `Done → Idle`              | settled back to rest             | none (quiet)               |

`Idle → Working` is intentionally silent on the user-facing channels so the
start of a turn does not beep on every keystroke-driven turn.

### Where transitions are emitted

Map 1:1 onto the existing event flow in `loop/events.cr` and `loop/agent.cr`:

| Code location                               | Transition emitted          |
|---------------------------------------------|-----------------------------|
| `Agent#run_turn` entry (`agent.cr:31`)      | `* → Working`               |
| `Agent#run_turn` return (`agent.cr:69`)     | `Working → Done`            |
| `Agent#cancel` / `UserCancellationError`    | `Working → Done` (cancelled)|
| `ToolBatch` pre-flight, approval pending    | `Working → InputRequired`   |
| approval callback returns a choice          | `InputRequired → Working`   |

The cleanest hook is a new `EventType::TurnEnd` (already proposed in §5.3.2
for the message queue) plus a new `EventType::StatusChange`. `App#on_event`
translates those into `StatusTracker#transition!`. `request_approval`
(`tui/app.cr:294`) is the single `InputRequired` entry point.

### Delivery channels

All channels are independently toggleable. A disabled channel is a no-op
(in no allocation / no fork), so a headless `h2code.cr -p` run pays nothing
for the TUI-less paths.

#### 1. Terminal desktop notification (port of TS)

Port `terminal-notification.ts` faithfully — it already handles the edge
cases (tmux DCS passthrough, OSC 9 capability detection, BEL fallback,
control-char sanitising, message length cap):

- `supports_osc9?` — allow-list on `TERM_PROGRAM` / `TERM` (iTerm2, WezTerm,
  Kitty, Ghostty, Warp).
- `build_sequences(notif, supports_osc9, inside_tmux)` → OSC 9 wrapped in
  tmux DCS passthrough, or a bare `BEL` fallback.
- `notify_once(key, notif)` — de-dupe by `key` so a repeated approval for
  the same tool doesn't spam (mirrors `notificationKeys` set in TS).

Ref: `apps/kimi-code/src/tui/utils/terminal-notification.ts` (148 lines).
Constant `MAX_TERMINAL_NOTIFICATION_MESSAGE_LENGTH` lives in
`tui/constant/terminal.ts`.

#### 2. Sound playback (NEW — no TS equivalent)

Play an mp3/wav when a transition fires. There is **no mature pure-Crystal
audio shard**, so `Notify::Player` is a thin cross-platform dispatcher that
shells out to the OS-native player:

| Platform | Command                                                                  |
|----------|--------------------------------------------------------------------------|
| macOS    | `afplay <file>` (builtin)                                                |
| Linux    | `pw-play` (PipeWire) → `paplay` (PulseAudio) → `aplay` (ALSA) → `ffplay` |
| Windows  | `powershell -c "(New-Object Media.SoundPlayer '<file>').PlaySync()"` (wav) → `ffplay` |

The first available command wins (probed once at startup, cached). Playback
runs in a detached fiber (`Process.run(..., output: :close)`), fire-and-forget:
a stuck/missing player must never block the agent loop. `ffplay` is the final
cross-platform fallback (bundled with ffmpeg) and also covers mp3 where the
native players only accept wav.

```crystal
module H2code::Notify
  class Player
    @cmd : {String, Array(String)}?  # resolved at init

    def play(path : String, async = true) : Nil
      cmd = @cmd || return
      spawn do
        Process.run(cmd[0], args: cmd[1] + [path], output: Process::Redirect::Close, error: Process::Redirect::Close)
      end
    end
  end
end
```

Bundled sounds ship under `~/.h2code/sounds/` (`done.mp3`, `alert.mp3`) and
are created on first run if absent (generated or vendored CC0 files). Users
can override paths in config.

**Cross-platform player note:** the explicit decision is to NOT write a
from-scratch audio decoder in Crystal. shelling out to the always-present
OS player (`afplay`/`aplay`/`pw-play`) plus `ffplay` as a fallback covers
every supported platform with ~80 LOC, versus thousands for a native
decoder + the risk of codec/ALSA/CoreAudio bindings.

#### 3. Webhook (custom POST request — NEW)

Fire a user-configured HTTP request on a transition. JSON body:

```json
{
  "event": "done",
  "status": "done",
  "prev_status": "working",
  "title": "Turn complete",
  "body": "<optional, e.g. last assistant text or tool that needs approval>",
  "session_id": "...",
  "timestamp": "2026-07-17T16:41:00Z"
}
```

```crystal
module H2code::Notify
  class Webhook
    def fire(payload : WebhookPayload) : Nil
      spawn do
        HTTP::Client.post(@url, body: payload.to_json,
                         headers: HTTP::Headers{"Content-Type" => "application/json"})
      end
    end
  end
end
```

Runs in a detached fiber with a configurable timeout (default 5s). Network
errors are swallowed and logged at debug level — a flaky webhook endpoint
must never break a turn. Method defaults to `POST`; `method`, custom
`headers`, and a `secret` (sent as `X-H2Code-Webhook-Secret`) are optional.

### Config

Driven entirely by TOML, mirroring the TS `[notifications]` block and
extending it:

```toml
[notifications]
enabled = true
condition = "unfocused"            # "unfocused" | "always"  (terminal channel only)

[notifications.sound]
enabled = true
done = "~/.h2code/sounds/done.mp3"
input_required = "~/.h2code/sounds/alert.mp3"
working = ""                       # optional, empty = silent

[notifications.terminal]
enabled = true                     # OSC 9 + BEL

[notifications.webhook]
enabled = false
url = "https://example.com/notify"
method = "POST"                    # POST (default) — also accepts PUT
timeout_ms = 5000
secret = ""                        # sent as X-H2Code-Webhook-Secret header
# headers = { Authorization = "Bearer ..." }   # optional custom headers
```

`condition` ("unfocused" | "always") applies only to the terminal channel —
it gates on terminal-focus detection the same way the TS version does
(`notifyTerminalOnce` checks `state.terminalState.focused`). Sound and
webhook fire regardless of focus (they exist precisely for the "I switched
away from the terminal" case).

These fields are added to `Config::Config` (`config/config.cr`) with matching
`parse_toml` / `save` cases, next to the existing `[agent]` block.

### Dispatcher

`Notify::Dispatcher` holds the optional `Terminal`, `Player`, and `Webhook`
instances and is called once per transition. It respects per-channel
`enabled` flags and the global `[notifications] enabled` master switch
(off = the whole subsystem is inert, including the status enum wiring).

```crystal
class H2code::Notify::Dispatcher
  def initialize(@terminal : Terminal?, @player : Player?, @webhook : Webhook?)
  end

  def on_transition(payload : TransitionPayload) : Nil
    return unless @config.enabled
    @terminal.try(&.notify(payload))      # checks `condition` + focus
    @player.try(&.play_for(payload))      # picks done/alert by event
    @webhook.try(&.fire(payload))         # async POST
  end
end
```

The dispatcher is owned by `App` (TUI) or constructed inline in the headless
`h2code.cr -p` path. `StatusTracker#transition!` calls `dispatcher.on_transition`
directly, so the agent loop itself stays unaware of channels.

### Implementation plan

1. **`Notify::StatusTracker` + `AgentStatus`** (`notify/status.cr`).
   Hold current status, expose `transition!`, call the registered dispatcher.
   Replace `@agent_busy` / `@status` string usage with status reads where it
   simplifies rendering (footer, queue pane).
2. **`Notify::Terminal`** (`notify/terminal.cr`). Port
   `terminal-notification.ts` (OSC 9, BEL, tmux passthrough, `supports_osc9?`,
   `notify_once` de-dupe). Wire `Working → Done` and `→ InputRequired` to
   `notify_once`.
3. **`Notify::Player`** (`notify/player.cr`). Probe OS player at init; cache
   the resolved command; `play(path)` spawns a detached fiber. Vendor default
   `done.mp3` / `alert.mp3` under `~/.h2code/sounds/`.
4. **`Notify::Webhook`** (`notify/webhook.cr`). Async POST with timeout,
   secret header, swallow errors.
5. **`Notify::Dispatcher`** (`notify/dispatcher.cr`). Fan-out + per-channel
   gating.
6. **Events.** Add `EventType::TurnEnd` + `EventType::StatusChange` to
   `loop/events.cr`; emit from `Agent#run_turn` and `ToolBatch` approval path.
7. **Config.** Add the `[notifications]` / `[notifications.sound]` /
   `[notifications.terminal]` / `[notifications.webhook]` blocks to
   `Config::Config` (parse + save).
8. **Wire-up.** `App` constructs the dispatcher from config on startup; TUI
   `request_approval` (`app.cr:294`) and turn-end (`app.cr:531`) become
   status transitions. Headless `h2code.cr -p` builds a dispatcher too (useful
   for CI/automation webhooks).
9. **Tests** (`spec/notify/`). Status transitions fan out to stubbed
   channels; player command resolution per fake `OSTYPE`; webhook payload
   shape; terminal sequence builder parity with TS.

### Out of scope

- Native audio decoding in pure Crystal (shell out to OS players instead).
- Focus detection via terminal queries beyond the env-var heuristic the TS
  version uses (`notifyTerminalOnce` relies on `terminalState.focused`,
  which is itself driven by focus-reporting escapes; full focus-event
  support is a separate TUI concern).
- Per-tool / per-event custom sound routing (only `done` / `input_required`
  / optional `working` for now).
- Webhook authentication schemes beyond the shared-secret header
  (no HMAC signing in v1).

---

## TUI Feature Matrix

### Kept 1:1 (no quality loss)

| Feature                       | Effort  |
|-------------------------------|---------|
| Streaming text (50ms flush)   | Medium  |
| Markdown rendering            | Medium  |
| Tool-call cards (header+body) | Medium  |
| Multiline input editor        | Medium  |
| Transcript (scrollback-based) | Low     |
| Core shortcuts (Enter/Ctrl+C/Ctrl+O/Shift+Tab) | Low |
| Footer (model + context%)     | Low     |
| Bash live output              | Low     |
| Diff preview (line-level)     | Medium  |
| Session resume/replay         | Low     |
| JSONL session persistence     | Low     |
| Config load/save (TOML)       | Low     |
| Spinner (braille)             | Low     |
| Color palette (20 tokens)     | Low     |
| Dark theme                    | Low     |

### Generic SelectList → all selectors (~1 day total)

A single `SelectList` component (80 lines) powers all selector dialogs.
Each dialog is just a data array:

| Selector              | Data source                          |
|-----------------------|--------------------------------------|
| Provider selector     | `LLM::KNOWN_PROVIDERS` (moonshot, zai)   |
| Model selector        | Hardcoded list of models             |
| Permission selector   | manual / auto / yolo                 |
| Effort selector       | low / medium / high                  |
| Session picker        | Session index scan                   |
| Theme selector        | dark / light                         |

### Simplified (works, but less polished)

| Feature               | TS version                              | h2code.cr version                     |
|-----------------------|-----------------------------------------|-------------------------------------|
| Syntax highlighting   | cli-highlight, 30+ langs, auto-detect   | Basic: TS/JS/Python/bash/go/rust    |
| Diff highlighting     | Word-level intra-line diff              | Line-level +/- with color           |
| Approval panel        | Danger detection (8 patterns), Ctrl+E preview, session-scope cache | y/n + optional feedback |
| Slash autocomplete    | Wrapping list with descriptions + arg hints | Simple name list               |
| Paste handling        | Compact `[paste #N +48 lines]` markers  | Raw paste into editor buffer        |
| Footer badges         | git badge, goal badge, tips rotation    | Model + context% only               |

### Added back in later phases (not lost, deferred)

| Feature               | Phase  | Est. effort |
|-----------------------|--------|-------------|
| Plan mode             | 3      | Medium      |
| Goals                 | 3      | Medium      |
| TodoList panel        | 2      | Low         |
| Slash commands (full) | 2      | Low         |
| MCP servers           | 4      | High        |
| Danger detection      | 2      | Low         |
| Session-scope approvals| 2     | Low         |
| Light theme           | 3      | Low         |
| External editor (Ctrl+G) | 2   | Low         |
| Steer (Ctrl+S)        | 2      | Low         |
| Background task (Ctrl+B) | 4   | Medium      |
| Compaction            | 2      | Medium      |
| Word-level diff       | 3      | Medium      |

### Not in scope (would need separate effort)

| Feature               | Why excluded                          |
|-----------------------|---------------------------------------|
| Agent swarm grid      | 1700+ lines, complex animation. Text log fallback. |
| Inline images (Kitty) | Binary graphics protocol, niche terminal support    |
| Image paste           | Clipboard image read needs native bindings           |
| Custom themes (tui.toml) | Low priority, dark theme sufficient               |
| Plugins system        | Complex runtime, defer                                |
| Subagent rich lifecycle cards | Can add simplified text version later       |
| /btw panel            | Defer                                                 |
| Cron jobs             | Defer                                                 |
| Background tasks browser | Defer                                              |
| HTTP server / REST API | Console-only target; `kap-server` is a separate concern |
| `/sessions` REST endpoint | Replaced by local CLI flags and slash commands       |

---

## Phases

### Phase 1: Bare agent loop + headless CLI (1-2 weeks)

Goal: `h2code.cr -p "fix this bug"` works end-to-end, output to stdout.

- [ ] Project scaffold: `shard.yml`, directory structure
- [ ] `LLM::MoonshotProvider` — Chat Completions API, SSE streaming
- [ ] `LLM::TokenCounter` — estimation
- [ ] `LLM::types.cr` — Message, ContentPart, ToolCall, Usage, Chunk
- [ ] `Loop::Agent` — run_turn() main loop
- [ ] `Loop::step.cr` — execute_step() (one LLM call)
- [x] `Loop::tool_batch.cr` — parallel `run_tool_batch()` (implemented in Phase 2.5)
- [ ] `Loop::retry.cr` — rate-limit retry (429, 500s)
- [ ] `Loop::dedup.cr` — tool-call deduplication (streak tracking → force-stop)
- [ ] `Loop::abort.cr` — abort signal + 2s grace timeout for tools
- [ ] `Tools::Bash` — Process.run with timeout
- [ ] `Tools::Read` — file read with offset/limit
- [ ] `Tools::Write` — file write
- [ ] `Tools::Edit` — string replacement
- [ ] `Tools::Glob` — pattern matching
- [ ] `Tools::Grep` — ripgrep wrapper
- [ ] `Tools::Registry` — registration + JSON schema for each tool
- [ ] `Context::Memory` — message history + incremental token count
- [ ] `Context::Projector` — project to provider message format
- [ ] `Context::Budget` — tool result truncation (>50k → file + 2k preview)
- [ ] `Context::Overflow` — 413 recovery (media-degrade → strip → compaction)
- [ ] `Context::Undo` — walk-back with compaction boundary stop
- [ ] `Permission::Manager` — basic manual/yolo/auto
- [ ] `Config` — TOML load/save, path resolution
- [ ] `Config::Proxy` — HTTP/SOCKS proxy from env vars
- [ ] `Prompt::SystemPrompt` — assemble from workspace + AGENTS.md + platform
- [ ] `Prompt::AgentsMd` — hierarchical AGENTS.md discovery + merge
- [ ] `Prompt::Template` — {{var}} replacement, throw on undefined
- [ ] `Auth::OAuth` — Moonshot device-code flow (or API key fallback)
- [ ] `Session::Index` — local session registry: list/get/filter by workspace, archived, empty
- [ ] `Session::Lifecycle` — create/fork/archive/restore/child (CLI-only, no server)
- [ ] CLI session flags: `-s <id>`, `-c/--continue`, `--new`, workspace-aware home dir
- [ ] v2 session file layout (`<workspace>/<session>/state.json`) + legacy fallback
- [ ] Headless CLI: `-p "prompt"`, stream output to stdout
- [ ] Tests: loop, tools, context, system prompt

**Milestone:** `h2code.cr -p "list files in this project"` → agent builds system
prompt with workspace context → runs Bash → prints result. Under 15 MB RSS.

### Phase 2: TUI core (1-2 weeks)

Goal: Interactive TUI with streaming, tool cards, input editor, message queue.

- [ ] `TUI::Terminal` — raw mode (termios), ANSI escape writing
- [ ] `TUI::Input` — keyboard parser (escape sequences, arrows, ctrl/shift)
- [ ] `TUI::Renderer` — frame buffer, line-based diff, write only changed lines
- [ ] `TUI::Resize` — SIGWINCH handler + cache invalidation
- [ ] `TUI::Component` — abstract base (render, handle_input)
- [ ] `TUI::Container` — vertical stack
- [ ] `TUI::Text` — styled text (bold, dim, fg color via hex)
- [ ] `TUI::Editor` — multiline input, Enter submit, Shift+Enter newline, history
- [ ] `TUI::Markdown` — basic markdown (headings, bold, code blocks, lists, links)
- [ ] `TUI::ToolCard` — header (`Using Bash (git status)`) + result preview
- [ ] `TUI::ShellBlock` — `$ command` + output
- [ ] `TUI::Diff` — line-level +/- with color
- [ ] `TUI::Transcript` — scrollable history (terminal scrollback)
- [ ] `TUI::Footer` — model + context% + permission mode
- [ ] `TUI::Spinner` — braille animation (80ms)
- [ ] `TUI::Streaming` — 50ms flush coalescing controller
- [ ] `TUI::QueuePane` — queued messages display (type-ahead while agent works)
- [ ] `TUI::Theme` — 20-token color palette, dark theme
- [ ] `TUI::State` — global TUIState
- [ ] `TUI::App` — layout assembly, event routing from agent
- [ ] `TUI::SelectList` — generic up/down/enter component
- [ ] `TUI::ApprovalPanel` — y/n + feedback + danger labels
- [ ] Session::Queue — message queue + drain on turn end
      (broken stub in `app.cr` — see §5.2; fix per §5.3: drain loop,
      `TurnEnd` event, state parity, persistence, cancel cleanup)
- [ ] Core shortcuts: Enter, Shift+Enter, Ctrl+C (cancel/exit), Ctrl+O (expand), Esc
- [ ] Ctrl+S — steer (inject queued message into running turn)
      (needs `Agent#steer` to inject into the live turn — see §5.3.3)
- [ ] Session: JSONL write during TUI session
- [ ] Session: resume/replay on startup
- [ ] TUI session picker (`/sessions`) + keyboard shortcut
- [ ] Slash commands `/new`, `/fork`, `/archive`, `/delete` for session management
- [ ] Permission::Danger — 8 danger patterns in approval
- [ ] TodoList panel

**Milestone:** Full interactive session — type prompt, see streaming response,
watch tool calls execute with approval + danger labels, type-ahead queue,
resume sessions.

### Phase 2.5: Parallel tool execution (must-have, ~3-5 days)

Goal: When the LLM returns multiple tool calls in one step, execute them
concurrently using Crystal fibers instead of sequentially, while preserving
result order and honoring abort/timeout/budget/dedup/approval rules.

This is a must-have for real-world coding tasks: a single agent step often
issues several `Read` calls (e.g. read 5–10 source files) or independent
`Bash`/`Grep` calls. Sequential execution multiplies latency and makes the
agent feel sluggish.

- [x] `Loop::ToolBatch` — fiber-based parallel dispatch for one batch
  - spawn one fiber per approved, non-dedup tool call
  - collect results via `Channel(ToolBatchResult)` indexed by call order
  - preserve output order matching the original `tool_calls` array so the LLM sees consistent `tool_call_id` → result mapping
- [x] Pre-flight checks happen before spawning fibers
  - tool name resolution
  - same-step deduplication
  - streak-based deduplication (`Loop::DedupTracker`)
  - permission approval (including danger detection and session-scope cache)
- [x] Per-tool abort propagation
  - each running tool fiber observes `AbortController#throw_if_aborted!`
  - Ctrl+C cancels all in-flight tools, not just the current one
- [x] Per-tool grace timeout
  - reuse `Loop.run_with_grace_timeout` inside each fiber
  - a hung tool does not block the rest of the batch
- [x] Post-execution budgeting
  - `Context::Budget.budget` applied to each result independently
  - results appended to `Context::Memory` in original order
- [x] Headless and TUI event ordering
  - `tool_call_start` events still emitted before execution begins
  - `tool_result` events emitted as each fiber completes, but `Context::Memory` receives them in `tool_calls` order
  - TUI tool cards update incrementally as results arrive
- [x] Tests (`spec/loop/tool_batch_spec.cr`)
  - two concurrent calls complete faster than their sum
  - abort cancels all running fibers
  - one failing/timeout tool does not prevent other results
  - result order matches input order regardless of completion order

**Milestone:** `h2code.cr -p "read src/a.cr, src/b.cr, src/c.cr and summarize"` issues
three `Read` calls concurrently and returns the combined answer in one step
without blocking on each file.

### Phase 3: Polish + selectors + hooks (1-2 weeks)

Goal: Feature parity for daily single-agent use.

- [ ] All selector dialogs (model, permission, effort, session, theme) via SelectList
- [ ] Slash commands (/model, /new, /compact, /help, /exit, /status, /undo, /usage)
- [ ] Slash command autocomplete (simple name list)
- [ ] Session-scope approval caching (auto-resolve identical tool+args)
- [ ] Session title editing (`/rename`) and restore from archive (`/restore`)
- [ ] Plan mode (EnterPlanMode / ExitPlanMode tools)
- [ ] Compaction (LLM-based context summarization, re-render system prompt after)
- [ ] External editor (Ctrl+G — open $EDITOR)
- [ ] Word-level diff highlighting
- [ ] Light theme
- [ ] Syntax highlighting (basic: TS/JS/Python/bash/go/rust/json)
- [ ] Context % calculation + display
- [ ] `/add-dir` command — additional working directories + system prompt injection
- [ ] `/export-md` — export session to markdown
- [ ] Hooks engine (PreToolUse, PostToolUse, UserPromptSubmit, Stop)
  - shell command execution with JSON stdin
  - exit code 2 = block, JSON output = allow/deny/modify
  - 30s timeout, SIGTERM → SIGKILL
- [ ] Notifications subsystem (see "Notifications (system + sound + webhook)")
  - `AgentStatus` enum + `StatusTracker` (replaces `@agent_busy`/`@status`)
  - `Notify::Terminal` — OSC 9 desktop notification + BEL fallback (port of TS)
  - `Notify::Player` — cross-platform mp3/wav via OS-native players (afplay/aplay/pw-play/ffplay)
  - `Notify::Webhook` — custom POST request on status transition
  - `[notifications]` TOML config blocks (sound / terminal / webhook)
  - `TurnEnd` + `StatusChange` events; fire on `Working → Done` and `→ InputRequired`
- [ ] `/undo` with undo selector (preview turns to roll back)

**Milestone:** Can replace kimi-code TS for daily coding tasks.

### Phase 4: Advanced (as needed)

- [ ] MCP server support
- [ ] Goals (CreateGoal/GetGoal/UpdateGoal/SetGoalBudget)
- [ ] Background tasks (TaskList/TaskOutput/TaskStop)
- [ ] Background task execution (Ctrl+B)
- [ ] Subagent (Agent tool — simplified text card, not full lifecycle)
- [ ] Multi-agent fiber pool (run N agents in one process)
- [ ] OAuth refresh token handling
- [ ] Config migrations from TS version

### Phase 5: Full parity with TS version (future)

Goal: close every gap identified in the TS-vs-Crystal TUI comparison.

#### 5a. Missing slash commands (TS: ~35, Crystal: 15)

- [ ] `/model` — actual model switching (currently stub: "not yet available")
- [ ] `/provider` — actual runtime provider switching via SelectList (currently stub: "coming soon"). See "5g. Runtime provider switching".
- [ ] `/sessions` (`/resume`) — session picker + resume
- [ ] `/plan` — plan mode toggle
- [ ] `/swarm` — swarm mode toggle / run one task
- [ ] `/goal` — autonomous goals (status / pause / resume / cancel / replace / next)
- [ ] `/tasks` (`/task`) — background tasks browser
- [ ] `/effort` (`/thinking`) — thinking effort selector (low / medium / high)
- [ ] `/permission` — permission mode selector dialog
- [ ] `/settings` (`/config`) — TUI settings dialog
- [ ] `/btw` — forked side-agent question
- [ ] `/mcp` — MCP server status
- [ ] `/plugins` — plugin management
- [ ] `/experiments` (`/experimental`) — experimental feature flags
- [ ] `/reload` — reload session + config.toml + tui.toml
- [ ] `/reload-tui` — reload only tui.toml UI preferences
- [ ] `/init` — analyze codebase and generate AGENTS.md
- [ ] `/fork` — fork current session
- [ ] `/title` (`/rename`) — set / show session title
- [ ] `/usage` — session tokens + context window + plan quotas
- [ ] `/feedback` — send feedback
- [ ] `/editor` — set external editor for Ctrl-G
- [ ] `/login`, `/logout` (`/disconnect`) — authentication
- [ ] `/export-debug-zip` — debug ZIP archive export
- [ ] `/web` — open current session in Web UI and exit
- [ ] `/version` — version information

#### 5b. Missing built-in tools (TS: ~25, Crystal: 7)

- [ ] `ReadMedia` — images / base64
- [ ] `LineEndings` — line-ending normalization
- [ ] `EnterPlanMode` / `ExitPlanMode` — planning mode tools
- [ ] `CreateGoal`, `GetGoal`, `UpdateGoal`, `SetGoalBudget` — goal tools
- [ ] `Agent` (subagent) — simplified text card, not full lifecycle
- [ ] `AgentSwarm` — swarm tool
- [ ] `AskUser` — structured question to user
- [ ] `SkillTool` — skill activation
- [ ] `FetchURL` — fetch web content
- [ ] `WebSearch` — web search
- [ ] `TaskList`, `TaskOutput`, `TaskStop` — background task management
- [ ] `CronCreate`, `CronList`, `CronDelete` — cron jobs

#### 5c. Missing TUI components / panels

- [x] Thinking / reasoning display
- [ ] Plan-box (plan mode presentation)
- [ ] Goal-panel
- [ ] Swarm progress visualization (grid or simplified)
- [ ] Todo-panel display (tool exists, no UI panel)
- [ ] Usage-panel (tokens / context window / plan quotas)
- [ ] Subagent / agent-group cards
- [ ] Background-agent status
- [ ] MCP status-panel
- [ ] Plugins status-panel
- [ ] Skill-activation display
- [x] Step-summary
- [ ] Cron-message rendering
- [ ] SelectList-powered selector dialogs: provider, model, permission, effort, session, theme (interactive, not just text commands)
- [ ] Help-panel dialog
- [ ] Compaction dialog
- [ ] Undo-selector (preview turns to roll back)
- [ ] Tasks-browser
- [ ] Question-dialog (reverse-rpc adapter)
- [ ] Searchable-list / paging (large transcript navigation)

#### 5d. Missing rendering / polish

- [ ] Syntax highlighting (TS / JS / Python / bash / go / rust / json)
- [ ] Word-level intra-line diff highlighting
- [ ] Inline images (Kitty graphics protocol)
- [ ] Image paste (clipboard native bindings)
- [ ] Custom themes (tui.toml)

#### 5e. Missing supporting infrastructure (TUI-dependent)

- [ ] `Auth::OAuth` — Moonshot device-code / refresh-token flow (directory exists, empty)
- [ ] `Context::Compaction` — LLM-based context summarization
- [ ] `Context::Overflow` — 413 recovery (media-degrade → strip → compaction)
- [ ] `Context::Undo` — walk-back with compaction boundary stop
- [ ] `Loop::Retry` — rate-limit / error retry (429, 500s)
- [ ] `Config::Paths` — XDG-aware path resolution
- [ ] `Config::Proxy` — HTTP / SOCKS proxy from env vars
- [ ] `Config::ProviderConfig` — API key, endpoint, model aliases
- [ ] `Session::Index` — local session registry (list / get / filter, workspace-aware)
- [ ] `Session::Lifecycle` — create / fork / archive / restore / child (CLI-only)
- [ ] `Session::Replay` — resume from JSONL event log
- [ ] `Permission::Policies` — rule matching (path globs, command patterns)
- [ ] `Permission::Danger` — 8 danger patterns (rm -rf, sudo, pipe-to-shell, chmod 777, etc.)
- [ ] `Hooks::Engine` — PreToolUse / PostToolUse / UserPromptSubmit / Stop hooks
- [ ] `Prompt::Workspace` — cwd file tree (2 levels) in system prompt
- [ ] Plugins system runtime

#### 5f. Swarm + extras

- [ ] Agent swarm tool
- [ ] Swarm visualization (grid or simplified)
- [ ] Multi-agent fiber pool (run N agents in one process)
- [ ] OAuth refresh-token handling
- [ ] Config migrations from TS version

#### 5g. Runtime provider switching

`/provider` is currently a stub (`tui/app.cr`): it only prints `KNOWN_PROVIDERS`
as plain text and the message "Runtime provider switching is coming soon." There
is **no SelectList, no input handler, no callback, no persistence**. To make the
selector actually work, three layers must be implemented. The data source
(`LLM::KNOWN_PROVIDERS` + `known_provider?` validator, `llm/provider.cr`) and the
generic `SelectList` component (`tui/select_list.cr`) already exist but are unused
for providers.

##### Layer 1 — UI: wire SelectList into `/provider`
- [ ] Add an `@provider_list : SelectList` field to `App` (instantiate in `initialize`).
- [ ] Replace the text-only `when "/provider"` handler in `tui/app.cr` with
      `@provider_list.show("Select provider", LLM::KNOWN_PROVIDERS.map(&.name))`.
- [ ] Route `SelectList#handle_input` (↑/↓/Enter/Esc) in the `App` input loop
      while the list is visible; call `select_provider(name)` on Enter, `hide` on Esc.
- [ ] Mark the active provider (current `@provider_name`) in the rendered rows.

##### Layer 2 — Agent: make the provider swappable at runtime (main blocker)
- [ ] `Loop::Agent#provider` is an immutable `getter` (`loop/agent.cr:9`); add a
      `swap_provider(provider : LLM::Provider)` method (or a setter) that replaces
      the stored instance. Decide: hard-swap vs. agent restart.
- [ ] Add a provider-builder entry point callable from the running TUI (today
      `build_provider` runs once at startup in `src/h2code.cr`); expose a factory
      that reconstructs a `LLM::Provider` from a name + current config.
- [ ] `App#select_provider(name)` calls the factory, then `agent.swap_provider(...)`,
      updates `@provider_name`, and emits a confirmation message.

##### Layer 3 — Config: persist the choice
- [ ] After a switch, call `Config#save` to write `[provider] default = "<name>"`
      (`config/config.cr:save` exists; nothing in the TUI currently invokes it).
- [ ] Validate the name against `LLM.known_provider?` before saving.

##### Immediate scope vs. deferred

| Backend                     | Status                                  |
|-----------------------------|-----------------------------------------|
| Moonshot             | Default, in place.                      |
| Z.AI / Zhipu (GLM)          | **Now** — first runtime-switch target.  |
| Anthropic / OpenAI / Google | **OPTIONAL — not required now.**        |

Adding a backend only needs: a `Provider` subclass + a `KNOWN_PROVIDERS` entry
+ a `[provider.<name>]` config block. Anthropic/OpenAI/Google are tracked here as
deferred work and do NOT block the `/provider` selector or z.ai switching; leave
them out of scope until explicitly requested.

---

## Crystal Dependencies (shards)

```yaml
# shard.yml
dependencies:
  toml:
    github: cristanronelis/toml.cr
    # or: crystal-community/toml.cr
  markd:
    github: icyleaf/markd
  # Everything else from stdlib:
  # HTTP, JSON, YAML, File, Dir, Process, IO, Channel, Fiber, Regex, Logger
```

No native C extensions needed for Phase 1-3.
PTY (for background tasks) deferred to Phase 4.

---

## Compatibility with TS Version

| Aspect                | Compatible? | Notes                                            |
|-----------------------|-------------|--------------------------------------------------|
| Session JSONL         | Yes         | Same event types, same format — read/write both  |
| Session file layout   | Yes         | v2 layout `<workspace>/<session>/state.json`    |
| Config TOML           | Yes         | Same structure, same paths                       |
| Auth tokens           | Yes         | Same OAuth token storage, same refresh flow      |
| Tool schemas          | Yes         | Same JSON schema for tool definitions            |
| Model API             | Yes         | Same Moonshot Chat Completions endpoint              |
| Slash commands        | Partial     | Core set compatible, TS-only commands ignored    |
| `/sessions` REST API  | N/A         | Console-only: no HTTP server, no REST endpoints  |

Users can switch between kimi-code TS and h2code.cr freely — sessions and config
are interchangeable.

---

## Estimated Code Size

| Component                     | Est. Crystal LOC | TS equivalent LOC |
|-------------------------------|-------------------|-------------------|
| LLM provider                  | ~600              | ~3,000 (kosong)   |
| Agent loop                    | ~1,000            | ~2,500 (loop/)    |
| Tool-call dedup + abort       | ~300              | ~1,000            |
| Tools                         | ~1,200            | ~5,000 (builtin/) |
| Context (memory+budget+overflow+undo) | ~900    | ~5,000            |
| Permission (+ danger detect)  | ~400              | ~2,000            |
| Session/config (+ queue+proxy)| ~600              | ~4,000            |
| System prompt assembly        | ~500              | ~1,500            |
| Auth                          | ~200              | ~1,000            |
| Hooks engine                  | ~250              | ~800              |
| Notifications (status+sound+webhook) | ~500      | N/A (net-new)     |
| TUI core                      | ~2,500            | ~52,000           |
| TUI selectors/dialogs         | ~500              | (part of 52k)     |
| TUI commands                  | ~400              | ~3,000            |
| **Total**                     | **~9,350**        | **~120,000**      |

~13x less code for equivalent core functionality.

---

## Risk Register

| Risk                          | Impact | Mitigation                                  |
|-------------------------------|--------|---------------------------------------------|
| Crystal Windows support       | High   | Target Linux/macOS first. Windows is preview |
| TOML shard maturity           | Low    | Multiple shards exist; fallback to YAML     |
| Markdown parser perf          | Low    | `markd` exists; can optimize or write custom |
| Crystal preview_mt bugs       | Medium | Stay single-threaded (fibers only)          |
| Moonshot API changes              | Low    | Pin API version, add compatibility layer    |
| Terminal compat (raw mode)    | Medium | Test on common terminals (xterm, kitty, ghostty, iTerm2) |
| SOCKS proxy in Crystal        | Medium | Crystal stdlib has HTTP proxy; SOCKS needs custom connector |
| SIGWINCH edge cases (tmux)    | Low    | Force full re-render on resize; test in tmux/screen |
| Grace timeout kills orphaned children | Medium | Use process groups for kill on timeout |
| No pure-Crystal audio decoder | Low | Shell out to OS players (afplay/aplay/pw-play/ffplay); ~80 LOC dispatcher |
| Webhook endpoint down/flaky | Low | Async fiber + 5s timeout; swallow+log errors, never break a turn |

---

## Success Criteria

1. `h2code.cr -p "what files are in this repo?"` completes with < 15 MB RSS
2. Interactive TUI session feels responsive (streaming ≤ 50ms latency)
3. Session saved by h2code.cr can be resumed by kimi-code TS and vice versa
4. Config file shared between both versions without conflicts
5. 10 concurrent agents (separate processes) use < 150 MB total RSS
6. All Phase 3 features working and tested
