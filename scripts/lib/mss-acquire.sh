#!/bin/bash
# mss-acquire.sh — acquisition for install.sh and model.sh (1.5.0, #15): Xcode
# Command Line Tools, Homebrew, Ollama, llama.cpp, a pinned ds4-server build, the
# model catalogue and resumable, size-checked model downloads.
#
# bash 3.2, sourced after mss-common.sh. Everything runs as the user: the only
# sudo calls are the CLT install (softwareupdate) and the Homebrew installer's
# own. Test overrides: MSS_CATALOG, MSS_DF, MSS_XCODE_SELECT, MSS_SW_VERS.

MSS_DS4_COMMIT=0aaea5a238fb41a35106a551e73c8409dfb751ac
MSS_DS4_REMOTE=https://github.com/antirez/ds4.git
MSS_BREW_INSTALLER=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
# The file a download in this run created, for the sha-mismatch rename (D6).
MSS_DOWNLOADED=""

mss_prefix() { case $1 in llamacpp) echo LLAMACPP ;; ds4) echo DS4 ;; esac; }

# ── catalogue (D4) ─────────────────────────────────────────────────────────────
mss_catalog_file() { printf '%s\n' "${MSS_CATALOG:-$REPO_DIR/config/models.catalog}"; }

# mss_catalog_ids <backend> <role>: ids with that role, in file order.
mss_catalog_ids() {
    awk -F'\t' -v b="$1" -v r="$2" '$0 !~ /^#/ && NF == 9 && $1 == b && $8 == r { print $2 }' "$(mss_catalog_file)"
}

# mss_catalog_get <backend> <id> <field>: repo, revision, file, size, sha256, role or license.
mss_catalog_get() {
    local col
    case $3 in
        repo) col=3 ;; revision) col=4 ;; file) col=5 ;; size) col=6 ;;
        sha256) col=7 ;; role) col=8 ;; license) col=9 ;; *) return 1 ;;
    esac
    awk -F'\t' -v b="$1" -v i="$2" -v c="$col" \
        '$0 !~ /^#/ && NF == 9 && $1 == b && $2 == i { print $c; found = 1; exit } END { exit !found }' \
        "$(mss_catalog_file)"
}

mss_catalog_url() {
    local repo rev file
    repo=$(mss_catalog_get "$1" "$2" repo) || return 1
    rev=$(mss_catalog_get "$1" "$2" revision) || return 1
    file=$(mss_catalog_get "$1" "$2" file) || return 1
    printf 'https://huggingface.co/%s/resolve/%s/%s\n' "$repo" "$rev" "$file"
}

# mss_human_size <bytes>: 2.5 GB, 12.1 GB, 137 GiB, 271 MB.
mss_human_size() {
    awk -v b="$1" 'BEGIN {
        if (b >= 100 * 1073741824) printf "%d GiB", b / 1073741824
        else if (b >= 1e9) printf "%.1f GB", b / 1e9
        else if (b >= 1e6) printf "%d MB", b / 1e6 + 0.5
        else printf "%d KB", b / 1e3 + 0.5 }'
}

# mss_free_bytes <path>: bytes available where <path> would live (MSS_DF overrides df).
mss_free_bytes() {
    local d=$1
    while [ ! -d "$d" ]; do d=$(dirname "$d"); done
    "${MSS_DF:-df}" -P -k "$d" 2>/dev/null | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }'
}

# ── downloads (D5) ─────────────────────────────────────────────────────────────
# https only, and nothing curl or a log line could misread.
mss_url_valid() {
    case ${1:-} in
        https://*) ;;
        *) mss_error "only https:// URLs are accepted"; return 1 ;;
    esac
    mss_match "$1" '^https://[A-Za-z0-9._~:/?#@!&+,;=%-]+$' || { mss_error "the URL has characters that are not allowed"; return 1; }
}

# mss_remote_size <url>: the final response's Content-Length after redirects.
mss_remote_size() {
    local headers
    headers=$(/usr/bin/curl --fail --silent --show-error --head --location --proto '=https' --proto-redir '=https' \
        --max-time 60 "$1" 2>&1) || { mss_error "cannot reach the download: ${headers##*: }"; return 1; }
    printf '%s\n' "$headers" | tr -d '\r' | awk '
        /^HTTP\// { n = "" }
        tolower($1) == "content-length:" { n = $2 }
        END { if (n ~ /^[0-9]+$/) print n; else exit 1 }'
}

