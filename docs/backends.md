# Inference Backends

Reference for the optional inference backends added in 1.3.0, for 1.7.0's
MLX-Serve backend and standby backends, and for 1.7.1's MLX LAN access. The README has the short version;
`config/backends.env.example` lists every variable.

Ollama stays the zero-config default: with `MSS_BACKENDS` unset or `ollama`,
installation is identical to v1.2.0. You may additionally install any of the
optional backends; **one** of them runs, the others wait on standby:

| backend | server | default bind | auth | notes |
|---|---|---|---|---|
| `ollama` | `/usr/local/bin/ollama serve` | `0.0.0.0:11434` (`OLLAMA_BIND`) | none (unchanged) | zero-config default |
| `llamacpp` | `llama-server` (any GGUF) | `127.0.0.1:8080` | optional `--api-key-file` | LAN bind needs an allowlist or a key |
| `ds4` | `ds4-server` (DwarfStar) | `127.0.0.1:8000` | **none** | LAN bind always needs `DS4_ALLOW_FROM` |
| `mlx` | `mlx-serve` 26.10.1 (MLX-Serve) | `127.0.0.1:11234` | **none** | LAN bind always needs `MLX_ALLOW_FROM`; one native MLX model directory |

`MSS_BACKENDS` is any comma list of distinct names from `ollama`, `llamacpp`,
`ds4` and `mlx`, in any order. An empty element, an unknown name or a
duplicate is rejected, naming it, before any system change. With two or more
optional backends, `MSS_ACTIVE_BACKEND` names the one that runs (or `none`);
with one it defaults to that one. Ollama is not optional: it runs whenever it is
selected, so `MSS_ACTIVE_BACKEND=ollama` is refused. Running two optional
backends at once is not supported: two large models in unified memory can
freeze the Mac.

## Security defaults

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
  marker (this boot's `kern.bootsessionuuid`, which does not move when the
  clock is set); the wrapper refuses to bind LAN without it. ds4 and
  mlx always need an allowlist on a LAN address. llama.cpp may use an API key
  file instead; then there is no pf policy and the key is the sole protection.
- **Extra args are allowlisted.** `LLAMACPP_EXTRA_ARGS` / `DS4_EXTRA_ARGS`
  accept only reviewed performance flags; anything that serves files, loads
  extra artifacts or persists state is rejected. ds4 also accepts `--mtp`,
  `--mtp-draft 1..3`, `--mtp-exact-sampling`, `--prefill-chunk 512..65536` and
  `--warm-weights`; `--mtp-model` and `--dspark*` stay rejected.
- **Inputs are validated, not escaped.** Paths must be absolute with no spaces
  or special characters, numbers must be integers, and a value containing a
  newline is refused. The service user defaults to the user who ran `sudo` and
  is never `root`.
- **A memory guard protects the host and Ollama.** It samples free memory,
  swap and the active backend's RSS, and after repeated violations writes its
  trip marker, then boots the backend out and keeps it down until
  `mss-enable.sh`. It never stops or reconfigures Ollama.
- **One model server at a time.** Every backend wrapper refuses (exit 78)
  unless the conf names it as the active backend, and refuses while any other
  process named `mlx-serve`, `ds4-server`, `llama-server` or like a configured
  `*_BIN` runs, managed or not: the guard watches one process. The installer
  refuses to start a backend beside such a process first.
- **mlx defaults to loopback; a LAN address needs an allowlist, and permitted
  clients reach every engine endpoint, including model load and pull.**
  `mlx-serve` listens on `0.0.0.0` by default, so the wrapper always passes
  `--host` (`127.0.0.1`, or `MLX_HOST`). `MLX_HOST` is loopback or one local
  IPv4 address, never `0.0.0.0`. A LAN bind also refuses while
  `~/.mlx-serve/providers.json` exists for the service user (`/tmp/.mlx-serve/`
  without `HOME`), so allowed clients cannot spend its provider credentials.
  `MLX_API_KEY_FILE` refuses the install: access control is the allowlist.

## Variables

