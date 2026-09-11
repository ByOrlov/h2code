#!/usr/bin/env bash
# Register the compose runner (docker-compose.yml) with a GitLab project.
#
#   ./register.sh <gitlab-url> <runner-token>
#
# The token comes from GitLab: Settings → CI/CD → Runners → "New project
# runner" (authentication token, glrt-…) — or the legacy project registration
# token. It is only passed to `gitlab-runner register`; the resulting
# config.toml lands in ./data/ (gitignored).
set -euo pipefail
cd "$(dirname "$0")"

URL="${1:?usage: register.sh <gitlab-url> <runner-token>}"
TOKEN="${2:?usage: register.sh <gitlab-url> <runner-token>}"

docker compose up -d runner

# New-style authentication tokens use --token; legacy registration tokens
# (gr…) use --registration-token.
FLAG=--token
[[ "$TOKEN" != glrt-* ]] && FLAG=--registration-token

docker compose exec -T runner gitlab-runner register --non-interactive \
  --url "$URL" "$FLAG" "$TOKEN" \
  --executor docker \
  --docker-image crystallang/crystal:1.21.0 \
  --docker-pull-policy if-not-present \
  --description "h2code linux (docker, self-hosted)"

# Let check + integration run in parallel instead of serializing (the runner
# processes at most this many jobs at once). The sed runs inside the container:
# config.toml is root-owned (written by the runner process).
docker compose exec -T runner sed -i 's/^concurrent = .*/concurrent = 2/' /etc/gitlab-runner/config.toml
docker compose restart runner
echo "Registered. Verify: docker compose exec -T runner gitlab-runner verify"
