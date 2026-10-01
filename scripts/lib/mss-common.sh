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

# ── backend selection (#1 D1, D2) ──────────────────────────────────────────────
# Any non-empty comma list of distinct names from ollama, llamacpp, ds4 and mlx,
# in any order. An empty element, an unknown name or a duplicate is named.
mss_validate_selection() {
    _sv_value=${1:-}
    [ -n "$_sv_value" ] || { mss_error "MSS_BACKENDS is empty"; return 1; }
    case $_sv_value in
        ,*|*,|*,,*) mss_error "MSS_BACKENDS: empty element in '$_sv_value'"; return 1 ;;
    esac
    _sv_seen=,
    _sv_ifs=$IFS
    IFS=,
    for _sv_name in $_sv_value; do
        case $_sv_name in
            ollama|llamacpp|ds4|mlx) ;;
            *) IFS=$_sv_ifs; mss_error "MSS_BACKENDS: unknown backend '$_sv_name'"; return 1 ;;
        esac
        case $_sv_seen in
            *",$_sv_name,"*) IFS=$_sv_ifs; mss_error "MSS_BACKENDS: duplicate '$_sv_name'"; return 1 ;;
        esac
        _sv_seen="$_sv_seen$_sv_name,"
    done
    IFS=$_sv_ifs
    return 0
}

mss_backend_selected() { case ",${MSS_BACKENDS:-ollama}," in *",$1,"*) return 0 ;; esac; return 1; }

# mss_optional_backends <selection>: its optional backends, space separated, in
# the fixed order llamacpp ds4 mlx.
mss_optional_backends() {
    _ob_out=""
    for _ob_b in llamacpp ds4 mlx; do
        case ",${1:-}," in *",$_ob_b,"*) _ob_out="$_ob_out $_ob_b" ;; esac
    done
    printf '%s\n' "${_ob_out# }"
}

# mss_count_words <words>: how many.
# shellcheck disable=SC2086  # the point is the word split
mss_count_words() { set -- ${1:-}; echo $#; }

# mss_active_backend <selection> <MSS_ACTIVE_BACKEND>: prints the one optional
# backend that runs, or none, by the D2 table. Ollama is not optional: it runs
# whenever it is selected, so naming it as the active backend is refused.
mss_active_backend() {
    _ab_opt=$(mss_optional_backends "${1:-ollama}")
    _ab_n=$(mss_count_words "$_ab_opt")
    _ab_set=${2:-}
    if [ "$_ab_set" = ollama ]; then
        mss_error "MSS_ACTIVE_BACKEND=ollama is refused: Ollama is not an optional backend and runs whenever it is selected"
        return 1
    fi
    if [ -z "$_ab_set" ]; then
        case $_ab_n in
            0) echo none ;;
            1) echo "$_ab_opt" ;;
            *) mss_error "MSS_ACTIVE_BACKEND is required when 2 or more optional backends are selected (one of: $_ab_opt none)"
               return 1 ;;
        esac
        return 0
    fi
    if [ "$_ab_set" = none ]; then echo none; return 0; fi
    case " $_ab_opt " in *" $_ab_set "*) echo "$_ab_set"; return 0 ;; esac
    if [ "$_ab_n" = 0 ]; then
        mss_error "MSS_ACTIVE_BACKEND: '$_ab_set' is not selected; with no optional backend selected only none is accepted"
    else
        mss_error "MSS_ACTIVE_BACKEND: '$_ab_set' is not a selected optional backend (one of: $_ab_opt none)"
    fi
    return 1
}

# The prefix of a backend's variables.
mss_backend_prefix() { case $1 in llamacpp) echo LLAMACPP ;; ds4) echo DS4 ;; mlx) echo MLX ;; esac; }

