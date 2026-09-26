#!/bin/bash
# mss-picker.sh — interactive backend picker for scripts/install.sh (#12, #15).
#
# Sourced by install.sh and model.sh after mss-common.sh and mss-acquire.sh.
# bash 3.2 compatible (macOS ships it): no bash 4 builtins or expansions (the CI
# step lists them). Prompts go to stderr, answers come from stdin. Every answer
# goes through the same validators the installer uses; backends.env is written
# only after the summary is confirmed. Installs, builds and downloads run only
# after a y (the model menu's starter is the one default-yes), as the user.
#
# Results, as exported variables for the rest of install.sh:
#   MSS_BACKENDS, OLLAMA_BIN, MSS_TUNE_MACOS, MSS_DEFER_MODEL and the chosen
#   backend's *_BIN/_MODEL/_MODEL_SHA256/_HOST/_PORT/_ALLOW_FROM (and
#   LLAMACPP_API_KEY_FILE)
#   MSS_PICKER_REPLACE  installed backend the check may look through
#   MSS_SWITCH_FROM     installed backend to uninstall after the check passes
#   MSS_DOWNLOADED      a model file downloaded in this run

# shellcheck disable=SC2034  # both are read by install.sh after the picker
MSS_PICKER_REPLACE=""
# shellcheck disable=SC2034
MSS_SWITCH_FROM=""
MSS_PICK_BREW_ASKED=0
MSS_PICK_DS4_BUILT=""

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
_mss_pick_menu_valid() {
    case $1 in [1-5]) return 0 ;; esac
    mss_error "choose 1, 2, 3, 4 or 5"
    return 1
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

# A menu answer between 1 and MSS_PICK_MENU_MAX.
_mss_pick_num_valid() {
    case $1 in [1-9]) [ "$1" -le "$MSS_PICK_MENU_MAX" ] && return 0 ;; esac
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
_mss_pick_sel_to_num() {
    case $1 in
        ollama) echo 1 ;;
        ollama,llamacpp|llamacpp,ollama) echo 2 ;;
        ollama,ds4|ds4,ollama) echo 3 ;;
        llamacpp) echo 4 ;;
        ds4) echo 5 ;;
        *) echo "" ;;
    esac
}

_mss_pick_num_to_sel() {
    case $1 in
        1) echo ollama ;;
        2) echo ollama,llamacpp ;;
        3) echo ollama,ds4 ;;
        4) echo llamacpp ;;
        5) echo ds4 ;;
    esac
}

_mss_pick_optional_of() {
    case ",$1," in
        *,llamacpp,*) echo llamacpp ;;
        *,ds4,*) echo ds4 ;;
        *) echo "" ;;
    esac
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
    [ ! -x /usr/local/bin/ollama ] || return 0
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
            if sha=$(shasum -a 256 "$resolved" 2>/dev/null | awk '{print $1}') && [ -n "$sha" ]; then
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
    mss_pick_model_menu "$b" 1
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
    esac

    # 2. binary, 3. model (the checksum comes from the catalogue or the user)
    _mss_pick_binary "$b" "$P" "$label"
    _mss_pick_model "$b" "$P"

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
    if [ -z "$def" ]; then
        [ "$b" = llamacpp ] && def=8080 || def=8000
    fi
    _mss_pick_set "${P}_PORT" "$def"
}

# Headless macOS tweaks (I2), asked once and saved.
_mss_pick_tweaks() {
    local def=N
    [ "$(printenv MSS_TUNE_MACOS)" != yes ] || def=Y
    mss_ask_yn "Apply headless macOS tweaks (no sleep, Spotlight, Time Machine, auto-updates)?" "$def"
    if [ "$MSS_ANSWER" = y ]; then _mss_pick_set MSS_TUNE_MACOS yes; else _mss_pick_set MSS_TUNE_MACOS no; fi
}

