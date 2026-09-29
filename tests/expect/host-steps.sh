#!/bin/sh
# host-steps.sh — the #27 host prompts (G, P, DI, DA) the picker will show on
# this Mac, as drive.exp steps answered with Enter.
#
#   sh tests/expect/host-steps.sh >> steps
#
# The picker shows P only when `pmset -g` prints an autorestart line, and DI or
# DA depending on where colima and docker are relative to the boot job's PATH.
# A CI job that drives the real picker asks this script instead of assuming what
# the runner image has installed. Run it with the PATH install.sh will see.
T=$(printf '\t')
# config/com.colima.daemon.plist's PATH; tests/run.sh pins mss-host.sh to it.
JOB_PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin

printf '%s\n' "or system [${T}@ENTER"
if /usr/bin/pmset -g 2>/dev/null | awk '$1 == "autorestart" { f = 1 } END { exit !f }'; then
    printf '%s\n' "after a power failure? [${T}@ENTER"
fi

on_job() ( PATH=$JOB_PATH; export PATH; command -v "$1" >/dev/null 2>&1 )
elsewhere=0
for t in colima docker; do
    on_job "$t" && continue
    command -v "$t" >/dev/null 2>&1 && elsewhere=1
done
if [ "$elsewhere" = 1 ]; then
    : # a tool outside the job's PATH: neither Docker question is asked
elif on_job colima && on_job docker; then
    printf '%s\n' "at every boot? Currently ${T}@ENTER"
else
    printf '%s\n' "with Homebrew? [${T}@ENTER"
fi
