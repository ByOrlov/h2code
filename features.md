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

- GitHub Actions: the repo has a `.github/workflows` directory and a
  checked remote points at github.com (the `gh` CLI is checked lazily on
  the first poll);
- GitLab CI: the repo has a `.gitlab-ci.yml` file and a checked remote
  points at gitlab.com, or at the host of the configured self-hosted
  endpoint (config `gitlab.endpoint` / `GITLAB_HOST` env);
- the checked remotes are the ones the pushed commit actually landed on:
  right after the push, `git branch -r --contains <sha>` names them from
  the freshly updated remote-tracking refs (origin is the fallback), so a
  `git push gitlab master` in a repo whose origin is GitHub — with both
  CI configs in the tree — is observed on GitLab, where the build runs;
- a manual binding wins over everything: `/ci type gitlab` (or
  `/ci type github <host>`) records the repository and its host in
  `~/.h2code/ci.json` (`hosts` + `urls` sections), and from then on every
  repository from that host is detected as that provider — a self-hosted
  GitLab needs no `gitlab.endpoint` config. `/ci type` alone lists the
  effective binding per remote;
- the pushed branch is covered by a workflow: some workflow's `on: push`
  trigger matches the branch (`branches` / `branches-ignore` filters,
  fnmatch globs; no filter covers every branch). A push to a ref no
  workflow triggers on never produces a CI status, so instead of parking
  a wait line until the timeout the observer is skipped and an info
  notification explains why. GitLab-bound pushes skip this gate —
  `.gitlab-ci.yml` `workflow:rules` are not parsed and count as covered.
  Undecidable input (detached HEAD, unparsable YAML) also counts as
  covered. `WaitForCI` applies the same gate to its default HEAD path.

No separate commit tool is needed — the observer piggybacks on every push,
exactly like sudo detection piggybacks on every elevated command. A manual
start is also available: the `/ci [<commit>]` slash command (`/ci check
[<commit>]` is the same thing spelled out; `cmd_ci` in
`src/tui/command_controller.cr`) resolves the argument through
`git rev-parse <commit>^{commit}` (short SHA, branch and tag all work; no
argument observes HEAD) and calls `Ci.service.observe` — same eligibility
gate as pushes, and from there the exact same wait-line / notification flow.

### CI observer (`src/tools/ci.cr`)

`Tools::Ci` follows the `Cron.service` pattern: a module-level service seam
(`Ci.service`) with a `LiveCiService` implementation. Provider detection
(`detect_repo`) resolves the repo into a `RepoInfo` (provider + host +
project path): with a sha in hand (post-push) the remotes whose tracking
refs contain the commit are checked first, then origin; the result is
cached per cwd and refreshed on every push. Each watched commit gets an
`Observer`
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
  failure logs via the first hard-failed job's `/jobs/{id}/trace`). The
  `?sha=` filter is not trusted alone: every returned pipeline row carries
  the `sha` of its commit, and rows whose `sha` differs from the observed
  one are dropped client-side — a verdict always belongs to the pushed
  commit, never to whatever else the instance mixes into the listing. The
  token
  (config `gitlab.token`, overridden by `GITLAB_TOKEN` /
  `GITLAB_PRIVATE_TOKEN` env, settable via `/gitlab token`) is **optional** —
  public projects answer anonymous pipeline queries. When access is denied
  (401/403/404 — private projects answer 404 to anonymous queries) and the
  `glab` CLI is installed (probed once), the poll is retried through
  `glab api --hostname <host> -X GET …`, so a glab login covers private
  projects without any token in h2code's config. When neither a token nor
  glab can authenticate (401/403/404), the observer settles as **error on
  the first poll** — an access denial never resolves by retrying, so the
  wait line disappears immediately with a hint to set a token / log in
  with glab instead of waiting out the failure threshold or MAX_WAIT_S.
  Self-hosted
  instances: set `gitlab.endpoint` (or `GITLAB_HOST`) to the base URL and
  remotes on that host are treated as GitLab — or bind the host once
  with `/ci type gitlab` (stored in `ci.json`, see below).

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
  `https://{host}/{group}/{project}/-/commit/{sha}` on GitLab — resolved
  from the remotes and empty when the repo info is unknown; on GitLab the
  link is repointed to the commit's pipeline
  `…/-/pipelines/{id}` as soon as a poll sees one),
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

## Fork Sandbox Isolation (`/fork` + `/merge`)

Fork a session into an isolated **standalone git clone**, work on a feature
without touching the main checkout, then fold the branch back with the agent's
help. No registry is kept — the deterministic directory layout is the source
of truth.

