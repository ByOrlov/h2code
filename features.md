# h2code Features

This file describes the high-level features of h2code and the architecture
behind them. Each feature entry states the user-visible behaviour, the
trigger/start conditions, and the moving parts in the codebase.

## Full CI Integration (ping-pong with GitHub Actions / GitLab CI)

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

- GitHub Actions: the repo has a `.github/workflows` directory and
  `git remote get-url origin` points at github.com (the `gh` CLI is checked
  lazily on the first poll);
- GitLab CI: the repo has a `.gitlab-ci.yml` file and the origin remote
  points at gitlab.com, or at the host of the configured self-hosted
  endpoint (config `gitlab.endpoint` / `GITLAB_HOST` env).

No separate commit tool is needed — the observer piggybacks on every push,
exactly like sudo detection piggybacks on every elevated command.

### CI observer (`src/tools/ci.cr`)

`Tools::Ci` follows the `Cron.service` pattern: a module-level service seam
(`Ci.service`) with a `LiveCiService` implementation. Provider detection
(`detect_repo`) resolves the origin remote once per cwd into a `RepoInfo`
(provider + host + project path). Each watched commit gets an `Observer`
that polls on a **fixed 30 s interval** (no backoff; gives up after
60 minutes). There are three polling backends:

- **GitHub direct REST mode (priority)** — when a GitHub token is configured
  (config.json `github.token`, overridden by `GITHUB_TOKEN` / `GH_TOKEN` env),
  the observer polls `api.github.com` itself (`GithubApi` in `ci.cr`:
  `/repos/{owner}/{repo}/actions/runs?head_sha=…`, run logs via the 302
  redirect + zip extraction). No `gh` CLI and no browser login involved; the
  owner/repo pair comes from `git remote get-url origin`.
- **gh CLI fallback** — without a token, `gh run list -c <sha> --json …` /
  `gh run view <id> --log-failed` are used (requires an interactive gh login).
- **GitLab REST mode** — GitLab repos are polled through the GitLab v4 API
  (`GitlabApi` in `ci.cr`: `/projects/{group%2Fproject}/pipelines?sha=…`,
  failure logs via the first hard-failed job's `/jobs/{id}/trace`). The token
  (config `gitlab.token`, overridden by `GITLAB_TOKEN` /
  `GITLAB_PRIVATE_TOKEN` env, settable via `/gitlab token`) is **optional** —
  public projects answer anonymous pipeline queries. When access is denied
  (401/403/404 — private projects answer 404 to anonymous queries) and the
  `glab` CLI is installed (probed once), the poll is retried through
  `glab api --hostname <host> -X GET …`, so a glab login covers private
  projects without any token in h2code's config. Self-hosted
  instances: set `gitlab.endpoint` (or `GITLAB_HOST`) to the base URL and
  remotes on that host are treated as GitLab.

Run aggregation (shared by the backends): pending while any run/pipeline is
in progress or none is registered yet; failure on any `failure`/`cancelled`/
`timed_out`/`action_required`/`startup_failure` GitHub conclusion or
`failed`/`canceled`/`manual` GitLab status; success otherwise. Transient
poll failures (gh/glab exit != 0, non-JSON output, HTTP 5xx/rate limit) are
retried — up to `MAX_CONSECUTIVE_FAILURES` in a row — before the observer
gives up with an "error", so the wait line never disappears on a blip. On
failure the observer also captures an excerpt of the failed-step logs / the
failed job's trace.

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
  `link: <url>` to the commit's checks page
  (`https://github.com/{owner}/{repo}/commit/{sha}/checks` on GitHub,
  `https://{host}/{group}/{project}/-/commits/{sha}` on GitLab — resolved
  from the origin remote and empty when the repo info is unknown),
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

## Worktree Isolation (`/fork` + `/merge`)

Fork a session into an isolated git worktree, work on a feature without
touching the main checkout, then fold the branch back with the agent's
help. No registry is kept — the deterministic directory layout and git's
own worktree state are the source of truth.

### `/fork`

Creates a git worktree plus a fresh branch `h2code-<session-id>` cut from
the **current branch** (not master) and checked out under
`~/.h2code/worktree/<encoded-project-path>/<branch>` (`/home/oleg/p1` ->
`home/oleg/p1`, `C:\Users\oleg\p1` -> `c/users/oleg/p1`). Then:

1. the conversation is forked into a new session whose `cwd` is the
   worktree dir (`Session::Lifecycle.fork`, `src/session/lifecycle.cr`);
2. the path-bound tools (`Read`, `Write`, `Edit`, `Glob`, `Grep`, `Bash`,
   `ApplyPatch`, `WaitForCI`) and both subagent runners retarget their
   `work_dir` at the worktree (`rebind_path_tools` in `src/h2code.cr`).

The switch only ever happens at the idle boundary — `/fork` refuses to
run while a turn is in flight, so no in-flight turn observes the cwd
change. Detached HEAD or a non-git cwd is reported and aborts the fork.

### `/merge`

Injects a synthetic user prompt telling the agent to merge the worktree
branch back into the original repository (resolved via
`git rev-parse --git-common-dir`) using Bash with an explicit `cwd`.
When that turn ends (`EventController` TurnEnd handler):

- branch fully merged + clean worktree → worktree removed
  (`git worktree remove`), branch deleted (`git branch -d`, refuses
  unmerged), tools/session retargeted back at the original checkout;
- merged but dirty → worktree kept for review (uncommitted files are
  never destroyed);
- not fully merged → kept, with a hint to re-run `/merge` or finish
  manually.

### Management and cleanup (`src/worktree.cr`)

- `/fork list` — every h2code worktree with branch, merged/dirty status,
  age and path.
- `/fork clean` — removes fully merged, clean worktrees; reports and
  keeps the unmerged or dirty ones.
- Age-based GC at TUI startup: fully merged, clean worktrees untouched
  for 14 days are removed; unmerged work is never collected.