See `config/backends.env.example` for the full annotated list: `MSS_BACKENDS`,
`MSS_ACTIVE_BACKEND`, `OLLAMA_BIND`, `<BACKEND>_BIN/_MODEL/_MODEL_SHA256/_HOST/_PORT/_ALLOW_FROM`,
`MLX_BIN/_MODEL_DIR/_HOST/_PORT/_ALLOW_FROM/_CTX/_EXTRA_ARGS`,
`LLAMACPP_API_KEY_FILE/_CTX/_PARALLEL`, `DS4_CTX/_BATCHED_SESSIONS/_WORKDIR`,
`<BACKEND>_EXTRA_ARGS`, the host choices (`MSS_GPU_PERCENT`, `MSS_DOCKER_INSTALL`,
`MSS_DOCKER_AUTOSTART`, `MSS_POWER_AUTORESTART`), and the guard/log knobs
(`MSS_GUARD_FREE_PCT`, `MSS_GUARD_SWAP_HEADROOM_MB`, `MSS_GUARD_STREAK`,
`MSS_LOG_MAX_MB`).

`DS4_BATCHED_SESSIONS` defaults to 4 on a Mac with 96 GB of RAM or more and to 2 otherwise; set it to override (1 serves one session at a time), and an existing ds4 install picks up the default on its next re-install.

## Install

```bash
# existing Ollama users: nothing to do; re-running install.sh is unchanged.
export MSS_BACKENDS=ollama,ds4
export DS4_BIN=/path/to/ds4-server
export DS4_MODEL=/path/to/model.gguf
export DS4_MODEL_SHA256=<sha256>
./scripts/install.sh
```

