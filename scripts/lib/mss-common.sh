#!/bin/sh
# mss-common.sh — shared validation, resolution and rendering helpers for
# mac-studio-server 1.3.0 (issue #9).
#
# POSIX sh, BSD userland only (BSD stat/shasum/readlink/date spellings).
# Root-run scripts that source this file never use tilde paths or HOME.

# ── errors ─────────────────────────────────────────────────────────────────────
mss_error() { echo "ERROR: $*" >&2; }
mss_die()   { mss_error "$@"; exit 1; }

# ── sha256 ─────────────────────────────────────────────────────────────────────
# shasum is Perl, and Perl fails on an inherited locale it cannot load (an SSH
# session with C.UTF-8). LC_ALL=C for this one call; the digest is the same.
mss_shasum256() { LC_ALL=C shasum -a 256 "$@"; }

# mss_match <value> <ERE>: the whole value must be one line matching ERE.
# grep matches line by line, so a value carrying a newline could otherwise pass
# on its first line and inject a second line into backends.conf.
_mss_nl='
'
_mss_cr=$(printf '\r')
mss_match() {
    case ${1:-} in *"$_mss_nl"*|*"$_mss_cr"*) return 1 ;; esac
    printf '%s\n' "${1:-}" | grep -Eq "$2"
}

# ── backend selection ──────────────────────────────────────────────────────────
# Valid: ollama, llamacpp, ds4, ollama,llamacpp, ollama,ds4. Rejects unknown
# names, duplicates, empty, "llamacpp,ds4" and all three.
mss_validate_selection() {
    _value=${1:-}
    [ -n "$_value" ] || { mss_error "MSS_BACKENDS is empty"; return 1; }
    _has_ollama=0; _has_llamacpp=0; _has_ds4=0
    _oldifs=$IFS
    IFS=,
    for _name in $_value; do
        case $_name in
            ollama)   [ "$_has_ollama" -eq 1 ]   && { IFS=$_oldifs; mss_error "MSS_BACKENDS: duplicate '$_name'"; return 1; }
                      _has_ollama=1 ;;
            llamacpp) [ "$_has_llamacpp" -eq 1 ] && { IFS=$_oldifs; mss_error "MSS_BACKENDS: duplicate '$_name'"; return 1; }
                      _has_llamacpp=1 ;;
            ds4)      [ "$_has_ds4" -eq 1 ]      && { IFS=$_oldifs; mss_error "MSS_BACKENDS: duplicate '$_name'"; return 1; }
                      _has_ds4=1 ;;
            *) IFS=$_oldifs; mss_error "MSS_BACKENDS: unknown backend '$_name'"; return 1 ;;
        esac
    done
    IFS=$_oldifs
    _optional=$(( _has_llamacpp + _has_ds4 ))
    [ "$_optional" -le 1 ] || { mss_error "MSS_BACKENDS: at most one optional backend (llamacpp,ds4 is invalid)"; return 1; }
    return 0
}

mss_backend_selected() { case ",${MSS_BACKENDS:-ollama}," in *",$1,"*) return 0 ;; esac; return 1; }

# ── IPv4 / CIDR / host ─────────────────────────────────────────────────────────
# Dotted quad, each octet 0..255 with no leading zeros (010 is ambiguous).
mss_validate_ipv4() {
    mss_match "${1:-}" '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' || return 1
    printf '%s\n' "$1" | awk -F. '$1<=255 && $2<=255 && $3<=255 && $4<=255 { exit 0 } { exit 1 }'
}

# An IPv4 address or CIDR. The prefix is 1..32: /0 would allow everything.
mss_validate_cidr_entry() {
    _e=${1:-}
    case $_e in
        */*)
            mss_validate_ipv4 "${_e%/*}" || return 1
            _len=${_e##*/}
            mss_match "$_len" '^[1-9][0-9]?$' || return 1
            [ "$_len" -le 32 ]
            ;;
        *) mss_validate_ipv4 "$_e" ;;
    esac
}

