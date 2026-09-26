#!/bin/sh
# install-backends.sh — root part of the mac-studio-server 1.3.0 installer (#9).
#
#   sudo env <vars> scripts/install-backends.sh [--render-only DIR]
#
# Validates EVERYTHING first: a bad variable must abort before any system
# change. Then renders backends.conf, pf.conf and plists, installs files with
# the ownership table from the issue, and bootstraps boot -> backend -> guard.
#
# --render-only DIR writes the rendered files (and the model stamp) into DIR
# without root, launchd or pf — used by tests. In that mode MSS_PFCTL may point
# at a stub; production always renders /sbin/pfctl unless explicitly overridden.

set -u

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib/mss-common.sh"

usage() { echo "usage: install-backends.sh [--render-only DIR]" >&2; exit 2; }

RENDER_ONLY=""
if [ "${1:-}" = "--render-only" ]; then
    [ -n "${2:-}" ] || usage
    RENDER_ONLY=$2
    shift 2
fi
[ $# -eq 0 ] || usage

# ── inputs (env) ───────────────────────────────────────────────────────────────
MSS_BACKENDS=${MSS_BACKENDS:-ollama}
MSS_SERVICE_USER=${OLLAMA_USER:-$(id -un)}
OLLAMA_BIND=${OLLAMA_BIND:-0.0.0.0}
LLAMACPP_BIN=${LLAMACPP_BIN:-}
LLAMACPP_MODEL=${LLAMACPP_MODEL:-}
LLAMACPP_MODEL_SHA256=${LLAMACPP_MODEL_SHA256:-}
LLAMACPP_HOST=${LLAMACPP_HOST:-127.0.0.1}
LLAMACPP_PORT=${LLAMACPP_PORT:-8080}
LLAMACPP_ALLOW_FROM=${LLAMACPP_ALLOW_FROM:-}
LLAMACPP_API_KEY_FILE=${LLAMACPP_API_KEY_FILE:-}
LLAMACPP_CTX=${LLAMACPP_CTX:-}
LLAMACPP_PARALLEL=${LLAMACPP_PARALLEL:-}
LLAMACPP_EXTRA_ARGS=${LLAMACPP_EXTRA_ARGS:-}
DS4_BIN=${DS4_BIN:-}
DS4_MODEL=${DS4_MODEL:-}
DS4_MODEL_SHA256=${DS4_MODEL_SHA256:-}
DS4_HOST=${DS4_HOST:-127.0.0.1}
DS4_PORT=${DS4_PORT:-8000}
DS4_ALLOW_FROM=${DS4_ALLOW_FROM:-}
DS4_CTX=${DS4_CTX:-65536}
DS4_BATCHED_SESSIONS=${DS4_BATCHED_SESSIONS:-}
DS4_WORKDIR=${DS4_WORKDIR:-}
DS4_EXTRA_ARGS=${DS4_EXTRA_ARGS:-}
MSS_GUARD_FREE_PCT=${MSS_GUARD_FREE_PCT:-10}
MSS_GUARD_SWAP_HEADROOM_MB=${MSS_GUARD_SWAP_HEADROOM_MB:-2048}
MSS_GUARD_STREAK=${MSS_GUARD_STREAK:-3}
MSS_LOG_MAX_MB=${MSS_LOG_MAX_MB:-100}
MSS_PFCTL=${MSS_PFCTL:-/sbin/pfctl}

LIBEXEC_DIR="/usr/local/libexec/mac-studio-server"
ETC_DIR="/usr/local/etc/mac-studio-server"
DB_DIR="/var/db/mac-studio-server"
LOG_DIR="/var/log/mac-studio-server"
PLIST_DIR="/Library/LaunchDaemons"
CONF="$ETC_DIR/backends.conf"
PF_FILE="$ETC_DIR/pf.conf"
STAMP_DIR=$DB_DIR

if [ -z "$RENDER_ONLY" ] && [ "$(id -u)" -ne 0 ]; then
    mss_die "install-backends.sh must run as root (or use --render-only)"
fi

# ── phase 1: validation (no system changes before this completes) ─────────────
mss_validate_selection "$MSS_BACKENDS" || exit 1

if mss_backend_selected ollama; then
    mss_validate_ipv4 "$OLLAMA_BIND" || mss_die "OLLAMA_BIND: '$OLLAMA_BIND' must be a single IPv4 address"
    mss_is_loopback_host "$OLLAMA_BIND" || \
        echo "WARNING: Ollama is LAN-bound on $OLLAMA_BIND — ensure your network is trusted." >&2
fi

_has_optional=0
_optional=""

validate_port_free() {
    _port=$1 _var=$2
    _pids=$(lsof -nP -iTCP:"$_port" -sTCP:LISTEN -t 2>/dev/null)
    [ -z "$_pids" ] || mss_die "$_var: port $_port is already bound by pid(s) $(echo $_pids | tr '\n' ' ')"
}

validate_optional_backend() {
    _b=$1
    _upper=$(echo "$_b" | tr '[:lower:]' '[:upper:]')
    case $_b in
        llamacpp)
            _bin=$LLAMACPP_BIN; _model=$LLAMACPP_MODEL; _sha=$LLAMACPP_MODEL_SHA256
            _host=$LLAMACPP_HOST; _port=$LLAMACPP_PORT; _allow=$LLAMACPP_ALLOW_FROM; _extra=$LLAMACPP_EXTRA_ARGS
            ;;
        ds4)
            _bin=$DS4_BIN; _model=$DS4_MODEL; _sha=$DS4_MODEL_SHA256
            _host=$DS4_HOST; _port=$DS4_PORT; _allow=$DS4_ALLOW_FROM; _extra=$DS4_EXTRA_ARGS
            ;;
    esac

    [ -n "$_bin" ]   || mss_die "${_upper}_BIN is required when '$_b' is selected"
    [ -n "$_model" ] || mss_die "${_upper}_MODEL is required when '$_b' is selected"
    mss_validate_sha256 "${_upper}_MODEL_SHA256" "$_sha" || exit 1

    case $(basename "$_model") in
        *-[0-9]*-of-[0-9]*.gguf) mss_die "${_upper}_MODEL: split GGUF sets are not supported" ;;
    esac

    _resolved_bin=$(mss_resolve_path "$_bin") || exit 1
    [ -f "$_resolved_bin" ] || mss_die "${_upper}_BIN: not a regular file: $_resolved_bin"
    [ -x "$_resolved_bin" ] || mss_die "${_upper}_BIN: not executable: $_resolved_bin"
    case $_b in
        llamacpp) LLAMACPP_BIN_RESOLVED=$_resolved_bin ;;
        ds4) DS4_BIN_RESOLVED=$_resolved_bin ;;
    esac

    _resolved_model=$(mss_resolve_path "$_model") || exit 1
    [ -f "$_resolved_model" ] || mss_die "${_upper}_MODEL: not a regular file: $_resolved_model"
    case $_b in
        llamacpp) LLAMACPP_MODEL_RESOLVED=$_resolved_model ;;
        ds4) DS4_MODEL_RESOLVED=$_resolved_model ;;
    esac

    mss_validate_host "${_upper}_HOST" "$_host" || exit 1
    if ! mss_is_loopback_host "$_host"; then
        mss_host_is_local "$_host" || mss_die "${_upper}_HOST: '$_host' is neither loopback nor assigned to a local interface"
    fi
    mss_validate_port "${_upper}_PORT" "$_port" || exit 1
    mss_validate_allowlist "${_upper}_ALLOW_FROM" "$_allow" || exit 1

    # LAN bind policy
    if ! mss_is_loopback_host "$_host"; then
        if [ "$_b" = ds4 ]; then
            [ -n "$_allow" ] || mss_die "DS4_ALLOW_FROM is required: ds4 has no authentication and DS4_HOST is not loopback"
        else
            if [ -z "$_allow" ] && [ -z "$LLAMACPP_API_KEY_FILE" ]; then
                mss_die "LLAMACPP_ALLOW_FROM (or LLAMACPP_API_KEY_FILE) is required for a LAN bind"
            fi
            if [ -z "$_allow" ] && [ -n "$LLAMACPP_API_KEY_FILE" ]; then
                echo "WARNING: llama-server is LAN-bound with an API key only — the key is the sole protection." >&2
            fi
        fi
    fi

    _parsed=$(mss_validate_extra_args "$_b" "$_extra" "${_upper}_EXTRA_ARGS") || exit 1
    case $_b in
        llamacpp) LLAMACPP_ARGS=$_parsed ;;
        ds4) DS4_ARGS=$_parsed ;;
    esac

    validate_port_free "$_port" "${_upper}_PORT"
}

