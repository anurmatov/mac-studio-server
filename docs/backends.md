# Inference Backends

Reference for the optional inference backends added in 1.3.0. The README has
the short version; `config/backends.env.example` lists every variable.

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
  marker; the wrapper refuses to bind LAN without this boot's marker. ds4 always
  needs an allowlist on a LAN address. llama.cpp may use an API key file
  instead; then there is no pf policy and the key is the sole protection.
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
  swap and the optional backend's RSS, and after repeated violations boots the
  optional backend out and keeps it down until `mss-enable.sh`. It never stops
  or reconfigures Ollama.

## Variables

See `config/backends.env.example` for the full annotated list: `MSS_BACKENDS`,
`OLLAMA_BIND`, `<BACKEND>_BIN/_MODEL/_MODEL_SHA256/_HOST/_PORT/_ALLOW_FROM`,
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
else changes. On a match it keeps a root-owned verification stamp, so the
install that follows does not hash again, and a re-install with an unchanged
model skips the hash entirely. `MSS_GPU_PERCENT` installs `com.mac-studio-server.gpumemory`
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

**Switching.** When `--configure` picks a different optional backend than the
installed one, it asks before removing the old one. On yes it saves the file,
checks the new selection as root first (so a busy port or bad checksum stops it
before anything is removed), then runs `sudo scripts/uninstall.sh --backend
<old>` and installs. On no it saves the file and installs nothing.
`--configure-only` never removes anything: it checks the new selection against
the installed one and says that `install.sh --configure` will offer the switch.
A plain `install.sh` with a saved file never switches.

## One-line install, model.sh and acquisition variables (1.5.0)

```bash
curl -fsSL https://raw.githubusercontent.com/anurmatov/mac-studio-server/v1.5.0/bootstrap.sh | sh
./scripts/model.sh                                        # menu: starter, more, own file/URL
./scripts/model.sh --catalog qwen3-4b                     # or --path FILE --sha256 HEX
./scripts/model.sh --url https://… --sha256 HEX [--dest FILE]
```

The one-liner trusts GitHub and this repo's protected release tags; it checks the clone matches what it downloaded.

`bootstrap.sh` clones `~/mac-studio-server` (`MSS_DIR`) at the release tag, or at a full
40-hex commit with `sh -s -- --ref <sha>`, then runs `install.sh` on the terminal.
`model.sh` needs a terminal and a `backends.env` with llama.cpp or ds4; it never touches Ollama.
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
sudo ./scripts/uninstall.sh --backend ds4
sudo ./scripts/uninstall.sh --all [--purge-logs]          # idempotent
```

## Migration

- **Existing Ollama users:** nothing to do. The default render of
  `com.ollama.service.plist` is byte-identical to v1.2.0.
- **Make Ollama loopback-only:** `export OLLAMA_BIND=127.0.0.1` and re-run
  `scripts/install.sh`.
- **Add a backend later:** set `MSS_BACKENDS=ollama,<backend>` plus that
  backend's variables and re-run the installer. Switching optional backends
  requires `scripts/uninstall.sh --backend <old>` first — nothing is removed
  silently.
- **`OLLAMA_GPU_PERCENT` and `DOCKER_AUTOSTART` (1.5.0 names):** deprecated but
  still read; the installer migrates them and prints a notice. See
  `docs/options.md`.

## Tested reference (ds4)

`ds4-server` at commit `0aaea5a238fb41a35106a551e73c8409dfb751ac`, one Qwen3.8
Flash Next Q4 GGUF at 65536 context, Mac Studio M1 Ultra 128 GB. The code stays
generic: binary and model paths are configuration, never hardcoded.
