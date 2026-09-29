#!/bin/bash

# Get user and base directory from environment or use defaults
USER=${OLLAMA_USER:-$(whoami)}
BASE_DIR=${OLLAMA_BASE_DIR:-"/Users/$USER/mac-studio-server"}
LOG_FILE="$BASE_DIR/logs/docker.log"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Log function
log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if Colima is installed
if ! command -v colima &>/dev/null; then
    log_action "ERROR: Colima is not installed. Please install it with: brew install colima"
    exit 1
fi

# Check if Docker CLI is installed
if ! command -v docker &>/dev/null; then
    log_action "ERROR: Docker CLI is not installed. Please install it with: brew install docker"
    exit 1
fi

# Check if Docker is already running
if docker info &>/dev/null; then
    log_action "Docker daemon is already running"
    exit 0
fi

# Start Colima. Sizing flags are for a first creation only: Colima applies
# --cpu/--memory/--disk to an existing stopped VM every time they are passed,
# so autostart would shrink a larger VM and fail a VM that is not vz (#27 D5).
# Stock macOS has no jq; `colima list --json` prints one object per instance.
# A VM counts as existing when either the list or Colima's own files show it:
# resizing on a list that came back empty is the one mistake that cannot be
# undone at the next boot, so the flags need both to say there is no VM.
colima_home=${COLIMA_HOME:-$HOME/.colima}
on_disk=0
if [ -e "$colima_home/default/colima.yaml" ] || [ -d "$colima_home/_lima/colima" ]; then on_disk=1; fi
if colima_out=$(colima list --json 2>/dev/null); then
    if printf '%s\n' "$colima_out" | grep -Eq '"name"[[:space:]]*:[[:space:]]*"default"'; then
        log_action "Starting the existing Colima instance (listed; no sizing flags)..."
        colima start 2>&1 | tee -a "$LOG_FILE"
    elif [ "$on_disk" = 1 ]; then
        log_action "colima list does not show default but $colima_home has it; starting with no sizing flags..."
        colima start 2>&1 | tee -a "$LOG_FILE"
    else
        log_action "No Colima instance listed or in $colima_home; creating the default instance..."
        colima start --cpu 4 --memory 8 --disk 50 --vm-type=vz --mount-type=virtiofs 2>&1 | tee -a "$LOG_FILE"
    fi
else
    log_action "colima list failed; starting with no flags (resizing is never the fallback)..."
    colima start 2>&1 | tee -a "$LOG_FILE"
fi

# Wait for Docker to become available
log_action "Waiting for Docker daemon to become available..."
for i in {1..60}; do
    if docker info &>/dev/null; then
        log_action "Docker daemon is now running via Colima"
        exit 0
    fi
    sleep 1
    if [ $((i % 10)) -eq 0 ]; then
        log_action "Still waiting for Docker daemon... ($i seconds elapsed)"
    fi
done

log_action "ERROR: Docker daemon did not start within the timeout period"
log_action "Try running: colima start"
exit 1 