if mss_backend_selected llamacpp; then
    _has_optional=1; _optional=llamacpp
    mss_validate_key_file LLAMACPP_API_KEY_FILE "$LLAMACPP_API_KEY_FILE" "$MSS_SERVICE_USER" || exit 1
    validate_optional_backend llamacpp
fi
if mss_backend_selected ds4; then
    _has_optional=1; _optional=ds4
    validate_optional_backend ds4
fi

if mss_backend_selected llamacpp && mss_backend_selected ds4; then
    mss_die "MSS_BACKENDS: at most one optional backend"
fi
if mss_backend_selected ollama && [ "$_has_optional" = 1 ]; then
    [ "$LLAMACPP_PORT" != 11434 ] || mss_die "port collision: LLAMACPP_PORT equals Ollama's 11434"
    [ "$DS4_PORT" != 11434 ] || mss_die "port collision: DS4_PORT equals Ollama's 11434"
fi

# Guard threshold sanity.
echo "$MSS_GUARD_STREAK" | grep -Eq '^[0-9]+$' && [ "$MSS_GUARD_STREAK" -ge 1 ] || mss_die "MSS_GUARD_STREAK must be a positive integer"
echo "$MSS_GUARD_FREE_PCT" | grep -Eq '^[0-9]+$' && [ "$MSS_GUARD_FREE_PCT" -ge 1 ] && [ "$MSS_GUARD_FREE_PCT" -le 99 ] || mss_die "MSS_GUARD_FREE_PCT must be 1..99"
echo "$MSS_GUARD_SWAP_HEADROOM_MB" | grep -Eq '^[0-9]+$' || mss_die "MSS_GUARD_SWAP_HEADROOM_MB must be an integer"
echo "$MSS_LOG_MAX_MB" | grep -Eq '^[0-9]+$' && [ "$MSS_LOG_MAX_MB" -ge 1 ] || mss_die "MSS_LOG_MAX_MB must be a positive integer"