# The default port of each optional backend.
mss_default_port() { case $1 in llamacpp) echo 8080 ;; ds4) echo 8000 ;; mlx) echo 11234 ;; esac; }

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
    elif [ "$_backend" = mlx ]; then
        # #1 D7: nothing here can widen the one-model memory bound, the
        # loopback bind or the log file. Every other flag is rejected.
        case $_flag in
            --max-concurrent|--prefill-chunk|--kv-quant|--prefix-cache-mem|--timeout) echo value; return ;;
            --metrics|--mtp|--no-mtp|--no-vision) echo novalue; return ;;
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
    elif [ "$_backend" = mlx ]; then
        case $_flag in
            --max-concurrent) echo '^([1-9]|1[0-6])$'; return ;;
            --prefill-chunk) echo '^[1-9][0-9]*$'; return ;;
            --kv-quant) echo '^(off|4|8)$'; return ;;
            # 0 and off would disable the prefix cache bound (MUST NOT 5).
            --prefix-cache-mem) echo '^([1-9][0-9]{0,5}MB|[1-9][0-9]{0,2}GB)$'; return ;;
            --timeout) echo '^[0-9]{1,6}$'; return ;;
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
    echo MSS_BACKENDS MSS_ACTIVE_BACKEND MSS_DEFER_MODEL OLLAMA_BIND OLLAMA_USER MSS_GPU_PERCENT OLLAMA_BIN \
        MSS_TUNE_MACOS MSS_POWER_AUTORESTART MSS_DOCKER_INSTALL MSS_DOCKER_AUTOSTART \
        LLAMACPP_BIN LLAMACPP_MODEL LLAMACPP_MODEL_SHA256 LLAMACPP_HOST LLAMACPP_PORT \
        LLAMACPP_ALLOW_FROM LLAMACPP_API_KEY_FILE LLAMACPP_CTX LLAMACPP_PARALLEL \
        LLAMACPP_EXTRA_ARGS \
        DS4_BIN DS4_MODEL DS4_MODEL_SHA256 DS4_HOST DS4_PORT DS4_ALLOW_FROM DS4_CTX \
        DS4_BATCHED_SESSIONS DS4_WORKDIR DS4_EXTRA_ARGS \
        MLX_BIN MLX_MODEL_DIR MLX_PORT MLX_CTX MLX_EXTRA_ARGS \
        MSS_GUARD_FREE_PCT MSS_GUARD_SWAP_HEADROOM_MB MSS_GUARD_STREAK MSS_LOG_MAX_MB
}

# mss_envfile_wants_active <selection> <active>: does backends.env carry
# MSS_ACTIVE_BACKEND (#1 D8 rule 6)? Only with two or more optional backends,
# or with none, so a 1.6.0 file re-saves without a new line.
mss_envfile_wants_active() {
    [ -n "${2:-}" ] || return 1
    [ "$2" != none ] || return 0
    [ "$(mss_count_words "$(mss_optional_backends "${1:-}")")" -ge 2 ]
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
            [ "$_ek" != MSS_ACTIVE_BACKEND ] || mss_envfile_wants_active "${MSS_BACKENDS:-}" "$_ev" || continue
            [ -z "$_ev" ] || printf '%s=%s\n' "$_ek" "$_ev"
        done
    } > "$_etmp"; then
        rm -f "$_etmp"; mss_error "cannot write $_etmp"; return 1
    fi
    mv -f "$_etmp" "$_ef" || { rm -f "$_etmp"; mss_error "cannot replace $_ef"; return 1; }
}

# ── MLX-Serve (#1 D7) ──────────────────────────────────────────────────────────
# The one supported upstream version. A bump is its own PR that re-verifies the
# upstream contracts (docs/backends.md).
MSS_MLX_SERVE_VERSION=26.9.6

# mss_run_bounded <seconds> <cmd...>: run cmd, stopping it after <seconds>
# (macOS has no timeout(1)). The deadline is a background `sleep <seconds>`, so
# the bound is wall time: counting 0.2 s polls let fork overhead on a slow Mac
# stretch 10 s to 14 s. The loop checks both every 0.2 s; at the deadline it
# sends TERM, waits up to 0.5 s (also wall time), sends KILL and returns 124. Otherwise it
# returns the command's status. The command's output (stdout and stderr) goes
# to a temporary file and is printed when it ends, so a child it leaves behind
# cannot hold the caller's command substitution open. Inside a lifecycle lock
# the child is also watched (mss_watchdog).
mss_run_bounded() {
    _rb_secs=$1; shift
    _rb_out=$(mktemp "${TMPDIR:-/tmp}/mss-bounded.XXXXXX") || return 1
    "$@" >"$_rb_out" 2>&1 </dev/null &
    _rb_pid=$!
    sleep "$_rb_secs" >/dev/null 2>&1 &
    _rb_timer=$!
    [ -z "${MSS_LOCK_SESSION:-}" ] || mss_watchdog "$_rb_pid"
    _rb_rc=""
    while kill -0 "$_rb_pid" 2>/dev/null; do
        if ! kill -0 "$_rb_timer" 2>/dev/null; then
            kill -TERM "$_rb_pid" 2>/dev/null
            sleep 0.5 >/dev/null 2>&1 &
            _rb_grace=$!
            while kill -0 "$_rb_pid" 2>/dev/null && kill -0 "$_rb_grace" 2>/dev/null; do
                sleep 0.1
            done
            kill "$_rb_grace" 2>/dev/null
            wait "$_rb_grace" 2>/dev/null
            kill -KILL "$_rb_pid" 2>/dev/null
            wait "$_rb_pid" 2>/dev/null
            _rb_rc=124
            break
        fi
        sleep 0.2
    done
    if [ -z "$_rb_rc" ]; then
        wait "$_rb_pid"
        _rb_rc=$?
    fi
    kill "$_rb_timer" 2>/dev/null
    wait "$_rb_timer" 2>/dev/null
    cat "$_rb_out"
    rm -f "$_rb_out"
    return "$_rb_rc"
}

