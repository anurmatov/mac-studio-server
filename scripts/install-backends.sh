#!/bin/sh
# install-backends.sh — root part of the mac-studio-server 1.3.0 installer (#9).
#
#   sudo env <vars> scripts/install-backends.sh [--check-only | --render-only DIR]
#
# Validates EVERYTHING first, including the model sha256: a bad variable or
# model must abort before any system change. Then writes the model stamp,
# renders backends.conf, pf.conf and plists, installs files with the ownership
# table from the issue, and bootstraps boot -> backend -> guard. Before any
# bootstrap it stops every job and waits for launchd to release its label (#18),
# and with a pf policy the backend starts only after this run's boot job has
# verified pf.
#
# --check-only runs only the validation and the hash; install.sh calls it before
# touching Ollama. As root, and only on a matching hash, it writes the model
# stamp (the only thing it may create), so the install does not hash again. A
# sha256 mismatch exits 3. --render-only DIR writes the rendered files (and the
# model stamp) into DIR without root, launchd or pf — used by tests. In that mode
# MSS_PFCTL may point at a stub; production always renders /sbin/pfctl unless
# explicitly overridden.
#
# MSS_DEFER_MODEL=yes installs the optional backend without a model: the conf
# says MSS_MODEL_STATE=waiting and no backend or guard job is installed.
#
# MSS_LAUNCHD_TIMEOUT (seconds, default 60) bounds each wait for a job to stop
# and for the boot job's pf marker. It exists for tests and for Macs that are
# unusually slow to stop the backend.

set -u
# sudo inherits the caller's umask; with 077, mkdir -p would create a missing
# /usr/local/libexec or /usr/local/etc that the service user cannot traverse.
umask 022

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib/mss-common.sh"

usage() { echo "usage: install-backends.sh [--check-only | --render-only DIR]" >&2; exit 2; }

RENDER_ONLY=""
CHECK_ONLY=0
case ${1:-} in
    --render-only)
        [ -n "${2:-}" ] || usage
        RENDER_ONLY=$2
        shift 2
        ;;
    --check-only)
        CHECK_ONLY=1
        shift
        ;;
esac
[ $# -eq 0 ] || usage
# tests/run.sh points non-root lookups under a sysroot (#21); a root pass must
# only ever see the real system.
[ -z "${MSS_TEST_SYSROOT:-}" ] || [ "$(id -u)" -ne 0 ] \
    || mss_die "MSS_TEST_SYSROOT is for tests/run.sh only and is refused as root"

# ── inputs (env) ───────────────────────────────────────────────────────────────
MSS_BACKENDS=${MSS_BACKENDS:-ollama}
# Under a direct `sudo`, id -un is root; the invoking user is the default.
MSS_SERVICE_USER=${OLLAMA_USER:-${SUDO_USER:-$(id -un)}}
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
# Set only by install.sh --configure(-only) when switching optional backends.
MSS_REPLACE_BACKEND=${MSS_REPLACE_BACKEND:-}
MSS_DEFER_MODEL=${MSS_DEFER_MODEL:-}
MSS_PROGRESS_SECONDS=${MSS_PROGRESS_SECONDS:-10}
MSS_LAUNCHD_TIMEOUT=${MSS_LAUNCHD_TIMEOUT:-60}

LIBEXEC_DIR="/usr/local/libexec/mac-studio-server"
ETC_DIR="/usr/local/etc/mac-studio-server"
DB_DIR="/var/db/mac-studio-server"
LOG_DIR="/var/log/mac-studio-server"
PLIST_DIR="/Library/LaunchDaemons"
CONF="$ETC_DIR/backends.conf"
PF_FILE="$ETC_DIR/pf.conf"
STAMP_DIR=${MSS_TEST_SYSROOT:-}$DB_DIR
[ -z "$RENDER_ONLY" ] || STAMP_DIR=$RENDER_ONLY

if [ -z "$RENDER_ONLY" ] && [ "$CHECK_ONLY" = 0 ] && [ "$(id -u)" -ne 0 ]; then
    mss_die "install-backends.sh must run as root (or use --check-only / --render-only)"
fi

# ── phase 1: validation (no system changes before this completes) ─────────────
mss_validate_selection "$MSS_BACKENDS" || exit 1
mss_validate_user OLLAMA_USER "$MSS_SERVICE_USER" || exit 1
if [ -z "$RENDER_ONLY" ]; then
    id -u "$MSS_SERVICE_USER" >/dev/null 2>&1 || mss_die "OLLAMA_USER: user '$MSS_SERVICE_USER' does not exist"
fi
mss_validate_path_chars MSS_PFCTL "$MSS_PFCTL" || exit 1
case $MSS_DEFER_MODEL in ''|yes) ;; *) mss_die "MSS_DEFER_MODEL must be yes or unset" ;; esac
mss_validate_uint MSS_PROGRESS_SECONDS "$MSS_PROGRESS_SECONDS" 1 60 || exit 1
mss_validate_uint MSS_LAUNCHD_TIMEOUT "$MSS_LAUNCHD_TIMEOUT" 1 600 || exit 1

