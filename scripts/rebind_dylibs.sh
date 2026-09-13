#!/usr/bin/env bash
# Rebind a macOS h2code binary's Homebrew-linked OpenSSL dylibs to @rpath and
# bundle them next to the binary. A crosspack matrix step (crosspack.yml, the
# macos entry) — ported verbatim from the old release.yml step so CI and local
# `crosspack build macos` produce the same self-contained layout.
#
#   ./scripts/rebind_dylibs.sh [binary]     # default: build/bin/h2code
#
# No-op off macOS (lets the same crosspack steps run everywhere).
#
# Crystal links against Homebrew's libssl.3.dylib / libcrypto.3.dylib with
# absolute install names (e.g. /usr/local/opt/openssl@3/lib/...). On a user
# machine that path usually does not exist (Homebrew on Apple Silicon lives
# under /opt/homebrew), so the binary fails with dyld "Library not loaded".
# Rebind to @rpath and bundle the dylibs next to the binary.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "rebind_dylibs: not macOS — nothing to do"
  exit 0
fi

BIN="${1:-build/bin/h2code}"
DIR="$(dirname "$BIN")"

otool -L "$BIN"

# Only act on the Homebrew-linked OpenSSL dylibs.
for lib in libssl.3.dylib libcrypto.3.dylib; do
  abs=$(otool -L "$BIN" | grep -E "/.*/${lib}\b" | awk '{print $1}' | head -n1 || true)
  [ -n "$abs" ] || continue
  cp "$abs" "$DIR/${lib}"
  # Rewrite the dylib's own id and its dependency on the sibling.
  install_name_tool -id "@rpath/${lib}" "$DIR/${lib}"
  # NOTE the trailing "|| true": libcrypto has no ssl/crypto deps, so grep
  # finds nothing, exits 1, and under `set -euo pipefail` that used to abort
  # the whole step after the rebind was half-done.
  other=$(otool -L "$DIR/${lib}" | grep -E "/.*/(libssl.3|libcrypto.3).dylib\b" | awk '{print $1}' || true)
  for dep in $other; do
    depname=$(basename "$dep")
    install_name_tool -change "$dep" "@rpath/${depname}" "$DIR/${lib}"
  done
  # Point the binary at the rebundled copy.
  install_name_tool -change "$abs" "@rpath/${lib}" "$BIN"
done

# Look beside the binary for the dylibs.
install_name_tool -add_rpath @loader_path "$BIN" 2>/dev/null || true

# install_name_tool invalidated the Homebrew signatures of the modified dylibs
# (see the warnings above); re-sign ad hoc or macOS kills the binary on launch
# with an invalid code signature.
for lib in libssl.3.dylib libcrypto.3.dylib; do
  [ -f "$DIR/${lib}" ] && codesign --force --sign - "$DIR/${lib}"
done
codesign --force --sign - "$BIN" 2>/dev/null || true
echo "--- after rebind ---"
otool -L "$BIN"
