#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

mkdir -p "$INSTALL_DIR"
cargo build --release --manifest-path "$ROOT/Cargo.toml"
install -m 755 "$ROOT/target/release/corplink-otp" "$INSTALL_DIR/corplink-otp"
echo "installed: $INSTALL_DIR/corplink-otp"