# The optional backend already installed (backends.conf is world-readable).
# A root pass reads the installed conf. Without root (--render-only or
# --check-only) MSS_CONF may point elsewhere, as for the picker; every real
# install checks again as root.
_installed_conf=$CONF
[ "$(id -u)" -eq 0 ] || _installed_conf=$(mss_conf_path)
_installed_opt=""
if [ -r "$_installed_conf" ]; then
    _installed_opt=$(awk -F= 'index($0,"MSS_GUARD_BACKEND=")==1{print substr($0,length("MSS_GUARD_BACKEND=")+1)}' "$_installed_conf")
fi

# MSS_REPLACE_BACKEND lets the switch check see through the backend that is
# about to be removed: only with --check-only, only for the installed backend.
if [ -n "$MSS_REPLACE_BACKEND" ]; then
    [ "$CHECK_ONLY" = 1 ] || mss_die "MSS_REPLACE_BACKEND is accepted only with --check-only"
    [ "$MSS_REPLACE_BACKEND" = "$_installed_opt" ] \
        || mss_die "MSS_REPLACE_BACKEND='$MSS_REPLACE_BACKEND' is not the installed optional backend ('${_installed_opt:-none}')"
fi

mss_validate_ipv4 "$OLLAMA_BIND" || mss_die "OLLAMA_BIND: '$OLLAMA_BIND' must be a single IPv4 address"
if mss_backend_selected ollama; then
    mss_is_loopback_host "$OLLAMA_BIND" || \
        echo "WARNING: Ollama is LAN-bound on $OLLAMA_BIND — ensure your network is trusted." >&2
fi

_has_optional=0
_optional=""

# pid_is_under <pid> <ancestor>: true when pid is ancestor or one of its
# descendants. Walks ppid links, at most 32 hops.
pid_is_under() {
    _p=$1; _hops=0
    while [ -n "$_p" ] && [ "$_p" -gt 1 ] && [ "$_hops" -lt 32 ]; do
        [ "$_p" = "$2" ] && return 0
        _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')
        _hops=$((_hops + 1))
    done
    return 1
}

# A listener is fine only when it belongs to one of the given labels' running
# jobs (re-install, or the backend a switch replaces): its PID, or an ancestor,
# is that job's PID. The job PID comes from `launchctl print system/<label>`,
# which needs root, so the exemption is decided only in the root pass. A
# non-root pass (--check-only or --render-only) defers any listener to it.
validate_port_free() {
    _port=$1 _var=$2
    shift 2
    _pids=$(lsof -nP -iTCP:"$_port" -sTCP:LISTEN -t 2>/dev/null | sort -u)
    [ -n "$_pids" ] || return 0
    if [ "$(id -u)" -ne 0 ]; then
        echo "note: $_var: port $_port is in use; ownership is checked in the root install" >&2
        return 0
    fi
    _owns=""
    for _label in "$@"; do
        _own=$(launchctl print "system/$_label" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -n 1)
        [ -z "$_own" ] || _owns="$_owns $_own"
    done
    _foreign=""
    for _lp in $_pids; do
        _mine=0
        for _own in $_owns; do
            if pid_is_under "$_lp" "$_own"; then _mine=1; break; fi
        done
        [ "$_mine" = 1 ] || _foreign="$_foreign $_lp"
    done
    [ -z "$_foreign" ] && return 0
    mss_die "port $_port is in use (pid$_foreign); set $_var in backends.env and re-run"
}

