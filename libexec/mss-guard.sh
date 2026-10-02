#!/bin/sh
# mss-guard.sh — memory guard for the ONE active optional backend (#9 D5, #1).
# Root, launched by com.mac-studio-server.guard every 60 s (plus RunAtLoad).
# NEVER targets Ollama. Sampling failures are sample_error events and take no
# action. Flags: --simulate-trip, --rotate-now, --evaluate FILE (pure, non-root).
#
# POSIX sh, BSD userland. No ~, no $HOME.

set -u

LABEL="com.mac-studio-server.guard"
_self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
LIBEXEC_DIR="/usr/local/libexec/mac-studio-server"
# repo layout: libexec/*.sh + scripts/lib/mss-common.sh; installed: same dir.
# A missing file in `.` is fatal in POSIX sh, so test first.
if [ -f "$_self_dir/mss-common.sh" ]; then
    . "$_self_dir/mss-common.sh"
else
    . "$_self_dir/../scripts/lib/mss-common.sh"
fi

DB_DIR="/var/db/mac-studio-server"
LOG_DIR="/var/log/mac-studio-server"
GUARD_LOG="$LOG_DIR/guard.jsonl"
TRIP_MARKER="$DB_DIR/guard.tripped"
BASELINE="$DB_DIR/swap-baseline"
BOOTSTRAP_LABEL="com.mac-studio-server"

# defaults; overwritten from backends.conf when it is readable
STREAK=3; FREE_PCT=10; SWAP_HEADROOM_MB=2048; LOG_MAX_MB=100
_backend=$(mss_conf_get MSS_GUARD_BACKEND || echo "")
_v=$(mss_conf_get MSS_GUARD_STREAK || echo "")    && [ -n "$_v" ] && STREAK=$_v
_v=$(mss_conf_get MSS_GUARD_FREE_PCT || echo "")  && [ -n "$_v" ] && FREE_PCT=$_v
_v=$(mss_conf_get MSS_GUARD_SWAP_HEADROOM_MB || echo "") && [ -n "$_v" ] && SWAP_HEADROOM_MB=$_v
_v=$(mss_conf_get MSS_LOG_MAX_MB || echo "")      && [ -n "$_v" ] && LOG_MAX_MB=$_v
MAX_BYTES=$(( LOG_MAX_MB * 1024 * 1024 ))

# json_escape: one JSON string body. Backslash and quote are escaped, tabs and
# newlines become \t and \n, other control characters are dropped.
json_escape() {
    printf '%s' "$1" | tr -d '\000-\010\013-\037' | awk '
        { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t") }
        NR > 1 { printf "\\n" }
        { printf "%s", $0 }'
}

log_event() {
    # log_event <event> [detail] — key order fixed by the guard data contract.
    _ev=$1; _detail=${2:-}
    _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ -n "$_detail" ]; then
        printf '{"ts":"%s","event":"%s","backend":"%s","detail":"%s"}\n' "$_ts" "$_ev" "$_backend" "$(json_escape "$_detail")" >> "$GUARD_LOG"
    else
        printf '{"ts":"%s","event":"%s","backend":"%s"}\n' "$_ts" "$_ev" "$_backend" >> "$GUARD_LOG"
    fi
}

backend_pid() {
    # PID from launchctl print, never pgrep (it can match unrelated commands).
    _out=$(launchctl print "system/$BOOTSTRAP_LABEL.$_backend" 2>/dev/null) || return 1
    _pid=$(printf '%s\n' "$_out" | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -n 1)
    [ -n "$_pid" ] || return 1
    echo "$_pid"
}

rotate_log() {
    # rotate_log <file> [force]: copy-truncate keeps the inode, because launchd
    # holds the backend log fd open. Without force, only above MSS_LOG_MAX_MB.
    _file=$1; _force=${2:-}
    [ -f "$_file" ] || return 0
    if [ "$_force" != force ]; then
        _size=$(stat -f %z "$_file" 2>/dev/null || echo 0)
        [ "$_size" -gt "$MAX_BYTES" ] || return 0
    fi
    rm -f "$_file.3"
    [ -f "$_file.2" ] && mv "$_file.2" "$_file.3"
    [ -f "$_file.1" ] && mv "$_file.1" "$_file.2"
    cp -p "$_file" "$_file.1"
    : > "$_file"
}