`install.sh` first runs `scripts/install-backends.sh --check-only` under
`sudo`, which validates every variable and hashes the model before anything
else changes. On a match it keeps the root-owned hash as
`<backend>.model.verified.next`, so the install that follows does not hash
again, and a re-install with an unchanged model skips the hash entirely. A full
read of a model never runs beside a running model server (other than that
backend's own re-hash): stop it first or stamp offline (runbook R1b). `MSS_GPU_PERCENT` installs `com.mac-studio-server.gpumemory`
whatever the selection, and an optional backend waits for that wired limit at start.

## Interactive install and backends.env (1.4.0)

`scripts/install.sh` picks its mode from the first matching row:

| condition | behaviour |
|---|---|
| `--configure` / `--configure-only` without a terminal | exit 2 |
| `--configure` / `--configure-only` as root | exit 1: run it as your user, it calls `sudo` itself |
| `--configure` | picker, save, check, install |
| `--configure-only` | picker, save, check under `sudo`; nothing is installed, may leave a verification stamp |
| no flag, and no terminal or `MSS_BACKENDS` set | 1.3.0 behaviour: environment only, `backends.env` is not read |
| no flag, terminal, as root | exit 1 |
| no flag, terminal, `backends.env` exists | use it without asking |
| no flag, terminal, no `backends.env` | picker (first run) |

`backends.env` lives next to `config/backends.env.example` (override with
`MSS_ENV_FILE`) and uses the same `KEY=value` format. It is parsed, never
sourced: unknown or duplicate keys, `export`, and values containing `$`,
backticks, quotes, backslashes or carriage returns are refused, naming the
line. It must be a regular file owned by you and not group- or world-writable.
A variable set in the environment wins over the file. The picker writes it
atomically with mode 0600, keeps keys it did not ask about (such as `DS4_CTX`
or `*_EXTRA_ARGS`), and drops comments. API keys are never stored; only the
path of a key file is.

Picker defaults come from the environment first, then the installed selection
(for the menu), then `backends.env`, then built-ins. Hashing the model reads
the whole file, and the check and root install hash it again unless the model
is unchanged since its last verification, so a first install of a large model
takes a few extra minutes.

**Leaving a backend out (1.7.0).** The menu takes several numbers
(`1) ollama 2) llama.cpp 3) ds4 4) mlx`, for example `1,3`). For an installed
optional backend left out, it asks right away whether to remove it with
`sudo scripts/uninstall.sh --backend <b>` (its model files and saved answers
are kept). `y` removes it once the root check has passed; `N` keeps it
selected (`kept installed: <b>`). With two or more optional backends it then
asks which one runs now (or none). `--configure-only` never removes anything:
it checks the new selection against the installed one and says that
`install.sh --configure` will offer the removal. A plain `install.sh` with a
saved file never removes a backend, and an installed backend missing from
`MSS_BACKENDS` refuses the install instead.

## One-line install, model.sh and acquisition variables (1.5.0)

```bash
curl -fsSL https://raw.githubusercontent.com/anurmatov/mac-studio-server/v1.7.1/bootstrap.sh | sh
./scripts/model.sh                                        # menu: starter, more, own file/URL
./scripts/model.sh --catalog qwen3-4b                     # or --path FILE --sha256 HEX
./scripts/model.sh --url https://… --sha256 HEX [--dest FILE]
```

The one-liner trusts GitHub and this repo's protected release tags; it checks the clone matches what it downloaded.

`bootstrap.sh` clones `~/mac-studio-server` (`MSS_DIR`) at the release tag, or at a full
40-hex commit with `sh -s -- --ref <sha>`, then runs `install.sh` on the terminal.
`model.sh` needs a terminal and a `backends.env` with llama.cpp or ds4 (`--backend llamacpp|ds4`
when both are selected; mlx models are directories, set with `install.sh --configure`); it never touches Ollama.
Models come from `config/models.catalog` (pinned revisions and sha256), download to
`~/models/<file>.part` and resume on a re-run.

| variable | where | effect |
|---|---|---|
| `MSS_DEFER_MODEL=yes` | `backends.env` | install llama.cpp or ds4 without a model; no backend job until `model.sh` |
| `OLLAMA_BIN` | `backends.env` | Ollama binary in the plist (unset: `/usr/local/bin/ollama`, `PATH`, then `/opt/homebrew/bin/ollama`); saved and checked only when Ollama is selected |
| `MSS_TUNE_MACOS=yes/no` | `backends.env` | headless tweaks; unset runs them with Ollama, as in 1.4.0 |
| `DS4_BUILD_DIR` | environment only | build ds4-server at the pinned commit there (not with `DS4_BIN`) |
| `LLAMACPP_BREW_INSTALL=yes` | environment only | `brew install llama.cpp` when `LLAMACPP_BIN` is unset |
| `LLAMACPP_MODEL_URL`, `DS4_MODEL_URL` | environment only | `catalog:<id>`, or an `https://` URL with `*_MODEL_SHA256` |
| `MSS_PROGRESS_SECONDS` | environment | hashing progress interval, 1–60 (default 10) |

Environment-only variables are never saved: a saved re-run never downloads or builds.

## Status / enable / uninstall

```bash
./scripts/status.sh                 # health + pf checks (pf checks need sudo)
sudo /usr/local/libexec/mac-studio-server/mss-enable.sh   # after a guard trip
sudo ./scripts/uninstall.sh --backend ds4                 # or llamacpp, mlx, ollama
sudo ./scripts/uninstall.sh --all [--purge-logs]          # idempotent
```

`uninstall.sh --backend <b>` stops it (waiting for launchd to release it),
removes its plist from both locations, its stamps and its plist record line,
and drops its name and keys from the conf. Removing the active backend also
removes the guard; nothing becomes active by itself. pf rules of a removed
LAN-bound backend stay until the next install. Model files and `backends.env`
are never touched.

## Active and standby backends (1.7.0)

| state | plist | conf | stamp | guard |
|---|---|---|---|---|
| active | `/Library/LaunchDaemons/com.mac-studio-server.<b>.plist`, loaded | its keys, `MSS_GUARD_BACKEND=<b>` | kept | installed |
| standby | `/usr/local/etc/mac-studio-server/standby/com.mac-studio-server.<b>.plist`, never loaded | its keys | kept | n/a |
| `none` active | no backend plist in `/Library/LaunchDaemons` | no `MSS_GUARD_BACKEND` | kept | removed |

launchd loads at boot only from `/Library/LaunchDaemons`, so a standby backend
cannot start after a reboot. A standby plist is byte-identical to its active
form; activation moves it, and its stamp is reused (no re-hash).

```bash
./scripts/backend.sh activate <llamacpp|ds4|mlx|none>   # switch; saves backends.env
./scripts/backend.sh stop <b>                           # until start or the next reboot
./scripts/backend.sh start <b>                          # exits 0 once it has a process
```

`backend.sh` runs as your user and asks for the password once. `activate`
needs `backends.env` and a selected backend; it runs the root check, then the
install, with `MSS_ACTIVE_BACKEND` set, and the install saves `MSS_BACKENDS`
and `MSS_ACTIVE_BACKEND` into `backends.env` under its lock. `start` and `stop`
act only on the active backend, through the root
`/usr/local/libexec/mac-studio-server/mss-lifecycle.sh`. `start` refuses after
a guard trip (run `mss-enable.sh`), when the job is already loaded, or beside
another model server.

**What restarts.** The installer works out, per job, whether its inputs
changed: its plist, the conf keys it reads, its model stamp, or whether it is
loaded at all. Only changed or unwanted jobs stop, in the order guard,
backends, boot; only changed or missing ones start, in the order boot (with
its pf check), the active backend, guard. Adding a standby backend or an
identical re-install restarts nothing, and Ollama reloads only when its plist
changes (`sudo launchctl kickstart -k system/com.ollama.service` restarts it by
hand). The run ends with `active: <b|none>; standby: <list|none>`,
`unchanged: <labels>` and `restarted: <labels>`, plus a warning when the guard
has tripped.

**When something fails.** Nothing is installed until every job to stop has
stopped: a job that does not stop within `MSS_LAUNCHD_TIMEOUT` leaves every
file as it was and brings back the jobs the run stopped. A job that fails to
start keeps the new configuration and names the rollback
(`backend.sh activate <previous>`). The new files are committed through a
journal (`/usr/local/etc/mac-studio-server/commit.journal`) with verified
copies under `.stage/`; a run killed part-way is finished or rolled back by the
next root pass, or refused when a file was edited meanwhile. Until then
`status.sh` reports `interrupted install`, and `backend.sh start`,
`mss-enable.sh` and `uninstall.sh --backend` refuse; `uninstall.sh --all`
always proceeds. A lifecycle plist edited by hand is refused and left as it is
(the installer keeps a record of their sha256 in
`/var/db/mac-studio-server/plists.sha256`).

**One command at a time.** Every root pass of the installer, `uninstall.sh`,
`mss-enable.sh` and `mss-lifecycle.sh` holds one lock
(`/var/run/com.mac-studio-server.lock`). Another command waits up to
`MSS_LOCK_TIMEOUT` seconds (default 30), then names the holder. A killed
command frees it within about a second; a change it had already started
finishes first, or is stopped, before the next command runs. The guard and the
boot job never wait for it. The lock needs `/usr/bin/perl` (macOS ships it).

**Status.** `status.sh` prints one block per selected optional backend: the
active one's health (for mlx also `ready` or `loading`), `standby (not running;
scripts/backend.sh activate <b>)` for a standby one, or what is wrong
(`standby plist missing`, `standby stamp missing`, `standby but loaded` with
the bootout command), `no optional backend active`, `interrupted install`, and
any model server outside the guard's view (`unmanaged <name> pid N (not
guarded)`).

## MLX-Serve (1.7.0)

`mlx-serve` comes from the Homebrew tap
`brew tap ddalcu/mlx-serve https://github.com/ddalcu/mlx-serve`, then
`brew install ddalcu/mlx-serve/mlx-serve` (arm64). It needs macOS 26.2 or later:
upstream builds the binary for 26.2, though the formula declares macOS 14. Exactly
version 26.10.1 is supported: the installer and the wrapper run `mlx-serve --version`
(10 s at most) and require its first line to be `mlx-serve 26.10.1`. The tap
tracks upstream `main`, so `brew pin mlx-serve`; after a `brew upgrade` the
wrapper refuses until a release of this project supports the new version.

