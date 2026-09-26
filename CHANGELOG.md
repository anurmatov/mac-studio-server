# Changelog

All notable changes to this project will be documented in this file.

## [1.3.0] - 2026-09-26

### Added
- Optional inference backends beside Ollama (one at a time): llama.cpp
  `llama-server` and DwarfStar `ds4-server`, selected via `MSS_BACKENDS`
- Fail-closed artifact validation: install-time symlink resolution and sha256
  verification; per-start size/inode/mtime stamp check
- pf allowlist policy for LAN-bound optional backends, with a root boot daemon
  that verifies pf is enabled, referenced and fully loaded before any LAN bind
- Per-backend allowlisted `*_EXTRA_ARGS`; unlisted flags abort the install
- Shared memory guard for the optional backend (never Ollama): free/swap/RSS
  sampling to `guard.jsonl`, trip after consecutive violations, root-only
  recovery via `mss-enable.sh`, copy-truncate log rotation
- `scripts/install-backends.sh` (with `--check-only`, used by `install.sh`
  before any system change, and `--render-only` for tests),
  `scripts/status.sh`, `scripts/uninstall.sh`, `scripts/lib/mss-common.sh`
- macOS arm64 CI: shellcheck, render/golden tests, launchd system tests with
  stub servers, and a real `llama-server` job
- `OLLAMA_BIND` for the Ollama plist; default render stays identical to 1.2.0

### Changed
- `scripts/install.sh` validates `MSS_BACKENDS` and runs the full optional
  backend check (model hash included) before any system change, then delegates
  optional backends to the root installer; the Ollama steps are unchanged

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