# Re-install with a different optional backend: refuse (D7).
_installed_opt=""
if [ -r "$CONF" ]; then
    _installed_opt=$(awk -F= 'index($0,"MSS_GUARD_BACKEND=")==1{print substr($0,length("MSS_GUARD_BACKEND=")+1)}' "$CONF")
    if [ -n "$_installed_opt" ] && [ -n "$_optional" ] && [ "$_installed_opt" != "$_optional" ]; then
        mss_die "installed optional backend is '$_installed_opt'; run scripts/uninstall.sh --backend $_installed_opt first"
    fi
fi

# Wired limit: same integer formula and evaluation order as set-gpu-memory.sh.
MSS_WIRED_LIMIT_MB=""
if [ -n "${OLLAMA_GPU_PERCENT:-}" ]; then
    echo "$OLLAMA_GPU_PERCENT" | grep -Eq '^[0-9]+$' && [ "$OLLAMA_GPU_PERCENT" -ge 1 ] && [ "$OLLAMA_GPU_PERCENT" -le 100 ] \
        || mss_die "OLLAMA_GPU_PERCENT must be 1..100"
    MSS_WIRED_LIMIT_MB=$(mss_wired_limit_mb "$OLLAMA_GPU_PERCENT")
fi

# ── phase 2: render ────────────────────────────────────────────────────────────
if [ -n "$RENDER_ONLY" ]; then
    ETC_DIR=$RENDER_ONLY; CONF=$RENDER_ONLY/backends.conf; PF_FILE=$RENDER_ONLY/pf.conf
    PLIST_DIR=$RENDER_ONLY; STAMP_DIR=$RENDER_ONLY; LIBEXEC_OUT=$RENDER_ONLY
else
    LIBEXEC_OUT=$LIBEXEC_DIR
fi

# pf policy: one block per LAN-bound optional backend port.
PF_RULES=""
PF_SPECS=""
if [ -n "$_optional" ]; then
    case $_optional in
        llamacpp) _oh=$LLAMACPP_HOST; _op=$LLAMACPP_PORT; _oa=$LLAMACPP_ALLOW_FROM ;;
        ds4)      _oh=$DS4_HOST; _op=$DS4_PORT; _oa=$DS4_ALLOW_FROM ;;
    esac
    if ! mss_is_loopback_host "$_oh"; then
        PF_RULES="pass in quick on lo0 proto tcp to any port $_op"
        for _e in $_oa; do
            PF_RULES="$PF_RULES
pass in quick proto tcp from $_e to any port $_op"
        done
        PF_RULES="$PF_RULES
block in quick proto tcp to any port $_op"
        PF_SPECS="$_op:$_oa"
    fi
fi
# shellcheck disable=SC2086  # PF_SPECS is one "port:entries" word per LAN-bound port
PF_RULE_COUNT=$(mss_pf_rule_count $PF_SPECS)
HAS_PF_POLICY=0; [ -n "$PF_RULES" ] && HAS_PF_POLICY=1

