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

Metal uses about 75% of RAM by default. `MSS_GPU_PERCENT` (1-100, or `system`) installs a
boot job that raises the limit for every backend together; llama.cpp or ds4 wait for it:

```bash
echo 'MSS_GPU_PERCENT=80' >> backends.env && ./scripts/install.sh
sudo ./scripts/set-gpu-memory.sh 85          # change it now, until reboot
```

`sudo` resets the environment, so pass the value as an argument. `system` removes the boot
job; the macOS default applies at the next boot (`sudo sysctl iogpu.wired_limit_mb=0` for
now). Unset leaves an installed job as it is.

## Docker via Colima

```bash
MSS_DOCKER_INSTALL=yes ./scripts/install.sh      # brew install colima docker (only missing ones)
MSS_DOCKER_AUTOSTART=yes ./scripts/install.sh    # start Colima at every boot
colima status                                    # log: logs/docker.log
```

The installer never starts, stops or resizes a Colima VM; autostart re-runs
`scripts/start-colima.sh`, which leaves an existing VM's size alone. `no` removes the boot
job and never stops a running Colima.

## Restart after a power failure

```bash
echo 'MSS_POWER_AUTORESTART=yes' >> backends.env && ./scripts/install.sh
```

Sets `pmset autorestart`. Unset leaves the power setting as it is.

## Upgrading from `OLLAMA_GPU_PERCENT` / `DOCKER_AUTOSTART`

Both old names still work: the installer prints a deprecation notice and migrates the value
to `MSS_GPU_PERCENT` in `backends.env` on the next save. A legacy `OLLAMA_GPU_PERCENT=80`
and a differing `MSS_GPU_PERCENT` together stop the run before anything changes. Until you
re-run the installer, the old `com.ollama.gpumemory` job keeps working after a `git pull`.

## Downgrading

A machine that migrated to `com.mac-studio-server.gpumemory` must run
`sudo launchctl bootout system/com.mac-studio-server.gpumemory` and
`sudo rm /Library/LaunchDaemons/com.mac-studio-server.gpumemory.plist` before going back to
v1.5.0, or both GPU jobs run at boot. `scripts/status.sh` flags two labels.

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
