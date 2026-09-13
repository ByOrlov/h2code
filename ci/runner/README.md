# GitLab runners (self-hosted)

Runs the `.gitlab-ci.yml` jobs of this repo on your own machines. The Linux
runner uses the Docker executor (below); the macOS and Windows runners use
shell executors directly on the host (see the sections further down).

**Important:** when creating the macOS/Windows runners, keep "run untagged
jobs" **off**. The Linux jobs (`check`, `integration`, `build:x86_64-linux`,
`release`) are untagged and require the Docker executor — a shell runner
with "run untagged" enabled would pick them up and fail.

## Linux runner (Docker executor)

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

## macOS runner (shell executor, tag `macos`)

Runs `integration:macos`, `build:aarch64-darwin` (native) and
`build:x86_64-darwin` (cross-compiled under Rosetta) on a Mac.

Host requirements:

- macOS on Apple Silicon (the x86_64 leg cross-compiles via Rosetta 2)
- Xcode Command Line Tools: `xcode-select --install`
- Crystal 1.21.x — `brew install crystal` or https://crystal-lang.org/install/
- Homebrew (Crystal's libssl/libyaml/pcre2 link dependencies)
- rake — bundled with the system Ruby, nothing to install
- Rosetta 2: `sudo softwareupdate --install-rosetta --agree-to-license`
  (the CI job also tries this, but it needs `sudo`; without passwordless
  sudo, run it once manually)

Setup:

1. In GitLab: project → **Settings → CI/CD → Runners → New project runner**,
   tag `macos`, "run untagged jobs" off. Copy the token (`glrt-…`).
2. Install and register the runner (https://docs.gitlab.com/runner/install/osx/):

   ```
   brew install gitlab-runner
   gitlab-runner register --url https://gitlab.com --token glrt-…   # executor: shell
   brew services start gitlab-runner
   ```

Notes:

- Until this runner is registered, the macOS jobs sit pending ("waiting for
  a runner") in every pipeline; the Linux jobs are not blocked by them.
- The `build:x86_64-darwin` job builds OpenSSL/libyaml/pcre2 from source
  under `arch -x86_64` into `~/x86_64-libs` on first run (Homebrew has no
  Intel bottles); later runs rebuild it from scratch, which takes a while.

## Windows runner (shell executor, tag `windows`)

Runs `integration:windows` and `build:x86_64-windows` on a Windows machine.

Host requirements:

- Crystal 1.21.x — the Windows installer from https://crystal-lang.org/install/
- Visual Studio Build Tools with the "Desktop development with C++" workload
  (MSVC + Windows SDK — Crystal's native toolchain on Windows)
- Git for Windows (git + bash on PATH — the build job runs under bash)
- Ruby + rake — RubyInstaller (https://rubyinstaller.org/); rake ships with it

Setup:

1. In GitLab: project → **Settings → CI/CD → Runners → New project runner**,
   tag `windows`, "run untagged jobs" off. Copy the token (`glrt-…`).
2. Install and register the runner
   (https://docs.gitlab.com/runner/install/windows/), from an elevated shell:

   ```
   .\gitlab-runner.exe register --url https://gitlab.com --token glrt-…   # executor: shell
   .\gitlab-runner.exe install
   .\gitlab-runner.exe start
   ```

   The shell executor uses pwsh when installed, otherwise Windows PowerShell
   (the job scripts are compatible with both).

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
- Toolchain caches: the runner bind-mounts `~/gitlab-runner-cache` (host) into
  every job container as `/cache`; jobs point `CRYSTAL_CACHE_DIR` (h2code) and
  `GOMODCACHE`/`GOCACHE`/`CARGO_TARGET_DIR`/npm cache (hvoice) there. GitLab
  server-side `cache:` is NOT used — this runner has no object storage, so
  runner 19.x has no cache adapter at all.

## Notes

- Disk: the Crystal image (~1.5 GB) plus the runner/helper images stay on the
  host; each job additionally writes build artifacts (~a few hundred MB) into
  its container, removed when the job ends. The `lib/` + `.shards/` CI cache
   lives in a Docker volume managed by the runner.
- The runner executes whatever `.gitlab-ci.yml` says on a push to GitLab —
  same trust model as giving the repo a shell on this machine. Fine for your
  own repos; think twice before enabling it for third-party forks.
