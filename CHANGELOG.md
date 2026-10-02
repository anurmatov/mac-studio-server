# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [1.7.1] - 2026-10-02

### Added
- MLX LAN access with the same address and allowed-clients questions as ds4

### Fixed
- A LAN-bound backend no longer refuses to start for the rest of a boot once the clock is set
- A LAN-bound mlx waits for its address at boot instead of failing to bind

## [1.7.0] - 2026-10-01

### Added
- MLX-Serve 26.10.1 as an optional backend: one native MLX model, on this Mac only (macOS 26.2 or later)
- Several optional backends at once: one runs, the others wait on standby and switch without a re-hash
- A command to switch, stop and start the optional backend, and a status row for every backend
- An interrupted or failed install is finished, rolled back or reported, never left half-switched

### Changed
- The backend menu takes several numbers, so its answers are not the old ones
- A re-install restarts only what changed; Ollama reloads only when its service changed
- Backends refuse to start beside another model server, managed or not

## [1.6.0] - 2026-09-29

### Added
- GPU memory percent, Docker install, Docker at boot and restart after a power failure are now asked, saved and reported by the installer
- A GPU boot job that no longer runs a user-editable script as root at every boot
- The status report covers the GPU limit, the power setting and the Docker boot job

### Changed
- The GPU limit is set by the system tool directly, so it survives removing an optional backend
- Autostarted Colima starts an existing VM without resizing it, even when the VM list comes back empty, and reloads only when its job changed
- Changing the GPU limit by hand takes the value as an argument and never defaults silently
- A non-interactive install finds a Homebrew Ollama on Apple silicon instead of assuming the Intel path

### Deprecated
- The GPU percent key is now backend-neutral (it was named after one backend); the old name is still read and migrated on the next save
- Docker autostart splits into "install what is missing" and "start at boot"; the old switch still works

### Fixed
- Model hashing works in SSH sessions that set an unsupported locale such as C.UTF-8
- Re-installing while a backend is running no longer fails with 'Bootstrap failed: 5'

## [1.5.0] - 2026-09-26

### Added
- One-line curl install that verifies the download and offers to install or build what is missing
- A model menu with a starter model and resumable downloads, and a command to switch models later
- DS4_EXTRA_ARGS accepts ds4's MTP speculative decoding, prefill chunk and weight warm-up flags

### Changed
- Headless macOS tweaks are now asked once instead of always applied; the answer is saved
- ds4 now serves 4 sessions at 96 GB of RAM or more, else 2, unless DS4_BATCHED_SESSIONS is set

## [1.4.0] - 2026-09-26

### Added
- Interactive backend picker when install.sh runs on a terminal
- Saved answers in backends.env, reused on the next run
- Guided switching between llama.cpp and DwarfStar with install.sh --configure

### Changed
- README now states the current version

## [1.3.0] - 2026-09-26

### Added
- Optional inference backends beside Ollama: llama.cpp llama-server and DwarfStar ds4-server, selected via MSS_BACKENDS
- Firewalled LAN access for optional backends with address allowlists
- Memory guard that stops the optional backend, never Ollama, when memory runs low
- Status and uninstall scripts
- OLLAMA_BIND to choose the Ollama bind address

### Changed
- Installation checks every setting and the model checksum before changing the system

## [1.2.0] - 2025-03-04

### Added
- Docker autostart support
  - Headless support
  - Automatic Colima installation and configuration
  - Configurable via DOCKER_AUTOSTART environment variable
  - Enables headless container operation

## [1.1.0] - 2025-03-01

### Added
- GPU Memory Optimization feature
  - Configurable GPU memory allocation via OLLAMA_GPU_PERCENT environment variable
  - Automatic allocation at system startup
  - Documentation on Metal memory allocation behavior

### Changed
- Made user configuration more flexible with environment variables
- Improved documentation with performance considerations
- Enhanced installation script with better error handling

## [1.0.0] - 2025-02-28

### Added
- Initial release
- System optimization for Mac Studio
- Ollama service configuration
- Automatic startup
- Memory usage reduction (11GB → 3GB)
- External network access
- Logging setup 