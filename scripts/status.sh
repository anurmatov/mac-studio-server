#!/bin/sh
# status.sh — health report for the selected backends (#9, #1).
# Exit 0 only if every selected backend is healthy. Never prints a key.
# With sudo, also verifies pf (enabled, referenced, full rule count) whenever a
# backend is LAN-bound.

set -u

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib/mss-common.sh"
. "$REPO_DIR/scripts/lib/mss-host.sh"
mss_host_root_guard

MSS_CONF=${MSS_CONF:-/usr/local/etc/mac-studio-server/backends.conf}
MSS_PFCTL=${MSS_PFCTL:-/sbin/pfctl}
ANCHOR="com.apple/250.mac-studio-server"

fail=0

conf_get() {
    awk -F= -v k="$1" 'index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "$MSS_CONF" 2>/dev/null
}

has_conf() { [ -r "$MSS_CONF" ]; }

healthy() { printf '  %-10s %s\n' "$1" "$2"; }
unhealthy() { printf '  %-10s %s\n' "$1" "$2"; fail=1; }

# The standby plists and the commit journal live beside the conf.
ETC_DIR=$(dirname "$MSS_CONF")
DB_DIR=/var/db/mac-studio-server

check_backend() {
    _b=$1
    _upper=$(mss_backend_prefix "$_b")
    _host=$(conf_get "${_upper}_HOST"); _host=${_host:-127.0.0.1}
    _port=$(conf_get "${_upper}_PORT"); _port=${_port:-$(mss_default_port "$_b")}
    _label="com.mac-studio-server.$_b"
    _lan=no; mss_is_loopback_host "$_host" || _lan=yes

    echo "$_b (host=$_host port=$_port lan-bound=$_lan):"
    # A LAN-bound mlx names its allowed clients (#33 D4). They live only in
    # the rendered pf rules; ds4 and llama.cpp keep their 1.7.0 rows.
    if [ "$_b" = mlx ] && [ "$_lan" = yes ]; then
        _allow=$(awk -v p="$_port" '$1 == "pass" && $6 == "from" && $10 == "port" && $11 == p { printf "%s%s", s, $7; s = " " }' \
            "$ETC_DIR/pf.conf" 2>/dev/null)
        [ -n "$_allow" ] && healthy allowed "$_allow" || unhealthy allowed "no pf allowlist for port $_port"
    fi

    _print=$(launchctl print "system/$_label" 2>/dev/null)
    _state=$(printf '%s\n' "$_print" | sed -n 's/^[[:space:]]*state = \(.*\)$/\1/p' | head -n 1)
    [ -n "$_state" ] && healthy launchd "$_state" || unhealthy launchd "not loaded"
    if [ "$_b" = mlx ]; then
        _pid=$(printf '%s\n' "$_print" | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -n 1)
        [ -z "$_pid" ] || healthy pid "$_pid"
    fi

    if lsof -nP -iTCP:"$_port" -sTCP:LISTEN >/dev/null 2>&1; then
        healthy listener "listening on $_host:$_port"
    else
        unhealthy listener "nothing listening on $_port"
    fi

    case $_b in
        ds4)          _path=/v1/models ;;
        llamacpp|mlx) _path=/health ;;
    esac
    if _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$_host:$_port$_path" 2>/dev/null); then
        # llama-server returns 503 while loading; that is healthy-but-loading.
        case "$_code" in 200|503) healthy health "HTTP $_code ($_path)" ;; *) unhealthy health "HTTP $_code ($_path)" ;; esac
    else
        unhealthy health "no response on $_path"
    fi
    # mlx-serve answers /health before its model is resolved: ready is a model
    # row with "state":"ready" in /v1/models; anything else is still loading.
    if [ "$_b" = mlx ]; then
        _models=$(curl -s --max-time 5 "http://$_host:$_port/v1/models" 2>/dev/null)
        case $_models in
            *'"state":"ready"'*|*'"state": "ready"'*) healthy model "ready" ;;
            *) healthy model "loading" ;;
        esac
    fi

    if [ -e "$DB_DIR/guard.tripped" ]; then
        unhealthy guard "trip marker present"
    else
        healthy guard "no trip marker"
    fi

    _last=$(tail -n 1 /var/log/mac-studio-server/guard.jsonl 2>/dev/null)
    [ -n "$_last" ] && healthy sample "$_last" || unhealthy sample "no guard samples yet"
}

