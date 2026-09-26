#!/bin/sh
# mss-boot.sh — one-shot root boot daemon for mac-studio-server pf policy (#9 D3).
#
# Installs as com.mac-studio-server.boot only when a backend has a pf policy.
# Order is fail-closed: stale marker deleted FIRST, then pf enabled, anchor
# loaded, and all three checks verified BEFORE the marker is written. A LAN-
# bound backend cannot start without this boot's marker.

set -u

LABEL="com.mac-studio-server.boot"
_self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# repo layout: libexec/*.sh + scripts/lib/mss-common.sh; installed: same dir.
# A missing file in `.` is fatal in POSIX sh, so test first.
if [ -f "$_self_dir/mss-common.sh" ]; then
    . "$_self_dir/mss-common.sh"
else
    . "$_self_dir/../scripts/lib/mss-common.sh"
fi

PF_CONF="${PF_CONF:-/usr/local/etc/mac-studio-server/pf.conf}"
ANCHOR="com.apple/250.mac-studio-server"
MARKER="${MARKER:-/var/run/com.mac-studio-server.boot.ok}"
MSS_PFCTL=$(mss_conf_get MSS_PFCTL || echo /sbin/pfctl)
MSS_PF_RULE_COUNT=$(mss_conf_get MSS_PF_RULE_COUNT || echo 0)

fail() {
    echo "$LABEL: $*"
    exit 1
}

# 0. A marker from a previous boot must never authorise this one.
rm -f "$MARKER"

# 1. Enable pf. `-E` takes an enable reference which is never released, so pf
#    stays enabled for the whole boot (a matching -X would disable it again).
"$MSS_PFCTL" -E >/dev/null 2>&1 || fail "pfctl -E failed"

# 2. Load the sub-anchor ruleset.
"$MSS_PFCTL" -a "$ANCHOR" -f "$PF_CONF" >/dev/null 2>&1 || fail "pfctl -a $ANCHOR -f failed"

# 3. Verify (a) enabled, (b) referenced by the main ruleset, (c) fully loaded.
"$MSS_PFCTL" -s info | grep -q 'Status: Enabled' || fail "pf check (a) failed: Status is not Enabled"

"$MSS_PFCTL" -sr | grep -Eq 'anchor "com\.apple/\*"' || fail "pf check (b) failed: main ruleset does not reference com.apple/*"

_loaded=$("$MSS_PFCTL" -a "$ANCHOR" -sr | grep -c '[^[:space:]]')
[ "$_loaded" -eq "$MSS_PF_RULE_COUNT" ] || fail "pf check (c) failed: anchor has $_loaded rules, expected $MSS_PF_RULE_COUNT"

# 4. Only now write this boot's marker.
sysctl -n kern.boottime > "$MARKER"
chown root:wheel "$MARKER"
chmod 0644 "$MARKER"
echo "$LABEL: pf verified (enabled, referenced, $_loaded rules); marker written"
