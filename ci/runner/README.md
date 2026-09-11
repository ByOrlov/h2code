# GitLab runner (self-hosted, Docker executor)

Runs the `.gitlab-ci.yml` jobs of this repo on your own machine. The runner
itself lives in a Docker container; every job then starts as a sibling
container on the host Docker (via the socket mount), so the host only needs
Docker — no Crystal install.

## Setup

1. Start the runner container:

   ```
   cd ci/runner
   docker compose up -d
   ```

2. Build the CI job image (once per machine hosting a runner; jobs reference
   it via `image:` in `.gitlab-ci.yml` and the runner reuses it with
   `pull_policy = if-not-present`):

   ```
   ./build-image.sh          # → h2code-ci:1.21.0 (crystal + ripgrep + rake)
   ```

3. Get a runner token from GitLab: project → **Settings → CI/CD → Runners →
   New project runner** (leave "run untagged jobs" enabled), copy the
   authentication token (`glrt-…`).

4. Register:

   ```
   ./register.sh https://gitlab.com <token>        # or your self-hosted URL
   ```

   The script registers a Docker-executor runner with the default image
   `crystallang/crystal:1.21.0`, `pull_policy = if-not-present`, and
   `concurrent = 2` so the `check` and `integration` jobs run in parallel.

## Operations

- Logs: `docker compose logs -f runner`
- Verify registration: `docker compose exec -T runner gitlab-runner verify`
- Stop/start: `docker compose down` / `docker compose up -d`

## Files

- `docker-compose.yml` — the runner service (socket mount + `./data` state).
- `Dockerfile` + `build-image.sh` — the CI job image (`h2code-ci:1.21.0`).
- `register.sh` — one-time registration helper.
- `data/` — runner state incl. `config.toml` with the token; **gitignored**.

## Reuse across runs

- Job image: built once, reused (`if-not-present`) — no per-job `apt-get`.
- `lib/` + `.shards/`: GitLab `cache:` keyed by `shard.lock` — `shards
  install` becomes a quick local copy.
- `CRYSTAL_CACHE_DIR` points into the project and is cached too, so `crystal
  spec` / `crystal build` reuse macro and dependency artifacts instead of
  recompiling from scratch.

## Notes

- Disk: the Crystal image (~1.5 GB) plus the runner/helper images stay on the
  host; each job additionally writes build artifacts (~a few hundred MB) into
  its container, removed when the job ends. The `lib/` + `.shards/` CI cache
   lives in a Docker volume managed by the runner.
- The runner executes whatever `.gitlab-ci.yml` says on a push to GitLab —
  same trust model as giving the repo a shell on this machine. Fine for your
  own repos; think twice before enabling it for third-party forks.
