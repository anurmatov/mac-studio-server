#!/bin/sh
# status.sh — health report for the selected backends (#9).
# Exit 0 only if every selected backend is healthy. Never prints a key.
# With sudo, also verifies pf (enabled, referenced, full rule count) whenever a
# backend is LAN-bound.

set -u

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib/mss-common.sh"

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
    check_backend "$_opt"

    # pf checks (sudo only): enabled, referenced by the main ruleset, and the
    # anchor rule count equals the rendered MSS_PF_RULE_COUNT.
    _host=$(conf_get "$(echo "$_opt" | tr '[:lower:]' '[:upper:]')_HOST")
    _host=${_host:-127.0.0.1}
    if ! mss_is_loopback_host "$_host"; then
        echo "pf:"
        if [ "$(id -u)" -eq 0 ]; then
            _count=$(conf_get MSS_PF_RULE_COUNT)
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

[ "$fail" -eq 0 ] || exit 1
exit 0