# Split an allowlist variable on whitespace and validate every entry.
mss_validate_allowlist() {
    _var=$1; _value=${2:-}
    [ -z "$_value" ] && return 0
    for _entry in $_value; do
        mss_validate_cidr_entry "$_entry" || { mss_error "$_var: invalid IPv4/CIDR entry '$_entry'"; return 1; }
    done
    return 0
}

# Is HOST an address assigned to a local interface? (ifconfig parse; override
# the binary via MSS_IFCONFIG in render-only tests.)
mss_host_is_local() {
    _host=${1:-127.0.0.1}
    mss_is_loopback_host "$_host" && return 0
    _ifconfig=${MSS_IFCONFIG:-/sbin/ifconfig}
    "$_ifconfig" 2>/dev/null | grep -Eq "inet[[:space:]]+$_host([[:space:]]|\$)"
}

mss_is_loopback_host() {
    case ${1:-} in
        127.0.0.1|localhost) return 0 ;;
        *) echo "${1:-}" | grep -Eq '^127\.' && return 0 ;;
    esac
    return 1
}

mss_validate_host() {
    _var=$1; _host=${2:-}
    [ -n "$_host" ] || { mss_error "$_var is empty"; return 1; }
    case $_host in *:*) mss_error "$_var: IPv6 is not supported"; return 1 ;; esac
    mss_validate_ipv4 "$_host" || { mss_error "$_var: '$_host' must be a single IPv4 address"; return 1; }
    return 0
}

# ── ports and integers ─────────────────────────────────────────────────────────
mss_validate_port() {
    _var=$1; _port=${2:-}
    mss_match "$_port" '^[0-9]+$' || { mss_error "$_var: '$_port' is not a number"; return 1; }
    [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] || { mss_error "$_var: '$_port' out of range"; return 1; }
}

# mss_validate_uint <var> <value> <min> [max]: decimal integer in range.
mss_validate_uint() {
    _var=$1; _v=${2:-}; _min=$3; _max=${4:-}
    mss_match "$_v" '^[0-9]{1,9}$' || { mss_error "$_var: '$_v' is not a non-negative integer"; return 1; }
    [ "$_v" -ge "$_min" ] || { mss_error "$_var: '$_v' is below $_min"; return 1; }
    [ -z "$_max" ] || [ "$_v" -le "$_max" ] || { mss_error "$_var: '$_v' is above $_max"; return 1; }
    return 0
}

# ── users and paths ────────────────────────────────────────────────────────────
# Service user: a plain macOS short name, never root.
mss_validate_user() {
    _var=$1; _u=${2:-}
    mss_match "$_u" '^[A-Za-z_][A-Za-z0-9_.-]{0,31}$' || { mss_error "$_var: '$_u' is not a valid user name"; return 1; }
    [ "$_u" != root ] || { mss_error "$_var: the service user must not be root (set OLLAMA_USER)"; return 1; }
    return 0
}

# Absolute path with no whitespace or shell/sed/plist metacharacters. Paths are
# written into backends.conf, the space-separated model stamp and sed-rendered
# plists, so anything outside this set is refused rather than escaped.
mss_validate_path_chars() {
    _var=$1; _path=${2:-}
    mss_match "$_path" '^/[A-Za-z0-9._/+@:,=-]*$' \
        || { mss_error "$_var: '$_path' must be an absolute path without spaces or special characters"; return 1; }
}

# ── sha256 / key file ──────────────────────────────────────────────────────────
mss_validate_sha256() {
    mss_match "${2:-}" '^[0-9a-fA-F]{64}$' || { mss_error "$1: not a 64-hex sha256"; return 1; }
}

mss_validate_key_file() {
    _var=$1; _file=${2:-}; _user=${3:-}
    [ -n "$_file" ] || return 0
    [ -f "$_file" ] || { mss_error "$_var: key file '$_file' does not exist"; return 1; }
    _owner=$(stat -f '%Su' "$_file")
    _mode=$(stat -f '%Lp' "$_file")
    [ "$_owner" = "$_user" ] || { mss_error "$_var: key file must be owned by $_user, is $_owner"; return 1; }
    case $_mode in
        600|400) ;;
        *) mss_error "$_var: key file mode must be 0600 or 0400, is $_mode"; return 1 ;;
    esac
    return 0
}

