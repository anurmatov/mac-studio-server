#!/bin/sh
# mlx-start.sh — fail-closed wrapper, then exec mlx-serve (#1 D7).
# Runs as the service user via com.mac-studio-server.mlx. mlx-serve listens on
# 0.0.0.0 by default, so --host is always passed: 127.0.0.1, or the LAN address
# in the conf (#33). mlx-serve has no auth, so a LAN bind additionally requires
# this boot's pf marker below. One resident model, no log file of its own.

set -u

BACKEND=mlx
_self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$_self_dir/mss-common.sh" ]; then
    . "$_self_dir/mss-common.sh"
else
    . "$_self_dir/../scripts/lib/mss-common.sh"
fi

# MSS_STAMP_DIR, MSS_BOOT_MARKER, MSS_MARKER_WAIT and MSS_HOST_WAIT are test
# hooks: launchd starts this job with no environment.
DB_DIR=${MSS_STAMP_DIR:-/var/db/mac-studio-server}
TRIP_MARKER="$DB_DIR/guard.tripped"
STAMP="$DB_DIR/$BACKEND.model.verified"
BOOT_MARKER=${MSS_BOOT_MARKER:-/var/run/com.mac-studio-server.boot.ok}
MARKER_WAIT=${MSS_MARKER_WAIT:-120}
HOST_WAIT=${MSS_HOST_WAIT:-120}

refuse() { echo "REFUSE: $1"; exit 78; }

# refuse must run in this shell: inside $(...) it would only exit the subshell.
[ -r "$(mss_conf_path)" ] || refuse "conf missing ($(mss_conf_path))"

# 1. The conf names the binary, the model directory, the host and the port.
#    No MLX_HOST line means loopback (#33 D5).
BIN=$(mss_conf_get MLX_BIN)
[ -n "$BIN" ] || refuse "conf missing MLX_BIN"
MODEL_DIR=$(mss_conf_get MLX_MODEL_DIR)
[ -n "$MODEL_DIR" ] || refuse "conf missing MLX_MODEL_DIR"
HOST=$(mss_conf_get MLX_HOST); HOST=${HOST:-127.0.0.1}
PORT=$(mss_conf_get MLX_PORT)
[ -n "$PORT" ] || refuse "conf missing MLX_PORT"
CTX=$(mss_conf_get MLX_CTX)
ARGS=$(mss_conf_get MLX_ARGS)
WIRED_LIMIT=$(mss_conf_get MSS_WIRED_LIMIT_MB)

# 2. Only the active backend starts (#1 D4).
ACTIVE=$(mss_conf_get MSS_GUARD_BACKEND)
[ "$ACTIVE" = "$BACKEND" ] || refuse "$BACKEND is not the active backend (active: ${ACTIVE:-none})"

# 3. No other model server, managed or not: the guard watches one process.
# Ollama's verified embedding worker is part of Ollama, which runs beside any
# backend (#35). This job runs as the service user, so the worker must too.
_srv=$(mss_start_blocker "$(id -u)") || refuse "pgrep is missing; cannot check for other model servers"
[ -z "$_srv" ] || refuse "model server already running (${_srv%% *} pid ${_srv#* })"

# 4. The model directory is the one verified at install: names, sizes, inodes
#    and mtimes only. No file content under it is read.
[ -r "$STAMP" ] || refuse "model not verified (manifest missing)"
_now=$(mss_mlx_manifest "$MODEL_DIR" 2>/dev/null) || refuse "model changed since verification (cannot list $MODEL_DIR)"
[ "$_now" = "$(cat "$STAMP")" ] || refuse "model changed since verification (manifest differs)"

# 5. Binary, and exactly the pinned version.
[ -x "$BIN" ] || refuse "binary missing"
_ver=$(mss_mlx_version_ok "$BIN" "" MLX_BIN 2>&1) || refuse "${_ver#ERROR: }"

# 6. Port free.
if _pids=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null) && [ -n "$_pids" ]; then
    refuse "port $PORT already bound by pid(s) $(echo "$_pids" | tr '\n' ' ')"
fi

# 7. Guard trip.
[ ! -e "$TRIP_MARKER" ] || refuse "guard tripped (sudo /usr/local/libexec/mac-studio-server/mss-enable.sh)"

# 8. A LAN bind (#33 D3). No providers file: allowed clients could spend its
#    third-party credentials through <model>@<provider>. mlx-serve reads it
#    from $HOME, or /tmp when HOME is unset; the exec below keeps this
#    environment, so this is the path it would read. Then this boot's pf
#    marker, as for ds4: never a LAN bind without the firewall verified.
#    The marker holds the boot-session id, not kern.boottime, which moves when
#    the clock is set after boot.
if ! mss_is_loopback_host "$HOST"; then
    _providers="${HOME-/tmp}/.mlx-serve/providers.json"
    [ ! -e "$_providers" ] || refuse "providers file present ($_providers); a LAN bind would share its credentials"
    _waited=0
    until mss_boot_marker_ok "$BOOT_MARKER"; do
        [ "$_waited" -ge "$MARKER_WAIT" ] && refuse "pf (no boot marker for this boot session after ${_waited}s)"
        sleep 1
        _waited=$((_waited + 1))
    done
fi

# 9. Wired limit applied (boot race with com.mac-studio-server.gpumemory).
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

# 10. The selected address is on an interface (#33). At boot this job can run
#     before the network has configured MLX_HOST, and mlx-serve would exit
#     with AddressUnavailable. Wait for it, bounded, then refuse.
if ! mss_is_loopback_host "$HOST" && ! mss_host_is_local "$HOST"; then
    echo "WAIT: $HOST is not on any interface yet (up to ${HOST_WAIT}s)"
    _waited=0
    until mss_host_is_local "$HOST"; do
        [ "$_waited" -ge "$HOST_WAIT" ] && refuse "address $HOST is not on any interface after ${_waited}s"
        sleep 1
        _waited=$((_waited + 1))
    done
fi

set -- "$BIN" --serve --model "$MODEL_DIR" --host "$HOST" --port "$PORT" --max-resident-models 1 --log-file off
[ -n "$CTX" ] && set -- "$@" --ctx-size "$CTX"
# shellcheck disable=SC2086  # validated, whitespace-split allowlist tokens
[ -n "$ARGS" ] && set -- "$@" $ARGS

echo "START: $(date -u +%Y-%m-%dT%H:%M:%SZ) backend=$BACKEND bin=$BIN model=$MODEL_DIR host=$HOST port=$PORT ctx=${CTX:-default}"
# exec keeps one PID: launchd's, mlx-serve's and the guard's are the same.
exec "$@"