render_placeholders() {
    # sed-safe value substitution: values are paths, numbers, users and
    # validated tokens — none contain & or backslashes.
    sed \
        -e "s|<OLLAMA_USER>|$MSS_SERVICE_USER|g" \
        -e "s|<MSS_WORKDIR>|${_WORKDIR:-/var/log/mac-studio-server}|g"
}

# ── phase 3: write outputs ─────────────────────────────────────────────────────
if [ -z "$RENDER_ONLY" ]; then
    mkdir -p "$LIBEXEC_DIR" "$ETC_DIR" "$DB_DIR" "$LOG_DIR"
    chown root:wheel "$LIBEXEC_DIR" "$ETC_DIR" "$DB_DIR" "$LOG_DIR"
    chmod 0755 "$LIBEXEC_DIR" "$ETC_DIR" "$DB_DIR" "$LOG_DIR"
else
    mkdir -p "$RENDER_ONLY"
fi

# scripts
for f in mss-common.sh mss-boot.sh mss-enable.sh mss-guard.sh llamacpp-start.sh ds4-start.sh; do
    src="$REPO_DIR/libexec/$f"
    [ -f "$src" ] || src="$REPO_DIR/scripts/lib/$f"
    cp "$src" "$LIBEXEC_OUT/$f.tmp"
    chmod 0755 "$LIBEXEC_OUT/$f.tmp"
    if [ -z "$RENDER_ONLY" ]; then chown root:wheel "$LIBEXEC_OUT/$f.tmp"; fi
    mv "$LIBEXEC_OUT/$f.tmp" "$LIBEXEC_OUT/$f"
done

# conf
_WORKDIR=""
if [ "$_optional" = ds4 ]; then
    _WORKDIR=${DS4_WORKDIR:-$(dirname "$DS4_BIN_RESOLVED")}
fi
{
    echo "MSS_BACKENDS=$MSS_BACKENDS"
    echo "MSS_SERVICE_USER=$MSS_SERVICE_USER"
    echo "OLLAMA_BIND=$OLLAMA_BIND"
    [ -n "$_optional" ] && echo "MSS_GUARD_BACKEND=$_optional"
    echo "MSS_PFCTL=$MSS_PFCTL"
    echo "MSS_PF_RULE_COUNT=$PF_RULE_COUNT"
    [ -n "$MSS_WIRED_LIMIT_MB" ] && echo "MSS_WIRED_LIMIT_MB=$MSS_WIRED_LIMIT_MB"
    echo "MSS_GUARD_FREE_PCT=$MSS_GUARD_FREE_PCT"
    echo "MSS_GUARD_SWAP_HEADROOM_MB=$MSS_GUARD_SWAP_HEADROOM_MB"
    echo "MSS_GUARD_STREAK=$MSS_GUARD_STREAK"
    echo "MSS_LOG_MAX_MB=$MSS_LOG_MAX_MB"
    if mss_backend_selected llamacpp; then
        echo "LLAMACPP_BIN=$LLAMACPP_BIN_RESOLVED"
        echo "LLAMACPP_MODEL=$LLAMACPP_MODEL_RESOLVED"
        echo "LLAMACPP_HOST=$LLAMACPP_HOST"
        echo "LLAMACPP_PORT=$LLAMACPP_PORT"
        echo "LLAMACPP_API_KEY_FILE=$LLAMACPP_API_KEY_FILE"
        echo "LLAMACPP_CTX=$LLAMACPP_CTX"
        echo "LLAMACPP_PARALLEL=$LLAMACPP_PARALLEL"
        echo "LLAMACPP_ARGS=$LLAMACPP_ARGS"
    fi
    if mss_backend_selected ds4; then
        echo "DS4_BIN=$DS4_BIN_RESOLVED"
        echo "DS4_MODEL=$DS4_MODEL_RESOLVED"
        echo "DS4_HOST=$DS4_HOST"
        echo "DS4_PORT=$DS4_PORT"
        echo "DS4_CTX=$DS4_CTX"
        echo "DS4_BATCHED_SESSIONS=$DS4_BATCHED_SESSIONS"
        echo "DS4_ARGS=$DS4_ARGS"
    fi
} > "$CONF.tmp"
if [ -z "$RENDER_ONLY" ]; then chown root:wheel "$CONF.tmp"; fi
chmod 0644 "$CONF.tmp"
mv "$CONF.tmp" "$CONF"

# pf rules
{
    echo "# mac-studio-server pf policy (rendered; anchor com.apple/250.mac-studio-server)"
    if [ -n "$PF_RULES" ]; then
        echo "# backend $_optional port block"
        echo "$PF_RULES"
    fi
} > "$PF_FILE.tmp"
chmod 0644 "$PF_FILE.tmp"
if [ -z "$RENDER_ONLY" ]; then chown root:wheel "$PF_FILE.tmp"; fi
mv "$PF_FILE.tmp" "$PF_FILE"