# mss_acquire_download <url> <dest> <expected size, or empty> <interactive 0|1>
# Downloads as the user to <dest>.part, resumable, then renames it to <dest>.
# <dest> is never replaced. Sets MSS_DOWNLOADED on success.
mss_acquire_download() {
    local url=$1 dest=$2 want=$3 inter=${4:-0} size part have need free dir rc
    mss_url_valid "$url" || return 1
    mss_validate_path_chars "download destination" "$dest" || return 1
    if [ -e "$dest" ] || [ -L "$dest" ]; then mss_error "$dest exists; an existing file is never replaced"; return 1; fi
    size=$(mss_remote_size "$url") || { mss_error "the server did not report a download size; nothing was downloaded"; return 1; }
    if [ -n "$want" ] && [ "$size" != "$want" ]; then
        mss_error "size mismatch: the server reports $size bytes, the catalogue $want; nothing was downloaded"
        return 1
    fi
    part=$dest.part
    have=0
    if [ -e "$part" ]; then
        have=$(stat -f %z "$part") || return 1
        if [ "$have" -gt "$size" ]; then
            if [ "$inter" = 1 ] && mss_ask_yn "$(basename "$part") is larger than the download. Delete it?" N \
                && [ "$MSS_ANSWER" = y ]; then
                rm -f "$part"; have=0
            else
                mss_error "$part is larger than $size bytes; delete it and re-run"
                return 1
            fi
        fi
    fi
    dir=$(dirname "$dest")
    need=$((size - have + 1073741824))
    free=$(mss_free_bytes "$dir")
    if [ -z "$free" ] || [ "$free" -lt "$need" ]; then
        mss_error "not enough space for $(basename "$dest"): needs $(mss_human_size "$need"), $(mss_human_size "${free:-0}") free"
        return 1
    fi
    mkdir -p "$dir" || return 1
    if [ "$have" -lt "$size" ]; then
        [ "$have" -eq 0 ] || echo "resuming $(basename "$dest") at $have bytes" >&2
        echo "downloading $(basename "$dest") ($(mss_human_size "$size")) to $dir" >&2
        /usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' --retry 5 --retry-delay 10 \
            --retry-all-errors --progress-bar -C - -o "$part" "$url"
        rc=$?
        if [ "$rc" = 33 ]; then
            # The server cannot resume: only a y deletes the partial file.
            if [ "$inter" = 1 ] && mss_ask_yn "The server cannot resume. Delete $(basename "$part") and start again?" N \
                && [ "$MSS_ANSWER" = y ]; then
                rm -f "$part"
                /usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' --retry 5 --retry-delay 10 \
                    --retry-all-errors --progress-bar -o "$part" "$url"
                rc=$?
            fi
        fi
        [ "$rc" = 0 ] || { mss_error "download failed (curl exit $rc); $part is kept, re-run to resume"; return 1; }
    fi
    have=$(stat -f %z "$part") || return 1
    [ "$have" = "$size" ] || { mss_error "downloaded $have bytes, expected $size; $part is kept"; return 1; }
    if [ -e "$dest" ] || [ -L "$dest" ]; then mss_error "$dest appeared during the download; not replaced"; return 1; fi
    mv "$part" "$dest" || return 1
    # shellcheck disable=SC2034  # read by mss_sha_mismatch_rename (mss-run.sh)
    MSS_DOWNLOADED=$dest
    echo "downloaded $dest" >&2
}

# ── Xcode Command Line Tools (B3, D2) ──────────────────────────────────────────
mss_clt_present() { "${MSS_XCODE_SELECT:-xcode-select}" -p >/dev/null 2>&1; }

# The headless method Homebrew also uses. Needs the run's sudo (U1).
mss_clt_install() {
    local marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress label rc
    touch "$marker" || return 1
    label=$(softwareupdate -l 2>/dev/null \
        | sed -n 's/^[[:space:]]*\*[[:space:]]*Label:[[:space:]]*\(Command Line Tools.*\)$/\1/p' | sort -V | tail -n 1)
    if [ -z "$label" ]; then
        rm -f "$marker"
        mss_error "no Command Line Tools update found; run xcode-select --install"
        return 1
    fi
    echo "installing $label" >&2
    sudo softwareupdate -i "$label" >&2
    rc=$?
    rm -f "$marker"
    [ "$rc" = 0 ] && mss_clt_present
}

# ── Homebrew, Ollama, llama.cpp (P1, P2, D3) ───────────────────────────────────
mss_brew() {
    if command -v brew >/dev/null 2>&1; then command -v brew
    elif [ -x /opt/homebrew/bin/brew ]; then echo /opt/homebrew/bin/brew
    else return 1
    fi
}