gib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'; }

# hash_file <backend> <path> <size>: prints the sha256. Progress goes to stderr
# (U3): every MSS_PROGRESS_SECONDS, SIGINFO makes BSD dd report the bytes copied,
# and one final "done" line always ends it. The sum is read through a FIFO.
hash_file() {
    _hb=$1; _hp=$2; _hs=$3
    _ht=$(mktemp -d "${TMPDIR:-/tmp}/mss-hash.XXXXXX") || return 1
    if ! mkfifo "$_ht/fifo"; then rm -rf "$_ht"; return 1; fi
    mss_shasum256 < "$_ht/fifo" > "$_ht/sum" &
    _hsum=$!
    dd if="$_hp" of="$_ht/fifo" bs=16777216 2>"$_ht/dd.log" &
    _hdd=$!
    _hn=0; _hlast=""
    while kill -0 "$_hdd" 2>/dev/null; do
        sleep 1
        _hn=$((_hn + 1))
        [ "$_hn" -ge "$MSS_PROGRESS_SECONDS" ] || continue
        _hn=0
        _hnow=$(sed -n 's/^[[:space:]]*\([0-9][0-9]*\) bytes.*/\1/p' "$_ht/dd.log" | tail -n 1)
        if [ -n "$_hnow" ] && [ "$_hnow" != "$_hlast" ]; then
            echo "hashing $_hb model: $(gib "$_hnow") / $(gib "$_hs") GiB" >&2
            _hlast=$_hnow
        fi
        kill -INFO "$_hdd" 2>/dev/null
    done
    wait "$_hdd"; _hrc=$?
    wait "$_hsum"
    _hsha=$(awk '{print $1}' "$_ht/sum")
    rm -rf "$_ht"
    if [ "$_hrc" != 0 ] || [ -z "$_hsha" ]; then mss_error "reading $_hp failed"; return 1; fi
    echo "hashing $_hb model: done ($(gib "$_hs") GiB)" >&2
    printf '%s\n' "$_hsha"
}