# trip <reason> [pid]: the marker first, then the bootout (#1 D6). A start that
# races the trip sees the marker and refuses, and a failed bootout is recorded;
# the next sample trips again. The guard never waits for the lifecycle lock: a
# safety stop must not queue behind an install.
trip() {
    _reason=$1; _tpid=${2:-none}
    _tlabel="$BOOTSTRAP_LABEL.$_backend"
    _tmp="${TRIP_MARKER}.$$"
    printf '%s; label=%s pid=%s\n' "$_reason" "$_tlabel" "$_tpid" > "$_tmp"
    chown root:wheel "$_tmp"
    chmod 0644 "$_tmp"
    mv "$_tmp" "$TRIP_MARKER"
    launchctl bootout "system/$_tlabel" 2>/dev/null
    _trc=$?
    log_event "trip" "$_reason; label=$_tlabel pid=$_tpid; bootout_rc=$_trc"
    echo "$LABEL: TRIPPED — $_reason; sudo $LIBEXEC_DIR/mss-enable.sh recovers"
}

# ── --evaluate FILE [--streak N] [--free-pct N] [--swap-headroom-mb N] ─────────
# Pure decision over a guard.jsonl: no side effects, non-root safe.
mss_guard_evaluate() {
    _file=$1
    [ -r "$_file" ] || { echo none; return 0; }
    _lines=$(grep -E '"event":"(sample|sample_error)"' "$_file" | tail -n "$STREAK")
    [ -n "$_lines" ] || { echo none; return 0; }
    _count=$(printf '%s\n' "$_lines" | wc -l | tr -d ' ')
    [ "$_count" -ge "$STREAK" ] || { echo none; return 0; }

    _free_all=1
    _swap_all=1
    _broken=0
    # One JSON object per line; details may contain spaces, so read whole lines.
    while IFS= read -r _line; do
        case $_line in
            *'"event":"sample_error"'*|*'"pid":null'*) _broken=1; break ;;
        esac
        _f=$(printf '%s' "$_line" | sed -n 's/.*"free_pct":\([0-9][0-9]*\).*/\1/p')
        if [ -n "$_f" ] && [ "$_f" -lt "$FREE_PCT" ]; then :; else _free_all=0; fi
        case $_line in
            *'"swap_baseline_mb":null'*) _swap_all=0 ;;
            *)
                _s=$(printf '%s' "$_line" | sed -n 's/.*"swap_used_mb":\([0-9][0-9]*\).*/\1/p')
                _b=$(printf '%s' "$_line" | sed -n 's/.*"swap_baseline_mb":\([0-9][0-9]*\).*/\1/p')
                _limit=$(( ${_b:-0} + SWAP_HEADROOM_MB ))
                if [ -n "$_s" ] && [ -n "$_b" ] && [ "$_s" -gt "$_limit" ]; then :; else _swap_all=0; fi
                ;;
        esac
    done <<EOF_LINES
$_lines
EOF_LINES
    if [ "$_broken" = 1 ]; then echo none
    elif [ "$_free_all" = 1 ]; then echo trip:free
    elif [ "$_swap_all" = 1 ]; then echo trip:swap
    else echo none
    fi
}

# ── argument dispatch ──────────────────────────────────────────────────────────
case "${1:-}" in
    --evaluate)
        FILE=${2:?usage: mss-guard.sh --evaluate FILE [--streak N] [--free-pct N] [--swap-headroom-mb N]}
        shift 2
        while [ $# -gt 0 ]; do
            case $1 in
                --streak) STREAK=$2; shift 2 ;;
                --free-pct) FREE_PCT=$2; shift 2 ;;
                --swap-headroom-mb) SWAP_HEADROOM_MB=$2; shift 2 ;;
                *) mss_die "unknown --evaluate option '$1'" ;;
            esac
        done
        mss_guard_evaluate "$FILE"
        exit 0
        ;;
    --simulate-trip)
        [ "$(id -u)" -eq 0 ] || mss_die "--simulate-trip must run as root"
        trip "simulate-trip (operator drill)" "$(backend_pid || echo none)"
        exit 0
        ;;
    --rotate-now)
        [ "$(id -u)" -eq 0 ] || mss_die "--rotate-now must run as root"
        rotate_log "$LOG_DIR/$_backend.log" force
        rotate_log "$GUARD_LOG" force
        log_event "rotate" "rotate-now"
        exit 0
        ;;
