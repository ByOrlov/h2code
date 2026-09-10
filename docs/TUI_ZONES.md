# TUI Rendering: Two-Zone Model

## Problem

The main terminal screen buffer has no scrollback API. The program cannot
detect when the user scrolls up, cannot rewrite lines that have scrolled into
the scrollback, and cannot move the viewport up. Any attempt to diff the
entire line array and rewrite changed lines — including lines that already
scrolled off — causes visual corruption when the user scrolls during active
LLM output.

## Solution: two zones

Split the rendered output into two independent zones with different
lifecycle rules:

```
┌──────────────────────────────────────┐
│  LOG (append-only)                   │   Written once, never rewritten.
│  - user message                      │   Grows downward; the terminal
│  - thinking block                    │   pushes old lines into scrollback
│  - tool result                       │   naturally as the active zone
│  - assistant message                 │   below it grows.
│  - tool result                       │
│  - step summary                      │
│  ...                                 │
├──────────────────────────────────────┤
│  ACTIVE ZONE (repainted every frame) │   Finite set of lines (5–15).
│  ⠹ Running Edit...                   │   Only this region is ever
│  ● streaming text...                 │   rewritten with cursor moves
│  ┌──────────────────────────────┐    │   + \e[2K / \e[J.
│  │ editor input                │    │
│  └──────────────────────────────┘    │
└──────────────────────────────────────┘
```

### LOG zone

Append-only. Every finalized piece of output — user messages, assistant
messages, tool results, thinking blocks, step summaries — is appended here
once and never touched again.

The log grows downward. When the total line count exceeds the terminal
height, the terminal scrolls naturally: each `\r\n` at the bottom of the
visible area pushes the top log line into the scrollback. The program does
not control this and does not need to — lines in the scrollback are
immutable history.

### ACTIVE zone

The bottom N lines of the rendered output. This is the only region that
changes between frames. It contains:

- **Spinner + status line** — animated (`⠋`→`⠙`→`⠹`), updates every 80 ms.
- **Live thinking preview** — last 2 lines of the streaming thinking text.
- **Streaming assistant text** — the in-progress assistant response.
- **CI observer wait line** — animated pulsing circle (○→◐→◑→◉→●), shown
  while a pushed commit's GitHub Actions build is pending. Bracketed by the
  `:ci` active-zone key (`declare_active`/`release_active`); on completion
  the outcome is appended to the log, satisfying the release invariant. See
  features.md ("Full CI integration").
- **Background-task wait lines** — same pulsing-circle treatment, one line
  per running background task (Bash/Agent `run_in_background`). Bracketed by
  the `:bg_tasks` active-zone key; fed by `refresh_bg_tasks!`, which polls
  the task registry from the main loop (~4x/sec — tasks have no push events
  into the TUI). When a task leaves the running snapshot, a one-line summary
  is appended to the log, satisfying the release invariant.
- **Editor box** — the input field, cursor, command hints.

The active zone is bounded: 5–15 lines depending on state. Because it is
always at the bottom of the visible area, all cursor moves stay within the
visible region and never reach into the scrollback.

## Transitions

When a streaming element finalizes, its lines migrate from the active zone
to the log:

| Event | Log | Active zone |
|---|---|---|
| `thinking_delta` stream finalizes | Thinking block appended | Live preview removed |
| `assistant_text` (stream ends) | Assistant message appended | Streaming text cleared |
| `tool_result` arrives | Tool result appended | Spinner/status updated |
| `tool_call_start` | (nothing) | Spinner/status updated |
| `turn_end` | (nothing) | Spinner stopped, status cleared |
| TodoList reaches all-`done` | `todo_snapshot` (frozen panel) appended | Live panel cleared |

After each transition, the active zone is rewritten from scratch. No
already-written log line is ever modified.