# ── path resolution (install-time only, one hop at a time) ───────────────────
mss_resolve_path() {
    _p=${1:-}
    case $_p in
        /*) ;;
        '') mss_error "path is empty"; return 1 ;;
        *)  mss_error "path '$_p' must be absolute"; return 1 ;;
    esac
    _hops=0
    while [ -L "$_p" ]; do
        _hops=$((_hops + 1))
        [ "$_hops" -gt 40 ] && { mss_error "symlink loop resolving '$_p'"; return 1; }
        _target=$(readlink "$_p") || { mss_error "readlink failed for '$_p'"; return 1; }
        case $_target in
            /*) _p=$_target ;;
            *)  _p="$(dirname "$_p")/$_target" ;;
        esac
    done
    _dir=$(cd "$(dirname "$_p")" 2>/dev/null && pwd -P) || { mss_error "parent of '$_p' does not exist"; return 1; }
    _p="$_dir/$(basename "$_p")"
    [ -e "$_p" ] || { mss_error "resolved path '$_p' does not exist"; return 1; }
    printf '%s\n' "$_p"
}

# ── wired limit (same integer formula and evaluation order as
#    scripts/set-gpu-memory.sh) ─────────────────────────────────────────────────
# mss_wired_limit_mb <percent> [memsize-bytes]: the second argument is the test
# hook; unset reads sysctl, which only a Mac answers.
mss_wired_limit_mb() {
    _percent=${1:?percent}
    _total=${2:-$(sysctl -n hw.memsize)}
    # shellcheck disable=SC2017  # must match set-gpu-memory.sh's integer order exactly
    echo $(( _total / 1024 / 1024 * _percent / 100 ))
}

# ── ds4 batched sessions default (#19) ─────────────────────────────────────────
# mss_ds4_default_sessions <hw.memsize bytes>: 4 with 96 GiB or more, else 2.
# One session means a second client evicts the first one's cached prompt.
mss_ds4_default_sessions() {
    if mss_match "${1:-}" '^[0-9]{1,15}$' && [ "$1" -ge 103079215104 ]; then
        echo 4
    else
        echo 2
    fi
}

# ── extra-args allowlist ───────────────────────────────────────────────────────
# Returns "value" | "novalue" | "" (not allowlisted) for a canonical flag.
mss_flag_kind() {
    _backend=$1; _flag=$2
    if [ "$_backend" = llamacpp ]; then
        case $_flag in
            --n-gpu-layers|--threads|--threads-batch|--batch-size|--ubatch-size|\
--cache-reuse|--threads-http|--timeout|--top-k|\
--n-predict|--seed|--reasoning-budget|\
--temp|--top-p|--min-p|--repeat-penalty) echo value; return ;;
            --flash-attn|--cache-type-k|--cache-type-v|--reasoning-format|--alias|--chat-template) echo value; return ;;
            --jinja|--mlock|--no-mmap|--metrics|--no-webui|--cont-batching|--no-cont-batching) echo novalue; return ;;
        esac
    elif [ "$_backend" = ds4 ]; then
        case $_flag in
            --threads|--power|--mixed-prefill-quantum|--mtp-draft|--prefill-chunk) echo value; return ;;
            # --mtp uses the MTP weights embedded in the verified model; the
            # file-loading --mtp-model and --dspark* stay rejected.
            --mtp|--mtp-exact-sampling|--warm-weights) echo novalue; return ;;
        esac
    fi
    echo ""
}

# Canonical ERE for a value-taking flag.
mss_flag_pattern() {
    _backend=$1; _flag=$2
    if [ "$_backend" = llamacpp ]; then
        case $_flag in
            --n-gpu-layers|--threads|--threads-batch|--batch-size|--ubatch-size|\
--cache-reuse|--threads-http|--timeout|--top-k) echo '^[0-9]+$'; return ;;
            --n-predict|--seed|--reasoning-budget) echo '^-?[0-9]+$'; return ;;
            --temp|--top-p|--min-p|--repeat-penalty) echo '^[0-9]+(\.[0-9]+)?$'; return ;;
            --flash-attn) echo '^(on|off|auto)$'; return ;;
            --cache-type-k|--cache-type-v) echo '^(f32|f16|bf16|q8_0|q4_0|q4_1|iq4_nl|q5_0|q5_1)$'; return ;;
            --reasoning-format) echo '^(none|deepseek|deepseek-legacy|auto)$'; return ;;
            --alias|--chat-template) echo '^[A-Za-z0-9._:-]{1,64}$'; return ;;
        esac
    elif [ "$_backend" = ds4 ]; then
        case $_flag in
            --threads|--mixed-prefill-quantum) echo '^[0-9]+$'; return ;;
            --power) echo '^[0-9]+$'; return ;;
            --prefill-chunk) echo '^[1-9][0-9]*$'; return ;;
            --mtp-draft) echo '^[1-3]$'; return ;;
        esac
    fi
    echo ""
}

# Expand a short alias to its canonical long flag.
mss_canonical_flag() {
    _backend=$1; _flag=$2
    if [ "$_backend" = llamacpp ]; then
        case $_flag in
            -ngl) echo --n-gpu-layers ;;
            -t) echo --threads ;;
            -tb) echo --threads-batch ;;
            -b) echo --batch-size ;;
            -ub) echo --ubatch-size ;;
            -to) echo --timeout ;;
            -n) echo --n-predict ;;
            -s) echo --seed ;;
            -fa) echo --flash-attn ;;
            -ctk) echo --cache-type-k ;;
            -ctv) echo --cache-type-v ;;
            *) echo "$_flag" ;;
        esac
    else
        echo "$_flag"
    fi
}

# mss_validate_extra_args <backend> <args-string> <varname>
# Prints the validated tokens, space separated, in input order. Rejects every
# token outside the allowlist, attached short forms, `-short=value` and any
# non-matching value. --power is additionally range-checked 1..100.
mss_validate_extra_args() {
    _backend=$1; _args=${2:-}; _var=${3:-EXTRA_ARGS}
    _out=""
    # shellcheck disable=SC2086  # spec: whitespace split, no quoting
    set -- $_args
    while [ $# -gt 0 ]; do
        _tok=$1
        _inline=""
        _flag=$_tok
        case $_tok in
            --*=*)
                _flag=${_tok%%=*}
                _inline=${_tok#*=}
                ;;
        esac
        _canonical=$(mss_canonical_flag "$_backend" "$_flag")
        _kind=$(mss_flag_kind "$_backend" "$_canonical")
        if [ -z "$_kind" ]; then
            mss_error "$_var: token '$_tok' is not allowlisted for $_backend"
            return 1
        fi
        # Attached short forms (-ngl99, -t8) and `-short=value` never match the
        # alias table, so the allowlist check above rejects them by construction.
        if [ "$_kind" = value ]; then
            if [ -n "$_inline" ]; then
                _value=$_inline
            else
                shift
                [ $# -gt 0 ] || { mss_error "$_var: flag '$_canonical' needs a value"; return 1; }
                _value=$1
            fi
            _pattern=$(mss_flag_pattern "$_backend" "$_canonical")
            mss_match "$_value" "$_pattern" || { mss_error "$_var: value '$_value' for $_canonical does not match $_pattern"; return 1; }
            if [ "$_canonical" = "--power" ]; then
                [ "$_value" -ge 1 ] && [ "$_value" -le 100 ] || { mss_error "$_var: --power must be 1..100"; return 1; }
            fi
            if [ "$_canonical" = "--prefill-chunk" ]; then
                [ "$_value" -ge 512 ] && [ "$_value" -le 65536 ] || { mss_error "$_var: --prefill-chunk must be 512..65536"; return 1; }
            fi
            _out="$_out $_canonical $_value"
        else
            [ -n "$_inline" ] && { mss_error "$_var: flag '$_canonical' takes no value"; return 1; }
            _out="$_out $_canonical"
        fi
        shift
    done
    # trim leading space
    printf '%s\n' "${_out# }"
    return 0
}

# ── Ollama plist render (P3) ───────────────────────────────────────────────────
# mss_render_ollama_plist <template> <user> <bind> <bin>. With the default bin
# /usr/local/bin/ollama the output is byte-identical to the v1.2.0 golden file.
# mss_default_ollama_bin [root-prefix]: the Ollama binary to render when
# OLLAMA_BIN is unset, in the picker's order: /usr/local/bin/ollama (1.3.0's
# path), then the ollama on PATH, then Homebrew's Apple silicon prefix, which a
# sudo PATH can lack. With none found it prints /usr/local/bin/ollama and
# returns 1. The prefix is install.sh's test sandbox; it is empty on a Mac.
mss_default_ollama_bin() {
    _obp=${1:-}
    if [ -x "$_obp/usr/local/bin/ollama" ]; then echo "$_obp/usr/local/bin/ollama"; return 0; fi
    _obf=$(command -v ollama 2>/dev/null) || _obf=""
    case $_obf in /*) if [ -x "$_obf" ]; then echo "$_obf"; return 0; fi ;; esac
    if [ -x "$_obp/opt/homebrew/bin/ollama" ]; then echo "$_obp/opt/homebrew/bin/ollama"; return 0; fi
    echo /usr/local/bin/ollama
    return 1
}

mss_render_ollama_plist() {
    sed -e "s|<OLLAMA_USER>|$2|g" -e "s|<OLLAMA_BIND>|$3|g" -e "s|<OLLAMA_BIN>|$4|g" "$1"
}

# ── one password prompt per run (U1) ──────────────────────────────────────────
# Asks once, then refreshes the sudo timestamp until the run's PID is gone. The
# PID check also ends the loop after an exec, which drops traps.
mss_sudo_keepalive() {
    sudo -v -p '[sudo] password (asked once): ' || { mss_error "sudo failed; nothing was changed"; return 1; }
    MSS_RUN_PID=${MSS_RUN_PID:-$$}
    ( while kill -0 "$MSS_RUN_PID" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) >/dev/null 2>&1 &
    MSS_KEEPALIVE_PID=$!
    trap 'mss_keepalive_stop' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

mss_keepalive_stop() {
    [ -z "${MSS_KEEPALIVE_PID:-}" ] || kill "$MSS_KEEPALIVE_PID" 2>/dev/null
    MSS_KEEPALIVE_PID=""
}

# ── launchd ────────────────────────────────────────────────────────────────────
# mss_launchd_wait_gone <label> <timeout-s>: returns 0 once `launchctl print
# system/<label>` fails, polling every 0.5 s, and 1 if the label is still there
# at the timeout. `launchctl bootout` returns before a running job has exited,
# and bootstrapping the label until then fails with "5: Input/output error"
# (#18). The only signal is launchctl print: pgrep can match unrelated processes.
mss_launchd_wait_gone() {
    _wl=$1; _wt=$2; _wn=0
    while launchctl print "system/$_wl" >/dev/null 2>&1; do
        if [ "$_wn" -ge $((_wt * 2)) ]; then
            mss_error "$_wl did not stop within ${_wt}s"
            return 1
        fi
        [ "$_wn" -gt 0 ] || echo "waiting for $_wl to stop" >&2
        sleep 0.5
        _wn=$((_wn + 1))
    done
    [ "$_wn" -eq 0 ] || echo "$_wl stopped after $(awk -v n="$_wn" 'BEGIN { printf "%g", n / 2 }')s" >&2
    return 0
}

# ── conf file ──────────────────────────────────────────────────────────────────
# Read-only loader for runtime scripts: backends.conf is root:wheel 0644.
mss_conf_path() { printf '%s\n' "${MSS_CONF:-/usr/local/etc/mac-studio-server/backends.conf}"; }

mss_conf_get() {
    _key=$1
    _file=$(mss_conf_path)
    [ -r "$_file" ] || return 1
    awk -F= -v k="$_key" 'index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "$_file"
}

# ── pf rule count ──────────────────────────────────────────────────────────────
# mss_pf_rule_count "<port>:<entry>,<entry>" ...: 2 + allowlist entries per
# LAN-bound port (lo0 pass, block, one pass per entry). Entries are
# comma-joined so one port stays one argument.
mss_pf_rule_count() {
    _count=0
    for _spec in "$@"; do
        _entries=${_spec#*:}
        _n=0
        _oldifs=$IFS
        IFS=,
        for _e in $_entries; do [ -n "$_e" ] && _n=$((_n + 1)); done
        IFS=$_oldifs
        _count=$((_count + 2 + _n))
    done
    echo "$_count"
}

# ── backends.env: the saved install.sh answers (parsed, never sourced) ────────
# Keys in config/backends.env.example order; tests/run.sh asserts they match.
mss_envfile_keys() {
    echo MSS_BACKENDS MSS_DEFER_MODEL OLLAMA_BIND OLLAMA_USER MSS_GPU_PERCENT OLLAMA_BIN \
        MSS_TUNE_MACOS MSS_POWER_AUTORESTART MSS_DOCKER_INSTALL MSS_DOCKER_AUTOSTART \
        LLAMACPP_BIN LLAMACPP_MODEL LLAMACPP_MODEL_SHA256 LLAMACPP_HOST LLAMACPP_PORT \
        LLAMACPP_ALLOW_FROM LLAMACPP_API_KEY_FILE LLAMACPP_CTX LLAMACPP_PARALLEL \
        LLAMACPP_EXTRA_ARGS \
        DS4_BIN DS4_MODEL DS4_MODEL_SHA256 DS4_HOST DS4_PORT DS4_ALLOW_FROM DS4_CTX \
        DS4_BATCHED_SESSIONS DS4_WORKDIR DS4_EXTRA_ARGS \
        MSS_GUARD_FREE_PCT MSS_GUARD_SWAP_HEADROOM_MB MSS_GUARD_STREAK MSS_LOG_MAX_MB
}

# mss_envfile_legacy_keys: keys the parser still accepts and mss_envfile_write
# never writes (#27). The resolver migrates them on the next save.
mss_envfile_legacy_keys() { echo OLLAMA_GPU_PERCENT; }

# A value is taken literally. Characters a shell would interpret are refused
# instead of escaped, so the file can never mean more than it says.
_mss_envfile_value_ok() {
    case ${1:-} in
        *'$'*|*'`'*|*'"'*|*"'"*|*'\'*|*"$_mss_cr"*|*"$_mss_nl"*) return 1 ;;
    esac
    return 0
}

# The file must be a regular file (not a symlink), owned by the invoking uid,
# and not group- or world-writable.
mss_envfile_check_file() {
    _ef=$1
    if [ -L "$_ef" ]; then mss_error "$_ef is a symlink; refusing to read it"; return 1; fi
    [ -f "$_ef" ] || { mss_error "$_ef is not a regular file"; return 1; }
    _euid=$(stat -f '%u' "$_ef") || return 1
    [ "$_euid" = "$(id -u)" ] || { mss_error "$_ef is owned by uid $_euid, not by you (uid $(id -u))"; return 1; }
    _emode=$(stat -f '%Lp' "$_ef") || return 1
    if [ $(( (0$_emode / 8) & 2 )) -ne 0 ] || [ $(( 0$_emode & 2 )) -ne 0 ]; then
        mss_error "$_ef is group- or world-writable (mode $_emode); run chmod 600 on it"
        return 1
    fi
    return 0
}

# mss_envfile_load FILE: validate every line first, then export each non-empty
# value unless the environment already has a non-empty value for that key.
# Sets MSS_ENVFILE_OVERRIDDEN to the keys the environment overrode.
mss_envfile_load() {
    _ef=$1
    mss_envfile_check_file "$_ef" || return 1
    _ekeys=" $(mss_envfile_keys) $(mss_envfile_legacy_keys) "
    _eseen=" "
    _eok=""
    _eno=0
    while IFS= read -r _eline || [ -n "$_eline" ]; do
        _eno=$((_eno + 1))
        _estrip=${_eline#"${_eline%%[![:space:]]*}"}
        case $_estrip in ''|'#'*) continue ;; esac
        case $_eline in
            export[[:space:]]*) mss_error "$_ef line $_eno: 'export' is not allowed; write KEY=value"; return 1 ;;
            *=*) ;;
            *) mss_error "$_ef line $_eno: not a KEY=value line"; return 1 ;;
        esac
        _ekey=${_eline%%=*}
        _evalue=${_eline#*=}
        case $_ekey in
            ''|*[!A-Z0-9_]*) mss_error "$_ef line $_eno: invalid key '$_ekey'"; return 1 ;;
        esac
        case $_ekeys in *" $_ekey "*) ;; *) mss_error "$_ef line $_eno: unknown key $_ekey"; return 1 ;; esac
        case $_eseen in *" $_ekey "*) mss_error "$_ef line $_eno: duplicate key $_ekey"; return 1 ;; esac
        _eseen="$_eseen$_ekey "
        _mss_envfile_value_ok "$_evalue" || {
            mss_error "$_ef line $_eno: $_ekey contains a quote, \$, backtick, backslash or carriage return; values are literal"
            return 1
        }
        [ "$_ekey" != MSS_BACKENDS ] || [ -n "$_evalue" ] || { mss_error "$_ef line $_eno: MSS_BACKENDS is empty"; return 1; }
        _eok="$_eok$_ekey=$_evalue$_mss_nl"
    done < "$_ef"
    case $_eseen in *" MSS_BACKENDS "*) ;; *) mss_error "$_ef has no MSS_BACKENDS line"; return 1 ;; esac

    MSS_ENVFILE_OVERRIDDEN=""
    MSS_ENVFILE_LOADED=""
    while IFS= read -r _eline; do
        [ -n "$_eline" ] || continue
        _ekey=${_eline%%=*}
        _evalue=${_eline#*=}
        [ -n "$_evalue" ] || continue
        # A key the environment already carries stays the environment's. That
        # includes the legacy GPU key; a file OLLAMA_GPU_PERCENT beside an
        # environment MSS_GPU_PERCENT is still exported, because the environment
        # does not carry that name, and mss_choices_resolve compares the two.
        if [ -n "$(printenv "$_ekey")" ]; then
            MSS_ENVFILE_OVERRIDDEN="$MSS_ENVFILE_OVERRIDDEN $_ekey"
            continue
        fi
        MSS_ENVFILE_LOADED="$MSS_ENVFILE_LOADED $_ekey"
        export "$_ekey=$_evalue"
    done <<MSS_ENVFILE_EOF
$_eok
MSS_ENVFILE_EOF
    return 0
}

# mss_envfile_write FILE: write every exported non-empty key, in the example's
# order, atomically with mode 0600. Refuses to run as root or to replace a
# symlink. Comments are not preserved. OLLAMA_BIN is written only when Ollama is
# selected: a DS4-only or llama.cpp-only file must not carry a binary that was
# removed on purpose.
mss_envfile_write() {
    _ef=$1
    [ "$(id -u)" -ne 0 ] || { mss_error "refusing to write $_ef as root"; return 1; }
    if [ -L "$_ef" ]; then mss_error "$_ef is a symlink; refusing to replace it"; return 1; fi
    for _ek in $(mss_envfile_keys); do
        _ev=$(printenv "$_ek")
        _mss_envfile_value_ok "$_ev" || { mss_error "$_ek has a character backends.env cannot hold (quote, \$, backtick, backslash)"; return 1; }
    done
    _etmp=$(mktemp "$(dirname "$_ef")/.backends.env.XXXXXX") || { mss_error "cannot create a temporary file next to $_ef"; return 1; }
    if ! chmod 600 "$_etmp"; then rm -f "$_etmp"; return 1; fi
    if ! {
        echo "# Written by scripts/install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
        echo "# KEY=value lines, parsed and never sourced: no quotes, no \$, no export."
        for _ek in $(mss_envfile_keys); do
            _ev=$(printenv "$_ek")
            [ "$_ek" != OLLAMA_BIN ] || mss_backend_selected ollama || continue
            [ -z "$_ev" ] || printf '%s=%s\n' "$_ek" "$_ev"
        done
    } > "$_etmp"; then
        rm -f "$_etmp"; mss_error "cannot write $_etmp"; return 1
    fi
    mv -f "$_etmp" "$_ef" || { rm -f "$_etmp"; mss_error "cannot replace $_ef"; return 1; }
}
