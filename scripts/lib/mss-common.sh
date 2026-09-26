#!/bin/sh
# mss-common.sh — shared validation, resolution and rendering helpers for
# mac-studio-server 1.3.0 (issue #9).
#
# POSIX sh, BSD userland only (BSD stat/shasum/readlink/date spellings).
# Root-run scripts that source this file never use tilde paths or HOME.

# ── errors ─────────────────────────────────────────────────────────────────────
mss_error() { echo "ERROR: $*" >&2; }
mss_die()   { mss_error "$@"; exit 1; }

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
mss_validate_ipv4() {
    echo "${1:-}" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
    echo "${1:-}" | awk -F. '$1<=255 && $2<=255 && $3<=255 && $4<=255 { exit 0 } { exit 1 }'
}

mss_validate_cidr_entry() {
    _e=${1:-}
    case $_e in
        */*)
            mss_validate_ipv4 "${_e%/*}" || return 1
            echo "$_e" | grep -Eq '^[0-9]{1,2}$' || return 1
            _len=${_e##*/}
            [ "$_len" -ge 0 ] && [ "$_len" -le 32 ]
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
    mss_validate_ipv4 "$_host" || { mss_error "$_var: '$_host' must be a single IPv4 address"; return 1; }
    echo "$_host" | grep -q ':' && { mss_error "$_var: IPv6 is not supported"; return 1; }
    return 0
}

# ── ports ──────────────────────────────────────────────────────────────────────
mss_validate_port() {
    _var=$1; _port=${2:-}
    echo "$_port" | grep -Eq '^[0-9]+$' || { mss_error "$_var: '$_port' is not a number"; return 1; }
    [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] || { mss_error "$_var: '$_port' out of range"; return 1; }
}

# ── sha256 / key file ──────────────────────────────────────────────────────────
mss_validate_sha256() {
    echo "${2:-}" | grep -Eq '^[0-9a-fA-F]{64}$' || { mss_error "$1: not a 64-hex sha256"; return 1; }
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
mss_wired_limit_mb() {
    _percent=${1:?percent}
    _total=${2:-$(sysctl -n hw.memsize)}
    # shellcheck disable=SC2017  # must match set-gpu-memory.sh's integer order exactly
    echo $(( _total / 1024 / 1024 * _percent / 100 ))
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
            --threads|--power|--mixed-prefill-quantum|--mtp-draft) echo value; return ;;
            --mtp|--mtp-exact-sampling) echo novalue; return ;;
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
            --threads|--mixed-prefill-quantum|--mtp-draft) echo '^[0-9]+$'; return ;;
            --power) echo '^[0-9]+$'; return ;;
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
                case $_flag in --*) ;; esac
            else
                shift
                [ $# -gt 0 ] || { mss_error "$_var: flag '$_canonical' needs a value"; return 1; }
                _value=$1
            fi
            _pattern=$(mss_flag_pattern "$_backend" "$_canonical")
            printf '%s\n' "$_value" | grep -Eq "$_pattern" || { mss_error "$_var: value '$_value' for $_canonical does not match $_pattern"; return 1; }
            if [ "$_canonical" = "--power" ]; then
                [ "$_value" -ge 1 ] && [ "$_value" -le 100 ] || { mss_error "$_var: --power must be 1..100"; return 1; }
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
# 2 + allowlist entries per LAN-bound port (lo0 pass, block, one pass per entry).
mss_pf_rule_count() {
    _count=0
    for _spec in "$@"; do
        _entries=${_spec#*:}
        _n=0
        if [ -n "$_entries" ]; then
            for _e in $_entries; do _n=$((_n + 1)); done
        fi
        _count=$((_count + 2 + _n))
    done
    echo "$_count"
}
