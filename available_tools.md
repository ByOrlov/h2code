# Available Tools

Reference for every built-in tool the agent exposes. MCP servers register
additional proxy tools under the `mcp__<server>__<tool>` namespace; they are
not listed here.

Tools are gated by the permission mode (`manual` / `auto` / `yolo`). The
"Approval" column is the default behavior in `manual`/`auto` modes; `yolo`
auto-approves everything.

## Files

### Read
Read a text file with 1-based line-number prefixes. Supports paging via
`line_offset` / `n_lines` (also negative offsets from EOF), rejects non-UTF-8
and binary files, and blocks sensitive paths (`.env`, SSH keys, credential
stores). Relative paths resolve against the working directory.

- **Approval:** auto-approved (read-only).

### Write
Create a file or replace its content entirely (append mode available).
Creates parent directories automatically. CRLF note: pass LF; the write
round-trips through the line-ending model view.

- **Approval:** ask.

### Edit
Exact string replacement in one file. `old_string` must appear exactly once
unless `replace_all: true`. The old/new strings must match the Read output
view verbatim (no line-number prefix). For pure-CRLF files pass LF and Edit
writes CRLF back.

- **Approval:** ask.

### ApplyPatch
Multi-file diff editing in the V4A patch format (codex-compatible):

```
*** Begin Patch
*** Add File: path/new.txt
+line
*** Update File: path/existing.py
*** Move to: path/renamed.py
@@ class Foo:
 context
-removed
+added
*** End of File
*** Delete File: path/old.txt
*** End Patch
```

A single call can add, update, move, and delete multiple files. The patch is
fully validated against current file contents before anything is written, so
a bad hunk leaves the tree untouched. Context matching is exact with
trailing/leading-whitespace tolerance; chunks within a hunk apply in file
order. Prefer this over many Edit calls when changing several files at once.

- **Approval:** ask; permission rules can match per-path (`ApplyPatch(src/*)`).
- **Plan mode:** blocked outright.

## Search

### Glob
Find files by glob pattern (e.g. `src/**/*.cr`), sorted by modification time.
Respects ignore files; capped result count.

- **Approval:** auto-approved (read-only).

### Grep
Search file contents with ripgrep. Output modes: `content`, `files_with_matches`,
`count_matches`. Supports `-i`, multiline, glob filter, context lines
(`-A`/`-B`/`-C`), offsets and head limits. Hidden files are searched by
default; VCS metadata and secrets are filtered out.

- **Approval:** auto-approved (read-only).

## Execution

### Bash
One-shot shell command with combined stdout/stderr capture and a timeout
(default 120s). `run_in_background: true` returns a `task_id` immediately and
streams output to a file — inspect with TaskList / TaskOutput / TaskStop.
Dangerous commands (recursive delete, sudo, pipe-to-shell, ...) are flagged
in the approval panel.

- **Approval:** always ask (unless yolo).

### InteractiveShell
Persistent shell sessions whose stdin stays writable — a dialogue with a
long-running process instead of a one-shot command. Use for REPLs
(`python3 -i`, `irb`, `node`), debuggers (`gdb`, `pdb`), dev servers,
`psql` / `redis-cli`.

Actions:

| Action | Params | Description |
|---|---|---|
| `start` | `command`, `cwd?` | Spawn the program; returns `session_id` and its banner. |
| `write` | `session_id`, `data` | Send raw bytes to stdin. Include a trailing `\n` to submit a line. |
| `read` | `session_id`, `wait_ms?` (default 250, max 10000) | Output produced since the previous read, waiting up to `wait_ms`. |
| `close_input` | `session_id` | Send EOF; programs reading to end-of-input exit on their own. |
| `kill` | `session_id` | Terminate the session. |
| `list` | — | Live sessions with status. |

Typical flow: `start` → `read` (banner) → `write "command\n"` → `read`
(result) → ... → `kill`. Up to 16 concurrent sessions; each keeps a 1 MiB
output ring. Sessions are killed when the agent exits; they are **not**
background tasks (TaskList / TaskStop do not manage them).

- **Approval:** ask (treated like Bash).

### TaskList / TaskOutput / TaskStop
Background task management for `Bash(run_in_background: true)` runs.
TaskList shows running/finished tasks; TaskOutput returns an output snapshot
(`block: true` waits for completion, default preview 30s); TaskStop cancels.
Completion notifications are delivered automatically.

- **Approval:** TaskList/TaskOutput auto-approved; TaskStop ask.

## Context & session

### CurrentTime
Local time (RFC 3339 with UTC offset), UTC, and Unix epoch milliseconds.
The system-prompt timestamp goes stale in long sessions — use this for
anything time-sensitive (expiry checks, cron schedules, freshness).

- **Approval:** auto-approved (read-only).

### GetContextRemaining
Context-window budget: tokens used, window size, tokens remaining, percent
used, and a near-limit warning before automatic compaction fires. Use it to
pace long tasks (targeted reads instead of whole files, trimmed outputs).

- **Approval:** auto-approved (read-only).

### select_tools
Progressive disclosure: dynamically load tool subsets into the session
(lowercase name by convention). Reduces prompt size when only a few tools
are needed.

## Agents & delegation

### Agent
Run a subagent with a scoped profile (`agent`, `coder`, `explore`, ...) and
get a conclusion back instead of a pile of file dumps. Foreground by
default; background mode supported.

### AgentSwarm
Launch many subagents over different inputs from one prompt template
(`{{item}}` placeholder). Same-type parallel fan-out.

### TodoList
Structured task tracking for multi-step work (`pending` / `in_progress` /
`done`). Renders in the TUI todo panel.

- **Approval:** auto-approved.

### Skill
Invoke registered skills from the skill listing (blocking requirement when a
skill matches the user's request).

## Planning, goals & user interaction

### EnterPlanMode / ExitPlanMode
Plan mode: read-only exploration, plan written to a plan file, user approval
via ExitPlanMode before implementation. Write/Edit/ApplyPatch and mutating
tools are blocked while active.

### AskUserQuestion
Structured questions with 2–4 options (multi-select supported) to resolve
ambiguity or get implementation preferences. Background mode available.

### CreateGoal / GetGoal / UpdateGoal / SetGoalBudget
Durable goals with verifiable completion criteria, lifecycle management
(`active` / `complete` / `blocked`), and turn/token/time budgets.

## Web

### FetchURL
Fetch a public http/https URL and return extracted text or the raw body.
Private/loopback addresses are not fetched; auth walls are detected.

### WebSearch
Web search with results (title, URL, summary, recency filters).

## Scheduling

### CronCreate / CronList / CronDelete
5-field cron schedules in local time that deliver a prompt to the agent at
each fire time (recurring or one-shot). Jobs auto-expire after 7 days of
inactivity; missed fires coalesce.

- **Approval:** CronCreate/CronDelete ask; blocked in plan mode.

## Media

### ReadMediaFile
View an image or video file, with automatic downsampling, region crops at
full fidelity, and per-call byte limits.

## MCP

- **`mcp__<server>__<tool>`** — proxy tools registered by configured MCP
  servers at connect time. Availability depends on the session's MCP
  configuration.
