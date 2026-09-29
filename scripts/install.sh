#!/bin/bash

# MSS_BACKENDS selects the backends (default: ollama, the v1.2.0 flow). An
# optional backend (llamacpp or ds4) is fully validated, model hash included,
# before anything below changes the system, then installed as root by
# scripts/install-backends.sh. `sudo` resets the environment, so every variable
# is passed explicitly.
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib/mss-common.sh" || exit 1
. "$REPO_DIR/scripts/lib/mss-acquire.sh" || exit 1
. "$REPO_DIR/scripts/lib/mss-run.sh" || exit 1
. "$REPO_DIR/scripts/lib/mss-host.sh" || exit 1
mss_host_root_guard

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
  --configure-only   pick and save backends.env, check it; installs nothing (may leave a verification stamp)
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
# U1: a terminal run asks for the password once, then keeps sudo alive.
if [ "$MSS_MODE" != env ]; then
    mss_sudo_keepalive || exit 1
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

# D7 step 2: resolve the legacy choice keys, then validate every choice before
# anything below changes the system. Nothing has been written yet.
mss_choices_resolve || exit 1
mss_choices_validate || exit 1

# Configuration
USER=${OLLAMA_USER:-$(whoami)}
BASE_DIR=${OLLAMA_BASE_DIR:-"/Users/$USER/mac-studio-server"}

# MSS_INSTALL_SANDBOX: tests/run.sh only. The Ollama service block below writes
# a handful of absolute paths (/Library/LaunchDaemons, /Users/$USER/.ollama) and
# calls the real sudo, so phase A cannot run install.sh end to end without them.
# With the flag every absolute path in this file is prefixed with the phase A
# sysroot, and the raw `sudo` calls go through the same ${MSS_SUDO:-sudo} shim
# the apply steps use. Never set outside tests/run.sh; the guard below refuses it
# for root, exactly as mss_host_root_guard does.
MSS_SYSROOT_PREFIX=""
if [ "${MSS_INSTALL_SANDBOX:-}" = 1 ]; then
    [ "$(id -u)" -ne 0 ] || { echo "install.sh: MSS_INSTALL_SANDBOX is for tests/run.sh only" >&2; exit 1; }
    [ -n "${MSS_TEST_SYSROOT:-}" ] || { echo "install.sh: MSS_INSTALL_SANDBOX needs MSS_TEST_SYSROOT" >&2; exit 1; }
    MSS_SYSROOT_PREFIX=$MSS_TEST_SYSROOT
    sudo() { ${MSS_SUDO:-sudo} "$@"; }
    mkdir -p "$MSS_SYSROOT_PREFIX/Library/LaunchDaemons" \
        "$MSS_SYSROOT_PREFIX/Users/$USER/.ollama"
fi
# Metal wired-memory limit in percent of RAM (shared by Ollama, llama.cpp, ds4)
GPU_PERCENT=${MSS_GPU_PERCENT:-""}
BIND=${OLLAMA_BIND:-0.0.0.0}
BACKENDS=${MSS_BACKENDS:-ollama}
LOG_FILE="$BASE_DIR/logs/install.log"

log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# mss_check <install-backends args>: the root check or install; a sha256
# mismatch (exit 3) keeps a file downloaded in this run as .sha-mismatch.
mss_check() {
    run_install_backends "$@"
    mss_rc=$?
    [ "$mss_rc" != 3 ] || mss_sha_mismatch_rename
    return "$mss_rc"
}