The release is tag `v26.10.1` (commit `02bee553`). Its asset
`mlx-serve-bin-macos-arm64.tar.gz` has sha256
`e53056e481364ff72188fafea8b3eb0aeb0b5b7cebcd6e6e7d26bf1ce4223873`, the same
value the tap's formula declares for 26.10.1. The installer does not check
this hash: Homebrew checks it on download, and only the version line is
checked here. That line is a version check, not proof of where the binary
came from. To confirm a Homebrew install, compare its formula's `sha256` with
this value.

| variable | default | rule |
|---|---|---|
| `MLX_BIN` | required | an executable, resolved once; the version probe |
| `MLX_MODEL_DIR` | required | a native MLX checkpoint directory (below) |
| `MLX_HOST` | `127.0.0.1` | loopback, or an IPv4 address on a local interface; never `0.0.0.0` |
| `MLX_PORT` | `11234` | distinct from every other selected port and from Ollama's 11434 |
| `MLX_ALLOW_FROM` | empty | IPv4 addresses or CIDRs (no `/0`); required when `MLX_HOST` is not loopback; only in pf |
| `MLX_CTX` | unset | 1..1048576; unset uses the model's own context |
| `MLX_EXTRA_ARGS` | empty | `--max-concurrent 1..16`, `--prefill-chunk 512..65536`, `--kv-quant off\|4\|8`, `--prefix-cache-mem <n>MB\|<n>GB`, `--timeout <s>`, `--metrics`, `--mtp`, `--no-mtp`, `--no-vision`; everything else is rejected |

