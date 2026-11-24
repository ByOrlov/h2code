#!/usr/bin/env bash
# Release build of h2code + hless — the entry point used by crosspack (the
# crosspack.yml matrix steps) and by `rake build_release` / `rake install`.
#
#   ./scripts/build_h2code.sh [crystal-target-triplet] [output-path]
#
# Builds the miniaudio bridge (scripts/build_miniaudio.sh prints the link
# flags) and compiles src/h2code.cr in release mode into build/bin/h2code by
# default — the artifacts.from directory the crosspack build stage distributes
# from. bin/hless.cr (the pager) is compiled alongside into the same
# directory; it needs no bridge, so it is a plain release build. The version
# baked into the binaries comes from CROSSBUILD_VERSION (exported by
# crosspack), falling back to H2CODE_VERSION / the latest git tag, matching
# src/version.cr. On Windows Crystal appends .exe to -o itself.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-}"
OUTPUT="${2:-build/bin/h2code}"

if command -v shards >/dev/null 2>&1; then
  shards install
elif [ -f lib/.shards.info ]; then
  echo "note: shards not found — using the existing lib/ tree" >&2
else
  echo "error: shards is required to fetch Crystal dependencies (it ships with Crystal)" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
# Fall back to a no-audio build when the bridge can't be built on this
# system (no cc / no bash) — same policy as the Rakefile's
# -Dwithout_miniaudio fallback. Release packaging (crosspack deps verified
# hosts) still builds the full-audio binary; a silent no-audio release is
# only possible when the toolchain was already incomplete.
AUDIO_FLAGS=""
if ! LINK_FLAGS="$(./scripts/build_miniaudio.sh "$TARGET")"; then
  echo "warning: miniaudio bridge build failed — building without audio (-Dwithout_miniaudio)" >&2
  LINK_FLAGS=""
  AUDIO_FLAGS="-Dwithout_miniaudio"
fi

export H2CODE_VERSION="${CROSSBUILD_VERSION:-${H2CODE_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0-dev)}}"

TARGET_ARGS=""
if [ -n "$TARGET" ]; then TARGET_ARGS="--target $TARGET"; fi

# LINK_FLAGS is a deliberately unquoted flag list; AUDIO_FLAGS is empty or
# -Dwithout_miniaudio; --link-flags is passed only when LINK_FLAGS is set.
# shellcheck disable=SC2086
crystal build src/h2code.cr -o "$OUTPUT" --release --no-debug --warnings none $AUDIO_FLAGS $TARGET_ARGS ${LINK_FLAGS:+--link-flags "$LINK_FLAGS"}

# hless — same directory as the h2code output (Windows appends .exe itself).
HLESS_OUTPUT="$(dirname "$OUTPUT")/hless"
# shellcheck disable=SC2086
crystal build bin/hless.cr -o "$HLESS_OUTPUT" --release --no-debug --warnings none $TARGET_ARGS
# The Telegram daemon ships beside h2code (same release archives, installers
# and packages — install.sh / install.ps1 put both on PATH). Pure stdlib:
# no miniaudio bridge, so no extra link flags. On Windows Crystal appends
# .exe to -o itself, same as above.
TG_OUTPUT="$(dirname "$OUTPUT")/h2code-tg-bot"
# shellcheck disable=SC2086
crystal build src/tg_bot/main.cr -o "$TG_OUTPUT" --release --no-debug --warnings none $TARGET_ARGS
