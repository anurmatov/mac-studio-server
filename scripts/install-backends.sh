#!/bin/sh
# install-backends.sh — root part of the mac-studio-server installer (#9, #1).
#
#   sudo env <vars> scripts/install-backends.sh [--check-only | --render-only DIR]
#
# MSS_BACKENDS selects any mix of ollama, llamacpp, ds4 and mlx. One optional
# backend runs (MSS_ACTIVE_BACKEND, or the only one selected); the others stay
# installed on standby, their plists under standby/ where launchd never loads
# them, so switching back needs no re-hash. Every root pass, --check-only
# included, holds the lifecycle lock and runs these phases:
#
#   1 read and validate   lock, interrupted-commit recovery, every input and the
#                         model checks; then the job plan. No side effects
#                         beyond .next stamps (a verified hash kept for later).
#   2 stage               every new file, and a verified copy of every old one,
#                         under .stage/; nothing installed changes
#   3 stop                the jobs that changed or are no longer wanted. A job
#                         that will not stop leaves everything as it was.
#   4 commit              journalled renames, only after every stop succeeded
#   5 start               boot (pf), the active backend, guard
#   6 save                MSS_BACKENDS and MSS_ACTIVE_BACKEND into backends.env,
#                         still under the lock (MSS_SAVE_ENVFILE, install only)
#
# An unchanged, loaded job is never booted out: adding a standby backend or an
# identical re-install restarts nothing.
#
# --check-only runs phase 1 only; install.sh calls it before touching Ollama.
# As root, a matching hash is kept as <b>.model.verified.next, so the install
# does not hash again. A sha256 mismatch exits 3. --render-only DIR writes the
# rendered files (conf, pf rules, plists, stamps) into DIR without root,
# launchd or pf — used by tests. In that mode MSS_PFCTL may point at a stub;
# production always renders /sbin/pfctl unless explicitly overridden.
#
# MSS_DEFER_MODEL=yes installs the one optional backend without a model: the
# conf says MSS_MODEL_STATE=waiting and no backend or guard job is installed.
#
# MSS_LAUNCHD_TIMEOUT (seconds, default 60) bounds each wait for a job to stop
# and for the boot job's pf marker. MSS_LOCK_TIMEOUT (default 30) bounds the
# wait for another lifecycle command.

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
MSS_BACKENDS=${MSS_BACKENDS-ollama}
MSS_ACTIVE_BACKEND=${MSS_ACTIVE_BACKEND:-}
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
MLX_BIN=${MLX_BIN:-}
MLX_MODEL_DIR=${MLX_MODEL_DIR:-}
MLX_HOST=${MLX_HOST:-127.0.0.1}
MLX_PORT=${MLX_PORT:-11234}
MLX_ALLOW_FROM=${MLX_ALLOW_FROM:-}
MLX_CTX=${MLX_CTX:-}
MLX_EXTRA_ARGS=${MLX_EXTRA_ARGS:-}
MSS_GUARD_FREE_PCT=${MSS_GUARD_FREE_PCT:-10}
MSS_GUARD_SWAP_HEADROOM_MB=${MSS_GUARD_SWAP_HEADROOM_MB:-2048}
MSS_GUARD_STREAK=${MSS_GUARD_STREAK:-3}
MSS_LOG_MAX_MB=${MSS_LOG_MAX_MB:-100}
MSS_PFCTL=${MSS_PFCTL:-/sbin/pfctl}
# Set only by install.sh --configure(-only) for the --check-only pass of a
# switch: installed optional backends about to be removed, comma separated.
MSS_REPLACE_BACKEND=${MSS_REPLACE_BACKEND:-}
MSS_DEFER_MODEL=${MSS_DEFER_MODEL:-}
MSS_PROGRESS_SECONDS=${MSS_PROGRESS_SECONDS:-10}
MSS_LAUNCHD_TIMEOUT=${MSS_LAUNCHD_TIMEOUT:-60}
# Phase 6: the user's backends.env and the user who owns it (install pass only).
MSS_SAVE_ENVFILE=${MSS_SAVE_ENVFILE:-}
MSS_SAVE_USER=${MSS_SAVE_USER:-}

LIBEXEC_DIR="/usr/local/libexec/mac-studio-server"
ETC_DIR="/usr/local/etc/mac-studio-server"
DB_DIR="/var/db/mac-studio-server"
LOG_DIR="/var/log/mac-studio-server"
PLIST_DIR="/Library/LaunchDaemons"
STANDBY_DIR="$ETC_DIR/standby"
CONF="$ETC_DIR/backends.conf"
PF_FILE="$ETC_DIR/pf.conf"
JOURNAL="$ETC_DIR/commit.journal"
STAGE="$ETC_DIR/.stage"
RECORD="$DB_DIR/plists.sha256"
BOOT_MARKER=/var/run/com.mac-studio-server.boot.ok
LABEL_PREFIX=com.mac-studio-server
STAMP_DIR=${MSS_TEST_SYSROOT:-}$DB_DIR
[ -z "$RENDER_ONLY" ] || STAMP_DIR=$RENDER_ONLY

IS_ROOT=0; [ "$(id -u)" -ne 0 ] || IS_ROOT=1
if [ -z "$RENDER_ONLY" ] && [ "$CHECK_ONLY" = 0 ] && [ "$IS_ROOT" = 0 ]; then
    mss_die "install-backends.sh must run as root (or use --check-only / --render-only)"
fi
# A root pass changes the system and holds the lifecycle lock; a non-root
# --check-only or --render-only takes no lock and changes nothing outside the
# render directory.
ROOT_PASS=0; [ "$IS_ROOT" = 0 ] || [ -n "$RENDER_ONLY" ] || ROOT_PASS=1

# The installed state. A root pass reads the system. Without root, MSS_CONF may
# point elsewhere, as for the picker, and the rest is read under the tests'
# sysroot; every real install checks again as root.
if [ "$IS_ROOT" = 1 ]; then
    I_CONF=$CONF; I_PLIST=$PLIST_DIR; I_STANDBY=$STANDBY_DIR; I_DB=$DB_DIR
else
    I_CONF=$(mss_conf_path); I_PLIST=${MSS_TEST_SYSROOT:-}$PLIST_DIR
    I_STANDBY=${MSS_TEST_SYSROOT:-}$STANDBY_DIR; I_DB=${MSS_TEST_SYSROOT:-}$DB_DIR
fi