# verify_model <backend> <resolved model> <expected sha>: prints the stamp line
# "path size inode mtime sha". Skips the re-hash only when the existing stamp
# matches the path, stat and expected sha. Writes nothing. A mismatch returns 3.
verify_model() {
    _vb=$1; _vpath=$2; _vwant=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
    _vstat=$(stat -f '%z %i %m' "$_vpath" 2>/dev/null) || { mss_error "stat failed: $_vpath"; return 1; }
    _vstamp="$STAMP_DIR/$_vb.model.verified"
    _vsha=""
    if [ -r "$_vstamp" ] && read -r _sp _ss _si _sm _sh < "$_vstamp" \
        && [ "$_sp" = "$_vpath" ] && [ "$_ss $_si $_sm" = "$_vstat" ] && [ "$_sh" = "$_vwant" ]; then
        echo "stamp unchanged for $_vb (skipping re-hash)" >&2
        _vsha=$_sh
    else
        _vsha=$(hash_file "$_vb" "$_vpath" "${_vstat%% *}") || return 1
        [ "$_vsha" = "$_vwant" ] || { mss_error "$_vb model sha256 mismatch (expected $_vwant, got $_vsha)"; return 3; }
    fi
    printf '%s %s %s\n' "$_vpath" "$_vstat" "$_vsha"
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
    if [ "$MSS_DEFER_MODEL" != yes ]; then
        [ -n "$_model" ] || mss_die "${_upper}_MODEL is required when '$_b' is selected"
        mss_validate_sha256 "${_upper}_MODEL_SHA256" "$_sha" || exit 1
        case $(basename "$_model") in
            *-[0-9]*-of-[0-9]*.gguf) mss_die "${_upper}_MODEL: split GGUF sets are not supported" ;;
        esac
    fi

    _resolved_bin=$(mss_resolve_path "$_bin") || exit 1
    mss_validate_path_chars "${_upper}_BIN (resolved)" "$_resolved_bin" || exit 1
    [ -f "$_resolved_bin" ] || mss_die "${_upper}_BIN: not a regular file: $_resolved_bin"
    [ -x "$_resolved_bin" ] || mss_die "${_upper}_BIN: not executable: $_resolved_bin"
    case $_b in
        llamacpp) LLAMACPP_BIN_RESOLVED=$_resolved_bin ;;
        ds4) DS4_BIN_RESOLVED=$_resolved_bin ;;
    esac

    # Waiting for a model (M3): nothing about the model is checked or written.
    _resolved_model=""
    if [ "$MSS_DEFER_MODEL" != yes ]; then
        _resolved_model=$(mss_resolve_path "$_model") || exit 1
        mss_validate_path_chars "${_upper}_MODEL (resolved)" "$_resolved_model" || exit 1
        [ -f "$_resolved_model" ] || mss_die "${_upper}_MODEL: not a regular file: $_resolved_model"
    fi
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

    # Numeric and path inputs that reach backends.conf or a plist.
    case $_b in
        llamacpp)
            [ -z "$LLAMACPP_CTX" ] || mss_validate_uint LLAMACPP_CTX "$LLAMACPP_CTX" 1 || exit 1
            [ -z "$LLAMACPP_PARALLEL" ] || mss_validate_uint LLAMACPP_PARALLEL "$LLAMACPP_PARALLEL" 1 || exit 1
            if [ -n "$LLAMACPP_API_KEY_FILE" ]; then
                mss_validate_path_chars LLAMACPP_API_KEY_FILE "$LLAMACPP_API_KEY_FILE" || exit 1
            fi
            ;;
        ds4)
            mss_validate_uint DS4_CTX "$DS4_CTX" 1 || exit 1
            if [ -n "$DS4_BATCHED_SESSIONS" ]; then
                mss_validate_uint DS4_BATCHED_SESSIONS "$DS4_BATCHED_SESSIONS" 0 || exit 1
            else
                # Unset: default from installed RAM. MSS_HW_MEMSIZE is a test
                # override, honoured only with --render-only.
                _memsize=$(sysctl -n hw.memsize 2>/dev/null)
                [ -z "$RENDER_ONLY" ] || _memsize=${MSS_HW_MEMSIZE:-$_memsize}
                DS4_BATCHED_SESSIONS=$(mss_ds4_default_sessions "$_memsize")
                echo "DS4_BATCHED_SESSIONS unset: using $DS4_BATCHED_SESSIONS for this Mac's RAM (set it to override; 1 = one session)" >&2
            fi
            if [ -n "$DS4_WORKDIR" ]; then
                DS4_WORKDIR_RESOLVED=$(mss_resolve_path "$DS4_WORKDIR") || exit 1
                [ -d "$DS4_WORKDIR_RESOLVED" ] || mss_die "DS4_WORKDIR: not a directory: $DS4_WORKDIR_RESOLVED"
            else
                DS4_WORKDIR_RESOLVED=$(dirname "$_resolved_bin")
            fi
            mss_validate_path_chars DS4_WORKDIR "$DS4_WORKDIR_RESOLVED" || exit 1
            ;;
    esac

    if [ -n "$MSS_REPLACE_BACKEND" ]; then
        validate_port_free "$_port" "${_upper}_PORT" "com.mac-studio-server.$_b" "com.mac-studio-server.$MSS_REPLACE_BACKEND"
    else
        validate_port_free "$_port" "${_upper}_PORT" "com.mac-studio-server.$_b"
    fi
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
mss_validate_uint MSS_GUARD_STREAK "$MSS_GUARD_STREAK" 1 || exit 1
mss_validate_uint MSS_GUARD_FREE_PCT "$MSS_GUARD_FREE_PCT" 1 99 || exit 1
mss_validate_uint MSS_GUARD_SWAP_HEADROOM_MB "$MSS_GUARD_SWAP_HEADROOM_MB" 0 || exit 1
mss_validate_uint MSS_LOG_MAX_MB "$MSS_LOG_MAX_MB" 1 || exit 1