# mss_mlx_version_ok <bin> [user] [var]: the probe. The first line of
# `<bin> --version` must be exactly "mlx-serve <pinned version>". With a user
# the probe runs as that user (a root pass never runs mlx-serve as root).
mss_mlx_version_ok() {
    _mv_bin=$1; _mv_user=${2:-}; _mv_var=${3:+$3: }
    if [ -n "$_mv_user" ]; then
        _mv_out=$(mss_run_bounded 10 sudo -u "$_mv_user" -- "$_mv_bin" --version 2>&1)
    else
        _mv_out=$(mss_run_bounded 10 "$_mv_bin" --version 2>&1)
    fi
    _mv_rc=$?
    case $_mv_rc in
        0) ;;
        124) mss_error "${_mv_var}$_mv_bin --version timed out after 10s"; return 1 ;;
        *) mss_error "${_mv_var}$_mv_bin --version exited $_mv_rc"; return 1 ;;
    esac
    _mv_line=$(printf '%s\n' "$_mv_out" | head -n 1)
    [ "$_mv_line" != "mlx-serve $MSS_MLX_SERVE_VERSION" ] || return 0
    case $_mv_line in
        "mlx-serve "*)
            mss_error "${_mv_var}mlx-serve ${_mv_line#mlx-serve } is installed; this release supports $MSS_MLX_SERVE_VERSION only" ;;
        *)  mss_error "${_mv_var}$_mv_bin is not mlx-serve (--version printed '$(printf '%s' "$_mv_line" | cut -c 1-80)')" ;;
    esac
    return 1
}

