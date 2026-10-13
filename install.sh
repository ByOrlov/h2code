#!/usr/bin/env bash
# H2Code installer — macOS / Linux.
# Usage:  curl -fsSL https://raw.githubusercontent.com/ByOrlov/H2Code/master/install.sh | bash
#         install.sh [path/to/h2code]   — install a locally built binary instead of
#                                         downloading a release asset (used by `rake install`)
set -euo pipefail

REPO="ByOrlov/H2Code"
INSTALL_DIR="${H2CODE_INSTALL_DIR:-$HOME/.h2code/bin}"
BIN_NAME="h2code"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
err()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }

# --- Detect OS + arch ---------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Darwin) os=darwin ;;
  Linux)  os=linux ;;
  *) err "Unsupported OS: $OS (this installer covers macOS and Linux)"; exit 1 ;;
esac
case "$ARCH" in
  x86_64|amd64)  arch=x86_64 ;;
  aarch64|arm64) arch=aarch64 ;;
  *) err "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# aarch64-linux is built via QEMU; verify it exists before assuming.
ASSET="h2code-${arch}-${os}.tar.gz"
URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

# --- Local binary mode --------------------------------------------------------
# When a path to an existing file is passed, skip the release download and
# install that binary instead (used by `rake install` from a source checkout).
LOCAL_BIN=""
if [ "${1:-}" != "" ]; then
  if [ ! -f "$1" ]; then
    err "Local binary not found: $1"
    exit 1
  fi
  LOCAL_BIN="$1"
fi

bold "Installing H2Code for ${arch}-${os}…"
if [ -n "$LOCAL_BIN" ]; then
  info "Source:        local build (${LOCAL_BIN})"
else
  info "Release asset: ${ASSET}"
fi
info "Install dir:   ${INSTALL_DIR}"

# --- Download -----------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SRC_BIN="${TMP}/${BIN_NAME}"
if [ -n "$LOCAL_BIN" ]; then
  SRC_BIN="$LOCAL_BIN"
else
  info "Downloading ${URL}…"
  if ! curl -fSL --retry 3 -o "${TMP}/${ASSET}" "$URL"; then
    err "Download failed."
    err "If you're on ${arch}-${os}, the asset may not be published yet."
    err "Check available assets at: https://github.com/${REPO}/releases/latest"
    exit 1
  fi

  # --- Verify + extract ---------------------------------------------------------
  info "Extracting…"
  tar -xzf "${TMP}/${ASSET}" -C "$TMP"
fi

# --- Runtime dependencies -----------------------------------------------------
# H2Code links dynamically against OpenSSL (libssl/libcrypto), libyaml and pcre2.
# They are part of Crystal's stdlib runtime and not declared in shard.yml, so we
# make sure they are present via the platform package manager. ripgrep (rg) is
# also required by the Grep and Glob tools and is installed the same way.
ensure_macos_deps() {
  command -v brew >/dev/null 2>&1 || {
    err "Homebrew not found. Install it from https://brew.sh, then:"
    err "  brew install openssl@3 libyaml pcre2"
    return 0
  }
  local missing=()
  for pkg in openssl@3 libyaml pcre2 ripgrep; do
    brew list "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    info "All runtime dependencies present (Homebrew)."
    return 0
  fi
  info "Installing missing Homebrew packages: ${missing[*]}"
  brew install "${missing[@]}"
}

