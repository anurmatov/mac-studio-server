#!/bin/sh
# mss-envfile-set.sh <backends.env> <sha256 of the installed conf>
#
# The installer's phase 6 save (#1 D5): the root pass runs it as the file's
# owner, still holding the lifecycle lock. It sets MSS_BACKENDS and
# MSS_ACTIVE_BACKEND to the installed values (MSS_ACTIVE_BACKEND only where
# backends.env carries it: two or more optional backends, or none active) and
# leaves every other line as it is. Right before the rename it hashes the
# installed conf again: if that is no longer the conf this install committed,
# it exits 3 without writing, so a late save can never record stale values.

set -u

_self_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$_self_dir/mss-common.sh"

[ $# -eq 2 ] || { echo "usage: mss-envfile-set.sh <backends.env> <conf sha256>" >&2; exit 2; }
FILE=$1; WANT=$2
[ "$(id -u)" -ne 0 ] || mss_die "refusing to write $FILE as root"
# A regular file, not a symlink, owned by this user and writable by no one else.
mss_envfile_check_file "$FILE" || exit 1
( mss_envfile_load "$FILE" ) >/dev/null || exit 1

CONF=$(mss_conf_path)
stale() { mss_error "installed state changed meanwhile; not saved"; exit 3; }
[ "$(mss_file_sha "$CONF")" = "$WANT" ] || stale
SEL=$(mss_conf_get MSS_BACKENDS)
[ -n "$SEL" ] || mss_die "$CONF has no MSS_BACKENDS"
ACT=$(mss_conf_get MSS_GUARD_BACKEND); ACT=${ACT:-none}
N=$(mss_count_words "$(mss_optional_backends "$SEL")")
LINE=""
if [ "$N" -ge 2 ] || { [ "$N" -ge 1 ] && [ "$ACT" = none ]; }; then LINE=$ACT; fi

TMP=$(mktemp "$(dirname "$FILE")/.backends.env.XXXXXX") || mss_die "cannot create a temporary file next to $FILE"
chmod 600 "$TMP" || { rm -f "$TMP"; exit 1; }
awk -v sel="$SEL" -v act="$LINE" '
    /^MSS_BACKENDS=/ { print "MSS_BACKENDS=" sel; if (act != "") print "MSS_ACTIVE_BACKEND=" act; next }
    /^MSS_ACTIVE_BACKEND=/ { next }
    { print }' "$FILE" > "$TMP" || { rm -f "$TMP"; mss_die "cannot write $TMP"; }
if cmp -s "$TMP" "$FILE"; then rm -f "$TMP"; exit 0; fi
[ "$(mss_file_sha "$CONF")" = "$WANT" ] || { rm -f "$TMP"; stale; }
mv -f "$TMP" "$FILE" || { rm -f "$TMP"; mss_die "cannot replace $FILE"; }
exit 0
