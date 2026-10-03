#!/bin/sh
# llamacpp-start.sh — fail-closed wrapper, then exec llama-server (#9 D4).
# Runs as the service user via com.mac-studio-server.llamacpp (root daemon,
# UserName <service user>). Every check refuses with one line and exit 78.

set -u

BACKEND=llamacpp
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

# Only the active backend starts (#1 D4).
ACTIVE=$(mss_conf_get MSS_GUARD_BACKEND)
[ "$ACTIVE" = "$BACKEND" ] || refuse "$BACKEND is not the active backend (active: ${ACTIVE:-none})"

# No other model server, managed or not: this runs before our own exec, so any
# match is another server, and the guard watches only one process.
# Ollama's verified embedding worker is part of Ollama, which runs beside any
# backend (#35). This job runs as the service user, so the worker must too.
_srv=$(mss_start_blocker "$(id -u)") || refuse "pgrep is missing; cannot check for other model servers"
[ -z "$_srv" ] || refuse "model server already running (${_srv%% *} pid ${_srv#* })"
BIN=$(mss_conf_get LLAMACPP_BIN)
[ -n "$BIN" ] || refuse "conf missing LLAMACPP_BIN"
MODEL=$(mss_conf_get LLAMACPP_MODEL)
[ -n "$MODEL" ] || refuse "conf missing LLAMACPP_MODEL"
HOST=$(mss_conf_get LLAMACPP_HOST); HOST=${HOST:-127.0.0.1}
PORT=$(mss_conf_get LLAMACPP_PORT); PORT=${PORT:-8080}
API_KEY_FILE=$(mss_conf_get LLAMACPP_API_KEY_FILE)
CTX=$(mss_conf_get LLAMACPP_CTX)
PARALLEL=$(mss_conf_get LLAMACPP_PARALLEL)
ARGS=$(mss_conf_get LLAMACPP_ARGS)
WIRED_LIMIT=$(mss_conf_get MSS_WIRED_LIMIT_MB)

# 1. The model is the exact file verified at install (size inode mtime). No
#    re-hash of a 100+ GiB artifact at every start.
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

# 5. pf marker from this boot, whenever a LAN bind has a pf policy. A LAN bind
#    without an allowlist is only accepted at install with an API key.
PF_RULE_COUNT=$(mss_conf_get MSS_PF_RULE_COUNT); PF_RULE_COUNT=${PF_RULE_COUNT:-0}
if ! mss_is_loopback_host "$HOST" && { [ "$PF_RULE_COUNT" != 0 ] || [ -z "$API_KEY_FILE" ]; }; then
    _waited=0
    until mss_boot_marker_ok "$BOOT_MARKER"; do
        [ "$_waited" -ge 120 ] && refuse "pf (no boot marker for this boot session after ${_waited}s)"
        sleep 1
        _waited=$((_waited + 1))
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

set -- "$BIN" -m "$MODEL" --host "$HOST" --port "$PORT"
[ -n "$API_KEY_FILE" ] && set -- "$@" --api-key-file "$API_KEY_FILE"
[ -n "$CTX" ] && set -- "$@" -c "$CTX"
[ -n "$PARALLEL" ] && set -- "$@" -np "$PARALLEL"
# shellcheck disable=SC2086  # validated, whitespace-split allowlist tokens
[ -n "$ARGS" ] && set -- "$@" $ARGS

echo "START: $(date -u +%Y-%m-%dT%H:%M:%SZ) backend=$BACKEND bin=$BIN model=$MODEL host=$HOST port=$PORT"
exec "$@"
