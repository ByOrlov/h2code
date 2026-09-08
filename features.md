# h2code Features

This file describes the high-level features of h2code and the architecture
behind them. Each feature entry states the user-visible behaviour, the
trigger/start conditions, and the moving parts in the codebase.

## Full CI Integration (ping-pong with GitHub Actions)

Automatically observe the CI status of commits the agent pushes, keep a live
"Waiting for CI for commit <sha>" indicator per pending commit in the active
zone, guard the TUI exit flow while a build is unchecked, and hand the result
back to the agent — success is logged into the session history, failure
starts a fix-up turn.

### Trigger (sudo-detect style)

The hook lives in the Bash tool (`src/tools/bash.cr`): after a command that
contains a `git push` segment exits successfully, the tool calls
`Ci.service.try_observe_push(command, cwd)`. The observed repository is the
one targeted by the command — `git -C <dir> push` watches `<dir>`, not the
session cwd. Observation starts only when all of these hold:

- the repo has a `.github/workflows` directory (GitHub Actions present);
- `git remote get-url origin` points at github.com;
- the `gh` CLI can query the commit (checked lazily on the first poll).

No separate commit tool is needed — the observer piggybacks on every push,
exactly like sudo detection piggybacks on every elevated command.

### CI observer (`src/tools/ci.cr`)

`Tools::Ci` follows the `Cron.service` pattern: a module-level service seam
(`Ci.service`) with a `LiveCiService` implementation. Each watched commit gets
an `Observer` that polls on a **quadratic backoff** (`5·n²` seconds, capped at
60s; gives up after 30 minutes). There are two polling backends:

- **Direct REST mode (priority)** — when a GitHub token is configured
  (config.json `github.token`, overridden by `GITHUB_TOKEN` / `GH_TOKEN` env),
  the observer polls `api.github.com` itself (`GithubApi` in `ci.cr`:
  `/repos/{owner}/{repo}/actions/runs?head_sha=…`, run logs via the 302
  redirect + zip extraction). No `gh` CLI and no browser login involved; the
  owner/repo pair comes from `git remote get-url origin`.
- **gh CLI fallback** — without a token, `gh run list -c <sha> --json …` /
  `gh run view <id> --log-failed` are used (requires an interactive gh login).

Run aggregation (shared by both backends): pending while any run is in
progress or none is registered yet; failure on any `failure`/`cancelled`/
`timed_out`/`action_required`/`startup_failure` conclusion; success
otherwise. Transient poll failures (gh exit != 0, non-JSON output, HTTP
5xx/rate limit) are retried — up to `MAX_CONSECUTIVE_FAILURES` in a row —
before the observer gives up with an "error", so the wait line never
disappears on a blip. On failure the observer also captures an excerpt of
the failed-step logs.

On a terminal state the service:

1. fires `on_update` (TUI: log line + release the active-zone wait line);
2. persists a `ci.status` event into the session wire log (audit trail;
   ignored on replay);
3. delivers a `<notification>` prompt (unless a `WaitForCI` call claimed the
   observer): **failure/error/timeout** wake the agent to fix the build;
   **success** is log-only — no turn is spawned.

### Active zone line + exit guard (TUI)

- While observers are pending, `render_controller.cr` renders one
  `Waiting for CI for commit <sha> (<elapsed>s)` line per pending observer
  (every push gets its own observer, oldest commit first) with a pulsing
  circle (`Spinner::CI_BULLET_FRAMES`), followed by a clickable
  `link: <url>` to the commit's Actions checks page on github.com
  (`https://github.com/{owner}/{repo}/commit/{sha}/checks`, resolved from
  the origin remote and empty when the owner/repo pair is unknown),
  bracketed by `declare_active(:ci)` /
  `release_active(:ci)` so the zone-balance invariant holds. A settled
  commit's outcome is logged even while other commits are still pending;
  the `:ci` key is released only when no observer is pending. Transient
  `gh` poll failures are retried (up to `MAX_CONSECUTIVE_FAILURES` in a
  row) so the wait line never disappears before a terminal status. The
  animation advances even when the agent is idle (added to the spin-phase
  wake condition in `app.cr`).
- While CI is pending, Ctrl+D / Ctrl+C / `/exit` still confirm-exit, but the
  footer is replaced with an explicit warning that a CI check is in flight —
  the user must manually press again to force quit (i18n key
  `ui.ci_exit_warning`).

### WaitForCI tool (`src/tools/wait_for_ci.cr`)

An agent-callable tool that blocks (honouring ESC via `abort_check`) until the
observer for HEAD — or an explicit `sha` — reaches a terminal state, then
returns the outcome (with the failure-log excerpt on failure). Calling it
claims the observer, suppressing the automatic notification since the tool
result itself lands in the transcript as the `tool.result`.

### Wiring

- Shared agent setup (`src/h2code.cr`): requires + `WaitForCI` registration +
  a default `LiveCiService` for all run modes.
- TUI wiring attaches `delivery` (the same `deliver_external_prompt` callback
  cron/background tasks use), the session `store`, and an `on_update` hook
  that emits the final status line into the log zone.
- ACP server registers `WaitForCI` too and shares the service.
