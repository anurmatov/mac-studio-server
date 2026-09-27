#!/bin/sh
# mss-enable.sh — the only sanctioned recovery after a guard trip (#9 D5).
# Root only. Boots the backend out and waits for launchd to release its label
# (#18), then clears guard.tripped and the swap baseline (the guard rewrites it
# for the next PID) and bootstraps the backend again. If the backend does not
# stop within 60 s it exits 1 with the trip marker kept, so running it again is
# the recovery.

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

launchctl bootout "system/com.mac-studio-server.$_backend" 2>/dev/null || true
mss_launchd_wait_gone "com.mac-studio-server.$_backend" 60 || exit 1

rm -f "$TRIP_MARKER" "$BASELINE"
echo "mss-enable: cleared trip marker and swap baseline"

launchctl bootstrap system "$PLIST"
echo "mss-enable: com.mac-studio-server.$_backend bootstrapped"