# Re-install with a different optional backend: refuse (D7), unless this is the
# switch check for exactly the installed backend.
if [ -n "$_installed_opt" ] && [ -n "$_optional" ] && [ "$_installed_opt" != "$_optional" ] \
    && [ -z "$MSS_REPLACE_BACKEND" ]; then
    mss_die "installed optional backend is '$_installed_opt'; run scripts/uninstall.sh --backend $_installed_opt first, or scripts/install.sh --configure to switch"
fi

# Wired limit: same integer formula and evaluation order as set-gpu-memory.sh.
MSS_WIRED_LIMIT_MB=""
# The legacy name is never honoured here: through install.sh and model.sh the
# resolver has already moved it onto MSS_GPU_PERCENT, so a non-empty
# OLLAMA_GPU_PERCENT means a direct run that would otherwise be ignored (#27).
if [ -n "${OLLAMA_GPU_PERCENT:-}" ]; then
    mss_die "OLLAMA_GPU_PERCENT is replaced by MSS_GPU_PERCENT; run scripts/install.sh (it migrates backends.env)"
fi
if [ -n "${MSS_GPU_PERCENT:-}" ] && [ "$_has_optional" = 1 ]; then
    mss_validate_uint MSS_GPU_PERCENT "$MSS_GPU_PERCENT" 1 100 || exit 1
    MSS_WIRED_LIMIT_MB=$(mss_wired_limit_mb "$MSS_GPU_PERCENT")
    mss_validate_uint "wired limit (from hw.memsize)" "$MSS_WIRED_LIMIT_MB" 1 || exit 1
    # The backend waits for this limit; something must apply it at every boot.
    # scripts/install.sh installs com.mac-studio-server.gpumemory before
    # calling us; model.sh pre-checks it. The exemption below is unchanged:
    # --check-only and --render-only run before step 9 installs the job.
    if [ -z "$RENDER_ONLY" ] && [ "$CHECK_ONLY" = 0 ] && [ ! -f "$PLIST_DIR/com.mac-studio-server.gpumemory.plist" ]; then
        mss_die "MSS_GPU_PERCENT is set but com.mac-studio-server.gpumemory is not installed; run scripts/install.sh"
    fi
fi

# The model hash is the only slow check, so it runs last. Exit 3 is a mismatch.
LLAMACPP_STAMP_LINE=""; DS4_STAMP_LINE=""
if [ "$MSS_DEFER_MODEL" != yes ]; then
    if mss_backend_selected llamacpp; then
        LLAMACPP_STAMP_LINE=$(verify_model llamacpp "$LLAMACPP_MODEL_RESOLVED" "$LLAMACPP_MODEL_SHA256") || exit $?
    fi
    if mss_backend_selected ds4; then
        DS4_STAMP_LINE=$(verify_model ds4 "$DS4_MODEL_RESOLVED" "$DS4_MODEL_SHA256") || exit $?
    fi
fi

# write_stamp <backend> <line>: the verified model's stamp, root:wheel 0644.
write_stamp() {
    _stamp="$STAMP_DIR/$1.model.verified"
    printf '%s\n' "$2" > "$_stamp.tmp"
    if [ -z "$RENDER_ONLY" ]; then chown root:wheel "$_stamp.tmp"; fi
    chmod 0644 "$_stamp.tmp"
    mv "$_stamp.tmp" "$_stamp"
}

if [ "$CHECK_ONLY" = 1 ]; then
    # D6: the hash matched, so root keeps it for the install. The directory and
    # one stamp per backend are the only paths this pass may create or change.
    if [ "$(id -u)" -eq 0 ] && { [ -n "$LLAMACPP_STAMP_LINE" ] || [ -n "$DS4_STAMP_LINE" ]; }; then
        if [ ! -d "$DB_DIR" ]; then
            mkdir -p "$DB_DIR"
            chown root:wheel "$DB_DIR"
            chmod 0755 "$DB_DIR"
        fi
        [ -z "$LLAMACPP_STAMP_LINE" ] || write_stamp llamacpp "$LLAMACPP_STAMP_LINE"
        [ -z "$DS4_STAMP_LINE" ] || write_stamp ds4 "$DS4_STAMP_LINE"
    fi
    if [ "$MSS_DEFER_MODEL" = yes ] && [ -n "$_optional" ]; then
        echo "install-backends: check passed (backends: $MSS_BACKENDS; $_optional waiting for a model)"
    else
        echo "install-backends: check passed (backends: $MSS_BACKENDS)"
    fi
    exit 0
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
    # pf applies only with an allowlist. llama.cpp on a LAN address with only an
    # API key has no pf policy: the key is its sole protection (D2).
    if ! mss_is_loopback_host "$_oh" && [ -n "$_oa" ]; then
        PF_RULES="pass in quick on lo0 proto tcp to any port $_op"
        for _e in $_oa; do
            PF_RULES="$PF_RULES