# mss_mlx_check_dir <var> <resolved dir>: a native MLX checkpoint directory. A
# top-level config.json and *.safetensors, no GGUF anywhere (mlx-serve would
# hand it to its GGUF engines), and only names, never contents, are read.
mss_mlx_check_dir() {
    _md_var=$1; _md_dir=$2
    mss_validate_path_chars "$_md_var" "$_md_dir" || return 1
    [ -d "$_md_dir" ] || { mss_error "$_md_var: not a directory: $_md_dir"; return 1; }
    [ -f "$_md_dir/config.json" ] || { mss_error "$_md_var: $_md_dir has no top-level config.json (native MLX checkpoints only)"; return 1; }
    _md_st=0
    for _md_f in "$_md_dir"/*.safetensors; do
        [ -f "$_md_f" ] && _md_st=1
    done
    [ "$_md_st" = 1 ] || { mss_error "$_md_var: $_md_dir has no top-level *.safetensors file"; return 1; }
    _md_g=$(find -L "$_md_dir" -name '*.gguf' 2>/dev/null | head -n 1)
    [ -z "$_md_g" ] || { mss_error "$_md_var: $_md_dir contains a GGUF file ($_md_g); GGUF models belong to llamacpp or ds4"; return 1; }
    mss_mlx_manifest "$_md_dir" >/dev/null || return 1
}

# mss_mlx_manifest <dir>: "mlx-manifest-v1 <dir>", then "<relpath> <size>
# <inode> <mtime>" per regular file, from find -L and stat -L only, dot-entries
# skipped, sorted under LC_ALL=C. No file content is read (#1 AC 11).
mss_mlx_manifest() {
    _mf_dir=$1
    _mf_list=$(cd "$_mf_dir" 2>/dev/null && LC_ALL=C find -L . -mindepth 1 -name '.*' -prune -o -type f -print 2>/dev/null) \
        || { mss_error "MLX_MODEL_DIR: cannot list $_mf_dir"; return 1; }
    _mf_list=$(printf '%s\n' "$_mf_list" | LC_ALL=C sort)
    printf 'mlx-manifest-v1 %s\n' "$_mf_dir"
    while IFS= read -r _mf_l; do
        [ -n "$_mf_l" ] || continue
        _mf_rel=${_mf_l#./}
        mss_validate_path_chars "MLX_MODEL_DIR file" "$_mf_dir/$_mf_rel" || return 1
        _mf_st=$(stat -L -f '%z %i %m' "$_mf_dir/$_mf_rel" 2>/dev/null) || { mss_error "MLX_MODEL_DIR: stat failed: $_mf_dir/$_mf_rel"; return 1; }
        printf '%s %s\n' "$_mf_rel" "$_mf_st"
    done <<MSS_MANIFEST_EOF
$_mf_list
MSS_MANIFEST_EOF
}

# ── model-server processes (#1 D4) ─────────────────────────────────────────────
# mss_model_server_names [extra names...]: the names a model server runs under:
# the three upstream servers, the basename of every *_BIN in the conf, and any
# extra names, one per line.
mss_model_server_names() {
    {
        printf '%s\n' mlx-serve ds4-server llama-server "$@"
        for _mn_k in LLAMACPP_BIN DS4_BIN MLX_BIN; do
            _mn_v=$(mss_conf_get "$_mn_k" 2>/dev/null) || _mn_v=""
            [ -z "$_mn_v" ] || basename "$_mn_v"
        done
    } | awk 'NF && !seen[$0]++'
}

# mss_model_servers [extra names...]: "<name> <pid>" for every process with one
# of those names (pgrep -x: the process name, at most 15 characters). Returns 2
# when pgrep is missing.
mss_model_servers() {
    command -v pgrep >/dev/null 2>&1 || return 2
    for _ms_n in $(mss_model_server_names "$@"); do
        for _ms_p in $(pgrep -x "$_ms_n" 2>/dev/null); do
            printf '%s %s\n' "$_ms_n" "$_ms_p"
        done
    done
    return 0
}

# mss_pid_under <pid> <ancestor>: pid is the ancestor or a descendant of it.
mss_pid_under() {
    _pu_p=$1; _pu_hops=0
    while [ -n "$_pu_p" ] && [ "$_pu_p" -gt 1 ] && [ "$_pu_hops" -lt 32 ]; do
        [ "$_pu_p" = "$2" ] && return 0
        _pu_p=$(ps -o ppid= -p "$_pu_p" 2>/dev/null | tr -d ' ')
        _pu_hops=$((_pu_hops + 1))
    done
    return 1
}

# mss_label_pid <label>: the PID launchd reports for system/<label>, if any.
mss_label_pid() {
    launchctl print "system/$1" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -n 1
}

# mss_unmanaged_server [extra names...]: the first "<name> <pid>" model server
# that is not a managed backend job (its PID, or a descendant of it), or
# nothing. Returns 2 when pgrep is missing. The job PIDs need root to read.
mss_unmanaged_server() {
    _um_owns=""
    for _um_b in llamacpp ds4 mlx; do
        _um_p=$(mss_label_pid "com.mac-studio-server.$_um_b")
        [ -z "$_um_p" ] || _um_owns="$_um_owns $_um_p"
    done
    _um_list=$(mss_model_servers "$@") || return 2
    while read -r _um_n _um_pid; do
        [ -n "$_um_pid" ] || continue
        _um_mine=0
        for _um_o in $_um_owns; do
            if mss_pid_under "$_um_pid" "$_um_o"; then _um_mine=1; break; fi
        done
        [ "$_um_mine" = 1 ] || { printf '%s %s\n' "$_um_n" "$_um_pid"; return 0; }
    done <<MSS_SERVERS_EOF
$_um_list
MSS_SERVERS_EOF
    return 0
}

# ── lifecycle lock (#1 D15) ────────────────────────────────────────────────────
# One lock for every lifecycle mutation. Only a Perl keeper holds its
# descriptor: the keeper opens the file itself (Perl marks it close-on-exec)
# and its only children are short `ps` calls, so no process the holder starts
# can keep the lock after the holder dies. Mutating commands run through
# mss_mut, which holds a second, shared lock for as long as the command and its
# descendants live; a keeper whose holder died drains (or kills) them before it
# lets the next command in. The guard and the boot job never take either lock.
mss_lock_file() { printf '%s\n' "${MSS_LOCK_FILE:-/var/run/com.mac-studio-server.lock}"; }
mss_mut_file() { printf '%s\n' "${MSS_MUT_FILE:-/var/run/com.mac-studio-server.mut}"; }

# mss_pid_start <pid>: the process start time, as one word (the same spelling
# the Perl side uses).
mss_pid_start() { LC_ALL=C /bin/ps -o lstart= -p "$1" 2>/dev/null | awk '{ $1 = $1; gsub(/ /, "_"); print }'; }

# The Perl side, one program with three modes:
#   keeper <lock> <timeout> <holder pid> <holder start> <cmd> <mut>
#   mut <lock> <mut> <session> <command...>
#   check <lock> <session>
# shellcheck disable=SC2016  # Perl source, not shell
_MSS_LOCK_PL='
use strict; use warnings;
use Fcntl qw(:DEFAULT :flock);
use POSIX qw(strftime);
sub nap { select(undef, undef, undef, $_[0]); }
sub pstart {
    my ($p) = @_;
    return "" unless defined $p && $p =~ /^[0-9]+$/;
    local $ENV{LC_ALL} = "C";
    open(my $ps, "-|", "/bin/ps", "-o", "lstart=", "-p", $p) or return "";
    my $s = <$ps>; close $ps;
    return "" unless defined $s;
    $s =~ s/^\s+|\s+$//g; $s =~ s/\s+/_/g;
    return $s;
}
sub owner_read {
    open(my $o, "<", $_[0]) or return ();
    my $l = <$o>; close $o;
    return () unless defined $l;
    chomp $l;
    my %h;
    for my $w (split / /, $l) { my ($k, $v) = split /=/, $w, 2; $h{$k} = $v if defined $v; }
    return %h;
}
sub owner_write {
    my ($f, $line) = @_;
    my $t = "$f.tmp.$$";
    open(my $o, ">", $t) or return 0;
    print $o "$line\n";
    close $o or return 0;
    chmod 0644, $t;
    return rename($t, $f);
}
sub alive_as {
    my ($v) = @_;
    return 0 unless defined $v;
    my ($p, $s) = split /\@/, $v, 2;
    return 0 unless defined $s && $p =~ /^[0-9]+$/ && kill(0, $p);
    return pstart($p) eq $s;
}
sub session_ok {
    my ($lock, $sess) = @_;
    return 0 unless defined $sess && $sess ne "";
    my %h = owner_read("$lock.owner");
    return 0 unless defined $h{session} && $h{session} eq $sess;
    return alive_as($h{keeper}) && alive_as($h{holder});
}
sub registry {
    my ($d) = @_;
    opendir(my $dh, $d) or return ();
    my @e = grep { /^[0-9]+$/ } readdir($dh);
    closedir $dh;
    return @e;
}
my $mode = shift @ARGV;
$mode = "" unless defined $mode;
if ($mode eq "keeper") {
    my ($lock, $timeout, $holder, $hstart, $cmd, $mut) = @ARGV;
    $| = 1;
    if (getppid() != $holder) { print "error the keeper is not a child of the holder\n"; exit 70; }
    my $kstart = pstart($$);
    sysopen(my $L, $lock, O_RDWR | O_CREAT, 0600) or do { print "error cannot open $lock: $!\n"; exit 70; };
    my $tries = 0;
    until (flock($L, LOCK_EX | LOCK_NB)) {
        if ($tries >= $timeout * 2) { print "busy\n"; exit 75; }
        exit 70 if getppid() != $holder;
        nap(0.5); $tries++;
    }
    sysopen(my $M, $mut, O_RDWR | O_CREAT, 0600) or do { print "error cannot open $mut: $!\n"; exit 70; };
    mkdir("$mut.d", 0700) unless -d "$mut.d";
    unlink map { "$mut.d/$_" } registry("$mut.d");
    open(my $R, "<", "/dev/urandom") or do { print "error /dev/urandom\n"; exit 70; };
    my $raw = ""; read($R, $raw, 16); close $R;
    if (length($raw) != 16) { print "error /dev/urandom\n"; exit 70; }
    my $tok = unpack("H*", $raw);
    my $since = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime());
    owner_write("$lock.owner", "session=$tok holder=$holder\@$hstart keeper=$$\@$kstart cmd=$cmd since=$since")
        or do { print "error cannot write $lock.owner\n"; exit 70; };
    print "ok $tok\n";
    open(STDOUT, ">", "/dev/null");
    nap(0.2) while getppid() == $holder;
    my $drained = 0;
    for (1 .. 150) { if (flock($M, LOCK_EX | LOCK_NB)) { $drained = 1; last; } nap(0.2); }
    my @reg = registry("$mut.d");
    unless ($drained) {
        my @groups;
        for my $e (@reg) {
            open(my $r, "<", "$mut.d/$e") or next;
            my $l = <$r>; close $r;
            next unless defined $l;
            chomp $l;
            my ($pg, $st) = split / /, $l, 2;
            push @groups, $pg if defined $st && pstart($pg) eq $st;
        }
        kill("-TERM", $_) for @groups;
        nap(5);
        kill("-KILL", $_) for @groups;
        flock($M, LOCK_EX);
    }
    unlink map { "$mut.d/$_" } registry("$mut.d");
    owner_write("$lock.owner", "released after draining " . scalar(@reg));
    exit 0;
}
if ($mode eq "mut") {
    my ($lock, $mut, $sess, @cmd) = @ARGV;
    die "mss_mut: no command\n" unless @cmd;
    setpgrp(0, 0);
    my $start = pstart($$);
    sysopen(my $M, $mut, O_RDWR | O_CREAT, 0600) or do { print STDERR "ERROR: cannot open $mut: $!\n"; exit 70; };
    flock($M, LOCK_SH) or do { print STDERR "ERROR: cannot lock $mut: $!\n"; exit 70; };
    my $reg = "$mut.d/$$";
    my $ok = open(my $r, ">", $reg);
    if ($ok) { print $r "$$ $start\n"; $ok = close $r; }
    unless ($ok && session_ok($lock, $sess)) {
        unlink $reg; close $M;
        my $s = (defined $sess && $sess ne "") ? $sess : "none";
        print STDERR "REFUSE: lifecycle session $s ended; @cmd not run\n";
        exit 75;
    }
    my $fl = fcntl($M, F_GETFD, 0);
    fcntl($M, F_SETFD, $fl & ~FD_CLOEXEC);
    my $lc = delete $ENV{MSS_MUT_LC_ALL};
    if (!defined $lc || $lc eq "mss-unset") { delete $ENV{LC_ALL}; } else { $ENV{LC_ALL} = $lc; }
    { no warnings "exec"; exec { $cmd[0] } @cmd; }
    print STDERR "ERROR: cannot run $cmd[0]: $!\n";
    exit 127;
}
if ($mode eq "check") { exit(session_ok($ARGV[0], $ARGV[1]) ? 0 : 1); }
print STDERR "mss lock: unknown mode\n";
exit 64;
'

# The test hooks MSS_LOCK_FILE and MSS_MUT_FILE are refused as root.
_mss_lock_hooks_check() {
    if [ "$(id -u)" -eq 0 ] && { [ -n "${MSS_LOCK_FILE:-}" ] || [ -n "${MSS_MUT_FILE:-}" ]; }; then
        mss_die "MSS_LOCK_FILE and MSS_MUT_FILE are for tests/run.sh only and are refused as root"
    fi
}

# mss_lock_owner_desc: the owner file without its session token.
mss_lock_owner_desc() {
    _lo=$(sed -e 's/session=[0-9a-f]* //' "$(mss_lock_file).owner" 2>/dev/null)
    printf '%s\n' "${_lo:-owner unknown}"
}

# mss_lock_acquire <cmd>: take the lifecycle lock for this shell, or exit 1.
# Must run in the holder's own shell (not a subshell): the keeper watches its
# parent and releases once that shell is gone. Exports MSS_LOCK_SESSION.
mss_lock_acquire() {
    _mss_lock_hooks_check
    _la_to=${MSS_LOCK_TIMEOUT:-30}
    mss_validate_uint MSS_LOCK_TIMEOUT "$_la_to" 1 3600 || exit 1
    [ -x /usr/bin/perl ] || mss_die "/usr/bin/perl is required for the lifecycle lock"
    _la_dir=$(mktemp -d "${TMPDIR:-/tmp}/mss-lock.XXXXXX") || mss_die "cannot create a temporary directory for the lifecycle lock"
    mkfifo "$_la_dir/fifo" || { rm -rf "$_la_dir"; mss_die "cannot create the lifecycle lock fifo"; }
    LC_ALL=C /usr/bin/perl -e "$_MSS_LOCK_PL" keeper "$(mss_lock_file)" "$_la_to" "$$" "$(mss_pid_start $$)" "$1" "$(mss_mut_file)" \
        9>&- </dev/null >"$_la_dir/fifo" 2>/dev/null &
    MSS_LOCK_KEEPER=$!
    _la_line=""
    IFS= read -r _la_line < "$_la_dir/fifo" || true
    rm -rf "$_la_dir"
    case $_la_line in
        "ok "*)
            MSS_LOCK_SESSION=${_la_line#ok }
            export MSS_LOCK_SESSION MSS_LOCK_KEEPER ;;
        busy)
            wait "$MSS_LOCK_KEEPER" 2>/dev/null || true
            mss_die "another mac-studio-server command holds the lock ($(mss_lock_owner_desc)); try again when it finishes" ;;
        *)
            wait "$MSS_LOCK_KEEPER" 2>/dev/null || true
            mss_die "cannot take the lifecycle lock (${_la_line:-the keeper exited}; it needs /usr/bin/perl)" ;;
    esac
}

# mss_lock_check: this shell still holds its session, or exit 1. Runs before
# every bootout, bootstrap, commit step and save.
mss_lock_check() {
    LC_ALL=C /usr/bin/perl -e "$_MSS_LOCK_PL" check "$(mss_lock_file)" "${MSS_LOCK_SESSION:-}" \
        || mss_die "lifecycle lock lost; nothing further was changed"
}

# mss_mut <command...>: run one mutating command under the session. It runs in
# a new process group holding the shared mutation lock; a runner that reaches
# the lock after its session ended refuses (75) without running anything, and
# so does the holder (exit 1).
mss_mut() {
    _mm_rc=0
    # Perl warns on a locale it cannot load (C.UTF-8 over SSH, as for shasum);
    # the command it runs gets the caller's LC_ALL back.
    # shellcheck disable=SC2097,SC2098  # the caller's LC_ALL, read before the override
    MSS_MUT_LC_ALL=${LC_ALL-mss-unset} LC_ALL=C \
        /usr/bin/perl -e "$_MSS_LOCK_PL" mut "$(mss_lock_file)" "$(mss_mut_file)" "${MSS_LOCK_SESSION:-}" "$@" || _mm_rc=$?
    [ "$_mm_rc" != 75 ] || mss_die "lifecycle lock lost; nothing further was changed"
    return "$_mm_rc"
}

# mss_watchdog <pid>...: kill these read-only children within a second once
# this holder's shell is gone, so no orphan keeps reading a model.
mss_watchdog() {
    _wd_holder=$$
    (
        while :; do
            _wd_any=0
            for _wd_p in "$@"; do kill -0 "$_wd_p" 2>/dev/null && _wd_any=1; done
            [ "$_wd_any" = 1 ] || exit 0
            if ! kill -0 "$_wd_holder" 2>/dev/null; then
                kill -TERM "$@" 2>/dev/null
                sleep 0.5
                kill -KILL "$@" 2>/dev/null
                exit 0
            fi
            sleep 0.5
        done
    ) 9>&- </dev/null >/dev/null 2>&1 &
}

# ── the job plan (#1 D5 phase 1 step 11) ───────────────────────────────────────
# mss_plan_jobs: a pure function. Reads "<key> <value...>" lines on stdin:
#   active.cur|active.new   <b|none>    installed and wanted active backend
#   waiting.new             yes|no      the wanted backend waits for a model
#   pf.new                  yes|no      the wanted conf has a pf policy
#   loaded                  <job>       one line per loaded job
#   plist.<job>.cur|new     <top|standby|absent> <sha256|->
#   keys.<job>.cur|new      <sha256>    the conf keys the job reads
#   stamp.<b>.cur|new       <sha256|->
#   pf.cur|pf.new.sha       <sha256|->  pf.conf
#   marker                  ok|missing  boot's pf marker for this boot
# Jobs are llamacpp ds4 mlx guard boot. Prints three lines, short job names:
#   stop <jobs: guard, backends, boot>
#   start <jobs: boot, the active backend, guard>
#   unchanged <loaded jobs kept running>
# An unchanged, loaded job is never in the stop set.
mss_plan_jobs() {
    awk '
    { k = $1; $1 = ""; sub(/^ /, ""); if (k == "loaded") L[$0] = 1; else V[k] = $0 }
    function ch(a, b) { return (a == b) ? 0 : 1 }
    END {
        act = V["active.new"]; if (act == "") act = "none"
        wait = (V["waiting.new"] == "yes")
        nb = split("llamacpp ds4 mlx", B, " ")
        for (i = 1; i <= nb; i++) {
            b = B[i]
            want[b] = (b == act && !wait)
            c = ch(V["plist." b ".cur"], V["plist." b ".new"]) || ch(V["keys." b ".cur"], V["keys." b ".new"]) \
                || ch(V["stamp." b ".cur"], V["stamp." b ".new"]) || !(b in L)
            if ((b in L) && (!want[b] || c)) stop[b] = 1
            if (want[b] && c) start[b] = 1
            if ((b in stop) || (b in start)) moved = 1
        }
        want["guard"] = (act != "none" && !wait)
        c = ch(V["plist.guard.cur"], V["plist.guard.new"]) || ch(V["keys.guard.cur"], V["keys.guard.new"]) || moved || !("guard" in L)
        if (("guard" in L) && (!want["guard"] || c)) stop["guard"] = 1
        if (want["guard"] && c) start["guard"] = 1
        want["boot"] = (V["pf.new"] == "yes")
        c = ch(V["plist.boot.cur"], V["plist.boot.new"]) || ch(V["keys.boot.cur"], V["keys.boot.new"]) \
            || ch(V["pf.cur"], V["pf.new.sha"]) || V["marker"] != "ok" || !("boot" in L)
        if (("boot" in L) && (!want["boot"] || c)) stop["boot"] = 1
        if (want["boot"] && c) start["boot"] = 1
        n = split("guard llamacpp ds4 mlx boot", O, " ")
        s = ""; for (i = 1; i <= n; i++) if (O[i] in stop) s = s " " O[i]
        print "stop" s
        s = ""; if ("boot" in start) s = s " boot"
        for (i = 1; i <= nb; i++) if (B[i] in start) s = s " " B[i]
        if ("guard" in start) s = s " guard"
        print "start" s
        s = ""; for (i = 1; i <= n; i++) if ((O[i] in L) && !(O[i] in stop)) s = s " " O[i]
        print "unchanged" s
    }'
}

# ── interrupted commit (#1 D5.C) ───────────────────────────────────────────────
# mss_file_sha <path>: its sha256, or "absent".
mss_file_sha() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        _fs=$(mss_shasum256 "$1" 2>/dev/null | awk '{ print $1 }')
        printf '%s\n' "${_fs:-unreadable}"
    else
        echo absent
    fi
}

# mss_commit_recover_plan <journal> <stage dir>: a pure decision over the
# journal and the files; it changes nothing. Each step's target is done (its
# new content), pending (its pre-run content) or foreign (anything else).
# Prints one line:
#   forward <pending> <steps>   every pending step has its verified staged copy
#   back <done>                 every done step has its verified pre-run copy
#   refuse-foreign <n> <target> a target matches neither; nothing may be undone
#   refuse                      neither direction can be verified
mss_commit_recover_plan() {
    _cr_j=$1; _cr_s=$2
    _cr_head=$(head -n 1 "$_cr_j" 2>/dev/null)
    case $_cr_head in "mss-commit-v1 "*) ;; *) echo refuse; return 0 ;; esac
    _cr_n=0; _cr_pending=0; _cr_done=0; _cr_fwd=1; _cr_back=1
    _cr_steps=$(sed 1d "$_cr_j")
    while read -r _cr_i _cr_t _cr_pre _cr_new _cr_rest; do
        [ -n "$_cr_i" ] || continue
        if [ -z "$_cr_new" ] || [ -n "$_cr_rest" ]; then echo refuse; return 0; fi
        _cr_n=$((_cr_n + 1))
        _cr_cur=$(mss_file_sha "$_cr_t")
        if [ "$_cr_cur" = "$_cr_new" ]; then
            _cr_done=$((_cr_done + 1))
            if [ "$_cr_pre" != absent ] && [ "$(mss_file_sha "$_cr_s/prev/$_cr_i")" != "$_cr_pre" ]; then _cr_back=0; fi
        elif [ "$_cr_cur" = "$_cr_pre" ]; then
            _cr_pending=$((_cr_pending + 1))
            if [ "$_cr_new" != absent ] && [ "$(mss_file_sha "$_cr_s/new/$_cr_i")" != "$_cr_new" ]; then _cr_fwd=0; fi
        else
            echo "refuse-foreign $_cr_i $_cr_t"
            return 0
        fi
    done <<MSS_JOURNAL_EOF
$_cr_steps
MSS_JOURNAL_EOF
    if [ "$_cr_fwd" = 1 ]; then echo "forward $_cr_pending $_cr_n"
    elif [ "$_cr_back" = 1 ]; then echo "back $_cr_done"
    else echo refuse
    fi
}

# ── hand-edited plists (#1 D5 step 8) ──────────────────────────────────────────
# mss_plist_check <plist> <record> <template> <user> [<working dir>...]: 0 when
# the plist is this installer's own. With a line in the record its sha256 must
# match; without one (the first run after 1.6.0) its bytes must equal the
# template rendered for <user>, with any of the given ds4 working directories.
mss_plist_check() {
    _pc_p=$1; _pc_rec=$2; _pc_tpl=$3; _pc_user=$4; shift 4
    [ -r "$_pc_p" ] || return 1
    _pc_line=$(awk -v p="$_pc_p" '$2 == p { print $1; exit }' "$_pc_rec" 2>/dev/null)
    if [ -n "$_pc_line" ]; then
        [ "$(mss_file_sha "$_pc_p")" = "$_pc_line" ]
        return
    fi
    [ -r "$_pc_tpl" ] || return 1
    [ $# -gt 0 ] || set -- /var/log/mac-studio-server
    for _pc_wd in "$@"; do
        sed -e "s|<OLLAMA_USER>|$_pc_user|g" -e "s|<MSS_WORKDIR>|$_pc_wd|g" "$_pc_tpl" | cmp -s - "$_pc_p" && return 0
    done
    return 1
}
