#!/bin/bash

# mac-studio-server installer (1.3.0).
#
# MSS_BACKENDS selects what is installed (default: ollama — identical to the
# v1.2.0 flow). Optional backends (llamacpp, ds4; at most one, plus ollama) are
# validated first and then installed by scripts/install-backends.sh as root.
# `sudo` resets the environment, so variables are passed explicitly.

set -e

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib/mss-common.sh"

# Configuration
USER=${OLLAMA_USER:-$(whoami)}
BASE_DIR=${OLLAMA_BASE_DIR:-"/Users/$USER/mac-studio-server"}
GPU_PERCENT=${OLLAMA_GPU_PERCENT:-""}
BIND=${OLLAMA_BIND:-0.0.0.0}
BACKENDS=${MSS_BACKENDS:-ollama}
LOG_FILE="$BASE_DIR/logs/install.log"

# Validation before any system change.
mss_validate_selection "$BACKENDS" || exit 1
mss_validate_ipv4 "$BIND" || { mss_error "OLLAMA_BIND: '$BIND' must be a single IPv4 address"; exit 1; }
mss_backend_selected llamacpp && : "${LLAMACPP_BIN:?LLAMACPP_BIN is required}"
mss_backend_selected llamacpp && : "${LLAMACPP_MODEL:?LLAMACPP_MODEL is required}"
mss_backend_selected llamacpp && : "${LLAMACPP_MODEL_SHA256:?LLAMACPP_MODEL_SHA256 is required}"
mss_backend_selected ds4 && : "${DS4_BIN:?DS4_BIN is required}"
mss_backend_selected ds4 && : "${DS4_MODEL:?DS4_MODEL is required}"
mss_backend_selected ds4 && : "${DS4_MODEL_SHA256:?DS4_MODEL_SHA256 is required}"

log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

if mss_backend_selected ollama; then
    mss_is_loopback_host "$BIND" || \
        log_action "WARNING: Ollama will be LAN-bound on $BIND — ensure your network is trusted."

    # Create necessary directories
    log_action "Creating necessary directories..."
    mkdir -p "$BASE_DIR/logs"
    chmod 755 "$BASE_DIR/logs"
    chown "$USER:staff" "$BASE_DIR/logs"

    # Make scripts executable
    log_action "Making scripts executable..."
    chmod +x "$BASE_DIR/scripts/"*.sh

    # Run optimization script
    log_action "Running system optimization..."
    "$BASE_DIR/scripts/optimize-mac-server.sh"

    # Install launch daemon
    log_action "Installing Ollama launch daemon..."
    sed -e "s|<OLLAMA_USER>|$USER|g" -e "s|<OLLAMA_BIND>|$BIND|g" \
        "$BASE_DIR/config/com.ollama.service.plist" > /tmp/com.ollama.service.plist
    sudo cp /tmp/com.ollama.service.plist /Library/LaunchDaemons/
    rm /tmp/com.ollama.service.plist

    sudo chown root:wheel /Library/LaunchDaemons/com.ollama.service.plist
    sudo chmod 644 /Library/LaunchDaemons/com.ollama.service.plist

    # Ensure Ollama directory exists with proper permissions
    log_action "Setting up Ollama directory..."
    mkdir -p "/Users/$USER/.ollama"
    chown "$USER:staff" "/Users/$USER/.ollama"

    # Load the launch daemon
    log_action "Loading Ollama service..."
    sudo launchctl unload /Library/LaunchDaemons/com.ollama.service.plist 2>/dev/null || true
    sudo launchctl load -w /Library/LaunchDaemons/com.ollama.service.plist
else
    log_action "Skipping Ollama (MSS_BACKENDS=$BACKENDS; an existing Ollama install is left untouched)"
fi

if [ -n "$GPU_PERCENT" ] && mss_backend_selected ollama; then
    log_action "Installing GPU memory optimization (${GPU_PERCENT}%)..."
    chmod +x "$BASE_DIR/scripts/set-gpu-memory.sh"

    sed -e "s|<OLLAMA_USER>|$USER|g" -e "s/<GPU_PERCENT>/$GPU_PERCENT/" \
        "$BASE_DIR/config/com.ollama.gpumemory.plist" > /tmp/com.ollama.gpumemory.plist
    sudo cp /tmp/com.ollama.gpumemory.plist /Library/LaunchDaemons/
    rm /tmp/com.ollama.gpumemory.plist

    sudo chown root:wheel /Library/LaunchDaemons/com.ollama.gpumemory.plist
    sudo chmod 644 /Library/LaunchDaemons/com.ollama.gpumemory.plist

    log_action "Loading GPU memory optimization service..."
    sudo launchctl unload /Library/LaunchDaemons/com.ollama.gpumemory.plist 2>/dev/null || true
    sudo launchctl load -w /Library/LaunchDaemons/com.ollama.gpumemory.plist

    log_action "GPU memory optimization enabled (${GPU_PERCENT}%)"
elif [ -n "$GPU_PERCENT" ]; then
    log_action "GPU memory optimization requested (${GPU_PERCENT}%); it will be re-applied by the boot flow"
else
    log_action "Skipping GPU memory optimization (set OLLAMA_GPU_PERCENT to enable, e.g. OLLAMA_GPU_PERCENT=80)"
fi

if [ "${DOCKER_AUTOSTART:-false}" = "true" ]; then
    log_action "Setting up Docker with Colima..."

    if ! command -v brew &>/dev/null; then
        log_action "Homebrew is required but not installed. Please install Homebrew first:"
        log_action "  /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        log_action "Skipping Docker autostart setup"
    else
        if ! command -v colima &>/dev/null; then
            log_action "Installing Colima via Homebrew..."
            brew install colima
        fi

        if ! command -v docker &>/dev/null; then
            log_action "Installing Docker CLI via Homebrew..."
            brew install docker
        fi

        chmod +x "$BASE_DIR/scripts/start-colima.sh"

        log_action "Installing Colima autostart..."

        sed "s|<OLLAMA_USER>|$USER|g" "$BASE_DIR/config/com.colima.daemon.plist" > /tmp/com.colima.daemon.plist
        sudo cp /tmp/com.colima.daemon.plist /Library/LaunchDaemons/
        rm /tmp/com.colima.daemon.plist

        sudo chown root:wheel /Library/LaunchDaemons/com.colima.daemon.plist
        sudo chmod 644 /Library/LaunchDaemons/com.colima.daemon.plist

        log_action "Loading Colima autostart service..."
        sudo launchctl unload /Library/LaunchDaemons/com.colima.daemon.plist 2>/dev/null || true
        sudo launchctl load -w /Library/LaunchDaemons/com.colima.daemon.plist

        log_action "Docker autostart with Colima enabled"
    fi
else
    log_action "Skipping Docker autostart (set DOCKER_AUTOSTART=true to enable)"
fi

# Optional backend (llamacpp or ds4): validated + installed as root.
if mss_backend_selected llamacpp || mss_backend_selected ds4; then
    log_action "Installing optional backend (MSS_BACKENDS=$BACKENDS)..."
    sudo env \
        MSS_BACKENDS="$BACKENDS" \
        OLLAMA_USER="$USER" \
        OLLAMA_BIND="$BIND" \
        OLLAMA_GPU_PERCENT="${OLLAMA_GPU_PERCENT:-}" \
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
        "$REPO_DIR/scripts/install-backends.sh"
fi

log_action "Installation completed"
