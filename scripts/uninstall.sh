#!/bin/sh
# uninstall.sh — idempotent removal (#9, #1 D12).
#   scripts/uninstall.sh --backend {ollama|llamacpp|ds4|mlx} | --all [--purge-logs]
# Removing one optional backend boots it out (and waits for launchd to release
# it), removes its plist from both locations, its stamp and its plist record
# line, and drops its keys from the conf. Removing the active one also removes
# the guard; nothing else becomes active. The shared jobs, conf and dirs go once
# no optional backend is left. Model files and backends.env are never touched;
# logs are kept unless --purge-logs. It holds the lifecycle lock; while an
# install was interrupted only --all proceeds (and removes the journal).

set -u

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib/mss-common.sh"
. "$REPO_DIR/scripts/lib/mss-host.sh"
mss_host_root_guard

usage() { echo "usage: uninstall.sh --backend {ollama|llamacpp|ds4|mlx} | --all [--purge-logs]" >&2; exit 2; }

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
case $TARGET in ollama|llamacpp|ds4|mlx|all) ;; *) usage ;; esac

if [ "$(id -u)" -ne 0 ]; then
    mss_die "uninstall.sh must run with sudo"
fi

LIBEXEC_DIR="/usr/local/libexec/mac-studio-server"
ETC_DIR="/usr/local/etc/mac-studio-server"
DB_DIR="/var/db/mac-studio-server"
LOG_DIR="/var/log/mac-studio-server"
PLIST_DIR="/Library/LaunchDaemons"
STANDBY_DIR="$ETC_DIR/standby"
CONF="$ETC_DIR/backends.conf"
RECORD="$DB_DIR/plists.sha256"
JOURNAL="$ETC_DIR/commit.journal"
STAGE="$ETC_DIR/.stage"
ANCHOR="com.apple/250.mac-studio-server"

conf_get() { awk -F= -v k="$1" 'index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "$CONF" 2>/dev/null; }

mss_lock_acquire uninstall
if [ -e "$JOURNAL" ]; then
    [ "$TARGET" = all ] || mss_die "an install was interrupted; re-run the install to finish it"
    mss_mut rm -rf "$JOURNAL" "$STAGE"
    echo "removed the interrupted install's journal and staging directory"
fi

loaded() { launchctl print "system/$1" >/dev/null 2>&1; }

bootout_label() {
    loaded "$1" || return 0
    mss_lock_check
    mss_mut launchctl bootout "system/$1" || true
}

# bootout_wait <label>: boot it out and wait until launchd has released it.
bootout_wait() {
    loaded "$1" || return 0
    bootout_label "$1"
    mss_launchd_wait_gone "$1" "${MSS_LAUNCHD_TIMEOUT:-60}" || mss_die "$1 did not stop; run the uninstall again"
}

# drop_record <path>...: their lines leave the plist record.
drop_record() {
    [ -e "$RECORD" ] || return 0
    mss_lock_check
    # shellcheck disable=SC2016  # the script is for sh -c
    mss_mut /bin/sh -c 'r=$1; shift; awk -v l="$*" "BEGIN { n = split(l, p, \" \"); for (i = 1; i <= n; i++) d[p[i]] = 1 } !(\$2 in d)" "$r" > "$r.tmp" && chown root:wheel "$r.tmp" && chmod 0644 "$r.tmp" && mv -f "$r.tmp" "$r"' \
        sh "$RECORD" "$@"
}

remove_plist() {
    bootout_label "$1"
    mss_lock_check
    mss_mut rm -f "$PLIST_DIR/$1.plist" "$STANDBY_DIR/$1.plist"
    drop_record "$PLIST_DIR/$1.plist" "$STANDBY_DIR/$1.plist"
}

remove_backend_files() { # the plists, stamps and record lines of one optional backend
    _l="com.mac-studio-server.$1"
    bootout_wait "$_l"
    mss_lock_check
    mss_mut rm -f "$PLIST_DIR/$_l.plist" "$STANDBY_DIR/$_l.plist" \
        "$DB_DIR/$1.model.verified" "$DB_DIR/$1.model.verified.next"
    drop_record "$PLIST_DIR/$_l.plist" "$STANDBY_DIR/$_l.plist"
}

remaining_optional() {
    # after removing TARGET, is an optional backend still selected?
    _sel=",$(conf_get MSS_BACKENDS),"
    case $TARGET in
        llamacpp|ds4|mlx) _sel=$(echo "$_sel" | sed "s/,$TARGET,/,/") ;;
        all) _sel="" ;;
    esac
    case $_sel in *,llamacpp,*|*,ds4,*|*,mlx,*) return 0 ;; *) return 1 ;; esac
}