# A standby backend is installed but never loaded: its plist sits in standby/,
# where launchd does not look, and its stamp is kept for the next activation.
check_standby() {
    _b=$1
    _label="com.mac-studio-server.$_b"
    echo "$_b:"
    if launchctl print "system/$_label" >/dev/null 2>&1; then
        unhealthy standby "standby but loaded (sudo launchctl bootout system/$_label)"
    elif [ ! -e "$ETC_DIR/standby/$_label.plist" ]; then
        unhealthy standby "standby plist missing"
    elif [ ! -e "$DB_DIR/$_b.model.verified" ]; then
        unhealthy standby "standby stamp missing"
    else
        healthy standby "standby (not running; scripts/backend.sh activate $_b)"
    fi
}

# Ollama
if has_conf; then _sel=$(conf_get MSS_BACKENDS); else _sel=""; fi
_sel=${_sel:-ollama}
case ",$_sel," in
    *,ollama,*)
        echo "ollama:"
        _state=$(launchctl print system/com.ollama.service 2>/dev/null | sed -n 's/^[[:space:]]*state = \(.*\)$/\1/p' | head -n 1)
        [ -n "$_state" ] && healthy launchd "$_state" || unhealthy launchd "not loaded"
        if _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:11434/api/version 2>/dev/null) && [ "$_code" = 200 ]; then
            healthy health "HTTP 200 (/api/version)"
        else
            unhealthy health "no /api/version response"
        fi
        ;;
esac

if [ -e "$ETC_DIR/commit.journal" ]; then
    echo "install:"
    unhealthy install "interrupted install (re-run the install to finish it)"
fi

# Optional backends: one row per selected one, active or standby.
_opt=$(conf_get MSS_GUARD_BACKEND)
_all=$(mss_optional_backends "$_sel")
[ -z "$_opt" ] || case " $_all " in *" $_opt "*) ;; *) _all="$_opt $_all" ;; esac
for _b in $_all; do
    if [ "$_b" = "$_opt" ]; then
        # Installed without a model (M3): no backend or guard job exists yet.
        if [ "$(conf_get MSS_MODEL_STATE)" = waiting ]; then
            echo "$_opt: waiting for a model (run scripts/model.sh)"
        else
            check_backend "$_opt"
        fi
    else
        check_standby "$_b"
    fi
done
if [ -n "$_all" ] && [ -z "$_opt" ]; then
    echo "optional:"
    healthy active "no optional backend active"
fi

# Any model server that is not the active job is outside the guard's view.
if [ -n "$_all" ]; then
    # A running active job whose PID this user cannot read could be any of
    # them; a job that is not running is none of them.
    _apid=""; _arunning=0
    if [ -n "$_opt" ]; then
        _aprint=$(launchctl print "system/com.mac-studio-server.$_opt" 2>/dev/null)
        _apid=$(printf '%s\n' "$_aprint" | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -n 1)
        printf '%s\n' "$_aprint" | grep -q '^[[:space:]]*state = running' && _arunning=1
    fi
    # Ollama's own embedding worker is part of Ollama, not an unmanaged server
    # (#35). It must run as the service user: the installed conf's under sudo,
    # this user's otherwise. Another user's process is unreadable without root,
    # so a non-root run by someone else shows it as unmanaged (check 2).
    if [ "$(id -u)" -eq 0 ]; then _wuid=$(mss_conf_service_uid); else _wuid=$(id -u); fi
    if ! _servers=$(mss_model_servers); then
        echo "servers:"; unhealthy servers "pgrep is missing; cannot check for other model servers"
    else
        _hdr=0; _hint=0
        while read -r _sn _sp; do
            [ -n "$_sp" ] || continue
            if [ -n "$_apid" ] && mss_pid_under "$_sp" "$_apid"; then continue; fi
            _why=""
            if [ "$_sn" = llama-server ]; then
                mss_ollama_embed_worker "$_sp" "$_wuid"
                case $? in
                    0) [ "$_hdr" = 1 ] || { echo "servers:"; _hdr=1; }
                       healthy worker "ollama embedding worker pid $_sp (part of Ollama)"
                       continue ;;
                    3) _why=" (not a verified Ollama embedding worker: $MSS_WORKER_REASON)" ;;
                esac
            fi
            if [ -z "$_apid" ] && [ "$_arunning" = 1 ]; then _hint=1; continue; fi
            [ "$_hdr" = 1 ] || { echo "servers:"; _hdr=1; }
            unhealthy unmanaged "unmanaged $_sn pid $_sp (not guarded)$_why"
        done <<MSS_SERVERS_EOF