# mss_apply_step <fn> [args...]: run one D7 apply step, echo its report lines
# to stdout and the log, and exit on its failure. Piping straight into `tee`
# would test tee's status, not the step's, and a failed step would report
# success (#27 r2).
mss_apply_step() {
    mss_step_out=$(
        "$@" 2>&1
        mss_step_rc=$?
        printf '@@RC@@%s\n' "$mss_step_rc"
    )
    mss_step_rc=${mss_step_out##*@@RC@@}
    printf '%s\n' "${mss_step_out%@@RC@@*}" | tee -a "$LOG_FILE" || exit 1
    [ "$mss_step_rc" != 0 ] || return 0
    mss_step_fn=$1
    shift
    mss_error "$mss_step_fn failed: $*"
    exit 1
}

# Validate before any system change.
mss_validate_selection "$BACKENDS" || exit 1
mss_validate_ipv4 "$BIND" || { mss_error "OLLAMA_BIND: '$BIND' must be a single IPv4 address"; exit 1; }
case ${MSS_TUNE_MACOS:-} in ''|yes|no) ;; *) mss_error "MSS_TUNE_MACOS must be yes or no"; exit 1 ;; esac
if [ -n "${OLLAMA_BIN:-}" ]; then
    OLLAMA_EXE=$OLLAMA_BIN
    mss_validate_path_chars OLLAMA_BIN "$OLLAMA_BIN" || exit 1
    [ -f "$OLLAMA_BIN" ] && [ -x "$OLLAMA_BIN" ] || { mss_error "OLLAMA_BIN: not an executable file: $OLLAMA_BIN"; exit 1; }
elif OLLAMA_EXE=$(mss_default_ollama_bin "$MSS_SYSROOT_PREFIX"); then
    # The Ollama already installed, not a fixed path: Homebrew on Apple silicon
    # puts it in /opt/homebrew/bin, and a plist naming /usr/local/bin/ollama
    # there cannot start (launchd EX_CONFIG). The path lives in the rendered
    # plist; env and loaded modes never write backends.env.
    mss_validate_path_chars "Ollama binary" "$OLLAMA_EXE" || exit 1
elif [ "$MSS_MODE" != picker ] && mss_backend_selected ollama; then
    # Nothing found: 1.3.0's default path is kept, and said out loud. (The
    # picker has already told the user how to install Ollama later.)
    echo "WARNING: no Ollama binary found; com.ollama.service will run $OLLAMA_EXE (brew install ollama, or set OLLAMA_BIN)" >&2
fi
[ -z "${MSS_PROGRESS_SECONDS:-}" ] || mss_validate_uint MSS_PROGRESS_SECONDS "$MSS_PROGRESS_SECONDS" 1 60 || exit 1
# D7: acquisition asked for by environment variables (the picker asks instead).
if [ "$MSS_MODE" != picker ]; then
    mss_d7_validate || exit 1
    mss_d7_run || exit 1
fi
if [ "$MSS_FLAG" = --configure-only ]; then
    mss_check --check-only || exit 1
    if [ -n "$MSS_PICKER_REPLACE" ]; then
        echo "$MSS_PICKER_REPLACE is still installed. install.sh --configure will offer to replace it." >&2
    fi
    echo "Saved $MSS_ENV_FILE and checked it; nothing was installed." >&2
    exit 0
fi
if mss_backend_selected llamacpp || mss_backend_selected ds4; then
    mss_check --check-only || exit 1
fi

# log_action and mss_apply_step append to $LOG_FILE, so its directory must exist first.
mkdir -p "$BASE_DIR/logs"

# D7 step 6: install the missing Docker tools (only MSS_DOCKER_INSTALL=yes
# installs; nothing here runs colima or docker). It runs before the switch
# removal, the Ollama steps and any launchd or pmset change, so a Homebrew
# failure leaves the machine as it was.
mss_apply_step mss_docker_install_apply

# D7 step 7: a confirmed switch removes the old backend only now, after the check passed.
if [ -n "$MSS_SWITCH_FROM" ]; then
    echo "Removing $MSS_SWITCH_FROM ..." >&2
    sudo /bin/sh "$REPO_DIR/scripts/uninstall.sh" --backend "$MSS_SWITCH_FROM" || exit 1
fi

