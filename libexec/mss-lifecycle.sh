#!/bin/sh
# mss-lifecycle.sh — stop or start the active optional backend (#1 D10).
#
#   sudo /usr/local/libexec/mac-studio-server/mss-lifecycle.sh stop|start <backend>
#
# Root only; scripts/backend.sh start|stop calls it. It holds the lifecycle
# lock and re-reads the installed conf under it: only the active backend can be
# stopped or started, and nothing else changes. stop lasts until the next start
# or reboot (the plist stays in /Library/LaunchDaemons). start refuses after a
# guard trip, when the label is already loaded, or beside another model server,
# and succeeds only once the job has a running process.

set -u

_self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$_self_dir/mss-common.sh" ]; then
    . "$_self_dir/mss-common.sh"
else
    . "$_self_dir/../scripts/lib/mss-common.sh"
fi

DB_DIR="/var/db/mac-studio-server"
LOG_DIR="/var/log/mac-studio-server"
TRIP_MARKER="$DB_DIR/guard.tripped"
JOURNAL="/usr/local/etc/mac-studio-server/commit.journal"
MSS_LAUNCHD_TIMEOUT=${MSS_LAUNCHD_TIMEOUT:-60}

usage() { echo "usage: mss-lifecycle.sh stop|start llamacpp|ds4|mlx" >&2; exit 2; }
[ $# -eq 2 ] || usage
ACTION=$1; B=$2
case $ACTION in start|stop) ;; *) usage ;; esac
case $B in llamacpp|ds4|mlx) ;; *) usage ;; esac
[ "$(id -u)" -eq 0 ] || mss_die "mss-lifecycle.sh must run as root"
mss_validate_uint MSS_LAUNCHD_TIMEOUT "$MSS_LAUNCHD_TIMEOUT" 1 600 || exit 1

mss_lock_acquire "mss-lifecycle-$ACTION"
[ ! -e "$JOURNAL" ] || mss_die "an install was interrupted; re-run the install to finish it"
[ -r "$(mss_conf_path)" ] || mss_die "no optional backend is installed"
ACTIVE=$(mss_conf_get MSS_GUARD_BACKEND)
[ "$ACTIVE" = "$B" ] || mss_die "$B is not the active backend (active: ${ACTIVE:-none})"
[ "$(mss_conf_get MSS_MODEL_STATE)" != waiting ] || mss_die "$B is waiting for a model (run scripts/model.sh)"
LABEL="com.mac-studio-server.$B"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
loaded() { launchctl print "system/$LABEL" >/dev/null 2>&1; }

if [ "$ACTION" = stop ]; then
    if loaded; then
        mss_lock_check
        mss_mut launchctl bootout "system/$LABEL" || true
        mss_launchd_wait_gone "$LABEL" "$MSS_LAUNCHD_TIMEOUT" \
            || mss_die "$LABEL did not stop within ${MSS_LAUNCHD_TIMEOUT}s; run the command again"
    fi
    echo "$B stopped until scripts/backend.sh start $B or the next reboot"
    exit 0
fi

[ ! -e "$TRIP_MARKER" ] \
    || mss_die "the guard tripped ($(head -n 1 "$TRIP_MARKER" 2>/dev/null)); recover with sudo /usr/local/libexec/mac-studio-server/mss-enable.sh"
! loaded || mss_die "$LABEL is already loaded"
_us=$(mss_unmanaged_server) || mss_die "pgrep is missing; cannot check for other model servers"
[ -z "$_us" ] || mss_die "unmanaged model server running (${_us% *} pid ${_us#* }); stop it first"
[ -e "$PLIST" ] || mss_die "$PLIST is missing; re-run the install"

mss_lock_check
mss_mut launchctl bootstrap system "$PLIST" || mss_die "launchctl bootstrap failed for $LABEL"
# A wrapper that refuses exits at once; a server keeps its PID. Two equal
# readings a second apart within 10 s count as started.
_i=0; _last=""
while [ "$_i" -lt 10 ]; do
    _pid=$(mss_label_pid "$LABEL")
    if [ -n "$_pid" ] && [ "$_pid" = "$_last" ] && kill -0 "$_pid" 2>/dev/null; then
        echo "$B started ($LABEL pid $_pid)"
        exit 0
    fi
    _last=$_pid
    sleep 1
    _i=$((_i + 1))
done
_why=$(grep '^REFUSE:' "$LOG_DIR/$B.log" 2>/dev/null | tail -n 1)
mss_die "$LABEL has no running process after 10s${_why:+ ($_why)}"