case $TARGET in
    ollama)
        remove_plist com.ollama.service
        echo "removed com.ollama.service (Ollama itself is untouched)"
        ;;
    llamacpp|ds4|mlx)
        _active=$(conf_get MSS_GUARD_BACKEND)
        remove_backend_files "$TARGET"
        echo "removed com.mac-studio-server.$TARGET and its stamp"
        if remaining_optional; then
            # The other backends keep their plists, stamps and keys; this one's
            # name and keys leave the conf. Nothing becomes active by itself.
            _was_active=0; [ "$_active" != "$TARGET" ] || _was_active=1
            if [ "$_was_active" = 1 ]; then
                remove_plist com.mac-studio-server.guard
                echo "removed the guard; no optional backend is active (scripts/backend.sh activate <backend>)"
            fi
            mss_lock_check
            # shellcheck disable=SC2016  # the script is for sh -c
            mss_mut /bin/sh -c 'awk -v t="$2" -v p="$3_" -v a="$4" "
                index(\$0, \"MSS_BACKENDS=\") == 1 {
                    n = split(substr(\$0, 14), s, \",\"); o = \"\"
                    for (i = 1; i <= n; i++) if (s[i] != t) o = o (o == \"\" ? \"\" : \",\") s[i]
                    print \"MSS_BACKENDS=\" o; next }
                index(\$0, p) == 1 { next }
                a == 1 && (index(\$0, \"MSS_GUARD_BACKEND=\") == 1 || index(\$0, \"MSS_MODEL_STATE=\") == 1) { next }
                { print }" "$1" > "$1.tmp" && chown root:wheel "$1.tmp" && chmod 0644 "$1.tmp" && mv -f "$1.tmp" "$1"' \
                sh "$CONF" "$TARGET" "$(mss_backend_prefix "$TARGET")" "$_was_active"
            if [ -d "$STANDBY_DIR" ] && [ -z "$(ls -A "$STANDBY_DIR" 2>/dev/null)" ]; then mss_mut rmdir "$STANDBY_DIR" || true; fi
            echo "the conf keeps the other optional backends (pf rules of a removed LAN backend stay until the next install)"
        fi
        ;;
    all)
        # D10: both GPU labels go with --all, never with --backend. The live
        # wired limit stays until the next reboot.
        mss_gpu_jobs_remove \
            && echo "removed both GPU boot jobs (the live wired limit lasts until reboot)" \
            || mss_error "could not remove both GPU boot jobs; check launchctl print system/$MSS_GPU_LABEL"
        remove_plist com.ollama.service
        for _b in llamacpp ds4 mlx; do remove_backend_files "$_b"; done
        echo "removed backend jobs, plists and stamps"
        ;;
esac

# Shared guard/boot removal when no optional backend remains.
if ! remaining_optional; then
    remove_plist com.mac-studio-server.guard
    remove_plist com.mac-studio-server.boot
    mss_lock_check
    mss_mut rm -f /var/run/com.mac-studio-server.boot.ok
    # shellcheck disable=SC2016
    mss_mut /bin/sh -c '/sbin/pfctl -a "$1" -F all >/dev/null 2>&1; exit 0' sh "$ANCHOR"
    mss_mut rm -rf "$CONF" "$ETC_DIR/pf.conf" "$STANDBY_DIR" "$RECORD" "$LIBEXEC_DIR"
    [ "$PURGE_LOGS" -eq 0 ] || mss_mut rm -rf "$LOG_DIR"
    echo "removed guard, boot, conf, pf rules, marker and shared dirs (model files kept)"
    [ "$PURGE_LOGS" -eq 0 ] && echo "logs kept in $LOG_DIR (use --purge-logs to remove)"
fi

# shellcheck disable=SC2016
[ "$TARGET" != all ] || mss_mut /bin/sh -c 'rmdir "$1" "$2" 2>/dev/null; exit 0' sh "$ETC_DIR" "$DB_DIR"
echo "uninstall complete (idempotent; re-running is safe)"
exit 0