conf_get_from() { awk -F= -v k="$2" 'index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null; }
label() { printf '%s.%s\n' "$LABEL_PREFIX" "$1"; }
loaded() { launchctl print "system/$(label "$1")" >/dev/null 2>&1; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
words_or_none() { [ -n "$1" ] && printf '%s\n' "$1" || echo none; }

# ── phase 1: lock, then interrupted-commit recovery (D5.C) ────────────────────
# mut_write <content> <dest>: a root:wheel 0644 file, written as one mutation.
mut_write() {
    # shellcheck disable=SC2016  # the script is for sh -c
    mss_mut /bin/sh -c 'printf "%s\n" "$1" > "$2.tmp" && chown root:wheel "$2.tmp" && chmod 0644 "$2.tmp" && mv -f "$2.tmp" "$2"' \
        sh "$1" "$2"
}

mut_mkdir() { # mut_mkdir <dir> <mode>
    [ -d "$1" ] && return 0
    # shellcheck disable=SC2016
    mss_mut /bin/sh -c 'mkdir -p "$1" && chown root:wheel "$1" && chmod "$2" "$1"' sh "$1" "$2"
}

recover_interrupted_commit() {
    [ -e "$JOURNAL" ] || return 0
    _rc_plan=$(mss_commit_recover_plan "$JOURNAL" "$STAGE")
    _rc_steps=$(sed 1d "$JOURNAL")
    case $_rc_plan in
        forward\ *)
            # shellcheck disable=SC2086  # "forward <pending> <steps>"
            set -- $_rc_plan
            while read -r _rc_i _rc_t _rc_pre _rc_new; do
                [ -n "$_rc_i" ] || continue
                [ "$(mss_file_sha "$_rc_t")" = "$_rc_pre" ] || continue
                mss_lock_check
                if [ "$_rc_new" = absent ]; then mss_mut rm -f "$_rc_t" || exit 1
                else mss_mut mv -f "$STAGE/new/$_rc_i" "$_rc_t" || exit 1; fi
            done <<MSS_STEPS_EOF
$_rc_steps
MSS_STEPS_EOF
            echo "NOTICE: completed an interrupted commit ($2 of $3 steps were pending)" ;;
        back\ *)
            _rc_rev=$(printf '%s\n' "$_rc_steps" | awk 'NF { l[NR] = $0 } END { for (i = NR; i > 0; i--) if (i in l) print l[i] }')
            while read -r _rc_i _rc_t _rc_pre _rc_new; do
                [ -n "$_rc_i" ] || continue
                [ "$(mss_file_sha "$_rc_t")" = "$_rc_new" ] || continue
                mss_lock_check
                if [ "$_rc_pre" = absent ]; then mss_mut rm -f "$_rc_t" || exit 1
                else mss_mut mv -f "$STAGE/prev/$_rc_i" "$_rc_t" || exit 1; fi
            done <<MSS_STEPS_EOF
$_rc_rev
MSS_STEPS_EOF
            echo "NOTICE: rolled the interrupted commit back to the pre-run state" ;;
        refuse-foreign\ *)
            # shellcheck disable=SC2086  # "refuse-foreign <n> <target>"
            set -- $_rc_plan
            mss_die "$3 matches neither its pre-run nor its new content; compare with $STAGE/prev/$2, fix by hand, re-run" ;;
        *)
            mss_die "cannot verify the interrupted commit; see $JOURNAL; sudo scripts/uninstall.sh --all removes everything" ;;
    esac
    mss_lock_check
    mss_mut rm -f "$JOURNAL" || exit 1
    mss_mut rm -rf "$STAGE" || exit 1
}

if [ "$ROOT_PASS" = 1 ]; then
    mss_lock_acquire install-backends
    recover_interrupted_commit
fi

# ── phase 1: inputs ────────────────────────────────────────────────────────────
mss_validate_selection "$MSS_BACKENDS" || exit 1
NEW_ACTIVE=$(mss_active_backend "$MSS_BACKENDS" "$MSS_ACTIVE_BACKEND") || exit 1
SELECTED_OPT=$(mss_optional_backends "$MSS_BACKENDS")
N_OPT=$(mss_count_words "$SELECTED_OPT")
mss_validate_user OLLAMA_USER "$MSS_SERVICE_USER" || exit 1
if [ -z "$RENDER_ONLY" ]; then
    id -u "$MSS_SERVICE_USER" >/dev/null 2>&1 || mss_die "OLLAMA_USER: user '$MSS_SERVICE_USER' does not exist"