mss_brew_install_cmd() { printf '%s\n' "/bin/bash -c \"\$(curl -fsSL --proto '=https' $MSS_BREW_INSTALLER)\""; }

# Homebrew's documented installer, as the user; it calls sudo itself.
mss_acquire_homebrew() {
    local script
    script=$(/usr/bin/curl -fsSL --proto '=https' "$MSS_BREW_INSTALLER") || { mss_error "cannot fetch the Homebrew installer"; return 1; }
    NONINTERACTIVE=1 /bin/bash -c "$script" || return 1
    mss_brew >/dev/null || return 1
    PATH="$(dirname "$(mss_brew)"):$PATH"
    export PATH
}

mss_acquire_ollama_brew() {
    local brew
    brew=$(mss_brew) || return 1
    # The user's y to our offer is the consent: Homebrew's own ask mode (its default since 4.6)
    # would stop again at "Do you want to proceed?" whenever dependencies come along.
    HOMEBREW_NO_ASK=1 "$brew" install ollama </dev/null >&2 || return 1
    OLLAMA_BIN="$("$brew" --prefix)/bin/ollama"
    [ -x "$OLLAMA_BIN" ] || return 1
    export OLLAMA_BIN
}

mss_acquire_llamacpp_brew() {
    local brew
    brew=$(mss_brew) || return 1
    HOMEBREW_NO_ASK=1 "$brew" install llama.cpp </dev/null >&2 || return 1
    LLAMACPP_BIN="$("$brew" --prefix)/bin/llama-server"
    [ -x "$LLAMACPP_BIN" ] || return 1
    export LLAMACPP_BIN
    echo "llama-server: $("$LLAMACPP_BIN" --version 2>&1 | grep -m 1 -i 'version' || echo 'version unknown')" >&2
}

# ── ds4-server at the pinned commit (D1, D2) ───────────────────────────────────
mss_ds4_manual_cmd() {
    printf '%s\n' "git clone $MSS_DS4_REMOTE ~/ds4 && cd ~/ds4 && git checkout ${MSS_DS4_COMMIT:0:12} && make ds4-server"
}

# What the build needs and lacks, comma-separated; empty when ready. The pinned ds4
# uses Metal APIs from the macOS 15 SDK (MTLResidencySet, MTLMathModeSafe).
mss_ds4_missing_prereqs() {
    local m="" t ver
    ver=$("${MSS_SW_VERS:-sw_vers}" -productVersion 2>/dev/null)
    case ${ver%%.*} in
        ''|*[!0-9]*) ;;
        *) [ "${ver%%.*}" -ge 15 ] || m="$m, macOS 15 or later (this Mac runs $ver)" ;;
    esac
    mss_clt_present || m="$m, Xcode Command Line Tools"
    for t in git make cc; do command -v "$t" >/dev/null 2>&1 || m="$m, $t"; done
    printf '%s\n' "${m#, }"
}