$_servers
MSS_SERVERS_EOF
        [ "$_hint" = 0 ] || echo "  (run with sudo to check for unmanaged servers)"
    fi
fi

if [ -n "$_opt" ]; then
    # pf checks (sudo only): enabled, referenced by the main ruleset, and the
    # anchor rule count equals the rendered MSS_PF_RULE_COUNT.
    _host=$(conf_get "$(mss_backend_prefix "$_opt")_HOST")
    _host=${_host:-127.0.0.1}
    _count=$(conf_get MSS_PF_RULE_COUNT); _count=${_count:-0}
    if ! mss_is_loopback_host "$_host" && [ "$_count" != 0 ]; then
        echo "pf:"
        if [ "$(id -u)" -eq 0 ]; then
            if "$MSS_PFCTL" -s info 2>/dev/null | grep -q 'Status: Enabled'; then
                healthy pf "enabled"
            else
                unhealthy pf "Status is not Enabled"
            fi
            if "$MSS_PFCTL" -sr 2>/dev/null | grep -Eq 'anchor "com\.apple/\*"'; then
                healthy pf "com.apple/* referenced"
            else
                unhealthy pf "com.apple/* not referenced"
            fi
            _loaded=$("$MSS_PFCTL" -a "$ANCHOR" -sr 2>/dev/null | grep -c '[^[:space:]]')
            [ "$_loaded" -eq "$_count" ] && healthy pf "anchor rules $_loaded/$_count" \
                || unhealthy pf "anchor rules $_loaded, expected $_count"
        else
            echo "  (run with sudo for pf checks)"
        fi
    fi
elif [ -z "$_all" ]; then
    [ -r "$MSS_CONF" ] || [ "$_sel" = ollama ] || { echo "no backends.conf found and no optional backend installed"; exit 1; }
fi

# ── host choices (#27 D9): read-only lines; power and Docker never change the
# exit code ────────────────────────────────────────────────────────────────────
echo "host:"
_r=$(mss_gpu_job_read); _kind=${_r%%|*}; _rec=${_r#*|}
case $_kind in
    both)
        unhealthy "gpu memory" "both GPU boot jobs installed; run scripts/install.sh with MSS_GPU_PERCENT" ;;
    new)
        # The recorded percent goes into arithmetic below, so anything but
        # 1-100 without a leading zero is treated as unreadable.
        if [ "$_rec" = unreadable ] || ! mss_match "$_rec" '^[1-9][0-9]{0,2}$' || [ "$_rec" -gt 100 ]; then
            unhealthy "gpu memory" "$MSS_GPU_LABEL is unreadable"
        else
            _mb=$(mss_wired_limit_mb "$_rec" 2>/dev/null)
            _live=$(_mss_sysctl -n iogpu.wired_limit_mb 2>/dev/null)
            if [ -n "$_mb" ] && [ "$_live" = "$_mb" ]; then
                healthy "gpu memory" "$_rec% ($_mb MB), live $_live MB ($MSS_GPU_LABEL)"
            else
                unhealthy "gpu memory" "$_rec% wants $_mb MB, live ${_live:-unreadable} MB ($MSS_GPU_LABEL)"
            fi
        fi ;;
    legacy)
        healthy "gpu memory" "${_rec:-80}% via $MSS_GPU_LABEL_LEGACY, live $(_mss_sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo unreadable) MB"
        echo "    $(mss_gpu_legacy_note)" ;;
    none)
        healthy "gpu memory" "system default (no boot job)" ;;
esac

_pcur=$(mss_power_current) && _pw="$_pcur" || _pw="unsupported"
echo "  $(printf '%-10s %s' 'power' "restore autorestart=$_pw")"

if [ -f "$(mss_daemon_dir)/$MSS_DOCKER_LABEL.plist" ]; then
    _d=off; _mss_gpu_loaded "$MSS_DOCKER_LABEL" && _d=on
    echo "  $(printf '%-10s %s' 'docker' "at boot $_d ($MSS_DOCKER_LABEL)")"
else
    echo "  $(printf '%-10s %s' 'docker' "at boot off ($MSS_DOCKER_LABEL not installed)")"
fi

[ "$fail" -eq 0 ] || exit 1
exit 0
