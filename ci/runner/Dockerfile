# CI job image: the stock Crystal image plus the packages every job needs
# (ripgrep for the specs, rake to drive the Rakefile). Baked in so jobs skip
# `apt-get update && apt-get install` (~40s) on every run; with the runner's
# pull_policy = if-not-present the built image is reused from the host.
#
# Build (once per machine / after editing):
#   ./build-image.sh
FROM crystallang/crystal:1.21.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends ripgrep rake \
    && rm -rf /var/lib/apt/lists/*