fi
mss_validate_path_chars MSS_PFCTL "$MSS_PFCTL" || exit 1
case $MSS_DEFER_MODEL in ''|yes) ;; *) mss_die "MSS_DEFER_MODEL must be yes or unset" ;; esac
mss_validate_uint MSS_PROGRESS_SECONDS "$MSS_PROGRESS_SECONDS" 1 60 || exit 1
mss_validate_uint MSS_LAUNCHD_TIMEOUT "$MSS_LAUNCHD_TIMEOUT" 1 600 || exit 1
if [ -n "$MSS_SAVE_ENVFILE$MSS_SAVE_USER" ]; then
    [ -z "$RENDER_ONLY" ] && [ "$CHECK_ONLY" = 0 ] || mss_die "MSS_SAVE_ENVFILE is accepted only in the install pass"
    case $MSS_SAVE_ENVFILE in /*) ;; *) mss_die "MSS_SAVE_ENVFILE: '$MSS_SAVE_ENVFILE' must be an absolute path" ;; esac
    mss_validate_user MSS_SAVE_USER "$MSS_SAVE_USER" || exit 1
    id -u "$MSS_SAVE_USER" >/dev/null 2>&1 || mss_die "MSS_SAVE_USER: user '$MSS_SAVE_USER' does not exist"
fi

# ── phase 1 step 2: the installed state ───────────────────────────────────────
I_SEL=""; I_ACTIVE=none; I_WAITING=0
if [ -r "$I_CONF" ]; then
    I_SEL=$(conf_get_from "$I_CONF" MSS_BACKENDS)
    _a=$(conf_get_from "$I_CONF" MSS_GUARD_BACKEND); [ -z "$_a" ] || I_ACTIVE=$_a
    [ "$(conf_get_from "$I_CONF" MSS_MODEL_STATE)" != waiting ] || I_WAITING=1
fi
I_OPT=$(mss_optional_backends "$I_SEL")
# A 1.6.0 conf always names its one optional backend in MSS_BACKENDS; this
# keeps a conf that does not (hand-written) from hiding the active one.
[ "$I_ACTIVE" = none ] || in_list "$I_ACTIVE" "$I_OPT" || I_OPT=$(mss_optional_backends "$I_SEL,$I_ACTIVE")

# ── phase 1 step 3: deselection ───────────────────────────────────────────────
# MSS_REPLACE_BACKEND lets the switch check see through installed backends that
# are about to be removed: only with --check-only, only installed names.
REPLACE=$(printf '%s' "$MSS_REPLACE_BACKEND" | tr ',' ' ')
if [ -n "$REPLACE" ]; then
    [ "$CHECK_ONLY" = 1 ] || mss_die "MSS_REPLACE_BACKEND is accepted only with --check-only"
    for _r in $REPLACE; do
        in_list "$_r" "$I_OPT" \
            || mss_die "MSS_REPLACE_BACKEND: '$_r' is not an installed optional backend (installed: $(words_or_none "$I_OPT"))"
    done
fi
for _b in $I_OPT; do
    in_list "$_b" "$SELECTED_OPT" || in_list "$_b" "$REPLACE" \
        || mss_die "$_b is installed but not selected; keep it, or run sudo scripts/uninstall.sh --backend $_b first (model files are kept)"
done

# ── phase 1 step 4: waiting for a model (D3) ──────────────────────────────────
DEFER=0
if [ "$MSS_DEFER_MODEL" = yes ]; then
    [ "$N_OPT" -le 1 ] || mss_die "MSS_DEFER_MODEL=yes needs exactly one optional backend (selected: $SELECTED_OPT)"
    ! in_list mlx "$SELECTED_OPT" || mss_die "MSS_DEFER_MODEL=yes is not supported for mlx; set MLX_MODEL_DIR"
    if [ "$N_OPT" = 1 ]; then
        [ "$NEW_ACTIVE" != none ] || mss_die "MSS_DEFER_MODEL=yes needs the optional backend active (MSS_ACTIVE_BACKEND=none)"
        DEFER=1
    fi
fi
if [ "$I_WAITING" = 1 ] && [ "$I_ACTIVE" != none ]; then
    for _b in $SELECTED_OPT; do
        in_list "$_b" "$I_OPT" && continue
        in_list "$I_ACTIVE" "$REPLACE" && continue
        mss_die "$I_ACTIVE is installed and waiting for a model; add one with scripts/model.sh before adding $_b"
    done
fi

mss_validate_ipv4 "$OLLAMA_BIND" || mss_die "OLLAMA_BIND: '$OLLAMA_BIND' must be a single IPv4 address"
if mss_backend_selected ollama; then
    mss_is_loopback_host "$OLLAMA_BIND" || \
        echo "WARNING: Ollama is LAN-bound on $OLLAMA_BIND — ensure your network is trusted." >&2
fi

# Everything that would reach a process listing, a model or a port as root
# runs with these helpers.

# port_foreign_pids <port> <label>...: the listeners on <port> that belong to
# none of the given labels' running jobs (their PID, or a descendant of it).
# The job PID comes from `launchctl print system/<label>`, which needs root, so
# a non-root pass prints "defer" instead.
port_foreign_pids() {
    _pp_port=$1; shift
    _pp_pids=$(lsof -nP -iTCP:"$_pp_port" -sTCP:LISTEN -t 2>/dev/null | sort -u)
    [ -n "$_pp_pids" ] || return 0
    [ "$IS_ROOT" = 1 ] || { echo defer; return 0; }
    _pp_owns=""
    for _pp_l in "$@"; do
        _pp_own=$(mss_label_pid "$_pp_l")
        [ -z "$_pp_own" ] || _pp_owns="$_pp_owns $_pp_own"
    done
    _pp_foreign=""
    for _pp_lp in $_pp_pids; do
        _pp_mine=0
        for _pp_own in $_pp_owns; do
            if mss_pid_under "$_pp_lp" "$_pp_own"; then _pp_mine=1; break; fi
        done
        [ "$_pp_mine" = 1 ] || _pp_foreign="$_pp_foreign $_pp_lp"
    done
    printf '%s\n' "${_pp_foreign# }"
}

# validate_port_free <port> <var> <label>...: the port of the backend this run
# starts may be held only by one of the given labels' jobs.
validate_port_free() {
    _vp_port=$1 _vp_var=$2
    shift 2
    _vp_f=$(port_foreign_pids "$_vp_port" "$@")
    case $_vp_f in
        '') return 0 ;;
        defer) echo "note: $_vp_var: port $_vp_port is in use; ownership is checked in the root install" >&2; return 0 ;;
    esac
    mss_die "port $_vp_port is in use (pid $_vp_f); set $_vp_var in backends.env and re-run"
}

gib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'; }

# hash_file <backend> <path> <size>: prints the sha256. Progress goes to stderr
# (U3): every MSS_PROGRESS_SECONDS, SIGINFO makes BSD dd report the bytes copied,
# and one final "done" line always ends it. The sum is read through a FIFO.
# Inside the lock the readers are watched, so a killed holder leaves no orphan
# reading the model.
hash_file() {
    _hb=$1; _hp=$2; _hs=$3
    _ht=$(mktemp -d "${TMPDIR:-/tmp}/mss-hash.XXXXXX") || return 1
    if ! mkfifo "$_ht/fifo"; then rm -rf "$_ht"; return 1; fi
    mss_shasum256 < "$_ht/fifo" > "$_ht/sum" &
    _hsum=$!
    dd if="$_hp" of="$_ht/fifo" bs=16777216 2>"$_ht/dd.log" &
    _hdd=$!
    [ -z "${MSS_LOCK_SESSION:-}" ] || mss_watchdog "$_hsum" "$_hdd"
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

# full_read_blocker <backend>: why a full read of this backend's model may not
# run now (D5.10), or nothing. Paging a model in beside a resident one can
# freeze the host, so a full read waits until no model server runs. The
# running active backend's own re-hash keeps 1.6.0's behaviour (R-9).
# Managed jobs are a root pass's view; any pass also looks for model-server
# processes by name.
full_read_blocker() {
    if [ "$IS_ROOT" = 1 ]; then
        if [ "$1" = "$I_ACTIVE" ] && [ -n "$(mss_label_pid "$(label "$1")")" ]; then return 0; fi
        for _fr_b in llamacpp ds4 mlx; do
            [ -z "$(mss_label_pid "$(label "$_fr_b")")" ] || { echo "$_fr_b"; return 0; }
        done
    fi
    _fr_s=$(mss_model_servers | head -n 1)
    [ -z "$_fr_s" ] || echo "${_fr_s% *}"
}

# verify_model <backend> <resolved model> <expected sha>: prints the stamp line
# "path size inode mtime sha". The final stamp or a .next stamp that matches
# the path, stat and expected sha skips the read. Otherwise the file is hashed
# and, in a root pass, the verified line is kept as <b>.model.verified.next. A
# mismatch returns 3.
verify_model() {
    _vb=$1; _vpath=$2; _vwant=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
    _vstat=$(stat -f '%z %i %m' "$_vpath" 2>/dev/null) || { mss_error "stat failed: $_vpath"; return 1; }
    for _vstamp in "$STAMP_DIR/$_vb.model.verified" "$STAMP_DIR/$_vb.model.verified.next"; do
        if [ -r "$_vstamp" ] && read -r _sp _ss _si _sm _sh < "$_vstamp" \
            && [ "$_sp" = "$_vpath" ] && [ "$_ss $_si $_sm" = "$_vstat" ] && [ "$_sh" = "$_vwant" ]; then
            echo "stamp unchanged for $_vb (skipping re-hash)" >&2
            printf '%s %s %s\n' "$_vpath" "$_vstat" "$_sh"
            return 0
        fi
    done
    _vblock=$(full_read_blocker "$_vb")
    if [ -n "$_vblock" ]; then
        mss_error "$_vb model needs a full read; stop the running server (scripts/backend.sh stop $_vblock) or stamp offline (R1b)"
        return 1
    fi
    _vsha=$(hash_file "$_vb" "$_vpath" "${_vstat%% *}") || return 1
    [ "$_vsha" = "$_vwant" ] || { mss_error "$_vb model sha256 mismatch (expected $_vwant, got $_vsha)"; return 3; }
    _vline="$_vpath $_vstat $_vsha"
    if [ "$ROOT_PASS" = 1 ]; then
        mut_mkdir "$DB_DIR" 0755 || return 1
        mut_write "$_vline" "$DB_DIR/$_vb.model.verified.next" || return 1
    fi
    printf '%s\n' "$_vline"
}

# ── phase 1 step 5: every selected optional backend ───────────────────────────
validate_optional_backend() {
    _b=$1
    _upper=$(mss_backend_prefix "$_b")
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
    if [ "$DEFER" != 1 ]; then
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
    if [ "$DEFER" != 1 ]; then
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
}

# The mlx branch (D7): one model, the pinned version, and the ds4 bind rules
# (#33 D1).
validate_mlx() {
    mss_mlx_loopback_check || exit 1
    [ -n "$MLX_BIN" ] || mss_die "MLX_BIN is required when 'mlx' is selected"
    [ -n "$MLX_MODEL_DIR" ] || mss_die "MLX_MODEL_DIR is required when 'mlx' is selected"
    MLX_BIN_RESOLVED=$(mss_resolve_path "$MLX_BIN") || mss_die "MLX_BIN: cannot resolve '$MLX_BIN'"
    mss_validate_path_chars "MLX_BIN (resolved)" "$MLX_BIN_RESOLVED" || exit 1
    [ -f "$MLX_BIN_RESOLVED" ] || mss_die "MLX_BIN: not a regular file: $MLX_BIN_RESOLVED"
    [ -x "$MLX_BIN_RESOLVED" ] || mss_die "MLX_BIN: not executable: $MLX_BIN_RESOLVED"
    # As root the probe runs as the service user: mlx-serve never runs as root.
    _mv_user=""; [ "$IS_ROOT" = 0 ] || _mv_user=$MSS_SERVICE_USER
    mss_mlx_version_ok "$MLX_BIN_RESOLVED" "$_mv_user" MLX_BIN || exit 1
    case $MLX_MODEL_DIR in /*) ;; *) mss_die "MLX_MODEL_DIR: '$MLX_MODEL_DIR' must be an absolute path" ;; esac
    MLX_MODEL_DIR_RESOLVED=$(mss_resolve_path "$MLX_MODEL_DIR" 2>/dev/null) \
        || mss_die "MLX_MODEL_DIR: '$MLX_MODEL_DIR' does not exist"
    mss_mlx_check_dir MLX_MODEL_DIR "$MLX_MODEL_DIR_RESOLVED" || exit 1
    mss_validate_host MLX_HOST "$MLX_HOST" || exit 1
    # mlx-serve's own default; it would listen on every interface.
    [ "$MLX_HOST" != 0.0.0.0 ] || mss_die "MLX_HOST: 0.0.0.0 would listen on every interface; choose one local address"
    if ! mss_is_loopback_host "$MLX_HOST"; then
        mss_host_is_local "$MLX_HOST" || mss_die "MLX_HOST: '$MLX_HOST' is neither loopback nor assigned to a local interface"
    fi
    mss_validate_port MLX_PORT "$MLX_PORT" || exit 1
    mss_validate_allowlist MLX_ALLOW_FROM "$MLX_ALLOW_FROM" || exit 1
    # LAN bind policy: as for ds4, an allowlist is the only protection.
    if ! mss_is_loopback_host "$MLX_HOST"; then
        [ -n "$MLX_ALLOW_FROM" ] || mss_die "MLX_ALLOW_FROM is required: mlx has no authentication and MLX_HOST is not loopback"
    fi
    [ -z "$MLX_CTX" ] || mss_validate_uint MLX_CTX "$MLX_CTX" 1 1048576 || exit 1
    MLX_ARGS=$(mss_validate_extra_args mlx "$MLX_EXTRA_ARGS" MLX_EXTRA_ARGS) || exit 1
}

LLAMACPP_BIN_RESOLVED=""; LLAMACPP_MODEL_RESOLVED=""; LLAMACPP_ARGS=""
DS4_BIN_RESOLVED=""; DS4_MODEL_RESOLVED=""; DS4_ARGS=""; DS4_WORKDIR_RESOLVED=""
MLX_BIN_RESOLVED=""; MLX_MODEL_DIR_RESOLVED=""; MLX_ARGS=""
if mss_backend_selected llamacpp; then
    mss_validate_key_file LLAMACPP_API_KEY_FILE "$LLAMACPP_API_KEY_FILE" "$MSS_SERVICE_USER" || exit 1
    validate_optional_backend llamacpp
fi
mss_backend_selected ds4 && validate_optional_backend ds4
mss_backend_selected mlx && validate_mlx

# ── phase 1 step 6: ports ──────────────────────────────────────────────────────
port_of() { case $1 in llamacpp) echo "$LLAMACPP_PORT" ;; ds4) echo "$DS4_PORT" ;; mlx) echo "$MLX_PORT" ;; esac; }
for _b in $SELECTED_OPT; do
    for _c in $SELECTED_OPT; do
        [ "$_b" != "$_c" ] || break
        [ "$(port_of "$_b")" != "$(port_of "$_c")" ] \
            || mss_die "port collision: $(mss_backend_prefix "$_c")_PORT and $(mss_backend_prefix "$_b")_PORT are both $(port_of "$_b")"
    done
    if mss_backend_selected ollama; then
        [ "$(port_of "$_b")" != 11434 ] || mss_die "port collision: $(mss_backend_prefix "$_b")_PORT equals Ollama's 11434"
    fi
done
# The backend this run starts may find its port held only by its own job, the
# previous active backend's or (for the switch check) one being replaced. A
# foreign listener on a standby port only warns: activation checks it again.
_allowed_labels=""
for _b in "$NEW_ACTIVE" "$I_ACTIVE" $REPLACE; do
    [ "$_b" = none ] || _allowed_labels="$_allowed_labels $(label "$_b")"
done
for _b in $SELECTED_OPT; do
    _p=$(port_of "$_b"); _v="$(mss_backend_prefix "$_b")_PORT"
    if [ "$_b" = "$NEW_ACTIVE" ] && [ "$DEFER" != 1 ]; then
        # shellcheck disable=SC2086  # a list of labels
        validate_port_free "$_p" "$_v" $_allowed_labels
    else
        # shellcheck disable=SC2086
        _f=$(port_foreign_pids "$_p" $_allowed_labels)
        case $_f in
            ''|defer) ;;
            *) echo "WARNING: $_v: port $_p of standby $_b is in use (pid $_f); activating $_b will refuse until it is free" >&2 ;;
        esac
    fi
done

# ── phase 1 step 7: no unmanaged model server beside a start (D5.7) ─────────
# active_will_start: whether this run starts the active backend, as far as it
# is known before the plan: a backend that is not running yet. The install pass
# checks again from its plan, which also restarts a running one that changed.
active_will_start() {
    [ "$NEW_ACTIVE" != none ] && [ "$DEFER" != 1 ] && [ -z "$(mss_label_pid "$(label "$NEW_ACTIVE")")" ]
}

# unmanaged_server_check (D5.7): a backend starts only when no other model
# server runs, managed or not. Only a root pass can see the managed jobs' PIDs.
# Ollama's verified embedding worker is part of Ollama and may run (#35). It
# must run as the user this run installs the jobs for: this run's validated
# input, never the installed conf, which a fresh install lacks and a changed
# OLLAMA_USER makes stale.
unmanaged_server_check() {
    _us_extra=""
    for _us_v in "$LLAMACPP_BIN_RESOLVED" "$DS4_BIN_RESOLVED" "$MLX_BIN_RESOLVED"; do
        [ -z "$_us_v" ] || _us_extra="$_us_extra $(basename "$_us_v")"
    done
    _us_uid=$(id -u "$MSS_SERVICE_USER" 2>/dev/null)
    # shellcheck disable=SC2086  # a list of names
    _us=$(MSS_CONF=$I_CONF mss_unmanaged_server "$_us_uid" $_us_extra) || mss_die "pgrep is missing; cannot check for other model servers"
    [ -z "$_us" ] || mss_die "$(mss_unmanaged_refusal "$_us")"
}

if [ "$IS_ROOT" = 1 ] && active_will_start; then unmanaged_server_check; fi

# ── phase 1 step 8: plists edited outside this installer ──────────────────────
I_USER=$(conf_get_from "$I_CONF" MSS_SERVICE_USER); I_USER=${I_USER:-$MSS_SERVICE_USER}
_i_ds4_bin=$(conf_get_from "$I_CONF" DS4_BIN)
for _j in llamacpp ds4 mlx guard boot; do
    in_list "$_j" "$REPLACE" && continue
    for _p in "$I_PLIST/$(label "$_j").plist" "$I_STANDBY/$(label "$_j").plist"; do
        [ -e "$_p" ] || [ -L "$_p" ] || continue
        _wds=""
        if [ "$_j" = ds4 ]; then
            _wds="$DS4_WORKDIR_RESOLVED"
            [ -z "$_i_ds4_bin" ] || _wds="$_wds $(dirname "$_i_ds4_bin")"
        fi
        # shellcheck disable=SC2086  # a list of working directories
        mss_plist_check "$_p" "$I_DB/plists.sha256" "$REPO_DIR/config/$(label "$_j").plist" "$I_USER" $_wds \
            || mss_die "$_p was changed outside this installer; copy it aside, remove it, then re-run"
    done
done

# Guard threshold sanity.
mss_validate_uint MSS_GUARD_STREAK "$MSS_GUARD_STREAK" 1 || exit 1
mss_validate_uint MSS_GUARD_FREE_PCT "$MSS_GUARD_FREE_PCT" 1 99 || exit 1
mss_validate_uint MSS_GUARD_SWAP_HEADROOM_MB "$MSS_GUARD_SWAP_HEADROOM_MB" 0 || exit 1
mss_validate_uint MSS_LOG_MAX_MB "$MSS_LOG_MAX_MB" 1 || exit 1

# Wired limit: same integer formula and evaluation order as set-gpu-memory.sh.
MSS_WIRED_LIMIT_MB=""
# The legacy name is never honoured here: through install.sh and model.sh the
# resolver has already moved it onto MSS_GPU_PERCENT, so a non-empty
# OLLAMA_GPU_PERCENT means a direct run that would otherwise be ignored (#27).
if [ -n "${OLLAMA_GPU_PERCENT:-}" ]; then
    mss_die "OLLAMA_GPU_PERCENT is replaced by MSS_GPU_PERCENT; run scripts/install.sh (it migrates backends.env)"
fi
# `system` is a first-class picker answer (D3 G) meaning "no wired limit", so it
# takes this branch exactly as an empty value does. Validating it as an integer
# killed every install with an optional backend selected (#27 r2, blocker 3).
if [ -n "${MSS_GPU_PERCENT:-}" ] && [ "${MSS_GPU_PERCENT:-}" != system ] && [ "$N_OPT" -gt 0 ]; then
    mss_validate_uint MSS_GPU_PERCENT "$MSS_GPU_PERCENT" 1 100 || exit 1
    # MSS_HW_MEMSIZE is the same render-only test hook the ds4 session default
    # uses; only --render-only may honour it, so an install still reads the Mac.
    _memsize=""
    if [ -n "$RENDER_ONLY" ]; then _memsize=${MSS_HW_MEMSIZE:-}; fi
    MSS_WIRED_LIMIT_MB=$(mss_wired_limit_mb "$MSS_GPU_PERCENT" "$_memsize")
    mss_validate_uint "wired limit (from hw.memsize)" "$MSS_WIRED_LIMIT_MB" 1 || exit 1
    # The backend waits for this limit; something must apply it at every boot.
    # scripts/install.sh installs com.mac-studio-server.gpumemory before
    # calling us; model.sh pre-checks it. The exemption below is unchanged:
    # --check-only and --render-only run before step 9 installs the job.
    if [ -z "$RENDER_ONLY" ] && [ "$CHECK_ONLY" = 0 ] && [ ! -f "$PLIST_DIR/com.mac-studio-server.gpumemory.plist" ]; then
        mss_die "MSS_GPU_PERCENT is set but com.mac-studio-server.gpumemory is not installed; run scripts/install.sh"
    fi
fi

# ── phase 1 step 10: models ────────────────────────────────────────────────────
# The model hash is the only slow check, so it runs last. Exit 3 is a mismatch.
# The mlx manifest reads names and stat only.
LLAMACPP_STAMP_LINE=""; DS4_STAMP_LINE=""; MLX_MANIFEST=""
if [ "$DEFER" != 1 ]; then
    if mss_backend_selected llamacpp; then
        LLAMACPP_STAMP_LINE=$(verify_model llamacpp "$LLAMACPP_MODEL_RESOLVED" "$LLAMACPP_MODEL_SHA256") || exit $?
    fi
    if mss_backend_selected ds4; then
        DS4_STAMP_LINE=$(verify_model ds4 "$DS4_MODEL_RESOLVED" "$DS4_MODEL_SHA256") || exit $?
    fi
fi
if mss_backend_selected mlx; then
    MLX_MANIFEST=$(mss_mlx_manifest "$MLX_MODEL_DIR_RESOLVED") || exit 1
fi

if [ "$CHECK_ONLY" = 1 ]; then
    if [ "$DEFER" = 1 ]; then
        echo "install-backends: check passed (backends: $MSS_BACKENDS; $NEW_ACTIVE waiting for a model)"
    else
        echo "install-backends: check passed (backends: $MSS_BACKENDS)"
    fi
    exit 0
fi

# ── rendering (the new state, as files) ───────────────────────────────────────
# pf policy: one block for the active backend's port, when it is LAN-bound with
# an allowlist. A standby backend has no pf policy until it is activated.
PF_RULES=""
PF_SPECS=""
case $NEW_ACTIVE in
    llamacpp) _oh=$LLAMACPP_HOST; _op=$LLAMACPP_PORT; _oa=$LLAMACPP_ALLOW_FROM ;;
    ds4)      _oh=$DS4_HOST; _op=$DS4_PORT; _oa=$DS4_ALLOW_FROM ;;
    mlx)      _oh=$MLX_HOST; _op=$MLX_PORT; _oa=$MLX_ALLOW_FROM ;;
    *)        _oh=127.0.0.1; _op=""; _oa="" ;;
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
# shellcheck disable=SC2086  # PF_SPECS is one "port:entry,entry" word per LAN-bound port
PF_RULE_COUNT=$(mss_pf_rule_count $PF_SPECS)
# The count the boot check compares against must equal the rules written.
_rendered=0
[ -z "$PF_RULES" ] || _rendered=$(printf '%s\n' "$PF_RULES" | grep -c .)
[ "$_rendered" -eq "$PF_RULE_COUNT" ] || mss_die "internal: pf rule count $PF_RULE_COUNT != rendered $_rendered"
HAS_PF_POLICY=0; [ -n "$PF_RULES" ] && HAS_PF_POLICY=1

# The backend and guard jobs exist only for an active backend with a model.
JOBS=0
[ "$NEW_ACTIVE" != none ] && [ "$DEFER" != 1 ] && JOBS=1
STANDBY_OPT=""
for _b in $SELECTED_OPT; do [ "$_b" = "$NEW_ACTIVE" ] || STANDBY_OPT="$STANDBY_OPT $_b"; done
STANDBY_OPT=${STANDBY_OPT# }

render_plist() { # render_plist <job> <dest>
    _rp_wd=/var/log/mac-studio-server
    [ "$1" != ds4 ] || _rp_wd=$DS4_WORKDIR_RESOLVED
    # sed-safe value substitution: values are paths, numbers, users and
    # validated tokens — none contain & or backslashes.
    sed -e "s|<OLLAMA_USER>|$MSS_SERVICE_USER|g" -e "s|<MSS_WORKDIR>|$_rp_wd|g" \
        "$REPO_DIR/config/$(label "$1").plist" > "$2"
}

# render_state <dir>: the conf, pf rules, plists (standby/ for standby
# backends) and stamps of the new state, in the --render-only layout.
render_state() {
    _rs=$1
    mkdir -p "$_rs" || mss_die "cannot create $_rs"
    {
        echo "MSS_BACKENDS=$MSS_BACKENDS"
        echo "MSS_SERVICE_USER=$MSS_SERVICE_USER"
        echo "OLLAMA_BIND=$OLLAMA_BIND"
        [ "$NEW_ACTIVE" = none ] || echo "MSS_GUARD_BACKEND=$NEW_ACTIVE"
        [ "$DEFER" != 1 ] || echo "MSS_MODEL_STATE=waiting"
        echo "MSS_PFCTL=$MSS_PFCTL"
        echo "MSS_PF_RULE_COUNT=$PF_RULE_COUNT"
        [ -z "$MSS_WIRED_LIMIT_MB" ] || echo "MSS_WIRED_LIMIT_MB=$MSS_WIRED_LIMIT_MB"
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
        if mss_backend_selected mlx; then
            echo "MLX_BIN=$MLX_BIN_RESOLVED"
            echo "MLX_MODEL_DIR=$MLX_MODEL_DIR_RESOLVED"
            # #33 D5: the default host is not written, so a loopback install
            # renders 1.7.0's conf byte for byte. The allowlist lives only in pf.
            [ "$MLX_HOST" = 127.0.0.1 ] || echo "MLX_HOST=$MLX_HOST"
            echo "MLX_PORT=$MLX_PORT"
            echo "MLX_CTX=$MLX_CTX"
            echo "MLX_ARGS=$MLX_ARGS"
        fi
    } > "$_rs/backends.conf"
    {
        echo "# mac-studio-server pf policy (rendered; anchor com.apple/250.mac-studio-server)"
        if [ -n "$PF_RULES" ]; then
            echo "# backend $NEW_ACTIVE port block"
            echo "$PF_RULES"
        fi
    } > "$_rs/pf.conf"
    # Waiting for a model: no backend or guard job, so nothing respawns at boot.
    if [ "$JOBS" = 1 ]; then
        render_plist "$NEW_ACTIVE" "$_rs/$(label "$NEW_ACTIVE").plist"
        render_plist guard "$_rs/$(label guard).plist"
    fi
    # A standby plist is byte-identical to its active form; activation moves it.
    for _b in $STANDBY_OPT; do
        mkdir -p "$_rs/standby"
        render_plist "$_b" "$_rs/standby/$(label "$_b").plist"
    done
    [ "$HAS_PF_POLICY" = 0 ] || render_plist boot "$_rs/$(label boot).plist"
    [ -z "$LLAMACPP_STAMP_LINE" ] || printf '%s\n' "$LLAMACPP_STAMP_LINE" > "$_rs/llamacpp.model.verified"
    [ -z "$DS4_STAMP_LINE" ] || printf '%s\n' "$DS4_STAMP_LINE" > "$_rs/ds4.model.verified"
    [ -z "$MLX_MANIFEST" ] || printf '%s\n' "$MLX_MANIFEST" > "$_rs/mlx.model.verified"
}

LIBEXEC_FILES="mss-common.sh mss-boot.sh mss-enable.sh mss-guard.sh llamacpp-start.sh ds4-start.sh mlx-start.sh mss-lifecycle.sh"
libexec_src() { if [ -f "$REPO_DIR/libexec/$1" ]; then echo "$REPO_DIR/libexec/$1"; else echo "$REPO_DIR/scripts/lib/$1"; fi; }

if [ -n "$RENDER_ONLY" ]; then
    render_state "$RENDER_ONLY"
    # The scripts a render shows are the 1.6.0 set, plus the mlx wrapper when
    # mlx is selected; the lifecycle command exists only on an install.
    for f in $LIBEXEC_FILES; do
        [ "$f" != mss-lifecycle.sh ] || continue
        [ "$f" != mlx-start.sh ] || mss_backend_selected mlx || continue
        cp "$(libexec_src "$f")" "$RENDER_ONLY/$f"
        chmod 0755 "$RENDER_ONLY/$f"
    done
    echo "render-only: conf, pf rules, plists and stamps written to $RENDER_ONLY"
    exit 0
fi

# ── the install pass (root, under the lock) ────────────────────────────────────
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mss-install.XXXXXX") || mss_die "cannot create a work directory"
chmod 0700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
render_state "$WORK/new"

sha_or_dash() { [ -e "$1" ] && mss_file_sha "$1" || echo -; }
keys_sha() { grep -E "^($2)=" "$1" 2>/dev/null | mss_shasum256 | awk '{ print $1 }'; }
keys_re() {
    case $1 in
        guard) echo 'MSS_GUARD_[A-Z0-9_]*|MSS_LOG_MAX_MB' ;;
        boot) echo 'MSS_PFCTL|MSS_PF_RULE_COUNT' ;;
        *) echo "MSS_SERVICE_USER|MSS_GUARD_BACKEND|MSS_MODEL_STATE|MSS_WIRED_LIMIT_MB|$(mss_backend_prefix "$1")_[A-Z0-9_]*" ;;
    esac
}
plist_state() { # plist_state <top> <standby>: "<top|standby|absent> <sha|->"
    if [ -e "$1" ]; then echo "top $(mss_file_sha "$1")"
    elif [ -e "$2" ]; then echo "standby $(mss_file_sha "$2")"
    else echo "absent -"; fi
}

# ── phase 1 step 11: the plan ──────────────────────────────────────────────────
LOADED=""
for _j in llamacpp ds4 mlx guard boot; do loaded "$_j" && LOADED="$LOADED $_j"; done
_marker=missing
! mss_boot_marker_ok "$BOOT_MARKER" || _marker=ok
PLAN=$(
    echo "active.cur $I_ACTIVE"
    echo "active.new $NEW_ACTIVE"
    [ "$DEFER" = 1 ] && echo "waiting.new yes" || echo "waiting.new no"
    [ "$HAS_PF_POLICY" = 1 ] && echo "pf.new yes" || echo "pf.new no"
    for _j in $LOADED; do echo "loaded $_j"; done
    for _j in llamacpp ds4 mlx guard boot; do
        echo "plist.$_j.cur $(plist_state "$PLIST_DIR/$(label "$_j").plist" "$STANDBY_DIR/$(label "$_j").plist")"
        echo "plist.$_j.new $(plist_state "$WORK/new/$(label "$_j").plist" "$WORK/new/standby/$(label "$_j").plist")"
        echo "keys.$_j.cur $(keys_sha "$CONF" "$(keys_re "$_j")")"
        echo "keys.$_j.new $(keys_sha "$WORK/new/backends.conf" "$(keys_re "$_j")")"
    done
    for _b in llamacpp ds4 mlx; do
        echo "stamp.$_b.cur $(sha_or_dash "$DB_DIR/$_b.model.verified")"
        # A backend without a new stamp (waiting for a model) keeps its old one.
        if [ -e "$WORK/new/$_b.model.verified" ]; then echo "stamp.$_b.new $(sha_or_dash "$WORK/new/$_b.model.verified")"
        else echo "stamp.$_b.new $(sha_or_dash "$DB_DIR/$_b.model.verified")"; fi
    done
    echo "pf.cur $(sha_or_dash "$PF_FILE")"
    echo "pf.new.sha $(sha_or_dash "$WORK/new/pf.conf")"
    echo "marker $_marker"
    ) || exit 1
PLAN=$(printf '%s\n' "$PLAN" | mss_plan_jobs)
STOP_SET=$(printf '%s\n' "$PLAN" | sed -n 's/^stop *//p')
START_SET=$(printf '%s\n' "$PLAN" | sed -n 's/^start *//p')
UNCHANGED_SET=$(printf '%s\n' "$PLAN" | sed -n 's/^unchanged *//p')

