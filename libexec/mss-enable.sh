#!/bin/sh
# mss-enable.sh — the only sanctioned recovery after a guard trip (#9 D5).
# Root only. Boots the backend out and waits for launchd to release its label
# (#18), then clears guard.tripped and the swap baseline (the guard rewrites it
# for the next PID) and bootstraps the backend again. If the backend does not
# stop within 60 s it exits 1 with the trip marker kept, so running it again is
# the recovery. It holds the lifecycle lock, and refuses while an install was
# interrupted (#1 D15, D5.C).

set -eu

LIBEXEC_DIR="/usr/local/libexec/mac-studio-server"
DB_DIR="/var/db/mac-studio-server"
TRIP_MARKER="$DB_DIR/guard.tripped"
BASELINE="$DB_DIR/swap-baseline"
JOURNAL="/usr/local/etc/mac-studio-server/commit.journal"

if [ "$(id -u)" -ne 0 ]; then
    echo "mss-enable: must run with sudo" >&2
    exit 1
fi

. "$LIBEXEC_DIR/mss-common.sh"
mss_lock_acquire mss-enable
if [ -e "$JOURNAL" ]; then
    echo "mss-enable: an install was interrupted; re-run the install to finish it" >&2
    exit 1
fi
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

if launchctl print "system/com.mac-studio-server.$_backend" >/dev/null 2>&1; then
    mss_lock_check
    mss_mut launchctl bootout "system/com.mac-studio-server.$_backend" || true
fi
mss_launchd_wait_gone "com.mac-studio-server.$_backend" 60 || exit 1

mss_lock_check
mss_mut rm -f "$TRIP_MARKER" "$BASELINE"
echo "mss-enable: cleared trip marker and swap baseline"

mss_lock_check
mss_mut launchctl bootstrap system "$PLIST"
echo "mss-enable: com.mac-studio-server.$_backend bootstrapped"