A standalone clone (`git clone --no-hardlinks`) owns its object database, refs,
reflog and config outright, unlike a linked worktree which shares all of that
with the main repository. Destructive commands run inside the sandbox
(`git branch -D`, `git update-ref`, `git gc --prune=now`, ...) cannot poison
the original repository or its other branches — the isolation is structural,
at the filesystem level (no shared inodes). The clone keeps the local source
repo on the `h2code-main` remote so `/merge` can resolve it, while `origin`
inherits the source repo's own remote URL (GitHub/GitLab) — so CI observation
(which keys off `git remote get-url origin`) and pushes to the shared remote
work in the sandbox exactly like in the original checkout. Sources without a
remote of their own keep the legacy layout (`origin` = local source path;
`main_repo` falls back to it).

### Write confinement (tool level)

Beyond the structural isolation, the tools themselves refuse to touch the
original repository from a fork session (`H2code::Sandbox`, `src/sandbox.cr`).
The sandbox's local source repo is resolved once per work dir (cached) and
then:

- `Write` / `Edit` / `ApplyPatch` (via `PathAccess` Mode::Write) reject any
  target inside the original repo — lexically and through a realpath pass, so
  a symlink planted in the sandbox cannot tunnel a write through;
- `Bash` and `InteractiveShell` reject a `cwd` inside the original repo and
  any command text referencing its absolute path (best-effort lexical match
  on path boundaries; references to the sandbox's own path are exempt
  because the encoded layout mirrors the repo's segments);
- reads, Grep and Glob of the original repo stay allowed.

The single exception is the `/merge` turn: the TUI raises
`Sandbox.merge_active` for that turn (an explicit user command whose purpose
is to write into the original repo) and lowers it at turn end.

### Sibling confinement (all sessions)

Two further guards apply to every session — fork or not — and are never
lifted, not even during `/merge`:

- the h2code session store (`~/.h2code/sessions/**`) is private session
  data: no tool ever writes there (any session's, its own included; tool
  plumbing such as background-task logs writes outside the tool gate and
  keeps working). Reading it with `Read` / `Grep` stays allowed;
- other sessions' sandboxes under `~/.h2code/worktree/**` are off-limits:
  only the session's own work tree is writable. Shared work folds back
  through the original repository.


### `/fork`

Creates a standalone clone plus a fresh branch `h2code-<session-id>` cut from
the **current branch** (not master) and checked out under
`~/.h2code/worktree/<encoded-project-path>/<branch>` (`/home/oleg/p1` ->
`home/oleg/p1`, `C:\Users\oleg\p1` -> `c/users/oleg/p1`). Then:

1. the conversation is forked into a new session whose `cwd` is the
   sandbox dir (`Session::Lifecycle.fork`, `src/session/lifecycle.cr`);
2. the path-bound tools (`Read`, `Write`, `Edit`, `Glob`, `Grep`, `Bash`,
   `ApplyPatch`, `WaitForCI`) and both subagent runners retarget their
   `work_dir` at the sandbox (`rebind_path_tools` in `src/h2code.cr`).

The switch only ever happens at the idle boundary — `/fork` refuses to
run while a turn is in flight, so no in-flight turn observes the cwd
change. Detached HEAD or a non-git cwd is reported and aborts the fork.

### `/merge`

Injects a synthetic user prompt telling the agent to fold the sandbox
branch back into the original repository (resolved via the clone's
`h2code-main` remote) using Bash with an explicit `cwd`:

1. `git fetch <sandbox> +<branch>:<branch>` — the branch lives only in
   the clone, so it is brought over first;
2. `git merge <branch> --no-edit`, resolving conflicts if any.

When that turn ends (`EventController` TurnEnd handler):

- branch fully merged + clean sandbox → sandbox removed (plain `rm -r`,
  nothing shared to deregister), branch deleted (`git branch -d`, refuses
  unmerged), tools/session retargeted back at the original checkout;
- merged but dirty → sandbox kept for review (uncommitted files are
  never destroyed);
- not fully merged → kept, with a hint to re-run `/merge` or finish
  manually.

### Management and cleanup (`src/worktree.cr`)

- `/fork list` — every h2code sandbox with branch, merged/dirty status,
  age and path.
- `/fork clean` — removes fully merged, clean sandboxes; reports and
  keeps the unmerged or dirty ones.
- `/fork forceclean` — removes EVERY sandbox (merged or not, dirty or
  not; branches force-deleted) and unlinks — never deletes — the sessions
  that lived in them: each linked session's `sandbox_folder` is cleared,
  so it survives and resumes in its plain checkout cwd. The sandbox the
  current session works in is kept.
- Age-based GC at TUI startup: fully merged, clean sandboxes untouched
  for 14 days are removed; unmerged work is never collected.
- Legacy linked worktrees created by older versions (marked by a `.git`
  file instead of a `.git` directory) are still listed, merged and
  cleaned up by the same commands.