pass in quick proto tcp from $_e to any port $_op"
        done
        PF_RULES="$PF_RULES
block in quick proto tcp to any port $_op"
        # shellcheck disable=SC2086  # allowlist is whitespace-separated
        PF_SPECS="$_op:$(printf '%s ' $_oa | sed 's/ $//' | tr ' ' ',')"
    fi
fi
# shellcheck disable=SC2086  # PF_SPECS is one "port:entry,entry" word per LAN-bound port
PF_RULE_COUNT=$(mss_pf_rule_count $PF_SPECS)
# The count the boot check compares against must equal the rules written.
_rendered=0
[ -z "$PF_RULES" ] || _rendered=$(printf '%s\n' "$PF_RULES" | grep -c .)
[ "$_rendered" -eq "$PF_RULE_COUNT" ] || mss_die "internal: pf rule count $PF_RULE_COUNT != rendered $_rendered"
HAS_PF_POLICY=0; [ -n "$PF_RULES" ] && HAS_PF_POLICY=1

render_placeholders() {
    # sed-safe value substitution: values are paths, numbers, users and
    # validated tokens — none contain & or backslashes.
    sed \
        -e "s|<OLLAMA_USER>|$MSS_SERVICE_USER|g" \
        -e "s|<MSS_WORKDIR>|${_WORKDIR:-/var/log/mac-studio-server}|g"
}

# ── phase 3: write outputs ─────────────────────────────────────────────────────
# The model stamp comes first: the sha is already verified, and a conf is never
# written that points at a model without a matching stamp.
if [ -z "$RENDER_ONLY" ]; then
    mkdir -p "$DB_DIR"
    chown root:wheel "$DB_DIR"
    chmod 0755 "$DB_DIR"
else
    mkdir -p "$RENDER_ONLY"
fi
[ -z "$LLAMACPP_STAMP_LINE" ] || write_stamp llamacpp "$LLAMACPP_STAMP_LINE"
[ -z "$DS4_STAMP_LINE" ] || write_stamp ds4 "$DS4_STAMP_LINE"

if [ -z "$RENDER_ONLY" ]; then
    mkdir -p "$LIBEXEC_DIR" "$ETC_DIR" "$LOG_DIR"
    chown root:wheel "$LIBEXEC_DIR" "$ETC_DIR" "$LOG_DIR"
    chmod 0755 "$LIBEXEC_DIR" "$ETC_DIR" "$LOG_DIR"
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
    _WORKDIR=$DS4_WORKDIR_RESOLVED