# mss_ds4_dir_state <dir>: new, reuse (its own clean checkout at the pin) or refuse.
mss_ds4_dir_state() {
    local d=$1 top
    if [ ! -e "$d" ] && [ ! -L "$d" ]; then echo new; return 0; fi
    if [ -L "$d" ] || [ ! -d "$d" ]; then echo refuse; return 0; fi
    top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || { echo refuse; return 0; }
    [ "$(cd "$top" && pwd -P)" = "$(cd "$d" && pwd -P)" ] || { echo refuse; return 0; }
    [ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" = "$MSS_DS4_COMMIT" ] || { echo refuse; return 0; }
    [ -z "$(git -C "$d" status --porcelain --untracked-files=no 2>/dev/null)" ] || { echo refuse; return 0; }
    echo reuse
}

# mss_acquire_ds4_build <dir>: clone the pin (or reuse a clean checkout at it),
# build as the user, check --help, and export DS4_BIN.
mss_acquire_ds4_build() {
    local d=$1 missing log pid n=0 help
    case $d in /*) ;; *) mss_error "DS4_BUILD_DIR must be an absolute path"; return 1 ;; esac
    mss_validate_path_chars DS4_BUILD_DIR "$d" || return 1
    missing=$(mss_ds4_missing_prereqs)
    if [ -n "$missing" ]; then
        mss_error "the ds4 build needs: $missing"
        return 1
    fi
    case $(mss_ds4_dir_state "$d") in
        refuse)
            mss_error "$d is not a clean ds4 checkout at ${MSS_DS4_COMMIT:0:12}; left untouched"
            return 1 ;;
        new)
            echo "cloning ds4 into $d" >&2
            git clone --quiet "$MSS_DS4_REMOTE" "$d" || { mss_error "git clone of $MSS_DS4_REMOTE failed"; return 1; }
            git -C "$d" checkout --quiet --detach "$MSS_DS4_COMMIT" \
                || { mss_error "ds4 commit ${MSS_DS4_COMMIT:0:12} not found"; return 1; } ;;
    esac
    [ "$(git -C "$d" rev-parse HEAD)" = "$MSS_DS4_COMMIT" ] || { mss_error "ds4 HEAD is not the pinned commit"; return 1; }
    log=$d/mss-build.log
    echo "building ds4-server (log: $log)" >&2
    make -C "$d" ds4-server >"$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        n=$((n + 1))
        [ $((n % 30)) -ne 0 ] || echo "still building…" >&2
    done
    if ! wait "$pid"; then
        mss_error "make ds4-server failed; the last 20 lines of $log:"
        tail -n 20 "$log" >&2
        return 1
    fi
    help=$("$d/ds4-server" --help 2>&1) || { mss_error "$d/ds4-server --help failed"; return 1; }
    printf '%s\n' "$help" | grep -q -- '--batched-session' \
        || { mss_error "$d/ds4-server --help does not list --batched-session"; return 1; }
    DS4_BIN=$d/ds4-server
    export DS4_BIN
    echo "built $DS4_BIN at ${MSS_DS4_COMMIT:0:12}" >&2
}

# ── non-interactive acquisition (D7): environment variables only ───────────────
# Checked before any network call; never read from or saved to backends.env.
mss_d7_validate() {
    local b P url sha
    if [ -n "${DS4_BUILD_DIR:-}" ] && [ -n "${DS4_BIN:-}" ]; then
        mss_error "set DS4_BIN or DS4_BUILD_DIR, not both"
        return 1
    fi
    case ${LLAMACPP_BREW_INSTALL:-} in
        ''|yes) ;;
        *) mss_error "LLAMACPP_BREW_INSTALL must be yes or unset"; return 1 ;;
    esac
    for b in llamacpp ds4; do
        P=$(mss_prefix "$b")
        url=$(printenv "${P}_MODEL_URL")
        [ -n "$url" ] || continue
        case $url in
            catalog:*)
                mss_catalog_url "$b" "${url#catalog:}" >/dev/null \
                    || { mss_error "${P}_MODEL_URL: '${url#catalog:}' is not a $b catalogue entry"; return 1; } ;;
            *)
                mss_url_valid "$url" || return 1
                sha=$(printenv "${P}_MODEL_SHA256")
                [ -n "$sha" ] || { mss_error "${P}_MODEL_URL needs ${P}_MODEL_SHA256"; return 1; }
                mss_validate_sha256 "${P}_MODEL_SHA256" "$sha" || return 1 ;;
        esac
    done
    return 0
}

mss_d7_run() {
    local b P url dest size sha file id
    if mss_backend_selected ds4 && [ -n "${DS4_BUILD_DIR:-}" ]; then
        mss_acquire_ds4_build "$DS4_BUILD_DIR" || return 1
    fi
    if mss_backend_selected llamacpp && [ "${LLAMACPP_BREW_INSTALL:-}" = yes ] && [ -z "${LLAMACPP_BIN:-}" ]; then
        mss_brew >/dev/null || { mss_error "LLAMACPP_BREW_INSTALL=yes needs Homebrew: $(mss_brew_install_cmd)"; return 1; }
        mss_acquire_llamacpp_brew || { mss_error "brew install llama.cpp failed"; return 1; }
    fi
    for b in llamacpp ds4; do
        mss_backend_selected "$b" || continue
        P=$(mss_prefix "$b")
        url=$(printenv "${P}_MODEL_URL")
        [ -n "$url" ] || continue
        dest=$(printenv "${P}_MODEL")
        if [ -n "$dest" ] && [ -e "$dest" ]; then
            echo "${P}_MODEL exists; ${P}_MODEL_URL is not downloaded" >&2
            continue
        fi
        case $url in
            catalog:*)
                id=${url#catalog:}
                size=$(mss_catalog_get "$b" "$id" size); sha=$(mss_catalog_get "$b" "$id" sha256)
                file=$(mss_catalog_get "$b" "$id" file); url=$(mss_catalog_url "$b" "$id") ;;
            *)
                size=""; sha=$(printenv "${P}_MODEL_SHA256"); file=${url%%\?*} ;;
        esac
        [ -n "$dest" ] || dest=$HOME/models/$(basename "$file")
        mss_acquire_download "$url" "$dest" "$size" 0 || return 1
        export "${P}_MODEL=$dest" "${P}_MODEL_SHA256=$sha"
    done
    return 0
}
