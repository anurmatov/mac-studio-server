#!/bin/bash
# mss-acquire.sh — acquisition for install.sh and model.sh (1.5.0, #15): Xcode
# Command Line Tools, Homebrew, Ollama, llama.cpp, a pinned ds4-server build, the
# model catalogue and resumable, size-checked model downloads.
#
# bash 3.2, sourced after mss-common.sh. Everything runs as the user: the only
# sudo calls are the CLT install (softwareupdate) and the Homebrew installer's
# own. Test overrides: MSS_CATALOG, MSS_MLX_CATALOG, MSS_DF, MSS_XCODE_SELECT, MSS_SW_VERS.

MSS_DS4_COMMIT=0aaea5a238fb41a35106a551e73c8409dfb751ac
MSS_DS4_REMOTE=https://github.com/antirez/ds4.git
MSS_BREW_INSTALLER=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
# The file a download in this run created, for the sha-mismatch rename (D6).
MSS_DOWNLOADED=""

mss_prefix() { case $1 in llamacpp) echo LLAMACPP ;; ds4) echo DS4 ;; mlx) echo MLX ;; esac; }

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

# mss_acquire_docker_brew: install only the Docker tools missing from the boot
# job's PATH (#27 D5). Never upgrade, reinstall or uninstall — a re-run is
# brew's to resume.
mss_acquire_docker_brew() {
    local brew tools _t
    brew=$(mss_brew) || return 1
    tools=""
    for _t in colima docker; do
        _mss_job_tool "$_t" >/dev/null 2>&1 || tools="$tools $_t"
    done
    [ -n "$tools" ] || return 0
    # shellcheck disable=SC2086  # the tool list is our own two literals
    HOMEBREW_NO_ASK=1 "$brew" install $tools </dev/null >&2 || return 1
    return 0
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

# MLX-Serve from its Homebrew tap (#1 D8). The tap tracks upstream main, so
# the installed version is checked by the probe, never assumed.
MSS_MLX_TAP=ddalcu/mlx-serve
MSS_MLX_TAP_URL=https://github.com/ddalcu/mlx-serve
mss_mlx_brew_cmd() { printf '%s\n' "brew tap $MSS_MLX_TAP $MSS_MLX_TAP_URL && brew install $MSS_MLX_TAP/mlx-serve"; }

mss_acquire_mlx_brew() {
    local brew
    brew=$(mss_brew) || return 1
    HOMEBREW_NO_ASK=1 "$brew" tap "$MSS_MLX_TAP" "$MSS_MLX_TAP_URL" </dev/null >&2 || return 1
    HOMEBREW_NO_ASK=1 "$brew" install "$MSS_MLX_TAP/mlx-serve" </dev/null >&2 || return 1
    MLX_BIN="$("$brew" --prefix)/bin/mlx-serve"
    [ -x "$MLX_BIN" ] || return 1
    export MLX_BIN
}

# ── MLX models (#35): catalogue, discovery and the pinned starter ─────────────
# config/mlx.catalog has one row per file (an MLX checkpoint is a directory):
#   id repo revision path size sha256 role license
# Its rows are checked as a whole before any is used. config/models.catalog
# and its parser are untouched: its first-match lookup takes one file per id.
mss_mlx_catalog_file() { printf '%s\n' "${MSS_MLX_CATALOG:-$REPO_DIR/config/mlx.catalog}"; }

# mss_mlx_catalog_check: every rule of #35 A.6, or a named error and 1. A
# refused catalogue offers no download; the chooser still works without it.
# The path character class is mss_validate_path_chars'.
mss_mlx_catalog_check() {
    local f out
    f=$(mss_mlx_catalog_file)
    [ -r "$f" ] || { mss_error "mlx catalogue $f is not readable; no download is offered"; return 1; }
    out=$(LC_ALL=C awk -F'\t' '
        function bad(m) { if (err == "") err = m }
        function hex(v, n) { return length(v) == n && v !~ /[^0-9a-fA-F]/ }
        /^#/ || /^[[:space:]]*$/ { next }
        {
            if (NF != 8) { bad("line " NR ": expected 8 tab-separated fields, found " NF); next }
            id = $1; p = $4
            if (id !~ /^[a-z0-9][a-z0-9._-]*$/) bad("line " NR ": id \"" id "\" is not a plain name")
            if ($2 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$/) bad("line " NR ": repo \"" $2 "\" is not <org>/<name>")
            if (!hex($3, 40)) bad("line " NR ": revision is not 40 hex characters")
            if (!hex($6, 64)) bad("line " NR ": sha256 is not 64 hex characters")
            if ($5 !~ /^[1-9][0-9]*$/) bad("line " NR ": size is not a positive integer")
            if (p !~ /^[A-Za-z0-9_+@:,=-][A-Za-z0-9._+@:,=-]*(\/[A-Za-z0-9_+@:,=-][A-Za-z0-9._+@:,=-]*)?$/ || p ~ /\.\./)
                bad("line " NR ": path \"" p "\" is not a relative name (no .., no leading . or /, at most one /)")
            if ($7 != "starter" && $7 != "test") bad("line " NR ": role must be starter or test")
            if ($8 !~ /^[A-Za-z0-9][A-Za-z0-9.+_-]*$/) bad("line " NR ": license is not a plain name")
            key = $2 FS $3 FS $7 FS $8
            if (!(id in K)) { K[id] = key; ids[++n] = id; if ($7 == "starter") st = st (st == "" ? "" : ", ") id }
            else if (K[id] != key) bad(id " rows disagree on repo, revision, role or license")
            if ((id, p) in P) bad(id " lists " p " twice")
            P[id, p] = 1
            if (p == "config.json") C[id] = 1
            if (p ~ /^[^\/]*\.safetensors$/) S[id] = 1
            if (p ~ /\.gguf$/) G[id] = 1
        }
        END {
            if (err == "" && n == 0) bad("no entries")
            for (i = 1; i <= n && err == ""; i++) {
                id = ids[i]
                if (!(id in C)) bad(id " has no top-level config.json")
                else if (!(id in S)) bad(id " has no top-level *.safetensors")
                else if (id in G) bad(id " has a .gguf file")
            }
            if (err == "" && index(st, ",")) bad("more than one starter (" st ")")
            if (err != "") { print err; exit 1 }
        }' "$f") || { mss_error "mlx catalogue $f: $out; no download is offered"; return 1; }
}

# mss_mlx_catalog_ids <role>: ids with that role, in file order.
mss_mlx_catalog_ids() {
    awk -F'\t' -v r="$1" '$0 !~ /^#/ && NF == 8 && $7 == r && !seen[$1]++ { print $1 }' "$(mss_mlx_catalog_file)"
}

# mss_mlx_catalog_get <id> <field>: repo, revision, role or license (shared by its rows).
mss_mlx_catalog_get() {
    local col
    case $2 in repo) col=2 ;; revision) col=3 ;; role) col=7 ;; license) col=8 ;; *) return 1 ;; esac
    awk -F'\t' -v i="$1" -v c="$col" \
        '$0 !~ /^#/ && NF == 8 && $1 == i { print $c; found = 1; exit } END { exit !found }' "$(mss_mlx_catalog_file)"
}

