#!/bin/sh
# ds4-start.sh — fail-closed wrapper, then exec ds4-server (#9 D4).
# Runs as the service user via com.mac-studio-server.ds4. ds4 has no auth, so
# a non-loopback bind additionally requires this boot's pf marker below.

set -u

BACKEND=ds4
_self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$_self_dir/mss-common.sh" ]; then
    . "$_self_dir/mss-common.sh"
else
    . "$_self_dir/../scripts/lib/mss-common.sh"
fi

DB_DIR="/var/db/mac-studio-server"
TRIP_MARKER="$DB_DIR/guard.tripped"
STAMP="$DB_DIR/$BACKEND.model.verified"
BOOT_MARKER="/var/run/com.mac-studio-server.boot.ok"

refuse() { echo "REFUSE: $1"; exit 78; }

# refuse must run in this shell: inside $(...) it would only exit the subshell.
[ -r "$(mss_conf_path)" ] || refuse "conf missing ($(mss_conf_path))"
BIN=$(mss_conf_get DS4_BIN)
[ -n "$BIN" ] || refuse "conf missing DS4_BIN"
MODEL=$(mss_conf_get DS4_MODEL)
[ -n "$MODEL" ] || refuse "conf missing DS4_MODEL"
HOST=$(mss_conf_get DS4_HOST); HOST=${HOST:-127.0.0.1}
PORT=$(mss_conf_get DS4_PORT); PORT=${PORT:-8000}
CTX=$(mss_conf_get DS4_CTX); CTX=${CTX:-65536}
SESSIONS=$(mss_conf_get DS4_BATCHED_SESSIONS)
ARGS=$(mss_conf_get DS4_ARGS)
WIRED_LIMIT=$(mss_conf_get MSS_WIRED_LIMIT_MB)

# 1. Verified model, unchanged since install.
[ -r "$STAMP" ] || refuse "model not verified (stamp missing)"
read -r _spath _ssize _sinode _smtime _ssha < "$STAMP" || _spath=""
[ "$_spath" = "$MODEL" ] || refuse "model changed since verification (stamp path)"
_now=$(stat -f '%z %i %m' "$MODEL" 2>/dev/null || echo missing)
[ "$_now" != missing ] || refuse "model changed since verification (missing)"
[ "$_now" = "$_ssize $_sinode $_smtime" ] || refuse "model changed since verification"

# 2. Binary.
[ -x "$BIN" ] || refuse "binary missing"

# 3. Port free.
if _pids=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null) && [ -n "$_pids" ]; then
    refuse "port $PORT already bound by pid(s) $(echo "$_pids" | tr '\n' ' ')"
fi

# 4. Guard trip.
[ ! -e "$TRIP_MARKER" ] || refuse "guard tripped (sudo /usr/local/libexec/mac-studio-server/mss-enable.sh)"

# 5. pf marker from this boot (ds4 has no auth; a LAN bind never starts
#    without the firewall verified this boot).
if ! mss_is_loopback_host "$HOST"; then
    _boot=$(sysctl -n kern.boottime 2>/dev/null || echo unavailable)
    _waited=0
    while ! { [ -r "$BOOT_MARKER" ] && [ "$(cat "$BOOT_MARKER" 2>/dev/null)" = "$_boot" ]; }; do
        [ "$_waited" -ge 120 ] && refuse "pf (no boot marker matching this kern.boottime after ${_waited}s)"
        sleep 1
        _waited=$((_waited + 1))
        _boot=$(sysctl -n kern.boottime 2>/dev/null || echo unavailable)
    done
fi

# 6. Wired limit applied (boot race with com.mac-studio-server.gpumemory).
if [ -n "$WIRED_LIMIT" ]; then
    _waited=0
    while :; do
        _cur=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
        [ "$_cur" -ge "$WIRED_LIMIT" ] && break
        [ "$_waited" -ge 120 ] && refuse "wired limit $_cur < expected $WIRED_LIMIT"
        sleep 2
        _waited=$((_waited + 2))
    done
fi

set -- "$BIN" -m "$MODEL" --host "$HOST" --port "$PORT" --ctx "$CTX"
case "$SESSIONS" in
    '') ;;
    *[!0-9]*|0|1) ;;
    *) set -- "$@" --batched-session "$SESSIONS" ;;
esac
# shellcheck disable=SC2086  # validated, whitespace-split allowlist tokens
[ -n "$ARGS" ] && set -- "$@" $ARGS

echo "START: $(date -u +%Y-%m-%dT%H:%M:%SZ) backend=$BACKEND bin=$BIN model=$MODEL host=$HOST port=$PORT ctx=$CTX"
exec "$@"