The model directory needs a top-level `config.json` and at least one top-level
`*.safetensors`, and no `.gguf` anywhere (GGUF models belong to llama.cpp or
ds4). Only names, sizes, inodes and mtimes are read, never file contents: the
manifest `/var/db/mac-studio-server/mlx.model.verified` lists every file, and
the wrapper refuses when the directory no longer matches it. The server runs
as the service user, as
`mlx-serve --serve --model <dir> --host <MLX_HOST> --port <port> --max-resident-models 1 --log-file off [--ctx-size <n>] [extra args]`,
with its output in `/var/log/mac-studio-server/mlx.log`. `MSS_DEFER_MODEL` does
not apply to mlx. `mlx.distributed` is out of scope.

Checked against upstream v26.10.1 (commit `02bee553`) source: the defaults
(`0.0.0.0:11234`), `--version`, one model with `--model <dir> --serve`, the
flags above and their limits, SIGTERM shutdown, `/health` answering before a
model is loaded (so readiness is `"state":"ready"` in `/v1/models`), and the
load, unload and pull endpoints that cannot be disabled. In 26.10.1 `--mtp`
is the default and accepted for compatibility; `--no-mtp` turns it off.
Upstream also turns speculative drafting on by default and loads a model's
bundled drafter automatically. Neither is tested here. Neither are upstream's
speed claims. Not tested on a real
Mac by this project's CI (it uses a stub): the installed `--version` line,
listening only on `MLX_HOST`, `"state":"ready"` after a load, SIGTERM releasing the
label in time, streamed Responses, a forced function call and the cancellation
counter (the release canary checks these five); `--max-resident-models 1` after
a local `/v1/load-model`; where `/api/pull` writes under launchd's `UserName`;
other model families, modalities, contexts, concurrency or cache budgets than
the canary records (configured maximums are not tested capacity); Metal on
hosted runners.

## Runbook (1.7.0)

Placeholders: `<checkout>`, `<user>`, `<mlx-serve>`, `<model-dir>`, `<prior vars>`.

- **R0 Look first (read-only).** `git -C <checkout> rev-parse HEAD`,
  `<mlx-serve> --version | head -1`, `cat /usr/local/etc/mac-studio-server/backends.conf`,
  `memory_pressure -Q`, `sysctl vm.swapusage`, `./scripts/status.sh`.
- **R1 Add a standby backend (nothing restarts).** `./scripts/install.sh --configure`,
  keeping the current backend active, or
  `sudo env <prior vars> MSS_BACKENDS=<current>,mlx MSS_ACTIVE_BACKEND=<current> MLX_BIN=<mlx-serve> MLX_MODEL_DIR=<model-dir> sh scripts/install-backends.sh`,
  first with `--check-only`. The output lists the running backend and the guard under `unchanged:`.
- **R1b Stamp a GGUF offline.** With no model server running
  (`./scripts/backend.sh stop <b>`), the same command with `--check-only` hashes
  once and keeps a `.next` stamp; later installs print `stamp unchanged`.
- **R2 Switch.** `./scripts/backend.sh activate mlx` (env mode: R1 with
  `MSS_ACTIVE_BACKEND=mlx`), then `./scripts/status.sh`.
- **R3 Roll back, or recover a failed start.** `./scripts/backend.sh activate <previous>`;
  it prints `stamp unchanged`, and `status.sh` exits 0.
- **R4 After a guard trip.** Read `/var/db/mac-studio-server/guard.tripped`,
  optionally R3, then `sudo /usr/local/libexec/mac-studio-server/mss-enable.sh`.
- **R5 Remove mlx, or go back to an older release.** `sudo sh scripts/uninstall.sh --backend mlx`.
  Before checking out an older release, keep at most one optional backend and
  delete `MSS_ACTIVE_BACKEND` and the `MLX_*` lines from `backends.env`: an
  older checkout refuses the new keys.
- **R6 mlx on the LAN (1.7.1).** Enable: `./scripts/install.sh --configure`,
  mlx, LAN yes, an address and the allowed clients; mlx restarts once. Verify:
  `./scripts/status.sh` shows `host=<address>`, `allowed` and `ready`, then
  `curl http://<address>:11234/v1/models` from an allowed client. Disable:
  `--configure` again, LAN no; mlx restarts on loopback and pf drops the port.
- **R7 After a `REFUSE:` line in `/var/log/mac-studio-server/mlx.log`.**
  `pf (no boot marker …)`: `sudo /usr/local/libexec/mac-studio-server/mss-boot.sh`
  names the pf problem; fix it and re-run the install. `providers file
  present`: remove that file or go back to loopback (R6). `address <ip> is not
  on any interface`: the network did not configure `MLX_HOST` within 120 s
  (a `WAIT:` line comes first); fix the network or the address. launchd retries.