# mss_mlx_catalog_files <id>: "<path> <size> <sha256>" lines, in catalogue order.
mss_mlx_catalog_files() {
    awk -F'\t' -v i="$1" '$0 !~ /^#/ && NF == 8 && $1 == i { print $4, $5, tolower($6) }' "$(mss_mlx_catalog_file)"
}

# mss_mlx_catalog_total <id>: the bytes of all its files.
mss_mlx_catalog_total() {
    awk -F'\t' -v i="$1" '$0 !~ /^#/ && NF == 8 && $1 == i { t += $5 } END { printf "%.0f\n", t }' "$(mss_mlx_catalog_file)"
}

# _mss_mlx_leaf <dir>: a model candidate by name: a top-level config.json or
# *.safetensors. Anything else (an <org> parent, a GGUF folder) is not one.
_mss_mlx_leaf() {
    local f
    [ -e "$1/config.json" ] && return 0
    for f in "$1"/*.safetensors; do [ -e "$f" ] && return 0; done
    return 1
}

# _mss_mlx_complete <resolved dir>: a candidate that is complete by name. It
# passes mss_mlx_check_dir; nothing at the top or one level down is an
# interrupted or rejected download; and every shard model.safetensors.index.json
# names exists at the top level. That index, at most 4 MiB, is the only file
# read; weights are never opened. A missing or failing find rejects: an empty
# listing proves nothing unless find ran and succeeded.
_mss_mlx_complete() {
    local d=$1 idx size name left
    mss_mlx_check_dir "model directory" "$d" 2>/dev/null || return 1
    command -v find >/dev/null 2>&1 || return 1
    left=$(find -L "$d" -mindepth 1 -maxdepth 2 \( -name '*.partial' -o -name '*.part' -o -name '*.sha-mismatch' \) \
        -print 2>/dev/null) || return 1
    [ -z "$left" ] || return 1
    idx=$d/model.safetensors.index.json
    [ -e "$idx" ] || [ -L "$idx" ] || return 0
    size=$(stat -L -f %z "$idx" 2>/dev/null) || return 1
    case $size in ''|*[!0-9]*) return 1 ;; esac
    [ "$size" -le 4194304 ] || return 1
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        case $name in */*|.*) return 1 ;; esac
        [ -f "$d/$name" ] || return 1
    done <<MSS_MLX_SHARDS
