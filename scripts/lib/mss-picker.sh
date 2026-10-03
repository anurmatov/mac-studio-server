#!/bin/bash
# mss-picker.sh — interactive backend picker for scripts/install.sh (#12, #15).
#
# Sourced by install.sh and model.sh after mss-common.sh and mss-acquire.sh.
# bash 3.2 compatible (macOS ships it): no bash 4 builtins or expansions (the CI
# step lists them). Prompts go to stderr, answers come from stdin. Every answer
# goes through the same validators the installer uses; backends.env is written
# only after the summary is confirmed. Installs, builds and downloads run only
# after a y (the model menu's starter is the one default-yes), as the user. The
# MLX model chooser's starter asks its own y/N, with N the default (#35).
#
# Results, as exported variables for the rest of install.sh:
#   MSS_BACKENDS, MSS_ACTIVE_BACKEND (two or more optional backends),
#   OLLAMA_BIN, MSS_TUNE_MACOS, MSS_DEFER_MODEL and every chosen backend's
#   *_BIN/_MODEL/_MODEL_SHA256/_HOST/_PORT/_ALLOW_FROM (and
#   LLAMACPP_API_KEY_FILE; MLX_BIN, MLX_MODEL_DIR and MLX_PORT for mlx)
#   MSS_GPU_PERCENT, MSS_POWER_AUTORESTART, MSS_DOCKER_INSTALL and (when the
#   autostart question ran) MSS_DOCKER_AUTOSTART
#   MSS_PICKER_REPLACE  installed backends the check may look through (comma list)
#   MSS_SWITCH_FROM     installed backends to uninstall after the check passes
#   MSS_DOWNLOADED      a model file downloaded in this run

# shellcheck disable=SC2034  # both are read by install.sh after the picker
MSS_PICKER_REPLACE=""
# shellcheck disable=SC2034
MSS_SWITCH_FROM=""
MSS_PICK_BREW_ASKED=0
MSS_PICK_DS4_BUILT=""
# The model menu offers "later" only with a single optional backend (#1 D3).
MSS_PICK_LATER=1

mss_pick_trap() {
    trap 'echo >&2; echo "install.sh: interrupted; nothing was saved or changed" >&2; exit 130' INT
}

mss_pick_eof() {
    echo >&2
    echo "install.sh: input ended; nothing was saved or changed" >&2
    exit 1
}

# mss_ask <prompt> <default> <validator>: re-asks on invalid input, exits 2
# after 3 invalid answers. The answer is left in MSS_ANSWER.
mss_ask() {
    local prompt=$1 default=$2 validator=$3 tries=0 answer
    while :; do
        if [ -n "$default" ]; then
            printf '%s [%s]: ' "$prompt" "$default" >&2
        else
            printf '%s: ' "$prompt" >&2
        fi
        IFS= read -r answer || mss_pick_eof
        [ -n "$answer" ] || answer=$default
        if "$validator" "$answer"; then
            MSS_ANSWER=$answer
            return 0
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 3 ]; then
            echo "install.sh: 3 invalid answers; nothing was saved or changed" >&2
            exit 2
        fi
    done
}

# mss_ask_yn <prompt> <Y|N>: MSS_ANSWER becomes y or n.
mss_ask_yn() {
    local prompt=$1 default=$2 hint
    case $default in Y) hint="Y/n" ;; *) hint="y/N" ;; esac
    mss_ask "$prompt [$hint]" "" _mss_pick_yn_valid
    case $MSS_ANSWER in
        '') [ "$default" = Y ] && MSS_ANSWER=y || MSS_ANSWER=n ;;
        [Yy]|[Yy][Ee][Ss]) MSS_ANSWER=y ;;
        *) MSS_ANSWER=n ;;
    esac
}
_mss_pick_yn_valid() {
    case $1 in ''|[YyNn]|[Yy][Ee][Ss]|[Nn][Oo]) return 0 ;; esac
    mss_error "answer y or n"
    return 1
}

# ── validators (each prints its own error) ─────────────────────────────────────
# The backend menu (#1 D8): numbers 1-4, comma-separated, no duplicates.
_mss_pick_menu_valid() {
    local a
    a=$(printf '%s' "$1" | tr -d ' ')
    if ! mss_match "$a" '^[1-4](,[1-4])*$'; then
        mss_error "answer numbers from 1 to 4, comma-separated (for example 1,3)"
        return 1
    fi
    if [ -n "$(printf '%s\n' "$a" | tr ',' '\n' | sort | uniq -d)" ]; then
        mss_error "each number only once"
        return 1
    fi
    return 0
}

# MLX-Serve: an executable that is exactly the pinned version.
_mss_pick_mlx_bin_valid() {
    local r
    r=$(mss_resolve_path "$1") || return 1
    mss_validate_path_chars "binary" "$r" || return 1
    [ -f "$r" ] && [ -x "$r" ] || { mss_error "not an executable file: $r"; return 1; }
    mss_mlx_version_ok "$r" "" ""
}