fi
{
    echo "MSS_BACKENDS=$MSS_BACKENDS"
    echo "MSS_SERVICE_USER=$MSS_SERVICE_USER"
    echo "OLLAMA_BIND=$OLLAMA_BIND"
    [ -n "$_optional" ] && echo "MSS_GUARD_BACKEND=$_optional"
    [ -n "$_optional" ] && [ "$MSS_DEFER_MODEL" = yes ] && echo "MSS_MODEL_STATE=waiting"
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

# plists
install_plist() {
    _src=$1 _dst=$2
    render_placeholders < "$REPO_DIR/config/$_src" > "$_dst.tmp"
    if [ -z "$RENDER_ONLY" ]; then chown root:wheel "$_dst.tmp"; fi
    chmod 0644 "$_dst.tmp"
    mv "$_dst.tmp" "$_dst"
}
# Waiting for a model: no backend or guard job, so nothing respawns at boot.
_JOBS=0
[ -n "$_optional" ] && [ "$MSS_DEFER_MODEL" != yes ] && _JOBS=1
if [ "$_JOBS" = 1 ]; then
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

# A deferred re-install leaves no backend or guard job from an earlier install.
if [ -n "$_optional" ] && [ "$_JOBS" = 0 ]; then
    for label in "$_optional" guard; do
        launchctl bootout "system/com.mac-studio-server.$label" 2>/dev/null || true
        rm -f "$PLIST_DIR/com.mac-studio-server.$label.plist"
    done
fi

# pre-create runtime files with the ownership table
if [ "$_JOBS" = 1 ]; then
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
[ "$_JOBS" = 1 ] && BOOTSTRAP="$BOOTSTRAP $_optional guard"

bootstrap_label() {
    launchctl bootstrap system "$PLIST_DIR/com.mac-studio-server.$1.plist" \
        || mss_die "launchctl bootstrap failed for com.mac-studio-server.$1"
    echo "bootstrapped com.mac-studio-server.$1"
}

# 1. Stop everything first, the watcher first.
_STOPPED=""
for label in guard $_optional boot; do
    case " $BOOTSTRAP " in
        *" $label "*)
            launchctl bootout "system/com.mac-studio-server.$label" 2>/dev/null || true
            _STOPPED="$_STOPPED $label"
            ;;
    esac
done
# A deferred re-install booted out the backend and guard above. With a pf
# policy, wait for them too: boot must not load the new anchor while the old
# backend still serves.
if [ "$HAS_PF_POLICY" = 1 ] && [ -n "$_optional" ] && [ "$_JOBS" = 0 ]; then
    _STOPPED="$_STOPPED $_optional guard"
fi

# 2. Wait until launchd has released every stopped label. Nothing is started
#    before this: bootstrapping a label it still holds fails with I/O error 5.
for label in $_STOPPED; do
    mss_launchd_wait_gone "com.mac-studio-server.$label" "$MSS_LAUNCHD_TIMEOUT" \
        || mss_die "com.mac-studio-server.$label did not stop within ${MSS_LAUNCHD_TIMEOUT}s; nothing was started; re-run the install once it has stopped"
done

# 3. With a pf policy the backend starts only after boot has written a marker
#    for this kern.boottime in this run. A marker left by an earlier install in
#    the same boot would let the backend start under the old anchor.
if [ "$HAS_PF_POLICY" = 1 ]; then
    BOOT_MARKER=/var/run/com.mac-studio-server.boot.ok
    rm -f "$BOOT_MARKER"
    bootstrap_label boot
    _boottime=$(sysctl -n kern.boottime 2>/dev/null)
    _n=0; _why=""
    while :; do
        if [ -n "$_boottime" ] && [ -r "$BOOT_MARKER" ] && [ "$(cat "$BOOT_MARKER" 2>/dev/null)" = "$_boottime" ]; then
            break
        fi
        _rc=$(launchctl print system/com.mac-studio-server.boot 2>/dev/null \
            | sed -n 's/^[[:space:]]*last exit code = \([0-9][0-9]*\).*/\1/p' | head -n 1)
        if [ -n "$_rc" ] && [ "$_rc" != 0 ]; then _why="exit code $_rc"; break; fi
        if [ "$_n" -ge $((MSS_LAUNCHD_TIMEOUT * 2)) ]; then _why="no marker within ${MSS_LAUNCHD_TIMEOUT}s"; break; fi
        sleep 0.5
        _n=$((_n + 1))
    done
    [ -z "$_why" ] || mss_die "pf boot check failed ($_why); com.mac-studio-server.$_optional was not started; sudo /usr/local/libexec/mac-studio-server/mss-boot.sh shows the reason"
    echo "pf verified by com.mac-studio-server.boot"
fi

# 4. The backend, then guard, each only once launchd no longer holds its label.
if [ "$_JOBS" = 1 ]; then
    for label in $_optional guard; do
        mss_launchd_wait_gone "com.mac-studio-server.$label" "$MSS_LAUNCHD_TIMEOUT" \
            || mss_die "com.mac-studio-server.$label is still loaded; re-run the install once it has stopped"
        bootstrap_label "$label"
    done
fi

echo "install-backends: done (backends: $MSS_BACKENDS; pf rules: $PF_RULE_COUNT)"
