#!/bin/bash

# MSS_BACKENDS selects the backends (default: ollama, the v1.2.0 flow). An
# optional backend (llamacpp or ds4) is fully validated, model hash included,
# before anything below changes the system, then installed as root by
# scripts/install-backends.sh. `sudo` resets the environment, so every variable
# is passed explicitly.
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib/mss-common.sh" || exit 1

# ── Modes (1.4.0). With no flag and no terminal, or with MSS_BACKENDS set, the
# 1.3.0 flow runs unchanged: environment variables only, backends.env is never
# read and nothing is asked. On a terminal, the saved backends.env is used, or
# the picker runs on first use. --configure / --configure-only always pick.
mss_install_usage() {
    cat >&2 <<'USAGE'
usage: scripts/install.sh [--configure | --configure-only]
  (no flag)          on a terminal, use the saved backends.env or pick on first run;
                     with MSS_BACKENDS set or no terminal, environment variables only
  --configure        pick the backends again, save backends.env, then install
  --configure-only   pick and save backends.env, check it, change nothing
USAGE
}
MSS_FLAG=""
for mss_arg in "$@"; do
    case $mss_arg in
        --configure|--configure-only)
            [ -z "$MSS_FLAG" ] || { mss_install_usage; exit 2; }
            MSS_FLAG=$mss_arg ;;
        -h|--help) mss_install_usage; exit 0 ;;
        *) echo "install.sh: unknown argument '$mss_arg'" >&2; mss_install_usage; exit 2 ;;
    esac
done
MSS_ENV_FILE=${MSS_ENV_FILE:-$REPO_DIR/backends.env}
MSS_PICKER_REPLACE=""
MSS_SWITCH_FROM=""
mss_on_terminal() { [ -t 0 ] && [ -t 2 ]; }
if [ -n "$MSS_FLAG" ]; then
    mss_on_terminal || { echo "install.sh $MSS_FLAG needs a terminal" >&2; exit 2; }
    [ "$(id -u)" -ne 0 ] || { echo "install.sh: run install.sh as your user; it calls sudo itself" >&2; exit 1; }
    MSS_MODE=picker
elif ! mss_on_terminal || [ -n "${MSS_BACKENDS+x}" ]; then
    MSS_MODE="env"
elif [ "$(id -u)" -eq 0 ]; then
    echo "install.sh: run install.sh as your user; it calls sudo itself" >&2
    exit 1
elif [ -e "$MSS_ENV_FILE" ] || [ -L "$MSS_ENV_FILE" ]; then
    MSS_MODE=loaded
else
    MSS_MODE=picker
fi
if [ "$MSS_MODE" = loaded ]; then
    mss_envfile_load "$MSS_ENV_FILE" || exit 1
    echo "Using $MSS_ENV_FILE: MSS_BACKENDS=$MSS_BACKENDS${MSS_ENVFILE_OVERRIDDEN:+ (set in the environment instead:$MSS_ENVFILE_OVERRIDDEN)}" >&2
elif [ "$MSS_MODE" = picker ]; then
    . "$REPO_DIR/scripts/lib/mss-picker.sh" || exit 1
    MSS_INSTALLED_SEL=$(mss_conf_get MSS_BACKENDS 2>/dev/null)
    MSS_INSTALLED_OPT=$(mss_conf_get MSS_GUARD_BACKEND 2>/dev/null)
    mss_picker_run "$MSS_ENV_FILE" "$MSS_INSTALLED_SEL" "$MSS_INSTALLED_OPT" \
        "$([ "$MSS_FLAG" = --configure-only ] && echo 1 || echo 0)"
fi

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
    # MSS_REPLACE_BACKEND reaches only the --check-only pass of a switch.
    mss_replace=""
    [ "${1:-}" != --check-only ] || mss_replace=$MSS_PICKER_REPLACE
    sudo env \
        MSS_REPLACE_BACKEND="$mss_replace" \
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
if [ "$MSS_FLAG" = --configure-only ]; then
    run_install_backends --check-only || exit 1
    if [ -n "$MSS_PICKER_REPLACE" ]; then
        echo "$MSS_PICKER_REPLACE is still installed. install.sh --configure will offer to replace it." >&2
    fi
    echo "Saved $MSS_ENV_FILE and checked it; nothing was installed." >&2
    exit 0
fi
if mss_backend_selected llamacpp || mss_backend_selected ds4; then
    run_install_backends --check-only || exit 1
fi
# A confirmed switch removes the old backend only now, after the check passed.
if [ -n "$MSS_SWITCH_FROM" ]; then
    echo "Removing $MSS_SWITCH_FROM ..." >&2
    sudo /bin/sh "$REPO_DIR/scripts/uninstall.sh" --backend "$MSS_SWITCH_FROM" || exit 1
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