# ── summary ────────────────────────────────────────────────────────────────────
_mss_pick_summary() {
    local sel=$1 b=$2 P
    echo >&2
    echo "Selection: $sel" >&2
    case ",$sel," in
        *,ollama,*)
            echo "  ollama: the Ollama service is (re)installed and restarted" >&2
            [ -z "$(printenv OLLAMA_BIN)" ] || echo "  ollama binary: $(printenv OLLAMA_BIN)" >&2
            echo "  headless tweaks: $(printenv MSS_TUNE_MACOS)" >&2
            ;;
    esac
    if [ -n "$b" ]; then
        P=$(mss_prefix "$b")
        echo "  $b binary:  $(printenv "${P}_BIN")" >&2
        if [ "$(printenv MSS_DEFER_MODEL)" = yes ]; then
            echo "  $b model:   later (scripts/model.sh)" >&2
        else
            echo "  $b model:   $(printenv "${P}_MODEL")" >&2
            echo "  $b sha256:  $(printenv "${P}_MODEL_SHA256")" >&2
        fi
        echo "  $b listens: $(printenv "${P}_HOST"):$(printenv "${P}_PORT")" >&2
        if ! mss_is_loopback_host "$(printenv "${P}_HOST")"; then
            [ -z "$(printenv "${P}_ALLOW_FROM")" ] || echo "  allowed:   $(printenv "${P}_ALLOW_FROM")" >&2
            [ "$b" != llamacpp ] || [ -z "$(printenv LLAMACPP_API_KEY_FILE)" ] \
                || echo "  key file:  $(printenv LLAMACPP_API_KEY_FILE)" >&2
        fi
    fi
    echo >&2
}

# mss_picker_run <env file> <installed selection> <installed optional> <configure-only 0|1>
# Asks, confirms, handles the switch question and saves the file. Exits on a
# declined confirmation or a declined switch.
mss_picker_run() {
    local file=$1 installed_sel=$2 installed_opt=$3 only=$4
    local env_sel def num sel b
    mss_pick_trap

    # Environment values are the defaults, ahead of the saved file.
    env_sel=$(printenv MSS_BACKENDS)
    if [ -e "$file" ] || [ -L "$file" ]; then
        mss_envfile_load "$file" || exit 1
    fi

    # 1. menu
    def=$(_mss_pick_sel_to_num "$env_sel")
    [ -n "$def" ] || def=$(_mss_pick_sel_to_num "$installed_sel")
    [ -n "$def" ] || def=$(_mss_pick_sel_to_num "$(printenv MSS_BACKENDS)")
    [ -n "$def" ] || def=1
    echo "Which backends should this Mac run?" >&2
    echo "  1) ollama" >&2
    echo "  2) ollama + llama.cpp" >&2
    echo "  3) ollama + ds4" >&2
    echo "  4) llama.cpp only" >&2
    echo "  5) ds4 only" >&2
    mss_ask "Choose" "$def" _mss_pick_menu_valid
    num=$MSS_ANSWER
    sel=$(_mss_pick_num_to_sel "$num")
    mss_validate_selection "$sel" || exit 1
    _mss_pick_set MSS_BACKENDS "$sel"
    b=$(_mss_pick_optional_of "$sel")

    case ",$sel," in *,ollama,*) _mss_pick_ollama ;; esac
    [ -z "$b" ] || _mss_pick_backend "$b"
    case ",$sel," in *,ollama,*) _mss_pick_tweaks ;; esac

    # 7. summary and confirmation
    _mss_pick_summary "$sel" "$b"
    if [ "$only" = 1 ]; then
        mss_ask_yn "Save?" Y
    else
        mss_ask_yn "Install with these settings?" Y
    fi
    if [ "$MSS_ANSWER" != y ]; then
        echo "install.sh: not confirmed; nothing was saved or changed" >&2
        exit 1
    fi

    # Switching: the installed optional backend differs from the new choice.
    if [ -n "$installed_opt" ] && [ "$installed_opt" != "$b" ]; then
        # shellcheck disable=SC2034  # read by install.sh
        MSS_PICKER_REPLACE=$installed_opt
        if [ "$only" != 1 ]; then
            mss_ask_yn "$installed_opt is installed. Remove it first with sudo scripts/uninstall.sh --backend $installed_opt?" N
            if [ "$MSS_ANSWER" != y ]; then
                mss_envfile_write "$file" || exit 1
                echo "Saved $file. Nothing was installed: $installed_opt is still installed." >&2
                exit 1
            fi
            # shellcheck disable=SC2034  # read by install.sh
            MSS_SWITCH_FROM=$installed_opt
        fi
    fi

    mss_envfile_write "$file" || exit 1
    echo "Saved $file" >&2
    trap 'exit 130' INT
}
