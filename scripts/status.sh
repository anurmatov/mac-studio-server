#!/bin/sh
# status.sh — health report for the selected backends (#9).
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

check_backend() {
    _b=$1
    _upper=$(echo "$_b" | tr '[:lower:]' '[:upper:]')
    _host=$(conf_get "${_upper}_HOST"); _host=${_host:-127.0.0.1}
    _port=$(conf_get "${_upper}_PORT"); _port=${_port:-$( [ "$_b" = ds4 ] && echo 8000 || echo 8080 )}
    _label="com.mac-studio-server.$_b"
    _lan=no; mss_is_loopback_host "$_host" || _lan=yes

    echo "$_b (host=$_host port=$_port lan-bound=$_lan):"

    _state=$(launchctl print "system/$_label" 2>/dev/null | sed -n 's/^[[:space:]]*state = \(.*\)$/\1/p' | head -n 1)
    [ -n "$_state" ] && healthy launchd "$_state" || unhealthy launchd "not loaded"

    if lsof -nP -iTCP:"$_port" -sTCP:LISTEN >/dev/null 2>&1; then
        healthy listener "listening on $_host:$_port"
    else
        unhealthy listener "nothing listening on $_port"
    fi

    case $_b in
        ds4)      _path=/v1/models ;;
        llamacpp) _path=/health ;;
    esac
    if _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$_host:$_port$_path" 2>/dev/null); then
        # llama-server returns 503 while loading; that is healthy-but-loading.
        case "$_code" in 200|503) healthy health "HTTP $_code ($_path)" ;; *) unhealthy health "HTTP $_code ($_path)" ;; esac
    else
        unhealthy health "no response on $_path"
    fi

    if [ -e /var/db/mac-studio-server/guard.tripped ]; then
        unhealthy guard "trip marker present"
    else
        healthy guard "no trip marker"
    fi

    _last=$(tail -n 1 /var/log/mac-studio-server/guard.jsonl 2>/dev/null)
    [ -n "$_last" ] && healthy sample "$_last" || unhealthy sample "no guard samples yet"
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

# Optional backend
_opt=$(conf_get MSS_GUARD_BACKEND)
if [ -n "$_opt" ]; then
    # Installed without a model (M3): no backend or guard job exists yet.
    if [ "$(conf_get MSS_MODEL_STATE)" = waiting ]; then
        echo "$_opt: waiting for a model (run scripts/model.sh)"
    else
        check_backend "$_opt"
    fi

    # pf checks (sudo only): enabled, referenced by the main ruleset, and the
    # anchor rule count equals the rendered MSS_PF_RULE_COUNT.
    _host=$(conf_get "$(echo "$_opt" | tr '[:lower:]' '[:upper:]')_HOST")
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
else
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
        if [ "$_rec" = unreadable ]; then
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
