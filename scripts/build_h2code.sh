#!/usr/bin/env bash
# Release build of h2code — the entry point used by crosspack (the crosspack.yml
# matrix steps) and by `rake build_release` / `rake install`.
#
#   ./scripts/build_h2code.sh [crystal-target-triplet] [output-path]
#
# Builds the miniaudio bridge (scripts/build_miniaudio.sh prints the link
# flags) and compiles src/h2code.cr in release mode into build/bin/h2code by
# default — the artifacts.from directory the crosspack build stage distributes
# from. The version baked into the binary comes from CROSSBUILD_VERSION
# (exported by crosspack), falling back to H2CODE_VERSION / the latest git
# tag, matching src/version.cr. On Windows Crystal appends .exe to -o itself.
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
LINK_FLAGS="$(./scripts/build_miniaudio.sh "$TARGET")"

export H2CODE_VERSION="${CROSSBUILD_VERSION:-${H2CODE_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0-dev)}}"

TARGET_ARGS=""
if [ -n "$TARGET" ]; then TARGET_ARGS="--target $TARGET"; fi

# LINK_FLAGS is a deliberately unquoted flag list.
# shellcheck disable=SC2086
crystal build src/h2code.cr -o "$OUTPUT" --release --no-debug --warnings none $TARGET_ARGS --link-flags "$LINK_FLAGS"