- **R8 Back to 1.7.0.** `--configure` with LAN no; delete the `MLX_HOST` and
  `MLX_ALLOW_FROM` lines from `backends.env` (1.7.0 refuses them); run the
  1.7.0 installer; `sudo pfctl -a com.apple/250.mac-studio-server -sr` shows no
  rule for the mlx port.
- **R9 Bumping `mlx-serve`.** In the same PR as the version pin, re-audit the
  upstream route table and the providers and `--lan-share` behaviour, and
  update R-1 below.

## Residual risks (1.7.0)

- **R-1** mlx-serve's `/v1/load-model`, `/v1/unload-model`, `/api/pull`,
  `/v1/models/rescan`, `/v1/providers*`, stored Responses and its web console
  are open on loopback, and with `MLX_HOST` to every allowed client (accepted
  in 1.7.1; pf is the boundary). A pull can fill the disk; a client-loaded
  model is outside the installer's checks (one resident model, the guard, and
  a restart returns to the verified one); stored Responses are shared across
  allowed clients by guessable ids. Binding an address advertises nothing:
  Bonjour is `--lan-share` only, which stays refused.
- **R-2** KeepAlive retries a crashing or refusing server every 30 s (existing).
- **R-3** The mlx manifest misses an in-place write that keeps a file's size,
  inode and mtime.
- **R-4** Model-server detection is by process name (`pgrep -x`, 15
  characters); a version probe can briefly look like a server.
- **R-5** Ollama and the active backend share memory, as `ollama,ds4` always did.
- **R-6/R-7** The tap tracks upstream `main`: the version probe is the pin, and
  a `brew upgrade` stops mlx until a pin bump (`brew pin mlx-serve`).
- **R-8** A 1.6.0 checkout refuses the new saved keys (R5).
- **R-9** The running backend's own re-hash keeps 1.6.0's behaviour (it reads
  its model beside itself); run `backend.sh stop` or R1b first.
- **R-10** Without a plist record, the first upgrade accepts a ds4
  `WorkingDirectory` only as this run's `DS4_WORKDIR` or the installed
  `DS4_BIN`'s directory.
- **R-11** A lock keeper killed by root leaves a one-step window before its
  command's next check.
- **R-12** A save to `backends.env` orphaned by a `SIGKILL` of `sudo` can rename
  between its conf check and its move; a stale write needs the conf to change
  in that moment.

## Migration

- **Existing Ollama users:** nothing to do. The default render of
  `com.ollama.service.plist` is byte-identical to v1.2.0.
- **Make Ollama loopback-only:** `export OLLAMA_BIND=127.0.0.1` and re-run
  `scripts/install.sh`.
- **Add a backend later:** set `MSS_BACKENDS=ollama,<backend>` plus that
  backend's variables and re-run the installer, or add it on standby (R1).
  Nothing is removed silently: leaving an installed backend out refuses until
  `scripts/uninstall.sh --backend <b>` (or a picker `y`).
- **From 1.6.0 to 1.7.0:** a 1.6.0 `backends.env` loads unchanged and re-saves
  without a new line; a 1.6.0 `backends.conf` reads as the installed set plus
  the active backend, and an unchanged selection renders byte-identically and
  restarts nothing. Plists stay where they are; the first install writes the
  plist record, and `standby/` appears only with a standby backend. Stamps are
  kept (deleted only by `uninstall.sh`); `.next` stamps are new. The menu
  numbers changed (multi-select), and an unchanged re-install no longer
  restarts the optional backend.
- **From 1.7.0 to 1.7.1:** a 1.7.0 `backends.env` has no `MLX_HOST`, so mlx
  stays on loopback; a plain re-install asks nothing new, renders the same
  files and restarts nothing. Going back: runbook R8.
- **`OLLAMA_GPU_PERCENT` and `DOCKER_AUTOSTART` (1.5.0 names):** deprecated but
  still read; the installer migrates them and prints a notice. See
  `docs/options.md`.

## Tested reference (ds4)

`ds4-server` at commit `0aaea5a238fb41a35106a551e73c8409dfb751ac`, one Qwen3.8
Flash Next Q4 GGUF at 65536 context, Mac Studio M1 Ultra 128 GB. The code stays
generic: binary and model paths are configuration, never hardcoded.
