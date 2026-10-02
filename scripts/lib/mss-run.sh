#!/bin/bash
# mss-run.sh — the root installer call shared by install.sh and model.sh (#15).
#
# bash 3.2. `sudo` resets the environment, so every variable is passed
# explicitly. Callers set BACKENDS, USER, BIND and GPU_PERCENT, and
# MSS_PICKER_REPLACE for a switch, and MSS_SAVE_ENVFILE / MSS_SAVE_USER when
# the install should save MSS_BACKENDS and MSS_ACTIVE_BACKEND.

run_install_backends() {
    # MSS_REPLACE_BACKEND (a comma list) reaches only the --check-only pass of
    # a switch; the save variables reach only the install pass, which writes
    # backends.env under the lifecycle lock (#1 D5 phase 6).
    local mss_replace="" mss_save_file="" mss_save_user=""
    if [ "${1:-}" = --check-only ]; then
        mss_replace=${MSS_PICKER_REPLACE:-}
    else
        mss_save_file=${MSS_SAVE_ENVFILE:-}
        mss_save_user=${MSS_SAVE_USER:-}
    fi
    # #33 D1: refuse MLX_API_KEY_FILE before sudo, which would drop it
    # silently, and pass it on as well, so the root check sees what the user
    # set. MLX_HOST and MLX_ALLOW_FROM are keys, validated by the root check.
    case ",$BACKENDS," in *,mlx,*) mss_mlx_loopback_check || return 1 ;; esac
    sudo env \
        MSS_REPLACE_BACKEND="$mss_replace" \
        MSS_SAVE_ENVFILE="$mss_save_file" \
        MSS_SAVE_USER="$mss_save_user" \
        MSS_LOCK_TIMEOUT="${MSS_LOCK_TIMEOUT:-}" \
        MSS_LAUNCHD_TIMEOUT="${MSS_LAUNCHD_TIMEOUT:-}" \
        MSS_BACKENDS="$BACKENDS" \
        MSS_ACTIVE_BACKEND="${MSS_ACTIVE_BACKEND:-}" \
        MSS_DEFER_MODEL="${MSS_DEFER_MODEL:-}" \
        MSS_PROGRESS_SECONDS="${MSS_PROGRESS_SECONDS:-}" \
        OLLAMA_USER="$USER" \
        OLLAMA_BIND="$BIND" \
        MSS_GPU_PERCENT="$GPU_PERCENT" \
        LLAMACPP_BIN="${LLAMACPP_BIN:-}" \
        LLAMACPP_MODEL="${LLAMACPP_MODEL:-}" \
        LLAMACPP_MODEL_SHA256="${LLAMACPP_MODEL_SHA256:-}" \
        LLAMACPP_HOST="${LLAMACPP_HOST:-}" \
        LLAMACPP_PORT="${LLAMACPP_PORT:-}" \
        LLAMACPP_ALLOW_FROM="${LLAMACPP_ALLOW_FROM:-}" \
        LLAMACPP_API_KEY_FILE="${LLAMACPP_API_KEY_FILE:-}" \
        LLAMACPP_CTX="${LLAMACPP_CTX:-}" \
        LLAMACPP_PARALLEL="${LLAMACPP_PARALLEL:-}" \
        LLAMACPP_EXTRA_ARGS="${LLAMACPP_EXTRA_ARGS:-}" \
        DS4_BIN="${DS4_BIN:-}" \
        DS4_MODEL="${DS4_MODEL:-}" \
        DS4_MODEL_SHA256="${DS4_MODEL_SHA256:-}" \
        DS4_HOST="${DS4_HOST:-}" \
        DS4_PORT="${DS4_PORT:-}" \
        DS4_ALLOW_FROM="${DS4_ALLOW_FROM:-}" \
        DS4_CTX="${DS4_CTX:-}" \
        DS4_BATCHED_SESSIONS="${DS4_BATCHED_SESSIONS:-}" \
        DS4_WORKDIR="${DS4_WORKDIR:-}" \
        DS4_EXTRA_ARGS="${DS4_EXTRA_ARGS:-}" \
        MLX_BIN="${MLX_BIN:-}" \
        MLX_MODEL_DIR="${MLX_MODEL_DIR:-}" \
        MLX_PORT="${MLX_PORT:-}" \
        MLX_CTX="${MLX_CTX:-}" \
        MLX_EXTRA_ARGS="${MLX_EXTRA_ARGS:-}" \
        MLX_HOST="${MLX_HOST:-}" \
        MLX_ALLOW_FROM="${MLX_ALLOW_FROM:-}" \
        MLX_API_KEY_FILE="${MLX_API_KEY_FILE:-}" \
        MSS_GUARD_FREE_PCT="${MSS_GUARD_FREE_PCT:-}" \
        MSS_GUARD_SWAP_HEADROOM_MB="${MSS_GUARD_SWAP_HEADROOM_MB:-}" \
        MSS_GUARD_STREAK="${MSS_GUARD_STREAK:-}" \
        MSS_LOG_MAX_MB="${MSS_LOG_MAX_MB:-}" \
        /bin/sh "$REPO_DIR/scripts/install-backends.sh" "$@"
}

# mss_sha_mismatch_rename: after a check exits 3, keep a file downloaded in this
# run as <file>.sha-mismatch (never deleted), so a re-run cannot reuse it.
mss_sha_mismatch_rename() {
    [ -n "${MSS_DOWNLOADED:-}" ] && [ -f "$MSS_DOWNLOADED" ] || return 0
    if [ -e "$MSS_DOWNLOADED.sha-mismatch" ]; then
        mss_error "$MSS_DOWNLOADED.sha-mismatch exists; $MSS_DOWNLOADED is left in place"
        return 0
    fi
    mv "$MSS_DOWNLOADED" "$MSS_DOWNLOADED.sha-mismatch" \
        && echo "kept the download as $MSS_DOWNLOADED.sha-mismatch" >&2
}
