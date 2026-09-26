#!/bin/bash
# mss-picker.sh — interactive backend picker for scripts/install.sh (#12).
#
# Sourced by install.sh after mss-common.sh. bash 3.2 compatible (macOS ships
# it): no associative arrays, no case-conversion expansions, no mapfile.
# Prompts go to stderr, answers come from stdin. Every answer goes through the
# same validators the installer uses; nothing is written until the summary is
# confirmed.
#
# Results, as exported variables for the rest of install.sh:
#   MSS_BACKENDS and the chosen backend's *_BIN/_MODEL/_MODEL_SHA256/_HOST/
#   _PORT/_ALLOW_FROM (and LLAMACPP_API_KEY_FILE)
#   MSS_PICKER_REPLACE  installed backend the check may look through
#   MSS_SWITCH_FROM     installed backend to uninstall after the check passes

# shellcheck disable=SC2034  # both are read by install.sh after the picker
MSS_PICKER_REPLACE=""
# shellcheck disable=SC2034
MSS_SWITCH_FROM=""

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

_mss_pick_port_valid() {
    mss_validate_port "port" "$1" || return 1
    [ "$1" != 11434 ] || { mss_error "11434 is Ollama's port"; return 1; }
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

# ── the optional backend's questions ───────────────────────────────────────────
_mss_pick_backend() {
    local b=$1 P label def resolved sha lan host addrs first key
    case $b in
        llamacpp) P=LLAMACPP; label="llama.cpp llama-server" ;;
        ds4) P=DS4; label="DwarfStar ds4-server" ;;
    esac

    # 2. binary
    def=$(printenv "${P}_BIN")
    if [ -z "$def" ] && [ "$b" = llamacpp ]; then def=$(command -v llama-server 2>/dev/null); fi
    mss_ask "$label binary path" "$def" _mss_pick_bin_valid
    _mss_pick_set "${P}_BIN" "$MSS_ANSWER"

    # 3. model
    mss_ask "Model file (.gguf) path" "$(printenv "${P}_MODEL")" _mss_pick_model_valid
    _mss_pick_set "${P}_MODEL" "$MSS_ANSWER"
    resolved=$(mss_resolve_path "$MSS_ANSWER")

    # 4. sha256. A saved value is kept with Enter; hashing is offered only on
    #    request, because it reads the whole model file.
    def=$(printenv "${P}_MODEL_SHA256")
    sha=""
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

    # 6. port
    def=$(printenv "${P}_PORT")
    if [ -z "$def" ]; then
        [ "$b" = llamacpp ] && def=8080 || def=8000
    fi
    mss_ask "Port" "$def" _mss_pick_port_valid
    _mss_pick_set "${P}_PORT" "$MSS_ANSWER"
}

# ── summary ────────────────────────────────────────────────────────────────────
_mss_pick_summary() {
    local sel=$1 b=$2 P
    echo >&2
    echo "Selection: $sel" >&2
    case ",$sel," in
        *,ollama,*) echo "  ollama: the Ollama service is (re)installed and restarted" >&2 ;;
    esac
    if [ -n "$b" ]; then
        case $b in llamacpp) P=LLAMACPP ;; ds4) P=DS4 ;; esac
        echo "  $b binary:  $(printenv "${P}_BIN")" >&2
        echo "  $b model:   $(printenv "${P}_MODEL")" >&2
        echo "  $b sha256:  $(printenv "${P}_MODEL_SHA256")" >&2
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

    [ -z "$b" ] || _mss_pick_backend "$b"

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
    trap - INT
}
