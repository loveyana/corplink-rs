#!/bin/bash
set -euo pipefail

BIN="${CORPLINK_BIN:-}"
LABEL="${CORPLINK_LABEL:-local.corplink-rs-gui}"
GATE="${CORPLINK_AUTH_GATE:-/tmp/corplink-gui-auth.gate}"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

/bin/launchctl bootout system/"$LABEL" 2>/dev/null || true
/bin/launchctl remove "$LABEL" 2>/dev/null || true
/bin/rm -f "$PLIST" "$GATE" 2>/dev/null || true

if [[ -n "$BIN" ]]; then
  /usr/bin/pkill -9 -f "$BIN" 2>/dev/null || true
else
  /usr/bin/pkill -9 -f 'corplink-rs' 2>/dev/null || true
fi
echo "stopped label=$LABEL"