# D5.7: before a backend starts, no other model server may run.
for _j in $START_SET; do
    case $_j in llamacpp|ds4|mlx) unmanaged_server_check ;; esac
done

# ── phase 1 step 12: one volume, so every commit step is an atomic rename ─────
existing_ancestor() { _ea=$1; while [ ! -e "$_ea" ]; do _ea=$(dirname "$_ea"); done; printf '%s\n' "$_ea"; }
_dev=""
for _d in "$ETC_DIR" "$PLIST_DIR" "$STANDBY_DIR" "$DB_DIR"; do
    _dd=$(stat -f %d "$(existing_ancestor "$_d")" 2>/dev/null) || mss_die "cannot stat $_d"
    [ -n "$_dev" ] || _dev=$_dd
    [ "$_dd" = "$_dev" ] || mss_die "$_d is on another volume than $ETC_DIR; the commit needs one volume (nothing was changed)"
done

# ── phase 2: stage ─────────────────────────────────────────────────────────────
# The commit steps, in order: stamps (and .next removals), conf, pf.conf, plist
# removals, standby plists, the active plists, and the plist record last. Each
# line is "<n> <target> <source|-> <pre-sha|absent> <new-sha|absent>"; an
# unchanged target gets no step.
STEPS=$WORK/steps; : > "$STEPS"
_n=0
add_step() { # add_step <target> <source or ->
    _as_pre=$(mss_file_sha "$1")
    if [ "$2" = - ]; then _as_new=absent; else _as_new=$(mss_file_sha "$2"); fi
    [ "$_as_pre" != "$_as_new" ] || return 0
    _n=$((_n + 1))
    printf '%s %s %s %s %s\n' "$_n" "$1" "$2" "$_as_pre" "$_as_new" >> "$STEPS"
}
for _b in llamacpp ds4 mlx; do
    mss_backend_selected "$_b" || continue
    [ ! -e "$WORK/new/$_b.model.verified" ] || add_step "$DB_DIR/$_b.model.verified" "$WORK/new/$_b.model.verified"
    [ ! -e "$DB_DIR/$_b.model.verified.next" ] || add_step "$DB_DIR/$_b.model.verified.next" -
