#!/bin/bash
# Actual VPN process entrypoint (invoked by launchd). Reads /tmp/corplink-gui.env.
set -euo pipefail

ENV_FILE="${CORPLINK_ENV_FILE:-/tmp/corplink-gui.env}"
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${CORPLINK_BIN:?}"
: "${CORPLINK_CFG:?}"

export CORPLINK_GUI=1
export CORPLINK_AUTH_GATE="${CORPLINK_AUTH_GATE:-/tmp/corplink-gui-auth.gate}"
export RUST_LOG="${RUST_LOG:-info}"

# Fresh gate each start — GUI must touch this after user finishes SSO.
rm -f "$CORPLINK_AUTH_GATE"

# Cookies live next to config.json; make sure we're not in /
cd "$(dirname "$CORPLINK_CFG")"

exec "$CORPLINK_BIN" "$CORPLINK_CFG"
