#!/bin/bash
# Privileged start: install a one-shot launchd job (KeepAlive=false) + env file.
set -euo pipefail

BIN="${CORPLINK_BIN:?CORPLINK_BIN required}"
CFG="${CORPLINK_CFG:?CORPLINK_CFG required}"
LOG="${CORPLINK_LOG:-/tmp/corplink-gui.log}"
LABEL="${CORPLINK_LABEL:-local.corplink-rs-gui}"
GATE="${CORPLINK_AUTH_GATE:-/tmp/corplink-gui-auth.gate}"
ENV_FILE="${CORPLINK_ENV_FILE:-/tmp/corplink-gui.env}"
RUN_SH="${CORPLINK_RUN_SH:-}"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

if [[ -z "$RUN_SH" ]]; then
  RUN_SH="$(cd "$(dirname "$0")" && pwd)/vpn-run.sh"
fi

mkdir -p "$(dirname "$LOG")"
: >"$LOG"
rm -f "$GATE"

# Stop any previous instance (no respawn loop).
/bin/launchctl bootout system/"$LABEL" 2>/dev/null || true
/bin/launchctl remove "$LABEL" 2>/dev/null || true
/usr/bin/pkill -9 -f "$BIN" 2>/dev/null || true
/bin/rm -f "$PLIST" 2>/dev/null || true
sleep 0.3

cat >"$ENV_FILE" <<EOF
export CORPLINK_BIN=$(printf '%q' "$BIN")
export CORPLINK_CFG=$(printf '%q' "$CFG")
export CORPLINK_AUTH_GATE=$(printf '%q' "$GATE")
export CORPLINK_ENV_FILE=$(printf '%q' "$ENV_FILE")
EOF
chmod 644 "$ENV_FILE"

# KeepAlive=false so a failed/exited login does NOT restart every ~10s.
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${RUN_SH}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CORPLINK_ENV_FILE</key>
    <string>${ENV_FILE}</string>
    <key>CORPLINK_GUI</key>
    <string>1</string>
    <key>CORPLINK_AUTH_GATE</key>
    <string>${GATE}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${LOG}</string>
  <key>StandardErrorPath</key>
  <string>${LOG}</string>
</dict>
</plist>
EOF
chmod 644 "$PLIST"

/bin/launchctl bootstrap system "$PLIST"
echo "started label=$LABEL keepAlive=false gate=$GATE log=$LOG"
