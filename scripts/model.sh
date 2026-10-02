#!/bin/bash
# model.sh — add or switch the optional backend's model later (#15 M5).
#
#   scripts/model.sh                                  menu (starter, more, own file/URL)
#   scripts/model.sh --catalog ID [--dest FILE]
#   scripts/model.sh --path FILE --sha256 HEX
#   scripts/model.sh --url URL --sha256 HEX [--dest FILE]
#   any of the above with --backend llamacpp|ds4 (required when both are selected)
#
# Needs a terminal and a backends.env with llamacpp or ds4. Downloads as the
# user, saves the model and sha256 to backends.env, then asks for the password
# once and runs only the optional-backend steps: the root check (one hash, the
# stamp), then the install, which loads the backend and guard. Ollama is never
# touched, and an old model file is never deleted.
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib/mss-common.sh" || exit 1
. "$REPO_DIR/scripts/lib/mss-acquire.sh" || exit 1
. "$REPO_DIR/scripts/lib/mss-run.sh" || exit 1
. "$REPO_DIR/scripts/lib/mss-picker.sh" || exit 1
. "$REPO_DIR/scripts/lib/mss-host.sh" || exit 1
mss_host_root_guard

mss_model_usage() {
    cat >&2 <<'USAGE'
usage: scripts/model.sh [--backend llamacpp|ds4] [--catalog ID [--dest FILE] | --path FILE --sha256 HEX | --url URL --sha256 HEX [--dest FILE]]
USAGE
}

# A terminal is required before anything else, even with flags (like --configure).
if ! [ -t 0 ] || ! [ -t 2 ]; then
    echo "model.sh needs a terminal" >&2
    exit 2
fi

M_CATALOG="" M_PATH="" M_URL="" M_SHA="" M_DEST="" M_BACKEND=""
while [ $# -gt 0 ]; do
    case $1 in
        --catalog|--path|--url|--sha256|--dest|--backend)
            [ $# -ge 2 ] || { mss_model_usage; exit 2; }
            case $1 in
                --catalog) M_CATALOG=$2 ;; --path) M_PATH=$2 ;; --url) M_URL=$2 ;;
                --sha256) M_SHA=$2 ;; --dest) M_DEST=$2 ;; --backend) M_BACKEND=$2 ;;
            esac
            shift 2 ;;
        -h|--help) mss_model_usage; exit 0 ;;
        *) echo "model.sh: unknown argument '$1'" >&2; mss_model_usage; exit 2 ;;
    esac
done
M_SOURCES=0
for v in "$M_CATALOG" "$M_PATH" "$M_URL"; do [ -z "$v" ] || M_SOURCES=$((M_SOURCES + 1)); done
[ "$M_SOURCES" -le 1 ] || { echo "model.sh: use one of --catalog, --path or --url" >&2; exit 2; }
if [ -n "$M_PATH" ] || [ -n "$M_URL" ]; then
    [ -n "$M_SHA" ] || { echo "model.sh: --path and --url need --sha256" >&2; exit 2; }
fi
[ -z "$M_DEST" ] || [ -n "$M_CATALOG" ] || [ -n "$M_URL" ] || { echo "model.sh: --dest goes with --catalog or --url" >&2; exit 2; }
case $M_BACKEND in ''|llamacpp|ds4) ;; *) echo "model.sh: --backend is llamacpp or ds4" >&2; exit 2 ;; esac
[ "$(id -u)" -ne 0 ] || { echo "model.sh: run it as your user; it calls sudo itself" >&2; exit 1; }
mss_host_root_guard

