#!/bin/bash

# Configuration
USER=${OLLAMA_USER:-$(whoami)}
BASE_DIR=${OLLAMA_BASE_DIR:-"/Users/$USER/mac-studio-server"}
# GPU memory percentage (if set, enables GPU optimization)
GPU_PERCENT=${OLLAMA_GPU_PERCENT:-""}
LOG_FILE="$BASE_DIR/logs/install.log"

log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

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
sed "s|<OLLAMA_USER>|$USER|g" "$BASE_DIR/config/com.ollama.service.plist" > "/tmp/com.ollama.service.plist"
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

log_action "Installation completed" 
