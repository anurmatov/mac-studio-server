#!/bin/bash

# set-gpu-memory.sh — set the Metal wired-memory limit by hand (#27).
#
#   sudo ./scripts/set-gpu-memory.sh 85        # now, until reboot
#   sudo ./scripts/set-gpu-memory.sh system    # back to the macOS default (0)
#
# With no argument it reads MSS_GPU_PERCENT, then the legacy OLLAMA_GPU_PERCENT.
# The legacy call contract stays: an un-migrated com.ollama.gpumemory boot job
# passes no argument and exports the legacy variable, and a `git pull` without
# a re-install must still apply the limit at the next boot.
#
# sudo resets the environment, so pass the value as an argument, or
# `sudo env MSS_GPU_PERCENT=85 ./scripts/set-gpu-memory.sh`. An argument wins
# over the environment; the script never falls back to a default silently.
USER=${OLLAMA_USER:-$(whoami)}
BASE_DIR=${OLLAMA_BASE_DIR:-"/Users/$USER/mac-studio-server"}
LOG_FILE="$BASE_DIR/logs/gpu-memory.log"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

_pct=${1:-}
_env=${MSS_GPU_PERCENT:-${OLLAMA_GPU_PERCENT:-}}
if [ -n "$_env" ] && [ -n "${OLLAMA_GPU_PERCENT:-}" ] && [ -n "${MSS_GPU_PERCENT:-}" ] \
    && [ "$OLLAMA_GPU_PERCENT" != "$MSS_GPU_PERCENT" ]; then
    echo "MSS_GPU_PERCENT=$MSS_GPU_PERCENT and OLLAMA_GPU_PERCENT=$OLLAMA_GPU_PERCENT differ; keep one" >&2
    exit 2
fi
if [ -z "$_pct" ]; then
    if [ -z "$_env" ]; then
        echo "usage: sudo ./scripts/set-gpu-memory.sh <1-100|system> (or set MSS_GPU_PERCENT)" >&2
        exit 2
    fi
    _pct=$_env
    log_action "No argument; using MSS_GPU_PERCENT=$_pct from the environment"
elif [ -n "$_env" ] && [ "$_pct" != "$_env" ]; then
    log_action "Argument $_pct wins over the environment ($_env)"
fi

case $_pct in
    system)
        _limit=0
        ;;
    ''|*[!0-9]*)
        echo "set-gpu-memory.sh: '$_pct' must be 1-100 or system" >&2
        exit 2
        ;;
    *)
        case $_pct in 0|0[0-9]*) echo "set-gpu-memory.sh: '$_pct' must be 1-100 with no leading zero" >&2; exit 2 ;; esac
        [ "$_pct" -le 100 ] || { echo "set-gpu-memory.sh: '$_pct' is above 100" >&2; exit 2; }
        # ${MSS_SYSCTL:-/usr/sbin/sysctl} so tests/run.sh can stand in for the
        _total=$(${MSS_SYSCTL:-/usr/sbin/sysctl} -n hw.memsize 2>/dev/null) \
            || { echo "set-gpu-memory.sh: cannot read hw.memsize" >&2; exit 1; }
        # same integer order as mss_wired_limit_mb / install-backends.sh
        _limit=$(( _total / 1024 / 1024 * _pct / 100 ))
        ;;
esac

log_action "Setting iogpu.wired_limit_mb=${_limit} (MSS_GPU_PERCENT=${_pct})..."
${MSS_SYSCTL:-/usr/sbin/sysctl} iogpu.wired_limit_mb="$_limit" || { log_action "ERROR: sysctl failed"; exit 1; }
log_action "GPU memory limit applied"