MSS_ENV_FILE=${MSS_ENV_FILE:-$REPO_DIR/backends.env}
case $MSS_ENV_FILE in /*) ;; *) MSS_ENV_FILE=$(pwd)/$MSS_ENV_FILE ;; esac
if [ ! -e "$MSS_ENV_FILE" ] && [ ! -L "$MSS_ENV_FILE" ]; then
    echo "model.sh: no $MSS_ENV_FILE; run scripts/install.sh --configure" >&2
    exit 1
fi
mss_envfile_load "$MSS_ENV_FILE" || exit 1
# D4b: resolve the legacy choice keys, check the four formats, and require the
# GPU boot job the file asks for — all before any download and before the save.
# model.sh never applies Docker, Homebrew or power settings, so it never probes
# them.
mss_choices_resolve || exit 1
mss_choices_check_format || exit 1
mss_gpu_job_precheck || exit 1
mss_validate_selection "$MSS_BACKENDS" || exit 1
# The GGUF backend this model is for (#1 D13): mlx models are directories.
M_GGUF=""
for b in llamacpp ds4; do mss_backend_selected "$b" && M_GGUF="$M_GGUF $b"; done
M_GGUF=${M_GGUF# }
if [ -n "$M_BACKEND" ]; then
    case " $M_GGUF " in
        *" $M_BACKEND "*) B=$M_BACKEND ;;
        *) echo "model.sh: $M_BACKEND is not selected in $MSS_ENV_FILE (MSS_BACKENDS=$MSS_BACKENDS)" >&2; exit 1 ;;
    esac
elif [ -z "$M_GGUF" ] && mss_backend_selected mlx; then
    echo "model.sh: mlx models are directories; set MLX_MODEL_DIR with scripts/install.sh --configure" >&2
    exit 1
elif [ -z "$M_GGUF" ]; then
    echo "model.sh: no llama.cpp or ds4 backend in $MSS_ENV_FILE; run scripts/install.sh --configure" >&2
    exit 1
elif [ "$M_GGUF" = "llamacpp ds4" ]; then
    echo "model.sh: llamacpp and ds4 are both selected; choose one with --backend llamacpp or --backend ds4" >&2
    exit 1
else
    B=$M_GGUF
fi
P=$(mss_prefix "$B")

# ── the model ──────────────────────────────────────────────────────────────────
if [ -n "$M_CATALOG" ]; then
    mss_catalog_url "$B" "$M_CATALOG" >/dev/null || { echo "model.sh: '$M_CATALOG' is not a $B catalogue entry" >&2; exit 1; }
    M_URL=$(mss_catalog_url "$B" "$M_CATALOG")
    M_SHA=$(mss_catalog_get "$B" "$M_CATALOG" sha256)
    M_SIZE=$(mss_catalog_get "$B" "$M_CATALOG" size)
    M_FILE=$(mss_catalog_get "$B" "$M_CATALOG" file)
elif [ -n "$M_URL" ]; then
    mss_url_valid "$M_URL" || exit 1
    mss_validate_sha256 "--sha256" "$M_SHA" || exit 1
    M_SIZE=""
    M_FILE=${M_URL%%\?*}
elif [ -n "$M_PATH" ]; then
    mss_validate_sha256 "--sha256" "$M_SHA" || exit 1
    _mss_pick_model_valid "$M_PATH" || exit 1
fi

if [ -n "$M_URL" ]; then
    [ -n "$M_DEST" ] || M_DEST=$HOME/models/$(basename "$M_FILE")
    case $M_DEST in /*) ;; *) echo "model.sh: --dest must be an absolute path" >&2; exit 2 ;; esac
    if [ -f "$M_DEST" ]; then
        echo "$M_DEST exists; using it (the check verifies its sha256)" >&2
    else
        mss_acquire_download "$M_URL" "$M_DEST" "$M_SIZE" 1 || exit 1
    fi
    _mss_pick_use_model "$P" "$M_DEST" "$M_SHA"
elif [ -n "$M_PATH" ]; then
    _mss_pick_use_model "$P" "$M_PATH" "$M_SHA"
else
    mss_pick_trap
    mss_pick_model_menu "$B" 0
    trap - INT
fi
_mss_pick_set MSS_DEFER_MODEL ""
# D4b: the pre-check ran before the download; run it again so a file is never
# saved that the boot job contradicts.
mss_gpu_job_precheck || exit 1
mss_envfile_write "$MSS_ENV_FILE" || exit 1
echo "Saved $MSS_ENV_FILE" >&2

# ── the optional backend only (never the Ollama steps) ─────────────────────────
mss_sudo_keepalive || exit 1
# shellcheck disable=SC2034  # all read by run_install_backends; a model change is never a switch
{
USER=${OLLAMA_USER:-$(whoami)}
BIND=${OLLAMA_BIND:-0.0.0.0}
GPU_PERCENT=${MSS_GPU_PERCENT:-""}
BACKENDS=$MSS_BACKENDS
MSS_PICKER_REPLACE=""
}
run_install_backends --check-only
rc=$?
if [ "$rc" != 0 ]; then
    [ "$rc" != 3 ] || mss_sha_mismatch_rename
    exit 1
fi
# The install saves MSS_BACKENDS and MSS_ACTIVE_BACKEND (as loaded) under its lock.
# shellcheck disable=SC2034  # read by run_install_backends
MSS_SAVE_ENVFILE=$MSS_ENV_FILE
# shellcheck disable=SC2034
MSS_SAVE_USER=$(id -un)
run_install_backends || exit 1
echo "$B: model $(printenv "${P}_MODEL") installed" >&2