done
add_step "$CONF" "$WORK/new/backends.conf"
add_step "$PF_FILE" "$WORK/new/pf.conf"
for _j in llamacpp ds4 mlx guard boot; do
    [ ! -e "$PLIST_DIR/$(label "$_j").plist" ] || [ -e "$WORK/new/$(label "$_j").plist" ] \
        || add_step "$PLIST_DIR/$(label "$_j").plist" -
    [ ! -e "$STANDBY_DIR/$(label "$_j").plist" ] || [ -e "$WORK/new/standby/$(label "$_j").plist" ] \
        || add_step "$STANDBY_DIR/$(label "$_j").plist" -
done
for _b in $STANDBY_OPT; do add_step "$STANDBY_DIR/$(label "$_b").plist" "$WORK/new/standby/$(label "$_b").plist"; done
for _j in llamacpp ds4 mlx guard boot; do
    [ ! -e "$WORK/new/$(label "$_j").plist" ] || add_step "$PLIST_DIR/$(label "$_j").plist" "$WORK/new/$(label "$_j").plist"
done
# The record of every lifecycle plist this commit leaves, by its final path.
for _j in llamacpp ds4 mlx guard boot; do
    [ ! -e "$WORK/new/$(label "$_j").plist" ] \
        || printf '%s %s\n' "$(mss_file_sha "$WORK/new/$(label "$_j").plist")" "$PLIST_DIR/$(label "$_j").plist"
    [ ! -e "$WORK/new/standby/$(label "$_j").plist" ] \
        || printf '%s %s\n' "$(mss_file_sha "$WORK/new/standby/$(label "$_j").plist")" "$STANDBY_DIR/$(label "$_j").plist"
