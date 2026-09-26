# Changelog

All notable changes to this project will be documented in this file.

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