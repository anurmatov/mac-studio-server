# Mac Studio Server Configuration for Ollama

This repository contains configuration and scripts for running Ollama LLM server on Apple Silicon Macs in headless mode (tested on Mac Studio with M1 Ultra).

## Overview

This configuration is optimized for running Mac Studio as a dedicated Ollama server, with:
- Headless operation (SSH access recommended)
- Minimal resource usage (GUI and unnecessary services disabled)
- Automatic startup and recovery
- Performance optimizations for Apple Silicon

## Latest Updates

- **[v1.3.0]** Optional inference backends: llama.cpp `llama-server` and DwarfStar `ds4-server` beside Ollama, with artifact verification, pf allowlists and a memory guard
- **[v1.2.0]** Added Docker autostart support for container applications (with [Colima](https://github.com/abiosoft/colima))
- **[v1.1.0]** Added GPU Memory Optimization - configure Metal to use more RAM for models
- **[v1.0.0]** Initial release with system optimizations and Ollama configuration

See the [CHANGELOG](CHANGELOG.md) for detailed version history.

## Features

- Automatic startup on boot
- Optimized for Apple Silicon
- System resource optimization through service disabling
- External network access
- Proper logging setup
- SSH-based remote management
- Docker autostart for container applications

## Requirements

- Mac with Apple Silicon
- macOS Sonoma or later
- [Ollama](https://ollama.com/) installed
- Administrative privileges
- SSH enabled (System Settings → Sharing → Remote Login)

## Remote Access

For optimal performance, we recommend:
1. Primary access method: SSH
```bash
ssh username@your-mac-studio-ip
```

2. (Optional) Screen Sharing is kept available for emergency/maintenance access but not recommended for regular use to save resources.

## Installation

1. Clone this repository:
```bash
git clone https://github.com/anurmatov/mac-studio-server.git
cd mac-studio-server
```

2. (Optional) Configure installation:
```bash
# Default values shown
export OLLAMA_USER=$(whoami)  # User to run Ollama as
export OLLAMA_BASE_DIR="/Users/$OLLAMA_USER/mac-studio-server"

# Optional features - only set these if you need them
export OLLAMA_GPU_PERCENT="80"  # Optional: Enable GPU memory optimization (percentage of RAM to allocate)
export DOCKER_AUTOSTART="true"  # Optional: Enable automatic Docker startup
```

3. Run the installation script:
```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

## Backends (1.3.0)

Ollama stays the zero-config default: with `MSS_BACKENDS` unset or `ollama`,
installation is identical to v1.2.0. You may additionally install **one**
optional backend:

| backend | server | default bind | auth | notes |
|---|---|---|---|---|
| `ollama` | `/usr/local/bin/ollama serve` | `0.0.0.0:11434` (`OLLAMA_BIND`) | none (unchanged) | zero-config default |
| `llamacpp` | `llama-server` (any GGUF) | `127.0.0.1:8080` | optional `--api-key-file` | LAN bind needs an allowlist or a key |
| `ds4` | `ds4-server` (DwarfStar) | `127.0.0.1:8000` | **none** | LAN bind always needs `DS4_ALLOW_FROM` |

Valid selections: `ollama`, `llamacpp`, `ds4`, `ollama,llamacpp`, `ollama,ds4`.
Everything else — unknown names, duplicates, `llamacpp,ds4`, all three — is
rejected before any system change.

### Security defaults

- **Artifact validation (fail-closed).** Binary and model paths are resolved
  once at install (per-hop `readlink`, no GNU extensions), the model sha256 is
  verified, and every start re-checks size/inode/mtime against the stamp. A
  changed or missing model refuses with `REFUSE:` and exit 78.
- **Ollama keeps its v1.2.0 bind.** It stays on `0.0.0.0:11434` by default,
  so existing installs do not change; the installer warns while it is
  LAN-bound. `OLLAMA_BIND=127.0.0.1` makes it loopback-only.
- **LAN binds are firewalled.** A non-loopback backend with an allowlist
  renders pf sub-anchor `com.apple/250.mac-studio-server` rules (loopback +
  your allowlist, then block). A root boot daemon enables pf, loads the anchor
  and verifies pf is enabled, referenced and fully loaded before writing a boot
  marker; the wrapper refuses to bind LAN without this boot's marker. ds4 always
  needs an allowlist on a LAN address. llama.cpp may use an API key file
  instead; then there is no pf policy and the key is the sole protection.
- **Extra args are allowlisted.** `LLAMACPP_EXTRA_ARGS` / `DS4_EXTRA_ARGS`
  accept only reviewed performance flags; anything that serves files, loads
  extra artifacts or persists state is rejected. ds4's `--mtp*` flags are not
  accepted in 1.3.0.
- **Inputs are validated, not escaped.** Paths must be absolute with no spaces
  or special characters, numbers must be integers, and a value containing a
  newline is refused. The service user defaults to the user who ran `sudo` and
  is never `root`.
- **A memory guard protects the host and Ollama.** It samples free memory,
  swap and the optional backend's RSS, and after repeated violations boots the
  optional backend out and keeps it down until `mss-enable.sh`. It never stops
  or reconfigures Ollama.

### Variables

See `config/backends.env.example` for the full annotated list: `MSS_BACKENDS`,
`OLLAMA_BIND`, `<BACKEND>_BIN/_MODEL/_MODEL_SHA256/_HOST/_PORT/_ALLOW_FROM`,
`LLAMACPP_API_KEY_FILE/_CTX/_PARALLEL`, `DS4_CTX/_BATCHED_SESSIONS/_WORKDIR`,
`<BACKEND>_EXTRA_ARGS`, and the guard/log knobs
(`MSS_GUARD_FREE_PCT`, `MSS_GUARD_SWAP_HEADROOM_MB`, `MSS_GUARD_STREAK`,
`MSS_LOG_MAX_MB`).

### Install

```bash
# existing Ollama users: nothing to do; re-running install.sh is unchanged.
export MSS_BACKENDS=ollama,ds4
export DS4_BIN=/path/to/ds4-server
export DS4_MODEL=/path/to/model.gguf
export DS4_MODEL_SHA256=<sha256>
./scripts/install.sh
```

`install.sh` first runs `scripts/install-backends.sh --check-only`, which
validates every variable and hashes the model without writing anything, and
only then touches Ollama. On a first install the model is therefore hashed
twice (the check, then the root installer); a re-install with an unchanged
model skips both. `OLLAMA_GPU_PERCENT` installs `com.ollama.gpumemory` whatever
the selection, and an optional backend waits for that wired limit at start.

### Status / enable / uninstall

```bash
./scripts/status.sh                 # health + pf checks (pf checks need sudo)
sudo /usr/local/libexec/mac-studio-server/mss-enable.sh   # after a guard trip
sudo ./scripts/uninstall.sh --backend ds4
sudo ./scripts/uninstall.sh --all [--purge-logs]          # idempotent
```

### Migration

- **Existing Ollama users:** nothing to do. The default render of
  `com.ollama.service.plist` is byte-identical to v1.2.0.
- **Make Ollama loopback-only:** `export OLLAMA_BIND=127.0.0.1` and re-run
  `scripts/install.sh`.
- **Add a backend later:** set `MSS_BACKENDS=ollama,<backend>` plus that
  backend's variables and re-run the installer. Switching optional backends
  requires `scripts/uninstall.sh --backend <old>` first — nothing is removed
  silently.

### Tested reference (ds4)

`ds4-server` at commit `0aaea5a238fb41a35106a551e73c8409dfb751ac`, one Qwen3.8
Flash Next Q4 GGUF at 65536 context, Mac Studio M1 Ultra 128 GB. The code stays
generic: binary and model paths are configuration, never hardcoded.

## Configuration

The Ollama service is configured with the following optimizations:
- External access enabled (0.0.0.0:11434)
- 8 parallel requests (adjustable)
- 30-minute model keep-alive
- Flash attention enabled
- Support for 4 simultaneously loaded models
- Model pruning disabled

### Customizing Configuration

To modify the Ollama service configuration:

1. Edit the configuration file:
```bash
vim config/com.ollama.service.plist
```

2. Apply the changes:
```bash
# Stop the current service
sudo launchctl unload /Library/LaunchDaemons/com.ollama.service.plist

# Render the placeholders and install the updated configuration
sed -e "s|<OLLAMA_USER>|$(whoami)|g" -e "s|<OLLAMA_BIND>|0.0.0.0|g" \
    config/com.ollama.service.plist | sudo tee /Library/LaunchDaemons/com.ollama.service.plist >/dev/null

# Set proper permissions
sudo chown root:wheel /Library/LaunchDaemons/com.ollama.service.plist
sudo chmod 644 /Library/LaunchDaemons/com.ollama.service.plist

# Load the updated service
sudo launchctl load -w /Library/LaunchDaemons/com.ollama.service.plist
```

3. Check the logs for any issues:
```bash
tail -f logs/ollama.err logs/ollama.log
```

## System Optimizations

The installation process:
- Disables unnecessary system services
- Configures power management for server use
- Optimizes for background operation
- Maintains Screen Sharing capability for remote management

## Logs

Log files are stored in the `logs` directory:
- `ollama.log` - Ollama service logs
- `ollama.err` - Ollama error logs
- `install.log` - Installation logs
- `optimization.log` - System optimization logs

## Performance Considerations

This configuration significantly reduces system resource usage:
- Memory usage reduction from 11GB to 3GB (tested on Mac Studio M1 Ultra)
- Disables GUI-related services
- Minimizes background processes
- Prevents sleep/hibernation
- Optimizes for headless operation

The dramatic reduction in memory usage (around 8GB) is achieved by:
1. Disabling Spotlight indexing
2. Turning off unnecessary system services
3. Minimizing GUI-related processes
4. Optimizing for headless operation

### GPU Memory Optimization (Optional)

By default, Metal runtime allocates only about 75% of system RAM for GPU operations. This configuration includes optional GPU memory optimization that:
- Runs at system startup (when enabled)
- Allocates a configurable percentage of your total RAM to GPU operations
- Logs the changes for monitoring

The GPU memory setting is critical for LLM performance on Apple Silicon, as it determines how much of your unified memory can be used for model operations.

This allows:
- More efficient model loading
- Better performance for large models
- Increased number of concurrent model instances
- Fuller utilization of Apple Silicon's unified memory architecture

To enable and configure GPU memory optimization, set the environment variable before installation:
```bash
export OLLAMA_GPU_PERCENT="80"  # Allocate 80% of RAM to GPU
./scripts/install.sh
```

Or to adjust after installation:
```bash
# Run with a custom percentage
OLLAMA_GPU_PERCENT=85 sudo ./scripts/set-gpu-memory.sh
```

If you don't set OLLAMA_GPU_PERCENT, GPU memory optimization will be skipped.

For best performance:
1. Use SSH for remote management
2. Keep display disconnected when possible
3. Avoid running GUI applications
4. Consider disabling Screen Sharing if not needed for emergency access
5. Adjust GPU memory percentage based on your available memory and workload

These optimizations leave more resources available for Ollama model operations, allowing for better performance when running large language models.

### Docker Autostart (Optional)

If you need to run Docker containers (e.g., for [Open WebUI](https://github.com/open-webui/open-webui)), you can configure Docker to start automatically using Colima. This feature is completely optional.

#### What is Colima?

[Colima](https://github.com/abiosoft/colima) is a container runtime for macOS that's designed to work well in headless environments. It provides Docker API compatibility without requiring Docker Desktop, making it ideal for server use.

#### Prerequisites:

1. Homebrew must be installed (the script will use it to install Colima and Docker CLI)
2. No special GUI requirements (works perfectly in headless environments)

To enable Docker autostart, run:

```bash
export DOCKER_AUTOSTART="true"
./scripts/install.sh
```

This will:
1. Install Colima and Docker CLI via Homebrew (if not already installed)
2. Create a LaunchDaemon that starts Colima automatically at boot time
3. Configure Colima with default settings

#### Troubleshooting Docker Autostart:

If Docker doesn't start automatically:

1. Check the logs:
```bash
cat ~/mac-studio-server/logs/docker.log
```

2. Try starting Colima manually:
```bash
colima start
```

3. Check Colima status:
```bash
colima status
```

If you don't need Docker containers, you can skip this feature entirely.

## Versioning

This project follows [Semantic Versioning](https://semver.org/):
- MAJOR version for incompatible changes
- MINOR version for new features
- PATCH version for bug fixes

The current version is *1.2.0*.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License