esac

# ── sample ─────────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || mss_die "$LABEL must run as root"
[ -n "$_backend" ] || exit 0

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

free_raw=$(memory_pressure -Q 2>/dev/null)
free_pct=$(printf '%s\n' "$free_raw" | sed -n 's/.*free percentage: \([0-9][0-9]*\)%.*/\1/p' | head -n 1)

swap_raw=$(sysctl -n vm.swapusage 2>/dev/null)
swap_mb=$(printf '%s\n' "$swap_raw" | awk '{for (i=1; i<=NF; i++) if ($i=="used") {v=$(i+2); gsub(/M/, "", v); printf "%d", v+0.5; exit}}')

pid=$(backend_pid || echo "")
rss_mb=0

if [ -z "$free_pct" ] || [ -z "$swap_mb" ]; then
    [ -n "$free_pct" ] || log_event "sample_error" "memory_pressure -Q unparseable: $(printf '%s' "$free_raw" | head -c 200)"
    [ -n "$swap_mb" ] || log_event "sample_error" "vm.swapusage unparseable: $(printf '%s' "$swap_raw" | head -c 200)"
    exit 0
fi

# Backend not running: a pid:null sample (it breaks any streak), no baseline.
if [ -z "$pid" ]; then
    printf '{"ts":"%s","event":"sample","backend":"%s","pid":null,"free_pct":%s,"swap_used_mb":%s,"swap_baseline_mb":null,"rss_mb":0}\n' \
        "$now" "$_backend" "$free_pct" "$swap_mb" >> "$GUARD_LOG"
    rotate_log "$LOG_DIR/$_backend.log"
    rotate_log "$GUARD_LOG"
    exit 0
fi

rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
rss_mb=$(( ${rss_kb:-0} / 1024 ))

# baseline lifecycle: rewritten on first sight of a new PID; absent → null and
# no swap trip (a fresh baseline can never trip on its own).
baseline_mb=null
if [ -r "$BASELINE" ]; then
    read -r _bpid _bswap _bts < "$BASELINE" || _bpid=""
fi
if [ "${_bpid:-}" = "$pid" ] && [ -n "${_bswap:-}" ]; then
    baseline_mb=$_bswap
else
    _tmp="${BASELINE}.$$"
    printf '%s %s %s\n' "$pid" "$swap_mb" "$now" > "$_tmp"
    chown root:wheel "$_tmp"
    chmod 0644 "$_tmp"
    mv "$_tmp" "$BASELINE"
    baseline_mb=$swap_mb
    log_event "baseline" "pid=$pid swap_mb=$swap_mb"
fi

printf '{"ts":"%s","event":"sample","backend":"%s","pid":%s,"free_pct":%s,"swap_used_mb":%s,"swap_baseline_mb":%s,"rss_mb":%s}\n' \
    "$now" "$_backend" "$pid" "$free_pct" "$swap_mb" "$baseline_mb" "$rss_mb" >> "$GUARD_LOG"

# ── trip decision (same code path as --evaluate) ───────────────────────────────
decision=$(mss_guard_evaluate "$GUARD_LOG")
case $decision in
    trip:free) trip "free_pct below $FREE_PCT for $STREAK consecutive samples" "$pid" ;;
    trip:swap) trip "swap exceeded baseline+$SWAP_HEADROOM_MB MB for $STREAK consecutive samples" "$pid" ;;
esac

# ── rotation after the decision, so the fresh samples stay in the live file ────
rotate_log "$LOG_DIR/$_backend.log"
rotate_log "$GUARD_LOG"