done > "$WORK/new/plists.sha256"
if [ -s "$WORK/new/plists.sha256" ]; then add_step "$RECORD" "$WORK/new/plists.sha256"
elif [ -e "$RECORD" ]; then add_step "$RECORD" -; fi

for _d in "$LIBEXEC_DIR" "$ETC_DIR" "$LOG_DIR" "$DB_DIR"; do mut_mkdir "$_d" 0755 || exit 1; done
mss_lock_check
# One mutation stages everything: the new files with their final owner and
# mode, and a verified copy of every target a step replaces or removes.
# shellcheck disable=SC2016  # the script is for sh -c
mss_mut /bin/sh -c '
    set -u
    . "$1"
    stage=$2; steps=$3
    rm -rf "$stage" && mkdir -p "$stage/new" "$stage/prev" && chmod 0700 "$stage" || exit 1
    while read -r n target src pre new; do
        if [ "$new" != absent ]; then
            cp "$src" "$stage/new/$n" && chown root:wheel "$stage/new/$n" && chmod 0644 "$stage/new/$n" || exit 1
            [ "$(mss_file_sha "$stage/new/$n")" = "$new" ] || { echo "ERROR: staged $target does not verify" >&2; exit 1; }
        fi
        if [ "$pre" != absent ]; then
            cp -p "$target" "$stage/prev/$n" || exit 1
            [ "$(mss_file_sha "$stage/prev/$n")" = "$pre" ] || { echo "ERROR: $target changed while it was staged" >&2; exit 1; }
        fi
    done < "$steps"