$(LC_ALL=C grep -o '"[^"]*\.safetensors"' "$idx" 2>/dev/null | tr -d '"' | LC_ALL=C sort -u)
MSS_MLX_SHARDS
    return 0
}

# mss_mlx_find_models: complete native MLX checkpoints in mlx-serve's own
# ~/.mlx-serve/models/<org>/<repo> and <name>, and in ~/models/<name>, as
# "found <resolved dir> <dir as found>" lines (each resolved dir once, as first
# found), then "skipped <n>": the candidates that failed a rule. Dot-entries
# (.mss-staging among them) are not looked at. "found" means complete by name,
# not verified or loadable.
mss_mlx_find_models() {
    local m=$HOME/.mlx-serve/models d sub r seen=" " skipped=0
    for d in "$m"/* "$HOME/models"/*; do
        [ -d "$d" ] || continue
        if _mss_mlx_leaf "$d"; then
            set -- "$d"
        elif [ "${d%/*}" = "$m" ]; then
            set --
            for sub in "$d"/*; do [ -d "$sub" ] && _mss_mlx_leaf "$sub" && set -- "$@" "$sub"; done
        else
            continue
        fi
        for sub in "$@"; do
            if r=$(mss_resolve_path "$sub" 2>/dev/null) && _mss_mlx_complete "$r"; then
                case $seen in *" $r "*) continue ;; esac
                seen="$seen$r "
                printf 'found %s %s\n' "$r" "$sub"
            else
                skipped=$((skipped + 1))
            fi
        done
    done
    printf 'skipped %s\n' "$skipped"
}

# _mss_mlx_read_blocker: nothing is read or hashed while a model server or
# Ollama runs, a verified Ollama embedding worker included, or when pgrep is
# missing: paging a download in beside a resident model can freeze the host.
_mss_mlx_read_blocker() {
    local s
    if ! s=$(mss_model_servers ollama); then
        echo "pgrep is missing, so a running model server cannot be ruled out; a download is checked by reading it. Choose \"another directory\"" >&2
        return 1
    fi
    s=$(printf '%s\n' "$s" | head -n 1)
    [ -z "$s" ] && return 0
    echo "${s%% *} (pid ${s#* }) is running; a download is checked by reading it, and nothing is read while Ollama or a model server runs. Stop it, or choose \"another directory\"" >&2
    return 1
}

# _mss_mlx_recorded <record file> <path> <file> <size> <sha256>: <file> matches its
# last verified line "<path> <size> <inode> <mtime> <sha256>" (same stat, same sha).
_mss_mlx_recorded() {
    local st
    [ -f "$1" ] && [ -f "$3" ] && [ ! -L "$3" ] || return 1
    st=$(stat -f '%z %i %m' "$3" 2>/dev/null) || return 1
    [ "${st%% *}" = "$4" ] || return 1
    awk -v p="$2" -v want="$2 $st $5" '$1 == p { l = $0 } END { exit !(l == want) }' "$1" 2>/dev/null
}

# _mss_mlx_quarantine <file> <target>: move a rejected file to <target>, or to
# <target>.1, .2, ... when that exists; never overwritten, never deleted. Prints
# where it went.
_mss_mlx_quarantine() {
    local t=$2 i=0
    mkdir -p "$(dirname "$t")" || return 1
    while [ -e "$t" ] || [ -L "$t" ]; do i=$((i + 1)); t=$2.$i; done
    mv "$1" "$t" || return 1
    printf '%s\n' "$t"
}

# _mss_mlx_tilde <path>: ~/… under $HOME.
_mss_mlx_tilde() {
    case $1 in "$HOME"/*) printf '%s/%s\n' '~' "${1#"$HOME"/}" ;; *) printf '%s\n' "$1" ;; esac
}

# mss_acquire_mlx_model <id>: the pinned download of a catalogue checkpoint,
# as the user, after a y (#35 A.4). It never writes into an existing
# directory: files go to ~/.mlx-serve/models/.mss-staging/<repo>, each is
# size- and sha256-checked, and only a complete stage is renamed, once, to
# ~/.mlx-serve/models/<repo> (mlx-serve's own layout). A file that does not
# match is moved aside to .mss-staging/<repo>.rejected/. On success
# MSS_MLX_ACQUIRED is the new directory; otherwise it prints why and returns 1,
# keeping what it staged, so choosing it again resumes.
mss_acquire_mlx_model() {
    local id=$1 repo rev models dest stage rec rej total nfiles vbytes=0 pbytes=0 remaining free msg
    local path size sha f have got st q saved_dl ino
    MSS_MLX_ACQUIRED=""
    repo=$(mss_mlx_catalog_get "$id" repo) || { mss_error "$id is not in the mlx catalogue"; return 1; }
    rev=$(mss_mlx_catalog_get "$id" revision) || return 1
    models=$HOME/.mlx-serve/models
    dest=$models/$repo; stage=$models/.mss-staging/$repo; rec=$stage.verified; rej=$stage.rejected
    mss_validate_path_chars "download destination" "$dest" || return 1

    # 1. nothing is read while a model server or Ollama runs
    _mss_mlx_read_blocker || return 1
    # 2. an existing destination is never written into, merged or replaced
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        echo "$(_mss_mlx_tilde "$dest") exists; choose it from the list or another directory" >&2
        return 1
    fi
    # 3. space for what is still to come, plus 1 GiB
    total=$(mss_mlx_catalog_total "$id")
    nfiles=$(mss_mlx_catalog_files "$id" | grep -c .)
    while read -r path size sha <&3; do
        if _mss_mlx_recorded "$rec" "$path" "$stage/$path" "$size" "$sha"; then
            vbytes=$((vbytes + size))
        elif [ -f "$stage/$path.part" ]; then
            have=$(stat -f %z "$stage/$path.part" 2>/dev/null) || have=0
            [ "$have" -le "$size" ] || have=$size
            pbytes=$((pbytes + have))
        fi
    done 3<<MSS_MLX_FILES
$(mss_mlx_catalog_files "$id")
MSS_MLX_FILES
    remaining=$((total - vbytes - pbytes))
    free=$(mss_free_bytes "$models")
    if [ -z "$free" ] || [ "$free" -lt $((remaining + 1073741824)) ]; then
        echo "not enough space: needs $(mss_human_size $((remaining + 1073741824))), $(mss_human_size "${free:-0}") free" >&2
        return 1
    fi
    # 4. consent; Enter is no
    msg="Download $id ($(mss_human_size "$total"), $nfiles files) to $(_mss_mlx_tilde "$dest") ($(mss_human_size "$free") free"
    [ $((vbytes + pbytes)) -eq 0 ] || msg="$msg, $(mss_human_size $((vbytes + pbytes))) already downloaded"
    mss_ask_yn "$msg)?" N
    [ "$MSS_ANSWER" = y ] || return 1

    # 5, 6. one file at a time, in catalogue order: skip what is recorded,
    # hash what is staged without a record, download what is missing; every
    # file is hashed as soon as it is complete, with no model server running.
    mkdir -p "$stage" || { mss_error "cannot create $stage"; return 1; }
    saved_dl=$MSS_DOWNLOADED
    while read -r path size sha <&3; do
        f=$stage/$path
        if _mss_mlx_recorded "$rec" "$path" "$f" "$size" "$sha"; then
            echo "$path: verified before; skipped" >&2
            continue
        fi
        if [ -e "$f" ] || [ -L "$f" ]; then
            have=$(stat -f %z "$f" 2>/dev/null)
            if [ ! -f "$f" ] || [ -L "$f" ] || [ "$have" != "$size" ]; then
                q=$(_mss_mlx_quarantine "$f" "$rej/$path.size-mismatch") || { mss_error "cannot move $f aside"; return 1; }
                echo "$path is not the catalogue's $size bytes; moved to $q" >&2
                return 1
            fi
        else
            mkdir -p "$(dirname "$f")" || return 1
            # MSS_DOWNLOADED names a llama.cpp or ds4 model for the root
            # check's sha-mismatch rename; these files are checked here.
            mss_acquire_download "https://huggingface.co/$repo/resolve/$rev/$path" "$f" "$size" 1 \
                || { MSS_DOWNLOADED=$saved_dl; return 1; }
            MSS_DOWNLOADED=$saved_dl
        fi
        _mss_mlx_read_blocker || return 1
        echo "verifying $path" >&2
        got=$(mss_shasum256 "$f" 2>/dev/null | awk '{ print $1 }')
        [ -n "$got" ] || { mss_error "cannot hash $f; it is kept in staging"; return 1; }
        if [ "$got" != "$sha" ]; then
            q=$(_mss_mlx_quarantine "$f" "$rej/$path.sha-mismatch") || { mss_error "cannot move $f aside"; return 1; }
            echo "$path sha256 mismatch; moved to $q" >&2
            return 1
        fi
        st=$(stat -f '%z %i %m' "$f") || return 1
        printf '%s %s %s\n' "$path" "$st" "$got" >> "$rec" || return 1
    done 3<<MSS_MLX_FILES
$(mss_mlx_catalog_files "$id")
MSS_MLX_FILES

    # 7. complete: exactly the catalogue's files, each recorded, and a valid
    # checkpoint; then one rename, re-checked afterwards.
    if [ "$(cd "$stage" && find . \( -type f -o -type l \) -print | sed 's|^\./||' | LC_ALL=C sort)" \
        != "$(mss_mlx_catalog_files "$id" | awk '{ print $1 }' | LC_ALL=C sort)" ]; then
        mss_error "$stage holds files the catalogue does not list; it is kept (remove them, or rm -rf $models/.mss-staging)"
        return 1
    fi
    while read -r path size sha <&3; do
        _mss_mlx_recorded "$rec" "$path" "$stage/$path" "$size" "$sha" \
            || { mss_error "$stage/$path changed after it was verified; it is kept in staging"; return 1; }
    done 3<<MSS_MLX_FILES
$(mss_mlx_catalog_files "$id")
MSS_MLX_FILES
    mss_mlx_check_dir "MLX download" "$stage" || return 1
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        echo "$(_mss_mlx_tilde "$dest") appeared during the download; the verified download is kept in staging" >&2
        return 1
    fi
    ino=$(stat -f %i "$stage") || return 1
    if ! mkdir -p "$(dirname "$dest")" || ! mv "$stage" "$dest"; then
        echo "cannot move the verified download to $(_mss_mlx_tilde "$dest"); it is kept in staging" >&2
        return 1
    fi
    # Something that created <dest> after the check makes mv nest the stage
    # inside it (the stage keeps its inode): move it back, leave <dest> alone.
    if [ "$(stat -f %i "$dest/${stage##*/}" 2>/dev/null)" = "$ino" ]; then
        [ ! -e "$stage" ] && mv "$dest/${stage##*/}" "$stage" \
            || mss_error "cannot move $dest/${stage##*/} back to $stage"
        echo "$(_mss_mlx_tilde "$dest") appeared during the download; the verified download is kept in staging" >&2
        return 1
    fi
    if [ ! -f "$dest/config.json" ] || [ -e "$stage" ] || [ -L "$stage" ]; then
        mss_error "the move to $dest did not complete as expected; check $dest and $stage"
        return 1
    fi
    rm -f "$rec"
    rmdir "$(dirname "$stage")" "$models/.mss-staging" 2>/dev/null || true
    [ ! -d "$rej" ] || echo "rejected files are kept in $(_mss_mlx_tilde "$rej")" >&2
    echo "downloaded and verified $id: $(_mss_mlx_tilde "$dest")" >&2
    # shellcheck disable=SC2034  # read by the MLX model chooser (mss-picker.sh)
    MSS_MLX_ACQUIRED=$dest
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