# model stamp (skip the re-hash when the existing stamp matches stat)
stamp_backend() {
    _b=$1; _resolved=$2; _expected=$3
    _stamp="$STAMP_DIR/$_b.model.verified"
    _stat=$(stat -f '%z %i %m' "$_resolved" 2>/dev/null) || mss_die "stat failed: $_resolved"
    if [ -r "$_stamp" ]; then
        read -r _sp _ss _si _sm _sh < "$_stamp" || _sp=""
        if [ "$_sp" = "$_resolved" ] && [ "$_ss $_si $_sm" = "$_stat" ]; then
            echo "stamp unchanged for $_b (skipping re-hash)"
            return 0
        fi
    fi
    echo "hashing $_resolved ..."
    _actual=$(shasum -a 256 "$_resolved" | awk '{print $1}')
    [ "$_actual" = "$(echo "$_expected" | tr '[:upper:]' '[:lower:]')" ] \
        || mss_die "$_b model sha256 mismatch (expected $_expected, got $_actual)"
    printf '%s %s %s\n' "$_resolved" "$_stat" "$_actual" > "$_stamp.tmp"
    if [ -z "$RENDER_ONLY" ]; then chown root:wheel "$_stamp.tmp"; fi
    chmod 0644 "$_stamp.tmp"
    mv "$_stamp.tmp" "$_stamp"
}
if mss_backend_selected llamacpp; then stamp_backend llamacpp "$LLAMACPP_MODEL_RESOLVED" "$LLAMACPP_MODEL_SHA256"; fi
if mss_backend_selected ds4; then stamp_backend ds4 "$DS4_MODEL_RESOLVED" "$DS4_MODEL_SHA256"; fi

# plists
install_plist() {
    _src=$1 _dst=$2
    render_placeholders < "$REPO_DIR/config/$_src" > "$_dst.tmp"
    if [ -z "$RENDER_ONLY" ]; then chown root:wheel "$_dst.tmp"; fi
    chmod 0644 "$_dst.tmp"
    mv "$_dst.tmp" "$_dst"
}
if [ -n "$_optional" ]; then
    install_plist "com.mac-studio-server.$_optional.plist" "$PLIST_DIR/com.mac-studio-server.$_optional.plist"
    install_plist "com.mac-studio-server.guard.plist" "$PLIST_DIR/com.mac-studio-server.guard.plist"
fi
if [ "$HAS_PF_POLICY" = 1 ]; then
    install_plist "com.mac-studio-server.boot.plist" "$PLIST_DIR/com.mac-studio-server.boot.plist"
fi

# ── phase 4: bootstrap (boot -> backend -> guard) ─────────────────────────────
if [ -n "$RENDER_ONLY" ]; then
    echo "render-only: conf, pf rules, plists and stamps written to $RENDER_ONLY"
    exit 0
fi

# pre-create runtime files with the ownership table
if [ -n "$_optional" ]; then
    if [ ! -f "$LOG_DIR/$_optional.log" ]; then
        : > "$LOG_DIR/$_optional.log"
        chown "$MSS_SERVICE_USER:staff" "$LOG_DIR/$_optional.log"
        chmod 0640 "$LOG_DIR/$_optional.log"
    fi
    if [ ! -f "$LOG_DIR/guard.jsonl" ]; then
        : > "$LOG_DIR/guard.jsonl"
        chown root:wheel "$LOG_DIR/guard.jsonl"
        chmod 0644 "$LOG_DIR/guard.jsonl"
    fi
fi

BOOTSTRAP=""
[ "$HAS_PF_POLICY" = 1 ] && BOOTSTRAP="$BOOTSTRAP boot"
[ -n "$_optional" ] && BOOTSTRAP="$BOOTSTRAP $_optional"
[ -n "$_optional" ] && BOOTSTRAP="$BOOTSTRAP guard"

for label in $BOOTSTRAP; do
    launchctl bootout "system/com.mac-studio-server.$label" 2>/dev/null || true
done
for label in $BOOTSTRAP; do
    launchctl bootstrap system "$PLIST_DIR/com.mac-studio-server.$label.plist" \
        || mss_die "launchctl bootstrap failed for com.mac-studio-server.$label"
    echo "bootstrapped com.mac-studio-server.$label"
done

echo "install-backends: done (backends: $MSS_BACKENDS; pf rules: $PF_RULE_COUNT)"
