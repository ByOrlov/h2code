#!/usr/bin/env bash
# Build the CI job image (Dockerfile) locally. Run once per machine that hosts
# a runner; the .gitlab-ci.yml `image:` refers to it by tag, and the runner's
# pull_policy = if-not-present reuses it without re-pulling.
set -euo pipefail
cd "$(dirname "$0")"
docker build -t h2code-ci:1.21.0 .