' sh "$REPO_DIR/scripts/lib/mss-common.sh" "$STAGE" "$STEPS" || mss_die "staging failed; nothing was changed"

# ── phase 3: stop ──────────────────────────────────────────────────────────────
STOPPED=""
for _j in $STOP_SET; do
    mss_lock_check
    mss_mut launchctl bootout "system/$(label "$_j")" || true
    STOPPED="$STOPPED $_j"
done
_not_stopped=""
for _j in $STOPPED; do
    mss_launchd_wait_gone "$(label "$_j")" "$MSS_LAUNCHD_TIMEOUT" || { _not_stopped=$_j; break; }
    echo "stopped $(label "$_j")"
done
if [ -n "$_not_stopped" ]; then
    # Nothing is committed. The jobs this run stopped come back from the
    # unchanged installed plists, boot first.
    mss_lock_check
    mss_mut rm -rf "$STAGE" || true
    for _j in boot llamacpp ds4 mlx guard; do
        in_list "$_j" "$STOPPED" || continue
        loaded "$_j" && continue
        _pl=$PLIST_DIR/$(label "$_j").plist
        [ -e "$_pl" ] || _pl=$STANDBY_DIR/$(label "$_j").plist
        [ ! -e "$_pl" ] || mss_mut launchctl bootstrap system "$_pl" || true
    done
    mss_error "$(label "$_not_stopped") did not stop within ${MSS_LAUNCHD_TIMEOUT}s; nothing was changed"
    for _j in $STOPPED; do
        if loaded "$_j"; then echo "  $(label "$_j"): loaded" >&2; else echo "  $(label "$_j"): not loaded" >&2; fi
    done
    exit 1
fi

