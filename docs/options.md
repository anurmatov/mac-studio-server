# Options

Settings the installer does not ask about. Each is a `backends.env` key or an environment
variable; re-run `./scripts/install.sh` after changing one.

## Ollama bind address

Ollama listens on `0.0.0.0:11434` with no password. To keep it on this Mac:

```bash
echo 'OLLAMA_BIND=127.0.0.1' >> backends.env && ./scripts/install.sh
```

`OLLAMA_BIND` takes one IPv4 address of this Mac. `OLLAMA_BIN` sets the Ollama binary when it
is not `/usr/local/bin/ollama` (the installer sets it for a Homebrew Ollama).

## Headless macOS tweaks

The installer asks once and saves `MSS_TUNE_MACOS=yes` or `no`. To apply them by hand:

```bash
./scripts/optimize-mac-server.sh
```

They turn off Spotlight indexing, Time Machine, sleep and hibernation, Power Nap, automatic
update checks and downloads, Handoff, and AFP/SMB file sharing, and keep Screen Sharing on.
The log is `logs/optimization.log`.

## GPU memory

Metal uses about 75% of RAM by default. `OLLAMA_GPU_PERCENT` installs a boot job that raises
the limit, and llama.cpp or ds4 wait for it at start:

```bash
echo 'OLLAMA_GPU_PERCENT=80' >> backends.env && ./scripts/install.sh
OLLAMA_GPU_PERCENT=85 sudo ./scripts/set-gpu-memory.sh    # change it now, until reboot
```

## Docker via Colima

```bash
DOCKER_AUTOSTART=true ./scripts/install.sh    # installs Colima and the Docker CLI with Homebrew
colima status                                 # log: logs/docker.log
```

## Changing Ollama settings

Edit `config/com.ollama.service.plist` (parallel requests, keep-alive, loaded models), then run
`./scripts/install.sh`; it renders and reloads the service.

## Logs

```bash
tail -f ~/mac-studio-server/logs/ollama.err       # also ollama.log, install.log
sudo tail -f /var/log/mac-studio-server/ds4.log   # or llamacpp.log, guard.jsonl
```

## Remote access

Turn on Remote Login (SSH) in System Settings → General → Sharing, then `ssh <user>@<mac>`.
The headless tweaks keep Screen Sharing on for maintenance.
