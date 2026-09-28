#!/bin/bash
# mss-run.sh — the root installer call shared by install.sh and model.sh (#15).
#
# bash 3.2. `sudo` resets the environment, so every variable is passed
# explicitly. Callers set BACKENDS, USER, BIND and GPU_PERCENT, and
# MSS_PICKER_REPLACE for a switch.

run_install_backends() {
    # MSS_REPLACE_BACKEND reaches only the --check-only pass of a switch.
    local mss_replace=""
    [ "${1:-}" != --check-only ] || mss_replace=${MSS_PICKER_REPLACE:-}
    sudo env \
        MSS_REPLACE_BACKEND="$mss_replace" \
        MSS_BACKENDS="$BACKENDS" \
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
