#!/bin/bash
# backend.sh — switch, stop or start the optional backend (#1 D10).
#
#   scripts/backend.sh activate <llamacpp|ds4|mlx|none>
#   scripts/backend.sh stop <backend>
#   scripts/backend.sh start <backend>
#
# Run it as your user; it asks for the password once. activate runs the root
# check, then the install, with MSS_ACTIVE_BACKEND set: the old backend stops
# first, the new one starts from its standby plist and stamp (no re-hash), and
# the install saves MSS_BACKENDS and MSS_ACTIVE_BACKEND to backends.env under
# its lock. An unchanged activation restarts nothing. stop and start act on the
# active backend only, through the root lifecycle command.
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib/mss-common.sh" || exit 1
. "$REPO_DIR/scripts/lib/mss-acquire.sh" || exit 1
. "$REPO_DIR/scripts/lib/mss-run.sh" || exit 1
. "$REPO_DIR/scripts/lib/mss-host.sh" || exit 1
mss_host_root_guard

LIFECYCLE=/usr/local/libexec/mac-studio-server/mss-lifecycle.sh

mss_backend_usage() {
    cat >&2 <<'USAGE'
usage: scripts/backend.sh activate <llamacpp|ds4|mlx|none>
       scripts/backend.sh stop|start <llamacpp|ds4|mlx>
USAGE
}

[ $# -eq 2 ] || { mss_backend_usage; exit 2; }
ACTION=$1; B=$2
case $ACTION in
    activate) case $B in llamacpp|ds4|mlx|none) ;; *) mss_backend_usage; exit 2 ;; esac ;;
    start|stop) case $B in llamacpp|ds4|mlx) ;; *) mss_backend_usage; exit 2 ;; esac ;;
    -h|--help) mss_backend_usage; exit 0 ;;
    *) mss_backend_usage; exit 2 ;;
esac
[ "$(id -u)" -ne 0 ] || { echo "backend.sh: run it as your user; it calls sudo itself" >&2; exit 1; }

if [ "$ACTION" != activate ]; then
    [ -x "$LIFECYCLE" ] || { echo "backend.sh: no optional backend is installed" >&2; exit 1; }
    mss_sudo_keepalive || exit 1
    sudo env MSS_LOCK_TIMEOUT="${MSS_LOCK_TIMEOUT:-}" MSS_LAUNCHD_TIMEOUT="${MSS_LAUNCHD_TIMEOUT:-}" \
        "$LIFECYCLE" "$ACTION" "$B"
    exit $?
fi

# ── activate ───────────────────────────────────────────────────────────────────
MSS_ENV_FILE=${MSS_ENV_FILE:-$REPO_DIR/backends.env}
case $MSS_ENV_FILE in /*) ;; *) MSS_ENV_FILE=$(pwd)/$MSS_ENV_FILE ;; esac
if [ ! -e "$MSS_ENV_FILE" ] && [ ! -L "$MSS_ENV_FILE" ]; then
    echo "backend.sh: no $MSS_ENV_FILE; run scripts/install.sh --configure" >&2
    exit 1
fi
# The saved answers are the install's inputs; only the active backend changes.
unset MSS_ACTIVE_BACKEND
mss_envfile_load "$MSS_ENV_FILE" || exit 1
mss_validate_selection "$MSS_BACKENDS" || exit 1
if [ "$B" != none ]; then
    case " $(mss_optional_backends "$MSS_BACKENDS") " in
        *" $B "*) ;;
        *) echo "backend.sh: $B is not selected in $MSS_ENV_FILE (MSS_BACKENDS=$MSS_BACKENDS); add it with scripts/install.sh --configure" >&2
           exit 1 ;;
    esac
fi
export MSS_ACTIVE_BACKEND=$B
mss_active_backend "$MSS_BACKENDS" "$MSS_ACTIVE_BACKEND" >/dev/null || exit 1
# The same pre-checks as model.sh: legacy keys, formats and the GPU boot job.
mss_choices_resolve || exit 1
mss_choices_check_format || exit 1
mss_gpu_job_precheck || exit 1

mss_sudo_keepalive || exit 1
# shellcheck disable=SC2034  # all read by run_install_backends; an activation is never a switch
{
USER=${OLLAMA_USER:-$(whoami)}
BIND=${OLLAMA_BIND:-0.0.0.0}
GPU_PERCENT=${MSS_GPU_PERCENT:-""}
BACKENDS=$MSS_BACKENDS
MSS_PICKER_REPLACE=""
}
run_install_backends --check-only || exit 1
# The install writes backends.env under its lock; nothing here writes it after.
# shellcheck disable=SC2034  # read by run_install_backends
MSS_SAVE_ENVFILE=$MSS_ENV_FILE
# shellcheck disable=SC2034
MSS_SAVE_USER=$(id -un)
run_install_backends || exit 1
