#!/bin/sh
# hold-lock.sh <seconds> | --mut '<command>' — hold the lifecycle lock (#1 D15).
# Takes the lock as "hold-lock", prints "held <pid> <keeper pid> <session>",
# then either sleeps in the foreground (the shell holds no lock descriptor, so a
# kill of this shell alone frees the lock while its sleep lives on) or runs the
# command through mss_mut, as a lifecycle command's mutating child.
_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
. "$_root/scripts/lib/mss-common.sh"
mss_lock_acquire hold-lock
echo "held $$ $MSS_LOCK_KEEPER $MSS_LOCK_SESSION"
if [ "${1:-}" = --mut ]; then
    mss_mut /bin/sh -c "$2"
    exit $?
fi
sleep "${1:-30}"