_mss_pick_mlx_dir_valid() {
    local r
    case $1 in /*) ;; *) mss_error "enter the absolute path of a native MLX model directory"; return 1 ;; esac
    r=$(mss_resolve_path "$1") || return 1
    mss_mlx_check_dir "model directory" "$r"
}

_mss_pick_bin_valid() {
    local r
    r=$(mss_resolve_path "$1") || return 1
    mss_validate_path_chars "binary" "$r" || return 1
    [ -f "$r" ] && [ -x "$r" ] || { mss_error "not an executable file: $r"; return 1; }
}

_mss_pick_model_valid() {
    local r
    r=$(mss_resolve_path "$1") || return 1
    mss_validate_path_chars "model" "$r" || return 1
    [ -f "$r" ] || { mss_error "not a regular file: $r"; return 1; }
    case $(basename "$r") in
        *-[0-9]*-of-[0-9]*.gguf) mss_error "split GGUF sets are not supported"; return 1 ;;
    esac
}

_mss_pick_sha_valid() { mss_validate_sha256 "sha256" "$1"; }

_mss_pick_sha_or_compute_valid() {
    case $1 in c|C) return 0 ;; esac
    mss_validate_sha256 "sha256" "$1"
}

_mss_pick_host_valid() {
    mss_validate_host "address" "$1" || return 1
    mss_host_is_local "$1" || { mss_error "$1 is not assigned to a local interface"; return 1; }
}

# The key file path, never the key. A value that is not an absolute path is
# refused without echoing it: it may be the key itself.
_mss_pick_keyfile_valid() {
    [ -n "$1" ] || return 0
    case $1 in
        /*) ;;
        *) mss_error "enter the absolute path of a file that holds the key, not the key itself"; return 1 ;;
    esac
    mss_validate_path_chars "key file" "$1" || return 1
    mss_validate_key_file "key file" "$1" "${OLLAMA_USER:-$(whoami)}"
}

_mss_pick_allow_valid() {
    [ -n "$1" ] || { mss_error "a LAN address needs at least one allowed IPv4 address or CIDR"; return 1; }
    mss_validate_allowlist "allowlist" "$1"
}

# A menu answer between 1 and MSS_PICK_MENU_MAX (the MLX chooser has up to 11).
_mss_pick_num_valid() {
    case $1 in [1-9]|[1-9][0-9]) [ "$1" -le "$MSS_PICK_MENU_MAX" ] && return 0 ;; esac
    mss_error "choose a number from 1 to $MSS_PICK_MENU_MAX"
    return 1
}

# A model path, or an https URL to download.
_mss_pick_model_or_url_valid() {
    case $1 in
        https://*) mss_url_valid "$1" ;;
        http://*) mss_error "only https:// URLs are accepted"; return 1 ;;
        *) _mss_pick_model_valid "$1" ;;
    esac
}

# A new download destination: an absolute path that does not exist yet.
_mss_pick_dest_valid() {
    case $1 in /*) ;; *) mss_error "enter an absolute path"; return 1 ;; esac
    mss_validate_path_chars "destination" "$1" || return 1
    if [ -e "$1" ] || [ -L "$1" ]; then mss_error "$1 exists; choose own file to use it"; return 1; fi
}

# ── helpers ────────────────────────────────────────────────────────────────────
# Menu numbers: 1 ollama, 2 llama.cpp, 3 ds4, 4 mlx.
_MSS_PICK_NAMES="ollama llamacpp ds4 mlx"

# _mss_pick_sel_to_num <selection>: its menu answer ("1,3"), or nothing when
# the selection is not valid.
_mss_pick_sel_to_num() {
    local n=0 out="" b
    [ -n "$1" ] && mss_validate_selection "$1" 2>/dev/null || return 0
    for b in $_MSS_PICK_NAMES; do
        n=$((n + 1))
        case ",$1," in *",$b,"*) out="$out,$n" ;; esac
    done
    printf '%s\n' "${out#,}"
}

# _mss_pick_num_to_sel <answer>: the selection, in menu order.
_mss_pick_num_to_sel() {
    local a n=0 out="" b
    a=$(printf '%s' "$1" | tr -d ' ')
    for b in $_MSS_PICK_NAMES; do
        n=$((n + 1))
        case ",$a," in *",$n,"*) out="$out,$b" ;; esac
    done
    printf '%s\n' "${out#,}"
}

# _mss_pick_sel_add <selection> <backend>: the selection with it, in menu order.
_mss_pick_sel_add() {
    local b out=""
    for b in $_MSS_PICK_NAMES; do
        case ",$1,$2," in *",$b,"*) out="$out,$b" ;; esac
    done
    printf '%s\n' "${out#,}"
}

_mss_pick_local_ipv4() {
    "${MSS_IFCONFIG:-/sbin/ifconfig}" 2>/dev/null \
        | awk '$1 == "inet" && $2 !~ /^127\./ { print $2 }'
}

# _mss_pick_set NAME VALUE: export one answer.
_mss_pick_set() { export "$1=$2"; }

_mss_pick_tilde() {
    case $1 in
        "$HOME"/*) printf '%s/%s\n' '~' "${1#"$HOME"/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# ── prerequisites (P1, P2) ─────────────────────────────────────────────────────
# Homebrew is offered once per run, and only when a chosen step needs it.
_mss_pick_need_brew() {
    mss_brew >/dev/null && return 0
    [ "$MSS_PICK_BREW_ASKED" = 0 ] || return 1
    MSS_PICK_BREW_ASKED=1
    mss_ask_yn "Install Homebrew (official installer)?" N
    if [ "$MSS_ANSWER" = y ]; then
        mss_acquire_homebrew && return 0
        echo "Homebrew install failed." >&2
    fi
    echo "manual: $(mss_brew_install_cmd)" >&2
    return 1
}

# Ollama: /usr/local/bin/ollama as in 1.4.0, else the one on PATH, else an offer.
_mss_pick_ollama() {
    local found
    [ ! -x "${MSS_TEST_SYSROOT:-}/usr/local/bin/ollama" ] || return 0
    found=$(printenv OLLAMA_BIN)
    if [ -n "$found" ] && [ -x "$found" ]; then return 0; fi
    found=$(command -v ollama 2>/dev/null)
    if [ -n "$found" ]; then
        _mss_pick_set OLLAMA_BIN "$found"
        return 0
    fi
    if _mss_pick_need_brew; then
        mss_ask_yn "Install Ollama (brew install ollama)?" N
        if [ "$MSS_ANSWER" = y ] && mss_acquire_ollama_brew; then
            echo "Ollama: $OLLAMA_BIN" >&2
            return 0
        fi
    fi
    echo "manual: brew install ollama" >&2
}

# ── binary (I7, D1-D3) ─────────────────────────────────────────────────────────
# A found or saved binary is used without asking; otherwise acquisition is
# offered, and the path is asked only when nothing was found or acquired.
_mss_pick_binary() {
    local b=$1 P=$2 label=$3 found dir
    found=$(printenv "${P}_BIN")
    if [ -z "$found" ] && [ "$b" = llamacpp ]; then found=$(command -v llama-server 2>/dev/null); fi
    if [ -n "$found" ] && _mss_pick_bin_valid "$found" 2>/dev/null; then
        _mss_pick_set "${P}_BIN" "$found"
        echo "Using $label: $found" >&2
        return 0
    fi
    case $b in
        llamacpp)
            if _mss_pick_need_brew; then
                mss_ask_yn "Install llama-server (brew install llama.cpp)?" N
                if [ "$MSS_ANSWER" = y ] && mss_acquire_llamacpp_brew; then
                    _mss_pick_set LLAMACPP_BIN "$LLAMACPP_BIN"
                    return 0
                fi
            fi
            echo "manual: brew install llama.cpp" >&2
            ;;
        ds4)
            dir=${DS4_BUILD_DIR:-$HOME/ds4}
            mss_ask_yn "Build ds4-server at the pinned commit in $(_mss_pick_tilde "$dir")?" N
            if [ "$MSS_ANSWER" = y ]; then
                if ! mss_clt_present; then
                    mss_ask_yn "Install Xcode Command Line Tools (needed for git)?" N
                    [ "$MSS_ANSWER" != y ] || mss_clt_install
                fi
                if mss_acquire_ds4_build "$dir"; then
                    _mss_pick_set DS4_BIN "$DS4_BIN"
                    MSS_PICK_DS4_BUILT=$dir
                    return 0
                fi
            fi
            echo "manual: $(mss_ds4_manual_cmd)" >&2
            ;;
    esac
    mss_ask "$label binary path" "" _mss_pick_bin_valid
    _mss_pick_set "${P}_BIN" "$MSS_ANSWER"
}

# ── model (M1, D4, D5) ─────────────────────────────────────────────────────────
# _mss_pick_sha <resolved model> <P>: the 1.4.0 checksum questions for a file
# the user supplied. A saved value is kept with Enter; hashing is only on request.
_mss_pick_sha() {
    local resolved=$1 P=$2 def sha=""
    def=$(printenv "${P}_MODEL_SHA256")
    if [ -n "$def" ]; then
        mss_ask "Model sha256 (Enter keeps the saved value, c computes it now)" "$def" _mss_pick_sha_or_compute_valid
        case $MSS_ANSWER in c|C) ;; *) sha=$MSS_ANSWER ;; esac
    fi
    if [ -z "$sha" ]; then
        mss_ask_yn "Compute the sha256 now? This reads the whole file" Y
        if [ "$MSS_ANSWER" = y ]; then
            echo "Hashing $resolved ..." >&2
            if sha=$(mss_shasum256 "$resolved" 2>/dev/null | awk '{print $1}') && [ -n "$sha" ]; then
                echo "sha256: $sha" >&2
                mss_ask_yn "Use it? Compare with the checksum your model's source publishes" Y
                [ "$MSS_ANSWER" = y ] || sha=""
            else
                echo "Could not hash $resolved; enter the checksum instead." >&2
                sha=""
            fi
        fi
        if [ -z "$sha" ]; then
            mss_ask "Model sha256 (64 hex characters)" "" _mss_pick_sha_valid
            sha=$MSS_ANSWER
        fi
    fi
    _mss_pick_set "${P}_MODEL_SHA256" "$sha"
}

# _mss_pick_use_model <P> <path> <sha>: a model is chosen; it is no longer deferred.
_mss_pick_use_model() {
    _mss_pick_set "${1}_MODEL" "$2"
    _mss_pick_set "${1}_MODEL_SHA256" "$3"
    _mss_pick_set MSS_DEFER_MODEL ""
}

# _mss_pick_default_dest <backend> <file>: ~/models/<file>, or the gguf/ directory
# of a ds4 checkout built in this run.
_mss_pick_default_dest() {
    if [ "$1" = ds4 ] && [ -n "$MSS_PICK_DS4_BUILT" ]; then
        printf '%s/gguf/%s\n' "$MSS_PICK_DS4_BUILT" "$(basename "$2")"
    else
        printf '%s/models/%s\n' "$HOME" "$(basename "$2")"
    fi
}

# _mss_pick_fetch <backend> <P> <url> <size or empty> <sha> <file> <confirm 0|1>:
# download and use the model. Returns 1 (back to the menu) on a decline or error.
_mss_pick_fetch() {
    local b=$1 P=$2 url=$3 size=$4 sha=$5 file=$6 confirm=$7 dest free
    dest=$(_mss_pick_default_dest "$b" "$file")
    if [ "$confirm" = 1 ]; then
        mss_ask "Save the model to" "$dest" _mss_pick_dest_valid
        dest=$MSS_ANSWER
        free=$(mss_human_size "$(mss_free_bytes "$(dirname "$dest")")")
        mss_ask_yn "Download ${size:+$(mss_human_size "$size") }to $(_mss_pick_tilde "$dest") ($free free)?" N
        if [ "$MSS_ANSWER" != y ]; then
            echo "manual: curl -fL --proto '=https' -o $(_mss_pick_tilde "$dest") $url" >&2
            return 1
        fi
    fi
    mss_acquire_download "$url" "$dest" "$size" 1 || return 1
    _mss_pick_use_model "$P" "$dest" "$sha"
}

# _mss_pick_catalog <backend> <P> <id> <confirm 0|1>
_mss_pick_catalog() {
    _mss_pick_fetch "$1" "$2" "$(mss_catalog_url "$1" "$3")" "$(mss_catalog_get "$1" "$3" size)" \
        "$(mss_catalog_get "$1" "$3" sha256)" "$(mss_catalog_get "$1" "$3" file)" "$4"
}

# _mss_pick_own <backend> <P>: a local path (checksum asked) or an https URL (sha256 required).
_mss_pick_own() {
    local b=$1 P=$2 url sha
    mss_ask "Model file (.gguf) path or https URL" "" _mss_pick_model_or_url_valid
    case $MSS_ANSWER in
        https://*)
            url=$MSS_ANSWER
            mss_ask "Model sha256 (64 hex characters)" "" _mss_pick_sha_valid
            sha=$MSS_ANSWER
            _mss_pick_fetch "$b" "$P" "$url" "" "$sha" "${url%%\?*}" 1
            ;;
        *)
            _mss_pick_set "${P}_MODEL" "$MSS_ANSWER"
            _mss_pick_set MSS_DEFER_MODEL ""
            _mss_pick_sha "$(mss_resolve_path "$MSS_ANSWER")" "$P"
            ;;
    esac
}

# mss_pick_model_menu <backend> <offer later 0|1>: the one-line model menu. Loops
# until a model is chosen (or deferred); a declined or failed download returns here.
mss_pick_model_menu() {
    local b=$1 later=$2 P name line n def starter id ids="" more_n=0 own_n later_n=0 i choice
    P=$(mss_prefix "$b")
    [ "$b" = llamacpp ] && name=llama.cpp || name=ds4
    starter=$(mss_catalog_ids "$b" starter | head -n 1)
    n=0; line=""
    if [ -n "$starter" ]; then
        line="$name model: 1) $starter $(mss_human_size "$(mss_catalog_get "$b" "$starter" size)") (starter) 2) more"
        n=2; more_n=2
    else
        # "model" is left out so the line stays within 100 characters (S4).
        line="$name (no small one exists):"
        for id in $(mss_catalog_ids "$b" more); do
            n=$((n + 1)); ids="$ids $id"
            line="$line $n) $id $(mss_human_size "$(mss_catalog_get "$b" "$id" size)")"
        done
    fi
    n=$((n + 1)); own_n=$n; line="$line $n) own file/URL"
    if [ "$later" = 1 ]; then n=$((n + 1)); later_n=$n; line="$line $n) later"; fi
    if [ -n "$starter" ]; then def=1; elif [ "$later" = 1 ]; then def=$later_n; else def=""; fi
    while :; do
        MSS_PICK_MENU_MAX=$n
        mss_ask "$line" "$def" _mss_pick_num_valid
        choice=$MSS_ANSWER
        if [ "$choice" = "$later_n" ]; then
            _mss_pick_set MSS_DEFER_MODEL yes
            _mss_pick_set "${P}_MODEL" ""
            _mss_pick_set "${P}_MODEL_SHA256" ""
            echo "$b: no model now; scripts/model.sh adds one later" >&2
            return 0
        elif [ "$choice" = "$own_n" ]; then
            _mss_pick_own "$b" "$P" && return 0
        elif [ -n "$starter" ] && [ "$choice" = 1 ]; then
            _mss_pick_catalog "$b" "$P" "$starter" 0 && return 0
        elif [ "$choice" = "$more_n" ]; then
            _mss_pick_more "$b" "$P" && return 0
        else
            i=0
            for id in $ids; do
                i=$((i + 1))
                [ "$i" = "$choice" ] || continue
                _mss_pick_catalog "$b" "$P" "$id" 1 && return 0
            done
        fi
    done
}

# "more": the other catalogue entries, one line each.
_mss_pick_more() {
    local b=$1 P=$2 id n=0 ids=""
    for id in $(mss_catalog_ids "$b" more); do
        n=$((n + 1)); ids="$ids $id"
        echo "  $n) $id $(mss_human_size "$(mss_catalog_get "$b" "$id" size)")" >&2
    done
    [ "$n" -gt 0 ] || { echo "no other $b models in the catalogue" >&2; return 1; }
    if [ "$n" -gt 1 ]; then
        MSS_PICK_MENU_MAX=$n
        mss_ask "More models" 1 _mss_pick_num_valid
        n=$MSS_ANSWER
    fi
    # shellcheck disable=SC2086  # ids is a word list of catalogue ids
    set -- $ids
    shift $((n - 1))
    _mss_pick_catalog "$b" "$P" "$1" 1
}

# The model step: a saved model that exists keeps the 1.4.0 questions (nothing is
# offered); otherwise the menu, with "later".
_mss_pick_model() {
    local b=$1 P=$2 saved
    saved=$(printenv "${P}_MODEL")
    if [ -n "$saved" ] && [ -f "$saved" ]; then
        mss_ask "Model file (.gguf) path" "$saved" _mss_pick_model_valid
        _mss_pick_set "${P}_MODEL" "$MSS_ANSWER"
        _mss_pick_set MSS_DEFER_MODEL ""
        _mss_pick_sha "$(mss_resolve_path "$MSS_ANSWER")" "$P"
        return 0
    fi
    mss_pick_model_menu "$b" "$MSS_PICK_LATER"
}

# ── Ollama starter (M2), after the Ollama service is loaded ────────────────────
# mss_pick_ollama_model <ollama binary> <host>
mss_pick_ollama_model() {
    local exe=$1 host=$2 id i=0
    id=$(mss_catalog_ids ollama starter | head -n 1)
    [ -n "$id" ] || return 0
    MSS_PICK_MENU_MAX=2
    mss_ask "Ollama model: 1) $id $(mss_human_size "$(mss_catalog_get ollama "$id" size)") (starter) 2) later" 1 \
        _mss_pick_num_valid
    if [ "$MSS_ANSWER" = 2 ]; then
        echo "later: ollama pull $id" >&2
        return 0
    fi
    while [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$host:11434/api/version" 2>/dev/null)" != 200 ]; do
        i=$((i + 1))
        if [ "$i" -ge 30 ]; then
            echo "Ollama is not answering yet; later: ollama pull $id" >&2
            return 0
        fi
        sleep 2
    done
    OLLAMA_HOST="$host:11434" "$exe" pull "$id" || echo "the pull failed; later: ollama pull $id" >&2
}

# ── the optional backend's questions ───────────────────────────────────────────
_mss_pick_backend() {
    local b=$1 P label def lan host addrs first key
    case $b in
        llamacpp) P=LLAMACPP; label="llama.cpp llama-server" ;;
        ds4) P=DS4; label="DwarfStar ds4-server" ;;
        mlx) P=MLX ;;
    esac

    # 2. binary, 3. model (the checksum comes from the catalogue or the user).
    # mlx has its own: a pinned version and a model directory (#1 D8).
    if [ "$b" = mlx ]; then
        _mss_pick_mlx
    else
        _mss_pick_binary "$b" "$P" "$label"
        _mss_pick_model "$b" "$P"
    fi

    # 5. LAN access. The default follows the saved host; loopback when none.
    host=$(printenv "${P}_HOST")
    if [ -n "$host" ] && ! mss_is_loopback_host "$host"; then def=Y; else def=N; fi
    mss_ask_yn "Allow LAN access to $b?" "$def"
    lan=$MSS_ANSWER
    if [ "$lan" = y ]; then
        # 5a. address
        addrs=$(_mss_pick_local_ipv4)
        if [ -n "$addrs" ]; then
            echo "Local IPv4 addresses: $(printf '%s\n' "$addrs" | tr '\n' ' ')" >&2
        fi
        first=$(printf '%s\n' "$addrs" | head -n 1)
        if [ -n "$host" ] && ! mss_is_loopback_host "$host"; then def=$host; else def=$first; fi
        mss_ask "LAN address to listen on" "$def" _mss_pick_host_valid
        _mss_pick_set "${P}_HOST" "$MSS_ANSWER"

        # 5b. llama.cpp: an API key file instead of an allowlist
        key=""
        if [ "$b" = llamacpp ]; then
            mss_ask "API key file path (blank to use an allowlist instead)" "$(printenv LLAMACPP_API_KEY_FILE)" _mss_pick_keyfile_valid
            key=$MSS_ANSWER
            _mss_pick_set LLAMACPP_API_KEY_FILE "$key"
        fi

        # 5c. allowlist
        if [ "$b" = ds4 ] || [ -z "$key" ]; then
            mss_ask "Allowed client addresses or CIDRs (space-separated)" "$(printenv "${P}_ALLOW_FROM")" _mss_pick_allow_valid
            _mss_pick_set "${P}_ALLOW_FROM" "$MSS_ANSWER"
        fi
    else
        _mss_pick_set "${P}_HOST" 127.0.0.1
    fi

    # 6. port: not asked (I6); the saved or default port is kept in backends.env.
    def=$(printenv "${P}_PORT")
    [ -n "$def" ] || def=$(mss_default_port "$b")
    _mss_pick_set "${P}_PORT" "$def"
}

# Headless macOS tweaks (I2), asked once and saved.
_mss_pick_tweaks() {
    local def=N
    [ "$(printenv MSS_TUNE_MACOS)" != yes ] || def=Y
    mss_ask_yn "Apply headless macOS tweaks (no sleep, Spotlight, Time Machine, auto-updates)?" "$def"
    if [ "$MSS_ANSWER" = y ]; then _mss_pick_set MSS_TUNE_MACOS yes; else _mss_pick_set MSS_TUNE_MACOS no; fi
}


# ── host choices (#27): G, P, DI, DA — after the tweaks question ──────────────
# Every prompt offers the default it detects (#26's rule). Each question is
# fully resolved before the next one's "shown when" is evaluated.

# G — Metal wired-memory limit. The validator is the same check D1 runs, so the
# picker can never save a value step 2 would refuse on every later run.
_mss_pick_gpu_valid() {
    case $1 in
        system) return 0 ;;
        [1-9]|[1-9][0-9]|100) ;;
        *) mss_error "answer a percent 1-100 (no leading zero) or system"; return 1 ;;
    esac
    _mss_sysctl -n iogpu.wired_limit_mb >/dev/null 2>&1 || {
        echo "this Mac has no iogpu.wired_limit_mb; answer system" >&2; return 1; }
    _mss_sysctl -n hw.memsize >/dev/null 2>&1 || {
        echo "cannot read hw.memsize; answer system" >&2; return 1; }
    return 0
}

_mss_pick_gpu() {
    local r kind rec def
    # D3 default order: the resolved value first, then the installed job's value,
    # then system. Ignoring the resolved value would re-ask a value the user has
    # already set (A8a).
    def=${MSS_GPU_PERCENT:-}
    r=$(mss_gpu_job_read); kind=${r%%|*}; rec=${r#*|}
    [ -n "$def" ] || case $kind in
        new|legacy|both) case $rec in [1-9]|[1-9][0-9]|100) def=$rec ;; *) def=system ;; esac ;;
        *) def=system ;;
    esac
    # A Mac without the limit can only answer system, so that is the default.
    _mss_sysctl -n iogpu.wired_limit_mb >/dev/null 2>&1 || def=system
    mss_ask "GPU memory for models (Ollama, llama.cpp, ds4): percent of RAM 1-100, or system" \
        "$def" _mss_pick_gpu_valid
    # `system` is saved as the answer it is. Unsetting the key would save
    # nothing, the apply step would print "left as is", and an installed job
    # would survive the run the user just answered "system" in (#27 r2, blocker 5).
    _mss_pick_set MSS_GPU_PERCENT "$MSS_ANSWER"
}

# P — restart after a power failure. Skipped (and saved nothing) when this Mac
# has no such setting.
_mss_pick_power() {
    local cur
    if ! cur=$(mss_power_current); then
        echo "This Mac has no restart-after-power-failure setting; skipped" >&2
        # A value loaded from backends.env would be saved again and refused by
        # step 2 on every later run, so a skipped P saves nothing.
        unset MSS_POWER_AUTORESTART
        return 0
    fi
    local def=N
    case ${MSS_POWER_AUTORESTART:-} in yes) def=Y ;; no) def=N ;; *) [ "$cur" = 1 ] && def=Y ;; esac
    mss_ask_yn "Start this Mac automatically after a power failure?" "$def"
    if [ "$MSS_ANSWER" = y ]; then _mss_pick_set MSS_POWER_AUTORESTART yes
    else _mss_pick_set MSS_POWER_AUTORESTART no; fi
}

# DI — install Colima / the Docker CLI with Homebrew. The picker installs
# nothing; install.sh does after confirmation (D7 step 6).
_mss_pick_docker_install() {
    # A tool the caller can run but the boot job cannot: asking about Docker
    # would save a yes that step 2 refuses on every later run, so both Docker
    # keys are dropped and neither question is asked (#27 r2 finding 1).
    # The helper returns 0 when such a tool exists and 1 when every Docker choice
    # is appliable, so the skip is the 0 branch. Negating it dropped both
    # questions on every ordinary Mac (#27 r3, blocker).
    local out
    if out=$(_mss_docker_outside_job_path); then
        echo "${out%% *} is at ${out#* }, outside the boot job's PATH; move or link it into /opt/homebrew/bin or /usr/local/bin" >&2
        unset MSS_DOCKER_INSTALL MSS_DOCKER_AUTOSTART
        return 1
    fi
    if ! _mss_docker_missing; then
        echo "Colima and the Docker CLI are installed" >&2
        return 0
    fi
    local def=N names
    [ "${MSS_DOCKER_INSTALL:-}" != yes ] || def=Y
    if [ -n "$(_mss_job_tool colima)" ]; then names="the Docker CLI"
    elif [ -n "$(_mss_job_tool docker)" ]; then names="Colima"
    else names="Colima and the Docker CLI"; fi
    mss_ask_yn "Install $names with Homebrew?" "$def"
    if [ "$MSS_ANSWER" = y ] && ! _mss_pick_need_brew; then
        echo "Without Homebrew the install can't run; Docker won't be installed." >&2
        _mss_pick_set MSS_DOCKER_INSTALL no
        return 0
    fi
    if [ "$MSS_ANSWER" = y ]; then _mss_pick_set MSS_DOCKER_INSTALL yes
    else _mss_pick_set MSS_DOCKER_INSTALL no; fi
}

# DA — start Colima at every boot. Only shown once both tools are present or
# DI was answered yes; when skipped, MSS_DOCKER_AUTOSTART stays unset.
_mss_pick_docker_autostart() {
    # DI returned 1 because a Docker tool sits outside the boot job's PATH.
    [ "${1:-}" = skipped ] && return 0
    if _mss_docker_missing && [ "${MSS_DOCKER_INSTALL:-}" != yes ]; then
        # D3: a skipped DA leaves autostart as it is. A loaded yes would be saved
        # again and refused by step 2 on every later run.
        unset MSS_DOCKER_AUTOSTART
        return 0
    fi
    local def=N
    if [ -f "$(mss_daemon_dir)/$MSS_DOCKER_LABEL.plist" ]; then def=Y; fi
    case ${MSS_DOCKER_AUTOSTART:-} in yes) def=Y ;; no) def=N ;; esac
    local now=off
    _mss_gpu_loaded "$MSS_DOCKER_LABEL" && now=on
    mss_ask_yn "Start Colima (Docker) at every boot? Currently $now." "$def"
    if [ "$MSS_ANSWER" = y ]; then _mss_pick_set MSS_DOCKER_AUTOSTART yes
    else _mss_pick_set MSS_DOCKER_AUTOSTART no; fi
}

_mss_pick_host_choices() {
    _mss_pick_gpu
    _mss_pick_power
    if _mss_pick_docker_install; then
        _mss_pick_docker_autostart
    else
        _mss_pick_docker_autostart skipped
    fi
}

# ── MLX-Serve (#1 D8) ──────────────────────────────────────────────────────────
# A saved or found mlx-serve is used when it is exactly the pinned version. A
# different version is named and the path asked; with none found, Homebrew is
# offered. The model is a native MLX checkpoint directory, from the MLX model
# chooser (#35). _mss_pick_backend asks the LAN questions and keeps the port,
# as for ds4 (#33 D2).
_mss_pick_mlx() {
    local found bin="" mism=0
    found=$(printenv MLX_BIN)
    [ -n "$found" ] || found=$(command -v mlx-serve 2>/dev/null)
    if [ -n "$found" ]; then
        if _mss_pick_mlx_bin_valid "$found"; then
            bin=$found
            echo "Using mlx-serve: $found" >&2
        else
            mism=1
        fi
    fi
    if [ -z "$bin" ] && [ "$mism" = 0 ]; then
        if _mss_pick_need_brew; then
            echo "mlx-serve comes from a Homebrew tap: $(mss_mlx_brew_cmd)" >&2
            mss_ask_yn "Install mlx-serve with Homebrew?" N
            if [ "$MSS_ANSWER" = y ] && mss_acquire_mlx_brew && _mss_pick_mlx_bin_valid "$MLX_BIN"; then
                bin=$MLX_BIN
            fi
        fi
        [ -n "$bin" ] || echo "manual: $(mss_mlx_brew_cmd)" >&2
    fi
    if [ -z "$bin" ]; then
        mss_ask "mlx-serve $MSS_MLX_SERVE_VERSION binary path" "" _mss_pick_mlx_bin_valid
        bin=$MSS_ANSWER
    fi
    _mss_pick_set MLX_BIN "$bin"
    _mss_pick_mlx_model
}

# The MLX model chooser (#35): the saved directory, the pinned starter download,
# complete checkpoints found on disk, or any directory. Enter keeps a usable
# saved directory and takes the starter only when nothing else exists; with
# checkpoints found there is no default, so Enter never downloads. A declined
# or failed download comes back here. Nothing here runs mlx-serve, loads a
# model or touches a service.
_mss_pick_mlx_model() {
    local saved reason starter="" out line found="" skipped=0 total=0 more=0 n=0 def="" choice i
    local keep_n=0 dl_n=0 dir_n first_n rows="" path tab
    tab=$(printf '\t')
    saved=$(printenv MLX_MODEL_DIR)
    if [ -n "$saved" ] && ! reason=$(_mss_pick_mlx_dir_valid "$saved" 2>&1 >/dev/null); then
        reason=$(printf '%s\n' "$reason" | head -n 1)
        echo "saved MLX_MODEL_DIR $saved is not usable: ${reason#ERROR: }" >&2
        saved=""
    fi
    mss_mlx_catalog_check && starter=$(mss_mlx_catalog_ids starter | head -n 1)
    # Found checkpoints, each once (the saved one is the keep row), shown as
    # found, sorted by that and capped at 8 rows; a row saves the resolved path.
    out=$(mss_mlx_find_models)
    while IFS= read -r line; do
        case $line in
            "found "*)
                path=${line#found }; path=${path%% *}
                if [ -n "$saved" ] && [ "$path" = "$(mss_resolve_path "$saved" 2>/dev/null)" ]; then continue; fi
                found="$found$(_mss_pick_tilde "${line#found "$path" }")$tab$path
" ;;
            "skipped "*) skipped=${line#skipped } ;;
        esac
    done <<MSS_FOUND_EOF
$out
MSS_FOUND_EOF
    found=$(printf '%s' "$found" | LC_ALL=C sort -t "$tab" -k 1,1)
    [ -z "$found" ] || total=$(printf '%s\n' "$found" | grep -c .)
    [ "$total" -le 8 ] || { more=$((total - 8)); found=$(printf '%s\n' "$found" | head -n 8); }
    [ "$skipped" = 0 ] || echo "skipped $skipped unusable checkpoint directories" >&2

    if [ -n "$saved" ]; then
        n=$((n + 1)); keep_n=$n; def=$n
        rows="$rows  $n) keep $(_mss_pick_tilde "$saved") (saved)
"
    fi
    if [ -n "$starter" ]; then
        n=$((n + 1)); dl_n=$n
        rows="$rows  $n) download $starter, $(mss_human_size "$(mss_mlx_catalog_total "$starter")") (small starter: checks the install, not for production use)
"
        [ -n "$def" ] || [ -n "$found" ] || def=$n
    fi
    first_n=$((n + 1))
    while IFS=$tab read -r line path; do
        [ -n "$path" ] || continue
        n=$((n + 1))
        rows="$rows  $n) $line (found)
"
    done <<MSS_FOUND_EOF
$found
MSS_FOUND_EOF
    [ "$more" = 0 ] || rows="$rows  $more more found: use \"another directory\"
"
    n=$((n + 1)); dir_n=$n
    rows="$rows  $n) another directory
"
    while :; do
        echo "mlx model (a native MLX checkpoint directory):" >&2
        printf '%s' "$rows" >&2
        MSS_PICK_MENU_MAX=$n
        mss_ask "mlx model" "$def" _mss_pick_num_valid
        choice=$MSS_ANSWER
        if [ "$choice" = "$keep_n" ]; then
            _mss_pick_set MLX_MODEL_DIR "$saved"
            return 0
        elif [ "$choice" = "$dl_n" ]; then
            if mss_acquire_mlx_model "$starter"; then
                _mss_pick_set MLX_MODEL_DIR "$MSS_MLX_ACQUIRED"
                return 0
            fi
        elif [ "$choice" = "$dir_n" ]; then
            mss_ask "MLX model directory (config.json and *.safetensors)" "$(printenv MLX_MODEL_DIR)" _mss_pick_mlx_dir_valid
            _mss_pick_set MLX_MODEL_DIR "$MSS_ANSWER"
            return 0
        else
            i=$((choice - first_n + 1))
            path=$(printf '%s\n' "$found" | sed -n "${i}p" | cut -f 2)
            _mss_pick_set MLX_MODEL_DIR "$path"
            return 0
        fi
    done
}

# ── the active optional backend (#1 D8 step 4) ─────────────────────────────────
# Asked only with two or more optional backends: which one runs now, or none.
_mss_pick_active() {
    local opts=$1 current=$2 b n=0 line def=1 choice
    line="Which optional backend should run now?"
    for b in $opts; do
        n=$((n + 1))
        line="$line $n) $b"
        [ "$b" != "$current" ] || def=$n
    done
    n=$((n + 1))
    line="$line $n) none"
    [ "$current" != none ] || def=$n
    MSS_PICK_MENU_MAX=$n
    mss_ask "$line" "$def" _mss_pick_num_valid
    choice=$MSS_ANSWER
    n=0
    for b in $opts none; do
        n=$((n + 1))
        [ "$n" = "$choice" ] && { _mss_pick_set MSS_ACTIVE_BACKEND "$b"; return 0; }
    done
}

# ── summary ────────────────────────────────────────────────────────────────────
_mss_pick_summary() {
    local sel=$1 active=$2 remove=$3 b P state
    echo >&2
    echo "Selection: $sel" >&2
    case ",$sel," in
        *,ollama,*)
            echo "  ollama: the Ollama service is (re)installed; it restarts only when its plist changes" >&2
            [ -z "$(printenv OLLAMA_BIN)" ] || echo "  ollama binary: $(printenv OLLAMA_BIN)" >&2
            ;;
    esac
    echo "  headless tweaks: $(printenv MSS_TUNE_MACOS)" >&2
    mss_gpu_summary_line "$(printenv MSS_GPU_PERCENT)" >&2
    mss_power_summary_line >&2
    mss_docker_install_summary_line >&2
    mss_docker_autostart_summary_line >&2
    # One line per optional backend: active or standby, binary, model, address.
    for b in $(mss_optional_backends "$sel"); do
        P=$(mss_prefix "$b")
        [ "$b" = "$active" ] && state=active || state=standby
        # mlx has a model directory and no sha256; like the others, it shows
        # its allowed clients when it is LAN-bound.
        if [ "$b" = mlx ]; then
            echo "  mlx: $state, $(printenv MLX_BIN), $(printenv MLX_MODEL_DIR), $(printenv MLX_HOST):$(printenv MLX_PORT)" >&2
        elif [ "$(printenv MSS_DEFER_MODEL)" = yes ]; then
            echo "  $b: $state, $(printenv "${P}_BIN"), model later (scripts/model.sh), $(printenv "${P}_HOST"):$(printenv "${P}_PORT")" >&2
        else
            echo "  $b: $state, $(printenv "${P}_BIN"), $(printenv "${P}_MODEL"), $(printenv "${P}_HOST"):$(printenv "${P}_PORT")" >&2
            echo "    sha256: $(printenv "${P}_MODEL_SHA256")" >&2
        fi
        if ! mss_is_loopback_host "$(printenv "${P}_HOST")"; then
            [ -z "$(printenv "${P}_ALLOW_FROM")" ] || echo "    allowed: $(printenv "${P}_ALLOW_FROM")" >&2
            [ "$b" != llamacpp ] || [ -z "$(printenv LLAMACPP_API_KEY_FILE)" ] \
                || echo "    key file: $(printenv LLAMACPP_API_KEY_FILE)" >&2
        fi
    done
    [ -z "$remove" ] || echo "  remove after the check: $remove" >&2
    echo >&2
}

# mss_picker_run <env file> <installed selection> <installed optional> <configure-only 0|1>
# Asks, confirms and saves the file. Exits on a declined confirmation.
mss_picker_run() {
    local file=$1 installed_sel=$2 installed_opt=$3 only=$4
    local env_sel env_active def num sel b opts n installed current remove=""
    mss_pick_trap

    # Environment values are the defaults, ahead of the saved file.
    env_sel=$(printenv MSS_BACKENDS)
    env_active=$(printenv MSS_ACTIVE_BACKEND)
    if [ -e "$file" ] || [ -L "$file" ]; then
        mss_envfile_load "$file" || exit 1
    fi

    # D1: resolve the legacy choice keys before the first question, but only
    # after the saved file is loaded. Resolving first would mark the run
    # resolved, and the later resolve in install.sh would hit its early return:
    # the file's legacy GPU key would then vanish with no notice, no conflict,
    # and nothing saved (#27 r2).
    mss_choices_resolve || exit 1

    # 1. menu: the default comes from the environment, the installed conf,
    #    the saved file, then 1.
    def=$(_mss_pick_sel_to_num "$env_sel")
    [ -n "$def" ] || def=$(_mss_pick_sel_to_num "$installed_sel")
    [ -n "$def" ] || def=$(_mss_pick_sel_to_num "$(printenv MSS_BACKENDS)")
    [ -n "$def" ] || def=1
    echo "Which backends should this Mac run? (numbers, comma-separated)" >&2
    echo "  1) ollama" >&2
    echo "  2) llama.cpp" >&2
    echo "  3) ds4" >&2
    echo "  4) mlx (MLX-Serve)" >&2
    mss_ask "Choose" "$def" _mss_pick_menu_valid
    num=$MSS_ANSWER
    sel=$(_mss_pick_num_to_sel "$num")

    # 2. an installed optional backend left out is removed only on a y.
    installed=$(mss_optional_backends "$installed_sel")
    if [ -n "$installed_opt" ]; then
        case " $installed " in *" $installed_opt "*) ;; *) installed="$installed $installed_opt" ;; esac
    fi
    for b in $installed; do
        case ",$sel," in *",$b,"*) continue ;; esac
        mss_ask_yn "$b is installed. Remove it now with sudo scripts/uninstall.sh --backend $b? Its model files and saved answers are kept." N
        if [ "$MSS_ANSWER" = y ]; then
            # shellcheck disable=SC2034  # read by install.sh
            MSS_PICKER_REPLACE=${MSS_PICKER_REPLACE:+$MSS_PICKER_REPLACE,}$b
            if [ "$only" != 1 ]; then
                # shellcheck disable=SC2034  # read by install.sh
                MSS_SWITCH_FROM=${MSS_SWITCH_FROM:+$MSS_SWITCH_FROM,}$b
                remove="${remove:+$remove }$b"
            fi
        else
            sel=$(_mss_pick_sel_add "$sel" "$b")
            echo "kept installed: $b" >&2
        fi
    done
    mss_validate_selection "$sel" || exit 1
    _mss_pick_set MSS_BACKENDS "$sel"
    opts=$(mss_optional_backends "$sel")
    n=$(mss_count_words "$opts")
    [ "$n" -lt 2 ] || MSS_PICK_LATER=0
    # A model "later" is single-backend only; a saved one is cleared here.
    [ "$n" -lt 2 ] || _mss_pick_set MSS_DEFER_MODEL ""

    # 3. each optional backend, in menu order
    case ",$sel," in *,ollama,*) _mss_pick_ollama ;; esac
    for b in $opts; do _mss_pick_backend "$b"; done

    # 4. which optional backend runs now
    if [ "$n" -ge 2 ]; then
        current=$env_active
        [ -n "$current" ] || current=$(printenv MSS_ACTIVE_BACKEND)
        [ -n "$current" ] || current=$installed_opt
        _mss_pick_active "$opts" "$current"
    else
        _mss_pick_set MSS_ACTIVE_BACKEND ""
    fi
    _mss_pick_tweaks

    # 5. host choices (#27), then the summary and confirmation
    _mss_pick_host_choices
    _mss_pick_summary "$sel" "$(mss_active_backend "$sel" "$(printenv MSS_ACTIVE_BACKEND)" 2>/dev/null)" "$remove"
    if [ "$only" = 1 ]; then
        mss_ask_yn "Save?" Y
    else
        mss_ask_yn "Install with these settings?" Y
    fi
    if [ "$MSS_ANSWER" != y ]; then
        echo "install.sh: not confirmed; nothing was saved or changed" >&2
        exit 1
    fi

    # 6. save; the final root pass saves the installed answers again under its lock.
    mss_envfile_write "$file" || exit 1
    echo "Saved $file" >&2
    trap 'exit 130' INT
}