if mss_backend_selected ollama; then
# Create necessary directories
log_action "Creating necessary directories..."
mkdir -p "$BASE_DIR/logs"
chmod 755 "$BASE_DIR/logs"
chown "$USER:staff" "$BASE_DIR/logs"

# Make scripts executable
log_action "Making scripts executable..."
chmod +x "$BASE_DIR/scripts/"*.sh

# Headless macOS tweaks (I2): asked once in the picker; unset keeps 1.4.0.
if [ "${MSS_TUNE_MACOS:-}" = no ]; then
    log_action "Skipping headless macOS tweaks (MSS_TUNE_MACOS=no; ./scripts/optimize-mac-server.sh applies them)"
else
    log_action "Running system optimization..."
    "$BASE_DIR/scripts/optimize-mac-server.sh"
fi

# Install launch daemon
log_action "Installing Ollama launch daemon ($OLLAMA_EXE)..."
# Replace user, bind address and binary in the plist file
mss_render_ollama_plist "$BASE_DIR/config/com.ollama.service.plist" "$USER" "$BIND" "$OLLAMA_EXE" > "/tmp/com.ollama.service.plist"
sudo cp "/tmp/com.ollama.service.plist" "$MSS_SYSROOT_PREFIX/Library/LaunchDaemons/"
rm "/tmp/com.ollama.service.plist"

sudo chown root:wheel "$MSS_SYSROOT_PREFIX/Library/LaunchDaemons/com.ollama.service.plist"
sudo chmod 644 "$MSS_SYSROOT_PREFIX/Library/LaunchDaemons/com.ollama.service.plist"

# Ensure Ollama directory exists with proper permissions
log_action "Setting up Ollama directory..."
mkdir -p "$MSS_SYSROOT_PREFIX/Users/$USER/.ollama"
chown "$USER:staff" "$MSS_SYSROOT_PREFIX/Users/$USER/.ollama"

# Load the launch daemon
log_action "Loading Ollama service..."
sudo launchctl unload "$MSS_SYSROOT_PREFIX/Library/LaunchDaemons/com.ollama.service.plist" 2>/dev/null || true
sudo launchctl load -w "$MSS_SYSROOT_PREFIX/Library/LaunchDaemons/com.ollama.service.plist"

mss_is_loopback_host "$BIND" || \
    log_action "WARNING: Ollama is LAN-bound on $BIND (OLLAMA_BIND=127.0.0.1 makes it loopback-only)"

# M2: the Ollama starter model, offered once the service is loaded (picker only).
if [ "$MSS_MODE" = picker ]; then
    if [ -x "$OLLAMA_EXE" ]; then
        [ "$BIND" = 0.0.0.0 ] && mss_ollama_host=127.0.0.1 || mss_ollama_host=$BIND
        mss_pick_ollama_model "$OLLAMA_EXE" "$mss_ollama_host"
    else
        echo "Ollama is not installed; later: brew install ollama, then scripts/install.sh" >&2
    fi
fi
else
    log_action "Skipping Ollama (MSS_BACKENDS=$BACKENDS); an existing Ollama install is left untouched"
    # Without Ollama the tweaks run only on an explicit yes (1.4.0 never ran them here).
    if [ "${MSS_TUNE_MACOS:-}" = yes ]; then
        log_action "Running system optimization..."
        "$BASE_DIR/scripts/optimize-mac-server.sh"
    fi
fi

# D7 step 9: the GPU boot job (D4 apply table).
mss_apply_step mss_gpu_apply "$GPU_PERCENT"

# D7 step 10: restart after a power failure (D6).
mss_apply_step mss_power_apply

# D7 step 11: the Colima boot job (D5 apply table; never stops a running Colima).
mss_apply_step mss_docker_autostart_apply

# Optional backend (llamacpp or ds4), validated above.
if mss_backend_selected llamacpp || mss_backend_selected ds4; then
    log_action "Installing optional backend (MSS_BACKENDS=$BACKENDS)..."
    mss_check || exit 1
fi

log_action "Installation completed" 