The streaming assistant block carries a **high-water mark**: the block is
re-rendered every frame over the full buffer, and markdown re-interpretation
of already-received tokens is not monotonic in line count (an open `**`/`*`/
`~~`/`` ` `` renders raw and wider, so the closing delimiter can re-wrap a
paragraph onto fewer lines; a bare ordered-list digit renders as a paragraph
for one frame). Since the active zone must never shrink, the block is padded
with blank lines to the tallest height it has reached during the stream, and
the residual deficit versus the finalized log rendering is compensated with
blank `spacer` log lines when the stream migrates
(`EventController#flush_streaming_text!`). See
`spec/tui/streaming_markdown_spec.cr` for the char-by-char reproducers.

The TodoList migration is special: the live todo panel is active-zone chrome
polled every frame, not a transcript entry, so it has no natural migration
path. When every item becomes `done`, the TUI freezes the rendered panel into a
`todo_snapshot` message (drawn like the live panel but without the active-zone
left bar — the log is immutable history) and clears the tool's state — the
completed plan scrolls into history and a fresh list can be started. See
`App#snapshot_todo_if_complete!`.

## Rendering algorithm

Inputs per frame:

- `log_lines` — finalized lines that should be visible above the active zone.
- `active_lines` — transient lines that form the active zone.
- `rows` — terminal height.

```
total         = log_lines.size + active_lines.size
viewport_top  = max(0, total - rows)
active_visible = min(active_lines.size, rows)
active_start  = total - active_visible
```

### Full render

Used on the first frame, after a resize, or whenever the viewport moves up
(`viewport_top` decreased). It is the only safe way to recover a consistent
screen state because the terminal cannot scroll down on its own.

```
cursor_home
for each line in log_lines + active_lines:
    newline               # except before the first line
    clear_line            # \e[2K
    write(line)
clear_below               # \e[J — erase leftover rows from a taller previous frame

hardware_cursor_row = max(0, total - 1)
prev_viewport_top   = viewport_top
prev_log_count    = log_lines.size
prev_active_visible = active_visible
log_zone.reset
log_zone.mark_flushed(log_lines.size)
```

`\e[2J` (full-screen erase) is intentionally avoided — it blanks the entire
visible area before new content is written and causes flicker. Rewriting in
place with `\e[K` / `\e[J` never produces a fully blank frame. `\e[3J` is also
avoided because it destroys the user's scrollback history.

### Incremental render

Used on every subsequent frame. It performs three small, independent steps:

1. **Scroll up if the viewport moved down.**

   ```
   scroll_delta = viewport_top - prev_viewport_top
   if scroll_delta > 0:
       move cursor to the bottom row of the visible area
       emit \r\n * scroll_delta
       hardware_cursor_row = viewport_top + min(rows, total - viewport_top) - 1
   ```

2. **Emit any new log lines.**

   The log zone tracks how many log lines have already been flushed
   (`log_zone.flushed`). Only the delta is written:

   ```
   new_log_count = log_lines.size - log_zone.flushed
   if new_log_count > 0:
       write_from = max(log_zone.flushed, viewport_top)
       move cursor to write_from
       emitted = log_zone.flush(port, log_lines)
       hardware_cursor_row = write_from + emitted
   else:
       log_zone.mark_flushed(log_lines.size)
   ```

   To avoid pushing the active zone off-screen in a single frame, the log
   throttle caps each flush to:

   ```
   chunk = max(1, rows - active_lines.size)
   ```

3. **Repaint the active zone at the bottom.**

   ```
   move cursor to active_start
   visible = active_zone.render(port, active_lines, rows, prev_active_visible)
   prev_active_visible = visible
   update hardware_cursor_row based on whether the zone shrank
   ```

   `ActiveZone#render` always draws from the current cursor row downward. If
   `active_lines.size > rows` it draws only the bottom `rows` lines
   (tail-clipping). If `prev_active_visible > visible` it issues `clear_below`
   after the new content to erase the stale rows below.

## Why this eliminates scroll bugs

1. **Log is immutable** — lines pushed into the scrollback are never
   rewritten, so no duplicates or corrupted content appears when scrolling up.
2. **Active zone is always visible** — all cursor moves are relative to the
   bottom of the visible area and stay within a small range (5–15 lines).
3. **No full-array diff** — the active zone is fully repainted every frame
   with `\e[2K`, so `merge_turn_steps` or message finalization cannot trigger
   a false "everything changed" repaint.
4. **No manual blank/scroll simulation** — freed rows are simply erased with
   `\e[J`; the terminal handles real scrolling via `\r\n` at the bottom row.
5. **Only three numbers track the previous frame** — `prev_viewport_top`,
   `prev_log_count`, and `prev_active_visible`. There is no height history,
   no blank counter, and no consume/shift state to desynchronize.
