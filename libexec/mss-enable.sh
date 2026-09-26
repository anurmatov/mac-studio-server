#!/bin/sh
# mss-enable.sh — the only sanctioned recovery after a guard trip (#9 D5).
# Root only. Clears guard.tripped and the swap baseline (the guard rewrites it
# for the next PID), then bootstraps the backend again.

set -eu

LIBEXEC_DIR="/usr/local/libexec/mac-studio-server"
DB_DIR="/var/db/mac-studio-server"
TRIP_MARKER="$DB_DIR/guard.tripped"
BASELINE="$DB_DIR/swap-baseline"

if [ "$(id -u)" -ne 0 ]; then
    echo "mss-enable: must run with sudo" >&2
    exit 1
fi

. "$LIBEXEC_DIR/mss-common.sh"
_backend=$(mss_conf_get MSS_GUARD_BACKEND || true)
if [ -z "$_backend" ]; then
    echo "mss-enable: no optional backend configured" >&2
    exit 1
fi
if [ "$(mss_conf_get MSS_MODEL_STATE || true)" = waiting ]; then
    echo "mss-enable: $_backend is waiting for a model (run scripts/model.sh)" >&2
    exit 1
fi
PLIST="/Library/LaunchDaemons/com.mac-studio-server.$_backend.plist"

rm -f "$TRIP_MARKER" "$BASELINE"
echo "mss-enable: cleared trip marker and swap baseline"

launchctl bootout "system/com.mac-studio-server.$_backend" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
echo "mss-enable: com.mac-studio-server.$_backend bootstrapped"