ensure_linux_deps() {
  # Each entry: "lib<ldconfig-name>|<apt pkgs>|<dnf pkgs>|<pacman pkgs>"
  # ldconfig-name is used to detect presence without the package manager.
  local -a rows=(
    "libssl.so.3|libssl3 libssl3t64|openssl-libs|openssl"
    "libcrypto.so.3|libssl3 libssl3t64|openssl-libs|openssl"
    "libyaml-0.so.2|libyaml-0-2|libyaml|libyaml"
    "libpcre2-8.so.0|libpcre2-8-0|pcre2|pcre2"
  )
  local missing_libs=()
  for row in "${rows[@]}"; do
    local lib="${row%%|*}"
    { ldconfig -p 2>/dev/null || true; } | grep -q "$lib" || missing_libs+=("$row")
  done

  local sudo=""
  if [ "$(id -u)" -ne 0 ]; then
    sudo="sudo"
  fi

  if [ "${#missing_libs[@]}" -eq 0 ]; then
    info "All runtime libraries present."
  else
    if command -v apt-get >/dev/null 2>&1; then
      local pkgs=()
      for row in "${missing_libs[@]}"; do pkgs+=($(echo "$row" | cut -d'|' -f2)); done
      info "Installing missing packages via apt-get: ${pkgs[*]}"
      $sudo apt-get update -qq
      # shellcheck disable=SC2086
      $sudo apt-get install -y $pkgs
    elif command -v dnf >/dev/null 2>&1; then
      local pkgs=()
      for row in "${missing_libs[@]}"; do pkgs+=($(echo "$row" | cut -d'|' -f3)); done
      info "Installing missing packages via dnf: ${pkgs[*]}"
      # shellcheck disable=SC2086
      $sudo dnf install -y $pkgs
    elif command -v yum >/dev/null 2>&1; then
      local pkgs=()
      for row in "${missing_libs[@]}"; do pkgs+=($(echo "$row" | cut -d'|' -f3)); done
      info "Installing missing packages via yum: ${pkgs[*]}"
      # shellcheck disable=SC2086
      $sudo yum install -y $pkgs
    elif command -v pacman >/dev/null 2>&1; then
      local pkgs=()
      for row in "${missing_libs[@]}"; do pkgs+=($(echo "$row" | cut -d'|' -f4)); done
      info "Installing missing packages via pacman: ${pkgs[*]}"
      # shellcheck disable=SC2086
      $sudo pacman -S --noconfirm --needed $pkgs
    else
      err "Could not detect a supported package manager."
      err "Please install OpenSSL, libyaml and pcre2 manually:"
      err "  ${missing_libs[*]}"
    fi
  fi

  # ripgrep (rg) — standalone binary required by the Grep and Glob tools.
  # Not a shared library, so it needs its own `command -v` detection.
  if command -v rg >/dev/null 2>&1; then
    info "ripgrep (rg) is available."
  else
    info "ripgrep (rg) not found — installing…"
    if command -v apt-get >/dev/null 2>&1; then
      $sudo apt-get update -qq
      $sudo apt-get install -y ripgrep
    elif command -v dnf >/dev/null 2>&1; then
      $sudo dnf install -y ripgrep
    elif command -v pacman >/dev/null 2>&1; then
      $sudo pacman -S --noconfirm --needed ripgrep
    else
      err "Could not install ripgrep automatically."
      err "Install it manually: https://github.com/BurntSushi/ripgrep#installation"
    fi
  fi
}

case "$os" in
  darwin) ensure_macos_deps ;;
  linux)  ensure_linux_deps ;;
esac

# --- Install ------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
mv -f "${SRC_BIN}" "${INSTALL_DIR}/${BIN_NAME}"
chmod +x "${INSTALL_DIR}/${BIN_NAME}"
info "Installed ${INSTALL_DIR}/${BIN_NAME}"

# The Telegram daemon ships in the same release archive (or next to a local
# build). Optional: older releases did not include it — same install dir, so
# PATH below covers both binaries.
TG_SRC="${TMP}/h2code-tg-bot"
[ -n "$LOCAL_BIN" ] && TG_SRC="$(dirname "$LOCAL_BIN")/h2code-tg-bot"
if [ -f "$TG_SRC" ]; then
  mv -f "$TG_SRC" "${INSTALL_DIR}/h2code-tg-bot"
  chmod +x "${INSTALL_DIR}/h2code-tg-bot"
  info "Installed ${INSTALL_DIR}/h2code-tg-bot"
else
  info "h2code-tg-bot not found — skipping (older release?)"
fi

# Startup tips data (tips/*.json, read from disk next to config.json — see
# src/tips/tips.cr). Only present when the release archive bundles them.
if [ -d "${TMP}/tips" ]; then
  TIPS_DIR="${H2CODE_HOME:-$HOME/.h2code}/tips"
  mkdir -p "$TIPS_DIR"
  cp -f "${TMP}"/tips/*.json "$TIPS_DIR/"
  info "Installed tips to ${TIPS_DIR}"
fi

# --- PATH ---------------------------------------------------------------------
case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) : already on PATH ;;
  *)
    # Pick the most relevant profile file based on the user's default login
    # shell ($SHELL), NOT on the interpreter running this script — when invoked
    # as `curl ... | bash` the interpreter is always bash, so checking
    # $BASH_VERSION would always select .bashrc even for zsh users (the macOS
    # default), and the line would never be sourced.
    case "${SHELL:-}" in
      */zsh)  PROFILE="$HOME/.zshrc" ;;
      */bash) PROFILE="$HOME/.bashrc" ;;
      */fish) PROFILE="$HOME/.config/fish/config.fish" ;;
      *)      PROFILE="$HOME/.profile" ;;
    esac

    case "${SHELL:-}" in
      */fish) LINE="set -gx PATH \$PATH ${INSTALL_DIR}" ;;
      *)      LINE="export PATH=\"\$PATH:${INSTALL_DIR}\"" ;;
    esac
    if [ -f "$PROFILE" ] && grep -qF "$INSTALL_DIR" "$PROFILE" 2>/dev/null; then
      : already added
    else
      mkdir -p "$(dirname "$PROFILE")"
      printf '\n# Added by H2Code installer\n%s\n' "$LINE" >> "$PROFILE"
      info "Added ${INSTALL_DIR} to PATH in ${PROFILE}"
      info "Restart your shell or run:  source ${PROFILE}"
    fi
    ;;
esac

# --- Done ---------------------------------------------------------------------
bold "✓ H2Code installed."
info "Version: $(${INSTALL_DIR}/${BIN_NAME} --version 2>/dev/null || echo 'unknown')"
info "Run 'h2code' to start. Use '/upgrade' inside the TUI to update later."
