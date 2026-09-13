#!/usr/bin/env bash
# Cross-compile the x86_64-darwin release binary on an arm64 macOS host — a
# crosspack matrix step (crosspack.yml, the macos entry). crosspack itself
# builds host-natively only (no cross-compilation), so the Intel artifact of
# the GitHub Release is produced here and CI picks it up from build/bin-x86_64.
#
#   H2CODE_BUILD_INTEL=1 ./scripts/build_h2code_intel.sh
#
# Skips unless both the host is arm64 and H2CODE_BUILD_INTEL=1 (the release
# workflow sets it; local `crosspack build macos` stays fast). The source-built
# libraries under ~/x86_64-libs are reused when present — the workflow caches
# that directory keyed on this script's hash.
#
# Homebrew dropped Intel macOS support entirely (Sept 2026): the installer
# itself refuses to run under Rosetta, so there is no brew, no bottles and no
# brew cache to scavenge. Build the three link dependencies from source
# instead, under `arch -x86_64` (inside a Rosetta shell plain `cc` targets
# x86_64), into $HOME/x86_64-libs. The dylib rebind step later matches any
# absolute libssl/libcrypto path, so the custom prefix is picked up there
# automatically.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "build_h2code_intel: not macOS — nothing to do"
  exit 0
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "build_h2code_intel: host is not arm64 (native build is already x86_64) — skipping"
  exit 0
fi
if [ "${H2CODE_BUILD_INTEL:-0}" != "1" ]; then
  echo "build_h2code_intel: Intel cross-build is CI-only (set H2CODE_BUILD_INTEL=1 to enable) — skipping"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

sudo softwareupdate --install-rosetta --agree-to-license || true

PREFIX="$HOME/x86_64-libs"
SRC="$PREFIX/src"
JOBS="$(sysctl -n hw.ncpu)"

if [ -f "$PREFIX/lib/pkgconfig/openssl.pc" ] \
   && [ -f "$PREFIX/lib/pkgconfig/libcrypto.pc" ] \
   && [ -f "$PREFIX/lib/pkgconfig/yaml-0.1.pc" ] \
   && [ -f "$PREFIX/lib/pkgconfig/libpcre2-8.pc" ]; then
  echo "build_h2code_intel: reusing cached libs under $PREFIX"
else
  rm -rf "$PREFIX"
  mkdir -p "$SRC"

  # openssl 3.x — Configure's darwin64-x86_64-cc target plus the build_sw /
  # install_sw targets skip the test binaries that crash under Rosetta.
  curl -fsSL --retry 3 -o "$SRC/openssl.tar.gz" \
    "https://www.openssl.org/source/openssl-3.5.4.tar.gz"
  mkdir "$SRC/openssl" && tar xzf "$SRC/openssl.tar.gz" -C "$SRC/openssl" --strip-components=1
  (
    cd "$SRC/openssl"
    arch -x86_64 ./Configure darwin64-x86_64-cc \
      --prefix="$PREFIX" --libdir=lib no-tests no-docs
    arch -x86_64 make -j"$JOBS" build_sw
    arch -x86_64 make install_sw
  )

  # libyaml — plain autotools build.
  curl -fsSL --retry 3 -o "$SRC/libyaml.tar.gz" \
    "https://github.com/yaml/libyaml/releases/download/0.2.5/yaml-0.2.5.tar.gz"
  mkdir "$SRC/libyaml" && tar xzf "$SRC/libyaml.tar.gz" -C "$SRC/libyaml" --strip-components=1
  (
    cd "$SRC/libyaml"
    arch -x86_64 ./configure --prefix="$PREFIX"
    arch -x86_64 make -j"$JOBS"
    arch -x86_64 make install
  )

  # pcre2 — plain autotools build (8-bit library is what Crystal links).
  curl -fsSL --retry 3 -o "$SRC/pcre2.tar.gz" \
    "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz"
  mkdir "$SRC/pcre2" && tar xzf "$SRC/pcre2.tar.gz" -C "$SRC/pcre2" --strip-components=1
  (
    cd "$SRC/pcre2"
    arch -x86_64 ./configure --prefix="$PREFIX"
    arch -x86_64 make -j"$JOBS"
    arch -x86_64 make install
  )
fi

# Fail loudly (and early) when any of the .pc files the Crystal link needs is
# missing — not minutes later in the build.
for pc in openssl.pc libcrypto.pc yaml-0.1.pc libpcre2-8.pc; do
  [ -f "$PREFIX/lib/pkgconfig/$pc" ] || { echo "error: missing $pc under $PREFIX/lib/pkgconfig" >&2; exit 1; }
done

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

# CC wrapper: skip -arch x86_64 for macro programs (compiled for host arch).
# Match the actual macro cache — $CRYSTAL_CACHE_DIR when overridden (GitLab
# runners point it at ~/.cache/h2code), the ~/.cache/crystal default otherwise.
CACHE_DIR="${CRYSTAL_CACHE_DIR:-$HOME/.cache/crystal}"
CC_WRAPPER="$(mktemp)/cc-wrapper"
mkdir -p "$(dirname "$CC_WRAPPER")"
cat > "$CC_WRAPPER" << WRAPPER
#!/bin/bash
for arg in "\$@"; do
  case "\$arg" in
    "$CACHE_DIR"/*|*/.cache/crystal/*) exec /usr/bin/cc "\$@" ;;
  esac
done
WRAPPER
echo "exec /usr/bin/cc -arch x86_64 -L$PREFIX/lib \"\$@\"" >> "$CC_WRAPPER"
chmod +x "$CC_WRAPPER"
export CC="$CC_WRAPPER"

./scripts/build_h2code.sh x86_64-apple-darwin build/bin-x86_64/h2code
./scripts/rebind_dylibs.sh build/bin-x86_64/h2code