# ── phase 4: commit ────────────────────────────────────────────────────────────
mss_lock_check
{
    echo "mss-commit-v1 $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    awk '{ print $1, $2, $4, $5 }' "$STEPS"
} > "$WORK/journal"
[ -z "$STANDBY_OPT" ] || mut_mkdir "$STANDBY_DIR" 0755 || exit 1
if [ -s "$STEPS" ]; then
    mut_write "$(cat "$WORK/journal")" "$JOURNAL" || mss_die "cannot write $JOURNAL; nothing was committed"
    while read -r _sn _st _ss _spre _snew; do
        mss_lock_check
        if [ "$_snew" = absent ]; then mss_mut rm -f "$_st" || mss_die "commit step $_sn ($_st) failed; re-run the install to finish it"
        else mss_mut mv -f "$STAGE/new/$_sn" "$_st" || mss_die "commit step $_sn ($_st) failed; re-run the install to finish it"; fi
    done < "$STEPS"
    mss_lock_check
    mss_mut rm -f "$JOURNAL" || exit 1
fi
mss_mut rm -rf "$STAGE" || exit 1
if [ -d "$STANDBY_DIR" ] && [ -z "$(ls -A "$STANDBY_DIR" 2>/dev/null)" ]; then mss_mut rmdir "$STANDBY_DIR" || true; fi
# The scripts the jobs run; an unchanged script is left alone.
for f in $LIBEXEC_FILES; do
    _src=$(libexec_src "$f")
    cmp -s "$_src" "$LIBEXEC_DIR/$f" && continue
    # shellcheck disable=SC2016
    mss_mut /bin/sh -c 'cp "$1" "$2.tmp" && chown root:wheel "$2.tmp" && chmod 0755 "$2.tmp" && mv -f "$2.tmp" "$2"' \
        sh "$_src" "$LIBEXEC_DIR/$f" || mss_die "cannot install $LIBEXEC_DIR/$f"
done

# ── phase 5: start (boot -> backend -> guard) ─────────────────────────────────
bootstrap_label() { # bootstrap_label <job>: 0 once launchd accepted it
    mss_launchd_wait_gone "$(label "$1")" "$MSS_LAUNCHD_TIMEOUT" || return 1
    mss_lock_check
    mss_mut launchctl bootstrap system "$PLIST_DIR/$(label "$1").plist" || return 1
    echo "bootstrapped $(label "$1")"
}
precreate() { # precreate <file> <owner:group> <mode>
    [ -f "$1" ] && return 0
    # shellcheck disable=SC2016
    mss_mut /bin/sh -c ': > "$1" && chown "$2" "$1" && chmod "$3" "$1"' sh "$1" "$2" "$3"
}
START_FAILED=""; FAILED_JOB=""; RESTARTED=""
for _j in $START_SET; do
    case $_j in
        boot)
            # The backend starts only after boot has written a marker for this
            # boot session in this run: one left by an earlier install in the
            # same boot would let it start under the old anchor.
            mss_lock_check
            mss_mut rm -f "$BOOT_MARKER" || true
            if ! bootstrap_label boot; then START_FAILED="launchctl bootstrap failed"; FAILED_JOB=boot; continue; fi
            _n=0; _why=""
            while :; do
                mss_boot_marker_ok "$BOOT_MARKER" && break
                _rc=$(launchctl print "system/$(label boot)" 2>/dev/null \
                    | sed -n 's/^[[:space:]]*last exit code = \([0-9][0-9]*\).*/\1/p' | head -n 1)
                if [ -n "$_rc" ] && [ "$_rc" != 0 ]; then _why="exit code $_rc"; break; fi
                if [ "$_n" -ge $((MSS_LAUNCHD_TIMEOUT * 2)) ]; then _why="no marker within ${MSS_LAUNCHD_TIMEOUT}s"; break; fi
                sleep 0.5
                _n=$((_n + 1))
            done
            if [ -n "$_why" ]; then
                START_FAILED="pf boot check failed ($_why); sudo /usr/local/libexec/mac-studio-server/mss-boot.sh shows the reason"
                FAILED_JOB=boot
                continue
            fi
            echo "pf verified by $(label boot)"
            RESTARTED="$RESTARTED $(label boot)" ;;
        guard)
            precreate "$LOG_DIR/guard.jsonl" root:wheel 0644 || exit 1
            if bootstrap_label guard; then RESTARTED="$RESTARTED $(label guard)"
            else START_FAILED=${START_FAILED:-launchctl bootstrap failed}; FAILED_JOB=${FAILED_JOB:-guard}; fi ;;
        *)
            # A failed pf check leaves the backend stopped (fail closed).
            if [ "$FAILED_JOB" = boot ]; then FAILED_JOB=$_j; continue; fi
            precreate "$LOG_DIR/$_j.log" "$MSS_SERVICE_USER:staff" 0640 || exit 1
            if bootstrap_label "$_j"; then RESTARTED="$RESTARTED $(label "$_j")"
            else START_FAILED="launchctl bootstrap failed"; FAILED_JOB=$_j; fi ;;
    esac
done

# ── phase 6: save (still under the lock) ──────────────────────────────────────
SAVE_FAILED=""
if [ -n "$MSS_SAVE_ENVFILE" ]; then
    mss_lock_check
    mss_mut sudo -u "$MSS_SAVE_USER" -- /bin/sh "$REPO_DIR/scripts/lib/mss-envfile-set.sh" \
        "$MSS_SAVE_ENVFILE" "$(mss_file_sha "$CONF")" 2>"$WORK/save.err"
    _save_rc=$?
    if [ "$_save_rc" != 0 ]; then
        SAVE_FAILED=$(sed -e 's/^ERROR: //' "$WORK/save.err" | tail -n 1)
        SAVE_FAILED=${SAVE_FAILED:-exit $_save_rc}
    fi
fi

# ── report ─────────────────────────────────────────────────────────────────────
labels_of() { _lo_out=""; for _j in $1; do _lo_out="$_lo_out $(label "$_j")"; done; words_or_none "${_lo_out# }"; }
if [ -n "$START_FAILED" ]; then
    _msg="$(label "$FAILED_JOB") failed to start ($START_FAILED); the new configuration is installed"
    if [ "$I_ACTIVE" != none ] && [ "$I_ACTIVE" != "$NEW_ACTIVE" ] && in_list "$I_ACTIVE" "$STANDBY_OPT"; then
        _msg="$_msg; $I_ACTIVE is on standby with its stamp; roll back with scripts/backend.sh activate $I_ACTIVE"
    fi
    mss_error "$_msg"
fi
if [ -n "$SAVE_FAILED" ]; then
    mss_error "installed $NEW_ACTIVE, but backends.env was not updated ($SAVE_FAILED); re-run scripts/backend.sh activate $NEW_ACTIVE"
fi
[ -z "$START_FAILED" ] && [ -z "$SAVE_FAILED" ] || exit 1

echo "install-backends: done (backends: $MSS_BACKENDS; pf rules: $PF_RULE_COUNT)"
echo "active: $NEW_ACTIVE; standby: $(words_or_none "$STANDBY_OPT")"
echo "unchanged: $(labels_of "$UNCHANGED_SET")"
echo "restarted: $(words_or_none "${RESTARTED# }")"
if [ "$NEW_ACTIVE" != none ] && [ -e "$DB_DIR/guard.tripped" ]; then
    echo "WARNING: guard tripped ($(head -n 1 "$DB_DIR/guard.tripped" 2>/dev/null)); $NEW_ACTIVE will not start until sudo /usr/local/libexec/mac-studio-server/mss-enable.sh"
fi
exit 0
