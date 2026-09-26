#!/bin/sh
# uninstall.sh — idempotent removal (#9).
#   scripts/uninstall.sh --backend {ollama|llamacpp|ds4} | --all [--purge-logs]
# Removes the selected backend's job, plist, stamp and pf rules; re-renders the
# conf and pf rules for whatever remains. Removes boot/guard/shared dirs once no
# optional backend is left. Keeps model files; keeps logs unless --purge-logs.

set -u

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib/mss-common.sh"

usage() { echo "usage: uninstall.sh --backend {ollama|llamacpp|ds4} | --all [--purge-logs]" >&2; exit 2; }

TARGET=""
PURGE_LOGS=0
while [ $# -gt 0 ]; do
    case $1 in
        --backend) TARGET=${2:?}; shift 2 ;;
        --all) TARGET=all; shift ;;
        --purge-logs) PURGE_LOGS=1; shift ;;
        *) usage ;;
    esac
done
[ -n "$TARGET" ] || usage
case $TARGET in ollama|llamacpp|ds4|all) ;; *) usage ;; esac

if [ "$(id -u)" -ne 0 ]; then
    mss_die "uninstall.sh must run with sudo"
fi

LIBEXEC_DIR="/usr/local/libexec/mac-studio-server"
ETC_DIR="/usr/local/etc/mac-studio-server"
DB_DIR="/var/db/mac-studio-server"
LOG_DIR="/var/log/mac-studio-server"
PLIST_DIR="/Library/LaunchDaemons"
CONF="$ETC_DIR/backends.conf"
ANCHOR="com.apple/250.mac-studio-server"

conf_get() { awk -F= -v k="$1" 'index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "$CONF" 2>/dev/null; }

bootout_label() {
    launchctl bootout "system/$1" 2>/dev/null || true
}

remove_plist() {
    bootout_label "$1"
    rm -f "$PLIST_DIR/$1.plist"
}

remaining_optional() {
    # after removing TARGET, is an optional backend still selected?
    _sel=",$(conf_get MSS_BACKENDS),"
    case $TARGET in
        llamacpp|ds4) _sel=$(echo "$_sel" | sed "s/,$TARGET,//") ;;
        all) _sel="" ;;
    esac
    case $_sel in *llamacpp*|*ds4*) return 0 ;; *) return 1 ;; esac
}

case $TARGET in
    ollama)
        remove_plist com.ollama.service
        echo "removed com.ollama.service (Ollama itself is untouched)"
        ;;
    llamacpp|ds4)
        remove_plist "com.mac-studio-server.$TARGET"
        rm -f "$DB_DIR/$TARGET.model.verified"
        echo "removed com.mac-studio-server.$TARGET and its stamp"
        if remaining_optional; then
            echo "note: another optional backend remains; re-run scripts/install-backends.sh to re-render"
        fi
        ;;
    all)
        remove_plist com.ollama.service
        remove_plist com.mac-studio-server.llamacpp
        remove_plist com.mac-studio-server.ds4
        rm -f "$DB_DIR/llamacpp.model.verified" "$DB_DIR/ds4.model.verified"
        echo "removed backend jobs, plists and stamps"
        ;;
esac

# Shared guard/boot removal when no optional backend remains.
if ! remaining_optional; then
    remove_plist com.mac-studio-server.guard
    remove_plist com.mac-studio-server.boot
    rm -f /var/run/com.mac-studio-server.boot.ok
    /sbin/pfctl -a "$ANCHOR" -F all 2>/dev/null || true
    rm -f "$CONF" "$ETC_DIR/pf.conf"
    rm -rf "$LIBEXEC_DIR"
    [ "$PURGE_LOGS" -eq 1 ] && rm -rf "$LOG_DIR"
    echo "removed guard, boot, conf, pf rules, marker and shared dirs (model files kept)"
    [ "$PURGE_LOGS" -eq 0 ] && echo "logs kept in $LOG_DIR (use --purge-logs to remove)"
fi

[ "$TARGET" = all ] && { rmdir "$ETC_DIR" "$DB_DIR" 2>/dev/null || true; }
echo "uninstall complete (idempotent; re-running is safe)"
exit 0
