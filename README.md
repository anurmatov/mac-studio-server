# Mac Studio Server

Turns an Apple silicon Mac into a headless model server: Ollama as a service that starts at boot,
plus optional llama.cpp, DwarfStar (ds4) or MLX-Serve servers (one running, the others on standby),
a memory guard, and firewalled LAN access.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/anurmatov/mac-studio-server/v1.7.0/bootstrap.sh | sh
```

Or clone it yourself: `git clone https://github.com/anurmatov/mac-studio-server.git && cd mac-studio-server && ./scripts/install.sh`.

## What the installer asks

Every question has a default; press Enter to take it. Installs and downloads happen only after a `y`.

1. Xcode Command Line Tools, if missing (needed for git).
2. Your password, once for the whole run.
3. Which backends (several numbers, e.g. `1,3`), whether to remove one you left out, and which runs now.
4. Missing Homebrew, Ollama, `llama-server`, `ds4-server` or `mlx-serve`: install or build it? (default no)
5. A model: the starter (the default, downloaded right away), another one, your own file or URL, or later.
6. LAN access for llama.cpp or ds4 (default no; yes asks for an address and allowed clients).
7. Headless macOS tweaks: no sleep, Spotlight, Time Machine or auto-updates (default no).
8. GPU memory percent for every backend (1-100 or system), restart after a power failure
   (default off), installing Colima and the Docker CLI, and starting Colima at boot.
9. A summary to confirm, then an Ollama starter model once the service is up.

## After install

```bash
./scripts/status.sh                   # health of every backend; exit 0 when all are healthy
./scripts/model.sh                    # add or switch the llama.cpp / ds4 model later
./scripts/install.sh --configure      # choose again (re-running without a flag reuses the answers)
./scripts/backend.sh activate mlx     # switch to a standby backend; also stop|start <backend>
sudo ./scripts/uninstall.sh --all     # remove every service; models and logs are kept
```

Logs: `~/mac-studio-server/logs/` (Ollama, install) and `/var/log/mac-studio-server/` (llama.cpp, ds4, mlx, guard).

## Options

Ollama listens on all interfaces (0.0.0.0) by default and has no password; set OLLAMA_BIND=127.0.0.1 to keep it on this Mac.

- **LAN access for llama.cpp or ds4:** answer yes in the installer. A macOS firewall (pf) allowlist
  guards the port; llama.cpp can use an API key file instead. See [docs/backends.md](docs/backends.md).
- **MLX-Serve:** exactly `mlx-serve` 26.9.6 with a native MLX model directory, on this Mac only (no LAN).
  See [docs/backends.md](docs/backends.md).
- **GPU memory:** set `MSS_GPU_PERCENT=80` in `backends.env` to let Metal use 80% of RAM
  for every backend. See [docs/options.md](docs/options.md).
- **Docker via Colima:** `MSS_DOCKER_AUTOSTART=yes ./scripts/install.sh` starts Colima at
  boot; `MSS_DOCKER_INSTALL=yes` installs what is missing. Power loss? `MSS_POWER_AUTORESTART=yes`.
  See [docs/options.md](docs/options.md).
- **Saved answers:** `backends.env` in the repository holds them, one `KEY=value` per line;
  [config/backends.env.example](config/backends.env.example) lists every key.
- **Scripted installs:** set `MSS_BACKENDS` and the backend variables; nothing is asked.
  See [docs/backends.md](docs/backends.md).

## Requirements

- A Mac with Apple silicon on macOS Sonoma or later, and an administrator account.
- Remote Login (SSH) on for headless use: System Settings → General → Sharing.
- Disk space for models: 2.5 GB for the starter; ds4 needs macOS 15 and 137 GiB or more.

## Updates

- **1.7.0** MLX-Serve, several backends at once (one running, the rest on standby), `backend.sh`.
- **1.6.0** GPU memory, Docker and restart-after-power-failure choices in the installer.
- **1.5.0** One-line install, guided downloads and builds, and `model.sh`.
- **1.3.0, 1.4.0** Optional llama.cpp and DwarfStar backends; the interactive picker and saved answers.

Current version: 1.7.0 (semver). History: [CHANGELOG.md](CHANGELOG.md).

## Contributing

Issues and pull requests are welcome.

## License

MIT, see [LICENSE](LICENSE).
