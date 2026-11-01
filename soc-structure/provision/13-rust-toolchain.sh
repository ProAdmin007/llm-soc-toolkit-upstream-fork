#!/usr/bin/env bash
#
# 13-rust-toolchain.sh
#
# Installs the Rust toolchain tuner-dev's sandbox is already configured
# to expect, and pre-populates its offline CARGO_HOME.
#
# scripts/soc-run-role puts /usr/local/lib/soc/rust/bin on tuner-dev's
# PATH and sets CARGO_HOME=<tuner-dev home>/.cargo + CARGO_NET_OFFLINE=true
# (runner-and-permissions.md §5.3: "Its sandbox gets an offline CARGO_HOME
# ... pre-populated at setup time, so a ticket-influenced build can never
# fetch a new dependency"). No script before this one actually did that
# setup -- found live when a tuner-dev run had a real, tested-but-for-this
# code fix ready on its own branch and had to self-escalate a
# permission_gap ticket because cargo/rustc were simply not there.
#
# Installs a single pinned toolchain directly, not a rustup-managed one:
# tuner-dev never switches toolchains, so the rustup proxy-binary
# indirection buys nothing here and is one more moving part in a sandbox
# that should have as few as possible. The toolchain's own bin/+lib/ are
# self-contained (binaries resolve shared libs via a relative $ORIGIN/../lib
# rpath) and can be copied as a pair without rustup present at all.
#
# Idempotent; requires root. Run after 03-tunerdev-checkout.sh.
#   sudo bash 13-rust-toolchain.sh
#
set -euo pipefail

TUNER=soc-tunerdev
CHECKOUT=/var/lib/soc/tunerdev/headless-siem     # from 03-tunerdev-checkout.sh
TUNER_HOME=/var/lib/soc/tunerdev
TOOLCHAIN_DIR=/usr/local/lib/soc/rust            # [SOC-ROOT-PATH]-adjacent; matches scripts/soc-run-role's PATH entry
CARGO_HOME="$TUNER_HOME/.cargo"

log() { printf '  %s\n' "$*"; }
astuner() { sudo -u "$TUNER" -H "$@"; }

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)"; exit 1; }
getent passwd "$TUNER" >/dev/null || { echo "$TUNER missing — run 01 first"; exit 1; }
[[ -d $CHECKOUT/.git ]] || { echo "tuner-dev checkout not found: $CHECKOUT — run 03-tunerdev-checkout.sh first"; exit 1; }

echo "== toolchain =="
if [[ -x "$TOOLCHAIN_DIR/bin/cargo" && -x "$TOOLCHAIN_DIR/bin/rustc" ]]; then
  log "already installed: $("$TOOLCHAIN_DIR/bin/rustc" --version)"
else
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' EXIT
  log "downloading rustup-init..."
  curl -sSf --max-time 30 https://sh.rustup.rs -o "$stage/rustup-init.sh"
  chmod +x "$stage/rustup-init.sh"
  log "installing a minimal stable toolchain into staging (this can take a minute)..."
  RUSTUP_HOME="$stage/rustup" CARGO_HOME="$stage/cargo" \
    "$stage/rustup-init.sh" -y --no-modify-path --profile minimal --default-toolchain stable >/dev/null
  tc_dir="$(find "$stage/rustup/toolchains" -maxdepth 1 -mindepth 1 -type d | head -1)"
  [[ -n "$tc_dir" ]] || { echo "rustup-init didn't produce a toolchain dir"; exit 1; }
  mkdir -p "$TOOLCHAIN_DIR"
  cp -a "$tc_dir/bin" "$tc_dir/lib" "$TOOLCHAIN_DIR/"
  chown -R root:root "$TOOLCHAIN_DIR"
  chmod -R a+rX "$TOOLCHAIN_DIR"
  log "installed: $("$TOOLCHAIN_DIR/bin/rustc" --version)"
fi

echo "== offline CARGO_HOME for $TUNER =="
mkdir -p "$CARGO_HOME"
chown "$TUNER:socroles" "$CARGO_HOME"
if [[ -d "$CARGO_HOME/registry/cache" ]]; then
  log "cargo registry cache already populated"
else
  log "fetching dependencies once online (cargo fetch against $CHECKOUT)..."
  astuner env PATH="$TOOLCHAIN_DIR/bin:/usr/bin:/bin" CARGO_HOME="$CARGO_HOME" \
    bash -c "cd '$CHECKOUT' && cargo fetch"
  log "populated: $(du -sh "$CARGO_HOME" | cut -f1)"
fi

echo "== verification =="
astuner env PATH="$TOOLCHAIN_DIR/bin:/usr/bin:/bin" CARGO_HOME="$CARGO_HOME" CARGO_NET_OFFLINE=true \
  bash -c "cd '$CHECKOUT' && cargo --version && echo offline-check: no network needed for a cached build"
echo
echo "DONE. $TUNER can now run cargo check/test --offline against its own checkout."
