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

## Variables

See `config/backends.env.example` for the full annotated list: `MSS_BACKENDS`,
`OLLAMA_BIND`, `<BACKEND>_BIN/_MODEL/_MODEL_SHA256/_HOST/_PORT/_ALLOW_FROM`,
`LLAMACPP_API_KEY_FILE/_CTX/_PARALLEL`, `DS4_CTX/_BATCHED_SESSIONS/_WORKDIR`,
`<BACKEND>_EXTRA_ARGS`, and the guard/log knobs
(`MSS_GUARD_FREE_PCT`, `MSS_GUARD_SWAP_HEADROOM_MB`, `MSS_GUARD_STREAK`,
`MSS_LOG_MAX_MB`).

## Install

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

## Tested reference (ds4)

`ds4-server` at commit `0aaea5a238fb41a35106a551e73c8409dfb751ac`, one Qwen3.8
Flash Next Q4 GGUF at 65536 context, Mac Studio M1 Ultra 128 GB. The code stays
generic: binary and model paths are configuration, never hardcoded.
