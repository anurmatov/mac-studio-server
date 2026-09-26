#!/bin/bash

# MSS_BACKENDS selects the backends (default: ollama, the v1.2.0 flow). An
# optional backend (llamacpp or ds4) is fully validated, model hash included,
# before anything below changes the system, then installed as root by
# scripts/install-backends.sh. `sudo` resets the environment, so every variable
# is passed explicitly.
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib/mss-common.sh" || exit 1

# Configuration
USER=${OLLAMA_USER:-$(whoami)}
BASE_DIR=${OLLAMA_BASE_DIR:-"/Users/$USER/mac-studio-server"}
# GPU memory percentage (if set, enables GPU optimization)
GPU_PERCENT=${OLLAMA_GPU_PERCENT:-""}
BIND=${OLLAMA_BIND:-0.0.0.0}
BACKENDS=${MSS_BACKENDS:-ollama}
LOG_FILE="$BASE_DIR/logs/install.log"

log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

run_install_backends() {
    sudo env \
        MSS_BACKENDS="$BACKENDS" \
        OLLAMA_USER="$USER" \
        OLLAMA_BIND="$BIND" \
        OLLAMA_GPU_PERCENT="$GPU_PERCENT" \
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

# Validate before any system change.
mss_validate_selection "$BACKENDS" || exit 1
mss_validate_ipv4 "$BIND" || { mss_error "OLLAMA_BIND: '$BIND' must be a single IPv4 address"; exit 1; }
if mss_backend_selected llamacpp || mss_backend_selected ds4; then
    run_install_backends --check-only || exit 1
fi

# log_action appends to $LOG_FILE, so its directory must exist first.
mkdir -p "$BASE_DIR/logs"

if mss_backend_selected ollama; then
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
# Replace user in plist file
sed -e "s|<OLLAMA_USER>|$USER|g" -e "s|<OLLAMA_BIND>|$BIND|g" "$BASE_DIR/config/com.ollama.service.plist" > "/tmp/com.ollama.service.plist"
sudo cp "/tmp/com.ollama.service.plist" /Library/LaunchDaemons/
rm "/tmp/com.ollama.service.plist"

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

mss_is_loopback_host "$BIND" || \
    log_action "WARNING: Ollama is LAN-bound on $BIND (OLLAMA_BIND=127.0.0.1 makes it loopback-only)"
else
    log_action "Skipping Ollama (MSS_BACKENDS=$BACKENDS); an existing Ollama install is left untouched"
fi

# Install GPU memory optimization (if GPU_PERCENT is set)
if [ -n "$GPU_PERCENT" ]; then
    log_action "Installing GPU memory optimization (${GPU_PERCENT}%)..."
    chmod +x "$BASE_DIR/scripts/set-gpu-memory.sh"

    # Replace user in GPU memory plist file
    sed -e "s|<OLLAMA_USER>|$USER|g" -e "s/<GPU_PERCENT>/$GPU_PERCENT/" "$BASE_DIR/config/com.ollama.gpumemory.plist" > "/tmp/com.ollama.gpumemory.plist"
    sudo cp "/tmp/com.ollama.gpumemory.plist" /Library/LaunchDaemons/
    rm "/tmp/com.ollama.gpumemory.plist"

    sudo chown root:wheel /Library/LaunchDaemons/com.ollama.gpumemory.plist
    sudo chmod 644 /Library/LaunchDaemons/com.ollama.gpumemory.plist

    # Load the GPU memory daemon
    log_action "Loading GPU memory optimization service..."
    sudo launchctl unload /Library/LaunchDaemons/com.ollama.gpumemory.plist 2>/dev/null || true
    sudo launchctl load -w /Library/LaunchDaemons/com.ollama.gpumemory.plist
    
    log_action "GPU memory optimization enabled (${GPU_PERCENT}%)"
else
    log_action "Skipping GPU memory optimization (set OLLAMA_GPU_PERCENT to enable, e.g. OLLAMA_GPU_PERCENT=80)"
fi

# Install Docker daemon (if DOCKER_AUTOSTART is set)
if [ "${DOCKER_AUTOSTART:-false}" = "true" ]; then
    log_action "Setting up Docker with Colima..."
    
    # Check if Homebrew is installed
    if ! command -v brew &>/dev/null; then
        log_action "Homebrew is required but not installed. Please install Homebrew first:"
        log_action "  /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        log_action "Skipping Docker autostart setup"
    else
        # Check if Colima is installed, install if not
        if ! command -v colima &>/dev/null; then
            log_action "Installing Colima via Homebrew..."
            brew install colima
        fi
        
        # Check if Docker CLI is installed, install if not
        if ! command -v docker &>/dev/null; then
            log_action "Installing Docker CLI via Homebrew..."
            brew install docker
        fi
        
        # Make Colima script executable
        chmod +x "$BASE_DIR/scripts/start-colima.sh"
        
        log_action "Installing Colima autostart..."
        
        # Replace user in Colima plist file
        sed "s|<OLLAMA_USER>|$USER|g" "$BASE_DIR/config/com.colima.daemon.plist" > "/tmp/com.colima.daemon.plist"
        sudo cp "/tmp/com.colima.daemon.plist" /Library/LaunchDaemons/
        rm "/tmp/com.colima.daemon.plist"

        sudo chown root:wheel /Library/LaunchDaemons/com.colima.daemon.plist
        sudo chmod 644 /Library/LaunchDaemons/com.colima.daemon.plist

        # Load the Colima daemon
        log_action "Loading Colima autostart service..."
        sudo launchctl unload /Library/LaunchDaemons/com.colima.daemon.plist 2>/dev/null || true
        sudo launchctl load -w /Library/LaunchDaemons/com.colima.daemon.plist
        
        log_action "Docker autostart with Colima enabled"
    fi
else
    log_action "Skipping Docker autostart (set DOCKER_AUTOSTART=true to enable)"
fi

# Optional backend (llamacpp or ds4), validated above.
if mss_backend_selected llamacpp || mss_backend_selected ds4; then
    log_action "Installing optional backend (MSS_BACKENDS=$BACKENDS)..."
    run_install_backends || exit 1
fi

log_action "Installation completed" 
