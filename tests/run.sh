#!/bin/sh
# tests/run.sh — mac-studio-server test harness (#9).
#
# Phase A (always): static checks, pure-function tests, render-only rendering.
# Phase B (only when CI=true or MSS_TEST_ALLOW_SYSTEM=1): launchd/pf system
# tests with stub servers — these disable services and load pf rules.

set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d /tmp/mss-tests.XXXXXX)
# The resolver returns physical paths; on macOS /tmp is a link to /private/tmp.
PTMP=$(cd "$TMP" && pwd -P)
PASS=0; FAIL=0
# MSS_TEST_PHASE=A runs only phase A, B only phase B; default runs both.
PHASE=${MSS_TEST_PHASE:-all}

ok()   { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { # check <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2' got '$3')"; fi
}
check_fail() { # check_fail <desc> <cmd...>
    if "$@" >/dev/null 2>&1; then fail "$1 (command unexpectedly succeeded)"; else ok "$1"; fi
}

. "$ROOT/scripts/lib/mss-common.sh"

# ── live-state guard and hash audit (#21) ─────────────────────────────────────
# The installed paths phase A must leave alone. A glob that matches nothing
# stays literal and is recorded as absent.
live_paths() {
    printf '%s\n' /usr/local/etc/mac-studio-server/backends.conf /usr/local/etc/mac-studio-server/pf.conf
    for _lp in /var/db/mac-studio-server/*.model.verified /usr/local/libexec/mac-studio-server/* \
        /Library/LaunchDaemons/com.mac-studio-server.*.plist; do
        printf '%s\n' "$_lp"
    done
    printf '%s\n' /usr/local/bin/ollama /Library/LaunchDaemons/com.ollama.service.plist \
        /Library/LaunchDaemons/com.mac-studio-server.gpumemory.plist \
        /Library/LaunchDaemons/com.colima.daemon.plist "$ROOT/backends.env"
}
# live_snap: paths on stdin, "path<TAB>state" out. Only stat, without -L; the
# contents of a file are never read.
live_snap() {
    while IFS= read -r _lp; do
        if [ -e "$_lp" ] || [ -L "$_lp" ]; then
            _ls=$(stat -f '%N %d %i %z %m %c %p %u %g %Y' "$_lp" 2>/dev/null) || _ls=unstatable
        else
            _ls=absent
        fi
        printf '%s\t%s\n' "$_lp" "$_ls"
    done
}
# live_diff <before> <after>: "path<TAB>same|changed" for each path in either.
live_diff() {
    awk -F'\t' 'NR == FNR { b[$1] = $2; seen[$1] = 1; next } { a[$1] = $2; seen[$1] = 1 }
        END { for (p in seen) { x = (p in b) ? b[p] : "absent"; y = (p in a) ? a[p] : "absent"
                                print p "\t" (x == y ? "same" : "changed") } }' "$1" "$2" | sort
}
# audit_bad <log>: logged dd and shasum inputs that are not under the test directory.
audit_bad() {
    awk -v t="$TMP/" -v p="$PTMP/" '{ f = substr($0, index($0, " ") + 1)
        if (f != "-" && index(f, t) != 1 && index(f, p) != 1) print }' "$1"
}

if [ "$PHASE" != B ]; then
# As root, --check-only writes a stamp for a fixture model and the real model
# is then refused at its next start (#21).
if [ "$(id -u)" -eq 0 ]; then
    echo "phase A must run as a non-root user" >&2
    exit 2
fi
# Non-root lookups of the host go under a sysroot of our own: the conf does not
# exist there, and HOME is empty. A test that sets MSS_CONF itself still wins.
SAVED_HOME=$HOME; SAVED_PATH=$PATH
mkdir -p "$TMP/sysroot" "$TMP/home" || { echo "cannot create the phase A sysroot" >&2; exit 2; }
MSS_TEST_SYSROOT=$TMP/sysroot
MSS_CONF=$TMP/sysroot/usr/local/etc/mac-studio-server/backends.conf
HOME=$TMP/home
export MSS_TEST_SYSROOT MSS_CONF HOME
[ "$(uname)" != Darwin ] || live_paths | live_snap > "$TMP/live.before"
# Hash audit: dd and shasum run through shims that log their input and exec the
# real tool (the PID stays dd's, so SIGINFO progress still works).
AUDIT_LOG="$TMP/audit.log"; : > "$AUDIT_LOG"
REAL_DD=$(command -v dd 2>/dev/null); REAL_SHASUM=$(command -v shasum 2>/dev/null)
AUDIT=0
if [ -n "$REAL_DD" ] && [ -n "$REAL_SHASUM" ]; then
    mkdir -p "$TMP/auditbin"
    cat > "$TMP/auditbin/dd" <<SHIM
#!/bin/sh
for _a in "\$@"; do
    case \$_a in if=*) printf 'dd %s\n' "\${_a#if=}" >> '$AUDIT_LOG' ;; esac
done
exec '$REAL_DD' "\$@"
SHIM
    cat > "$TMP/auditbin/shasum" <<SHIM
#!/bin/sh
_skip=0; _any=0
for _a in "\$@"; do
    if [ "\$_skip" = 1 ]; then _skip=0; continue; fi
    case \$_a in
        -a) _skip=1 ;;
        -?*) ;;
        *) printf 'shasum %s\n' "\$_a" >> '$AUDIT_LOG'; _any=1 ;;
    esac
done
[ "\$_any" = 1 ] || printf 'shasum -\n' >> '$AUDIT_LOG'
exec '$REAL_SHASUM' "\$@"
SHIM
    chmod +x "$TMP/auditbin/dd" "$TMP/auditbin/shasum"
    PATH="$TMP/auditbin:$PATH"; export PATH
    AUDIT=1
else
    fail "hash audit needs shasum and dd"
fi

echo "== phase A: static =="
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning -s sh "$ROOT"/libexec/*.sh "$ROOT"/scripts/lib/mss-common.sh "$ROOT"/scripts/lib/mss-host.sh "$ROOT"/scripts/install-backends.sh "$ROOT"/scripts/status.sh "$ROOT"/scripts/uninstall.sh "$ROOT"/tests/expect/host-steps.sh; then
        ok "shellcheck -s sh"
    else
        fail "shellcheck -s sh"
    fi
    if shellcheck -S warning "$ROOT"/scripts/install.sh "$ROOT"/scripts/model.sh "$ROOT"/scripts/lib/mss-picker.sh "$ROOT"/scripts/lib/mss-acquire.sh "$ROOT"/scripts/lib/mss-run.sh; then ok "shellcheck bash scripts"; else fail "shellcheck bash scripts"; fi
else
    echo "skip - shellcheck not installed"
fi

for f in "$ROOT"/libexec/*.sh "$ROOT"/scripts/lib/*.sh "$ROOT"/scripts/*.sh; do
    sh -n "$f" || fail "sh -n $f"
done
ok "sh -n on all scripts"

BAD=$(grep -nE 'stat -c|sha256sum|readlink -f|date -d' "$ROOT"/libexec/*.sh "$ROOT"/scripts/lib/*.sh "$ROOT"/scripts/install-backends.sh "$ROOT"/scripts/status.sh "$ROOT"/scripts/uninstall.sh 2>/dev/null || true)
[ -z "$BAD" ] && ok "no GNU-only spellings" || fail "GNU-only spellings found: $BAD"
# #21: shasum only through mss_shasum256, which forces its locale.
BADSHA=$(grep -rnE '(^|[^_])shasum' "$ROOT/scripts" "$ROOT/libexec" "$ROOT/bootstrap.sh" \
    | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -vF 'mss_shasum256() { LC_ALL=C shasum -a 256 "$@"; }' || true)
[ -z "$BADSHA" ] && ok "shasum runs only through mss_shasum256 (#21)" || fail "shasum outside mss_shasum256: $BADSHA"
# #27 r2 adds install.sh: MSS_INSTALL_SANDBOX prefixes its absolute writes with
# the sysroot so phase A can run install.sh end to end without touching /Library.
# set-gpu-memory.sh reads it to gate its MSS_SYSCTL hook, never to find a path.
check "MSS_TEST_SYSROOT is read by exactly six files (#21, #27)" \
    "scripts/install-backends.sh scripts/install.sh scripts/lib/mss-host.sh scripts/lib/mss-picker.sh scripts/set-gpu-memory.sh tests/run.sh" \
    "$(cd "$ROOT" && grep -rl --exclude-dir=.git MSS_TEST_SYSROOT . | sed 's|^\./||' | sort | tr '\n' ' ' | sed 's/ $//')"
# Every PATH= keeps $PATH, so the hash-audit shims stay first (#21). tests/run.sh
# counts from the phase A header to its summary line. One form is exempt: a
# `PATH=<set>; export PATH` pair inside a subshell, which replaces the search
# path on purpose and is invisible to its caller — that is how _mss_job_tool
# asks whether a tool is on the boot job's PATH, where appending $PATH would
# report a tool the daemon cannot reach at boot.
PATHRE='(^|[^A-Za-z0-9_])PATH='
BADPATH=$( { grep -rnE "$PATHRE" "$ROOT/scripts" "$ROOT/libexec" "$ROOT/bootstrap.sh"
    awk '/^if \[ "\$PHASE" != B \]; then$/ { a = 1 } a { print FILENAME ":" FNR ":" $0 } /^echo "phase A: \$PASS passed/ { a = 0 }' \
        "$ROOT/tests/run.sh" | grep -E "$PATHRE"
    } | grep -Ev '\$(PATH|\{PATH\})([^A-Za-z0-9_]|$)' | grep -vF "PATHRE='" | grep -vF '; export PATH' || true)
[ -z "$BADPATH" ] && ok "every PATH= assignment keeps \$PATH (#21)" || fail "PATH= without \$PATH: $BADPATH"

echo "== phase A: mss_resolve_path =="
ln -s target2 "$TMP/link1" 2>/dev/null || true
echo x > "$TMP/target1"
ln -s ../$TMP/target1 "$TMP/target2" 2>/dev/null || { echo x > "$TMP/target2"; ln -sf "$TMP/target1" "$TMP/target2"; }
# simple 2-hop: link -> target
echo x > "$TMP/hop2"; ln -sf hop2 "$TMP/hop1"
check "resolve 2-hop absolute" "$PTMP/hop2" "$(mss_resolve_path "$TMP/hop1")"
# Homebrew-style relative chain: bin/tool -> ../Cellar/tool/1.0/bin/tool
mkdir -p "$TMP/brew/bin" "$TMP/brew/Cellar/tool/1.0/bin"
echo x > "$TMP/brew/Cellar/tool/1.0/bin/tool"
ln -sf ../Cellar/tool/1.0/bin/tool "$TMP/brew/bin/tool"
check "resolve relative Homebrew-style link" "$PTMP/brew/Cellar/tool/1.0/bin/tool" "$(mss_resolve_path "$TMP/brew/bin/tool")"
check_fail "resolve rejects relative" mss_resolve_path relative/path
# 41-hop loop
p="$TMP/loop0"; i=0
while [ $i -lt 42 ]; do ln -sf "loop$((i+1))" "$TMP/loop$i" 2>/dev/null; i=$((i+1)); done
check_fail "resolve rejects symlink loop" mss_resolve_path "$p"
ln -sf dangling-target "$TMP/dangling"
check_fail "resolve rejects dangling" mss_resolve_path "$TMP/dangling"

echo "== phase A: extra args =="
check "llamacpp args" "--n-gpu-layers 99 --flash-attn on --jinja --cache-type-k q8_0" \
    "$(mss_validate_extra_args llamacpp '-ngl 99 --flash-attn=on --jinja --cache-type-k q8_0' T)"
check "ds4 args" "--power 60 --threads 8" "$(mss_validate_extra_args ds4 '--power 60 --threads 8' T)"
for bad in '-ngl99' '-t=8' '--slot-save-path /tmp' '--path /' '--lora-scaled a 1' '--control-vector x' '--kv-disk-dir d' '--trace f' '--cors' '--flash-attn yes'; do
    check_fail "reject extra arg: $bad" mss_validate_extra_args llamacpp "$bad" T
done
check "ds4 MTP, prefill and warm-up args (#16)" "--mtp --mtp-draft 3 --mtp-exact-sampling --prefill-chunk 4096 --warm-weights" \
    "$(mss_validate_extra_args ds4 '--mtp --mtp-draft 3 --mtp-exact-sampling --prefill-chunk=4096 --warm-weights' T)"
check "ds4 range edges (#16)" "--mtp-draft 1 --prefill-chunk 512 --prefill-chunk 65536" \
    "$(mss_validate_extra_args ds4 '--mtp-draft 1 --prefill-chunk 512 --prefill-chunk 65536' T)"
for bad in '--mtp-model x' '--trace f' '--power 0' '--power 101' \
    '--mtp-draft 9' '--mtp-draft 0' '--mtp-draft=4' '--mtp-draft' '--mtp=1' '--warm-weights=1' '--warm-weights x' \
    '--prefill-chunk=abc' '--prefill-chunk 511' '--prefill-chunk 65537' '--prefill-chunk 0512' '--prefill-chunk' '-mtp' \
    '--dspark' '--dspark-confidence 0.5' '--dspark-strict' '--mtp-timing' '--mtp-margin 3'; do
    check_fail "reject ds4 extra arg: $bad" mss_validate_extra_args ds4 "$bad" T
done

echo "== phase A: validators =="
for good in 192.0.2.10 192.0.2.0/24 10.0.0.0/8 192.0.2.7/32; do
    if mss_validate_cidr_entry "$good"; then ok "allowlist accepts $good"; else fail "allowlist accepts $good"; fi
done
for bad in 0.0.0.0/0 192.0.2.0/33 192.0.2.010 192.0.2.0/024 192.0.2.0/ 256.1.1.1 '192.0.2.1
10.0.0.1'; do
    check_fail "allowlist rejects '$bad'" mss_validate_cidr_entry "$bad"
done
check_fail "user root rejected" mss_validate_user OLLAMA_USER root
check_fail "path with space rejected" mss_validate_path_chars P '/path/to/my model.gguf'
check_fail "relative path rejected" mss_validate_path_chars P 'path/to/model.gguf'
check_fail "uint with newline rejected" mss_validate_uint N "$(printf '4096\nDS4_ARGS=--trace x')" 1
check_fail "uint non-numeric rejected" mss_validate_uint N abc 1

echo "== phase A: selections =="
for good in ollama llamacpp ds4 'ollama,llamacpp' 'ollama,ds4'; do
    if mss_validate_selection "$good"; then ok "selection '$good'"; else fail "selection '$good'"; fi
done
for bad in '' 'foo' 'llamacpp,ds4' 'ollama,llamacpp,ds4' 'ollama,ollama' 'llamacpp,llamacpp' ','; do
    check_fail "selection rejected: '$bad'" mss_validate_selection "$bad"
done

echo "== phase A: waiting for launchd to release a label (#18) =="
mkdir -p "$TMP/lc-twice" "$TMP/lc-always"
# launchctl stubs: print succeeds twice and then fails, or always succeeds.
cat > "$TMP/lc-twice/launchctl" <<STUB
#!/bin/sh
n=\$(cat '$TMP/lc-twice/n' 2>/dev/null || echo 0)
echo \$((n + 1)) > '$TMP/lc-twice/n'
[ "\$n" -lt 2 ]
STUB
printf '#!/bin/sh\nexit 0\n' > "$TMP/lc-always/launchctl"
chmod +x "$TMP/lc-twice/launchctl" "$TMP/lc-always/launchctl"
OUT=$( (PATH="$TMP/lc-twice:$PATH"; mss_launchd_wait_gone com.mac-studio-server.test 5) 2>&1); RC=$?
check "mss_launchd_wait_gone returns 0 once the label goes" 0 "$RC"
printf '%s' "$OUT" | grep -q 'waiting for com.mac-studio-server.test to stop' \
    && printf '%s' "$OUT" | grep -q 'com.mac-studio-server.test stopped after' \
    && ok "mss_launchd_wait_gone logs the wait and the stop" || fail "mss_launchd_wait_gone output: $OUT"
OUT=$( (PATH="$TMP/lc-always:$PATH"; mss_launchd_wait_gone com.mac-studio-server.test 1) 2>&1); RC=$?
check "mss_launchd_wait_gone returns 1 at the timeout" 1 "$RC"
printf '%s' "$OUT" | grep -q 'did not stop within 1s' && ok "mss_launchd_wait_gone names the timeout" \
    || fail "mss_launchd_wait_gone timeout output: $OUT"
BOOTS=$(cd "$ROOT" && grep -rl 'launchctl bootstrap' scripts libexec bootstrap.sh | sort | tr '\n' ' ' | sed 's/ $//')
# #27 adds mss-host.sh: the GPU and Colima boot jobs converge through the same
# bootstrap/wait/enable sequence as the backend jobs.
check "launchctl bootstrap appears only in install-backends.sh, mss-enable.sh and mss-host.sh" \
    "libexec/mss-enable.sh scripts/install-backends.sh scripts/lib/mss-host.sh" "$BOOTS"
for f in libexec/mss-enable.sh scripts/install-backends.sh scripts/lib/mss-host.sh; do
    grep -q 'mss_launchd_wait_gone "' "$ROOT/$f" && ok "$f calls mss_launchd_wait_gone" || fail "$f never calls mss_launchd_wait_gone"
done


echo "== phase A: #27 D4 render, helper, and A17 install-backends guards =="
# The #27 blocks below all call helpers from this one file, so it is sourced at
# the first of them. REPO_DIR is normally set at the system-tests boundary; the
# helpers resolve config templates through it, so it has to exist before they
# run, not merely before phase B.
REPO_DIR=$ROOT
. "$ROOT/scripts/lib/mss-host.sh"
# The A17 install-backends.sh rows need the model fixtures and run after the
# --check-only block below. Everything here runs on every runner.
mkdir -p "$TMP/h27b" "$TMP/h27b/stub"
check "render 80% at 128 GiB equals the golden file" 0 \
    "$(mss_gpu_render 80 104857 | cmp - "$ROOT/tests/golden/com.mac-studio-server.gpumemory.80.plist" >/dev/null 2>&1; echo $?)"
grep -F -A1 '<string>/usr/sbin/sysctl</string>' "$ROOT/tests/golden/com.mac-studio-server.gpumemory.80.plist" \
    | grep -q '<string>iogpu.wired_limit_mb=104857</string>' \
    && ok "the golden render sets the limit with sysctl directly" || fail "the golden render does not run sysctl directly"
check "mss_wired_limit_mb 80 at 128 GiB is 104857" 104857 "$(mss_wired_limit_mb 80 137438953472)"
# set-gpu-memory.sh helper (A4)
cat > "$TMP/h27b/stub/sysctl" <<'XS'
#!/bin/sh
# hw.memsize: the harness pins 128 GiB via MSS_H27_MEMSIZE so the expected MB
# is a constant; anything else falls back to this host's real value.
if [ "${1:-}" = -n ]; then
    [ "${2:-}" = hw.memsize ] || exit 1
    [ -n "${MSS_H27_MEMSIZE:-}" ] && { echo "$MSS_H27_MEMSIZE"; exit 0; }
    /usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 137438953472
    exit 0
fi
echo "sysctl $*" >> "$MSS_H27_LOG"; exit 0
XS
cat > "$TMP/h27b/stub/sudo" <<'XS'
#!/bin/sh
case ${1:-} in -v) exit 0 ;; -n) shift ;; esac
exec "$@"
XS
chmod +x "$TMP/h27b/stub/sysctl"
helper_case() { # helper_case <log> <env=...>... -- args...: rc
    _log=$1; shift
    : > "$_log"
    ( export MSS_H27_LOG=$_log MSS_H27_MEMSIZE=137438953472 OLLAMA_BASE_DIR="$TMP/h27b" MSS_SYSCTL="$TMP/h27b/stub/sysctl" MSS_SUDO="$TMP/h27b/stub/sudo" PATH="$TMP/h27b/stub:$PATH"
      while [ "$#" -gt 0 ] && [ "$1" != -- ]; do export "${1?}"; shift; done
      shift
      "$ROOT/scripts/set-gpu-memory.sh" "$@" >/dev/null 2>&1 )
}
helper_case "$TMP/h27b/a1.log" -- 85; check "helper: an argument sets the limit" "sysctl iogpu.wired_limit_mb=111411" "$(cat "$TMP/h27b/a1.log")"
helper_case "$TMP/h27b/a2.log" -- system; check "helper: system writes 0" "sysctl iogpu.wired_limit_mb=0" "$(cat "$TMP/h27b/a2.log")"
helper_case "$TMP/h27b/a3.log" OLLAMA_GPU_PERCENT=80 --; check "helper: legacy environment with no argument" "sysctl iogpu.wired_limit_mb=104857" "$(cat "$TMP/h27b/a3.log")"
helper_case "$TMP/h27b/a4.log" MSS_GPU_PERCENT=70 OLLAMA_GPU_PERCENT=80 --; RC=$?
check "helper: differing environment keys exit 2" 2 "$RC"
check "helper: differing keys write nothing" "" "$(cat "$TMP/h27b/a4.log")"
helper_case "$TMP/h27b/a5.log" --; RC=$?
check "helper: nothing given exits 2" 2 "$RC"
check "helper: nothing given writes nothing (never 80 silently)" "" "$(cat "$TMP/h27b/a5.log")"
helper_case "$TMP/h27b/a6.log" MSS_GPU_PERCENT=70 -- 85; check "helper: the argument wins over the environment" "sysctl iogpu.wired_limit_mb=111411" "$(cat "$TMP/h27b/a6.log")"
# MSS_SYSCTL is a test hook: outside a test sysroot the helper uses the real
# sysctl however it is set, so a stray variable cannot redirect a root run.
helper_case "$TMP/h27b/a7.log" MSS_TEST_SYSROOT= -- 85
check "helper: MSS_SYSCTL is ignored outside a test sysroot" "" "$(cat "$TMP/h27b/a7.log")"

echo "== phase A: #27 D5 start-colima.sh (existing VM keeps its size) =="
mkdir -p "$TMP/h27c"
cat > "$TMP/h27c/colima" <<'XS'
#!/bin/sh
echo "colima $*" >> "$MSS_H27_LOG"
[ "${1:-}" = list ] || exit 0
[ "${MSS_H27_LIST_RC:-0}" = 0 ] || exit 1
[ -n "${MSS_H27_LIST:-}" ] && cat "$MSS_H27_LIST"
XS
cat > "$TMP/h27c/docker" <<'XS'
#!/bin/sh
# docker stub: `info` fails until `colima start` has run, so start-colima
# proceeds to its start line and then leaves its wait loop at once.
[ "${1:-}" = info ] && ! grep -q '^colima start' "$MSS_H27_LOG" 2>/dev/null && exit 1
exit 0
XS
chmod +x "$TMP/h27c/colima" "$TMP/h27c/docker"
start_case() { # start_case <list-file|-> <list-rc> [home]: the colima start argv
    : > "$TMP/h27c/log"
    ( export MSS_H27_LOG="$TMP/h27c/log" OLLAMA_BASE_DIR="$TMP/h27c"
      [ -z "${3:-}" ] || export HOME="$3"
      [ "$1" = - ] && unset MSS_H27_LIST || export MSS_H27_LIST="$1"
      export MSS_H27_LIST_RC=$2
      PATH="$TMP/h27c:$PATH"
      "$ROOT/scripts/start-colima.sh" >/dev/null 2>&1 )
    sed -n 's/^colima start.*/&/p' "$TMP/h27c/log" | head -n 1
}
printf '{"name":"default","runtime":"docker","status":"Stopped"}\n' > "$TMP/h27c/compact.json"
printf '{"name": "default", "status": "Stopped", "cpus": 8}\n' > "$TMP/h27c/spaced.json"
: > "$TMP/h27c/empty.json"
printf '{"name":"other","status":"Stopped"}\n{"name":"second"}\n' > "$TMP/h27c/other.json"
check "an existing default starts with no flags" "colima start" "$(start_case "$TMP/h27c/compact.json" 0)"
check "spaced JSON also starts with no flags" "colima start" "$(start_case "$TMP/h27c/spaced.json" 0)"
check "empty list creates with today's flags" \
    "colima start --cpu 4 --memory 8 --disk 50 --vm-type=vz --mount-type=virtiofs" "$(start_case "$TMP/h27c/empty.json" 0)"
check "other names only create with today's flags" \
    "colima start --cpu 4 --memory 8 --disk 50 --vm-type=vz --mount-type=virtiofs" "$(start_case "$TMP/h27c/other.json" 0)"
check "a failing list starts with no flags (never resize)" "colima start" "$(start_case "$TMP/h27c/compact.json" 1)"
# Manual step 9 at a44b988: a 6/12/80 VM came back 4/8/50 after a reboot. A VM
# that Colima's own files show is never resized, even when the list misses it.
mkdir -p "$TMP/h27c/home-yaml/.colima/default" "$TMP/h27c/home-lima/.colima/_lima/colima" "$TMP/h27c/home-none"
printf 'cpu: 6\nmemory: 12\ndisk: 80\n' > "$TMP/h27c/home-yaml/.colima/default/colima.yaml"
check "an empty list over an existing colima.yaml starts with no flags" "colima start" \
    "$(start_case "$TMP/h27c/empty.json" 0 "$TMP/h27c/home-yaml")"
check "other names over an existing Lima instance start with no flags" "colima start" \
    "$(start_case "$TMP/h27c/other.json" 0 "$TMP/h27c/home-lima")"
check "an empty list with nothing on disk still creates with today's flags" \
    "colima start --cpu 4 --memory 8 --disk 50 --vm-type=vz --mount-type=virtiofs" \
    "$(start_case "$TMP/h27c/empty.json" 0 "$TMP/h27c/home-none")"
check "COLIMA_HOME is where the VM is looked for" "colima start" \
    "$(export COLIMA_HOME="$TMP/h27c/home-yaml/.colima"; start_case "$TMP/h27c/empty.json" 0 "$TMP/h27c/home-none")"
check "the existing VM's colima.yaml is untouched" "$(printf 'cpu: 6\nmemory: 12\ndisk: 80')" \
    "$(cat "$TMP/h27c/home-yaml/.colima/default/colima.yaml")"

echo "== phase A: #27 D6 power apply =="
HS_STUBBED="$TMP/h27d"
mkdir -p "$HS_STUBBED"
# _mss_root runs the command directly on a root pass, so the pmset stub would be
# exec'd by root here. MSS_SUDO points every privileged call at the same shim the
# apply helpers use, which is what makes a stubbed privileged write observable
# regardless of who runs phase A.
mkdir -p "$TMP/nosudo"
printf '#!/bin/sh\ncase $1 in -v) exit 0 ;; -n) shift ;; esac\nexec "$@"\n' > "$TMP/nosudo/sudo"
chmod +x "$TMP/nosudo/sudo"
# power_case <pmset-stub> [env=...]: the D8 line(s) then rc. Every row gets a
# private state directory, because the autorestart stubs are stateful and one
# row's write must not become the next row's starting value. Directories are
# named after the row rather than a counter: power_case always runs inside a
# command substitution, and a counter bumped there dies with the subshell, so
# every row would share one directory and the "unchanged" rows would read back a
# previous row's write and report "changed".
power_dir() { printf '%s/h27d/%s-%s\n' "$TMP" "$1" "$(shift; printf '%s' "$*" | tr -c 'A-Za-z0-9._-' '_')"; }
# power_writes <stub> <env...>: the `pmset -a` calls the last power_case with
# the same arguments made, one line each.
power_writes() { grep '^pmset -a' "$(power_dir "$@")/pmset.log" 2>/dev/null || true; }
power_case() {
    _stub=$1
    _state=$(power_dir "$@"); shift
    rm -rf "$_state"; mkdir -p "$_state"
    ( export MSS_PMSET="$ROOT/tests/stubs/$_stub" MSS_SUDO="$TMP/nosudo/sudo" MSS_STUB_STATE="$_state"
      while [ "$#" -gt 0 ]; do export "${1?}"; shift; done
      mss_power_apply 2>&1; echo "rc=$?" )
}
check "power unset on a supported Mac reports the current state" "Restart after power failure: left as is (off)
rc=0" "$(power_case pmset-autorestart-0)"
check "power unset on an unsupported Mac is a line, not an error" "Restart after power failure: left as is (unsupported)
rc=0" "$(power_case pmset-none)"
check "power=yes against 0 writes once" "Restart after power failure: on, changed
rc=0" "$(power_case pmset-autorestart-0 MSS_POWER_AUTORESTART=yes)"
check "power=no against 0 is unchanged" "Restart after power failure: off, unchanged
rc=0" "$(power_case pmset-autorestart-0 MSS_POWER_AUTORESTART=no)"
check "power=yes against 1 is unchanged" "Restart after power failure: on, unchanged
rc=0" "$(power_case pmset-autorestart-1 MSS_POWER_AUTORESTART=yes)"
check "power=no against 1 writes once" "Restart after power failure: off, changed
rc=0" "$(power_case pmset-autorestart-1 MSS_POWER_AUTORESTART=no)"
# constraint 4, counted: zero writes when unset or equal, exactly one when different
check "A6 unset makes no pmset -a call" "" "$(power_writes pmset-autorestart-0)"
check "A6 unset on 1 makes no pmset -a call" "" "$(power_writes pmset-autorestart-1)"
check "A6 equal (no against 0) makes no pmset -a call" "" "$(power_writes pmset-autorestart-0 MSS_POWER_AUTORESTART=no)"
check "A6 equal (yes against 1) makes no pmset -a call" "" "$(power_writes pmset-autorestart-1 MSS_POWER_AUTORESTART=yes)"
check "A6 yes against 0 makes exactly one write" "pmset -a autorestart 1" "$(power_writes pmset-autorestart-0 MSS_POWER_AUTORESTART=yes)"
check "A6 no against 1 makes exactly one write" "pmset -a autorestart 0" "$(power_writes pmset-autorestart-1 MSS_POWER_AUTORESTART=no)"
check "A6 unsupported makes no pmset -a call" "" "$(power_writes pmset-none)"
OUT=$(power_case pmset-sticky MSS_POWER_AUTORESTART=yes); RCline=${OUT##*rc=}
check "a sticky pmset fails the readback" 1 "$RCline"
printf '%s' "$OUT" | grep -q 'pmset did not apply autorestart=1 (reads 0)' && ok "the mismatch names both values" || fail "sticky: $OUT"
OUT=$(power_case pmset-none MSS_POWER_AUTORESTART=yes); RCline=${OUT##*rc=}
check "a key on a Mac without the setting exits 1" 1 "$RCline"
check "a key on a Mac without the setting writes nothing" "" "$(power_writes pmset-none MSS_POWER_AUTORESTART=yes)"
printf '%s' "$OUT" | grep -q 'no restart-after-power-failure setting' && ok "the missing-setting message names the unset" || fail "none: $OUT"
# constraint 4: pmset -a only when set and different
for f in scripts/optimize-mac-server.sh; do
    grep -q autorestart "$ROOT/$f" && fail "$f gained autorestart (constraint 4)" || ok "$f never touches autorestart (constraint 4)"
done


echo "== phase A: guard --evaluate fixtures =="
E="$ROOT/libexec/mss-guard.sh"
check "free3" "trip:free"  "$($E --evaluate $ROOT/tests/fixtures/guard/free3.jsonl)"
check "free2ok" "none"     "$($E --evaluate $ROOT/tests/fixtures/guard/free2ok.jsonl)"
check "swap3" "trip:swap"  "$($E --evaluate $ROOT/tests/fixtures/guard/swap3.jsonl)"
check "err-streak" "none"  "$($E --evaluate $ROOT/tests/fixtures/guard/err-streak.jsonl)"
check "pidnull" "none"     "$($E --evaluate $ROOT/tests/fixtures/guard/pidnull.jsonl)"
check "interleaved" "trip:free" "$($E --evaluate $ROOT/tests/fixtures/guard/interleaved.jsonl)"
check "nullbaseline" "none" "$($E --evaluate $ROOT/tests/fixtures/guard/nullbaseline.jsonl)"
check "streak2 on free2" "trip:free" "$($E --evaluate $ROOT/tests/fixtures/guard/free2.jsonl --streak 2)"
check "streak2 on free2ok" "none" "$($E --evaluate $ROOT/tests/fixtures/guard/free2ok.jsonl --streak 2)"
check "sample_error with spaces in detail" "none" "$($E --evaluate $ROOT/tests/fixtures/guard/err-detail.jsonl)"

echo "== phase A: render-only =="
make_fixture() { # make_fixture <backend> <dir>: stub bin + fake gguf + sha
    _b=$1; _d=$2
    mkdir -p "$_d"
    cp "$ROOT/tests/stubs/fake-server.sh" "$_d/$_b-server"
    chmod +x "$_d/$_b-server"
    printf 'fake-gguf-for-tests-%s' "$_b" > "$_d/model.gguf"
    mss_shasum256 "$_d/model.gguf" | awk '{print $1}' > "$_d/model.sha"
}
render() { # render <backends> <dir> [extra env...]
    _sel=$1; _dir=$2; shift 2
    mkdir -p "$_dir"
    # The extra env comes last: env keeps the last value, so a test's override wins.
    env MSS_BACKENDS="$_sel" OLLAMA_USER=testuser \
        LLAMACPP_BIN="$TMP/fix/llamacpp/llamacpp-server" \
        LLAMACPP_MODEL="$TMP/fix/llamacpp/model.gguf" \
        LLAMACPP_MODEL_SHA256="$(cat "$TMP/fix/llamacpp/model.sha")" \
        DS4_BIN="$TMP/fix/ds4/ds4-server" \
        DS4_MODEL="$TMP/fix/ds4/model.gguf" \
        DS4_MODEL_SHA256="$(cat "$TMP/fix/ds4/model.sha")" \
        "$@" sh "$ROOT/scripts/install-backends.sh" --render-only "$_dir"
}
make_fixture llamacpp "$TMP/fix/llamacpp"
make_fixture ds4 "$TMP/fix/ds4"

for sel in ollama llamacpp ds4 'ollama,llamacpp' 'ollama,ds4'; do
    d="$TMP/render-$(echo "$sel" | tr , -)"
    if render "$sel" "$d" >/dev/null 2>"$d.err"; then
        ok "render '$sel'"
    else
        fail "render '$sel': $(cat "$d.err")"
        continue
    fi
    for plist in "$d"/*.plist; do
        [ -e "$plist" ] || continue
        if command -v plutil >/dev/null 2>&1; then
            if plutil -lint "$plist" >/dev/null 2>&1; then ok "plutil $(basename "$plist") ($sel)"; else fail "plutil $(basename "$plist") ($sel)"; fi
        fi
        LEFT=$(grep -o '<[A-Z_]\+>' "$plist" || true)
        [ -z "$LEFT" ] && ok "no placeholders $(basename "$plist") ($sel)" || fail "placeholders left: $LEFT"
    done
    [ -f "$d/backends.conf" ] && ok "conf rendered ($sel)" || fail "conf missing ($sel)"
done
# optional backend plist shape
D="$TMP/render-ollama-ds4"
grep -q '<key>KeepAlive</key>' "$D/com.mac-studio-server.ds4.plist" && ok "ds4 KeepAlive" || fail "ds4 KeepAlive"
grep -q '<integer>30</integer>' "$D/com.mac-studio-server.ds4.plist" && ok "ds4 ThrottleInterval 30" || fail "ds4 ThrottleInterval"
grep -q '<string>testuser</string>' "$D/com.mac-studio-server.ds4.plist" && ok "ds4 UserName=testuser" || fail "ds4 UserName"
grep -q "^DS4_MODEL=$PTMP/fix/ds4/model.gguf\$" "$D/backends.conf" && ok "conf has resolved ds4 model path" || fail "conf ds4 model path"
grep -q "^$PTMP/fix/ds4/model.gguf [0-9]* [0-9]* [0-9]* $(cat "$TMP/fix/ds4/model.sha")\$" "$D/ds4.model.verified" \
    && ok "ds4 stamp is path size inode mtime sha" || fail "ds4 stamp format"

echo "== phase A: golden ollama render =="
mss_render_ollama_plist "$ROOT/config/com.ollama.service.plist" mssgolden 0.0.0.0 /usr/local/bin/ollama \
    > "$TMP/ollama-rendered.plist"
if cmp -s "$TMP/ollama-rendered.plist" "$ROOT/tests/golden/com.ollama.service.v1.2.0.plist"; then
    ok "ollama default render byte-identical to v1.2.0 golden"
else
    fail "ollama default render differs from golden"
fi

echo "== phase A: invalid configs abort =="
BADSEL="$TMP/badsel"
check_fail "render llamacpp,ds4" render 'llamacpp,ds4' "$BADSEL"
check_fail "render all three" render 'ollama,llamacpp,ds4' "$BADSEL"
check_fail "render unknown" render 'foo' "$BADSEL"
check_fail "render duplicates" render 'ollama,ollama' "$BADSEL"
check_fail "render empty" render '' "$BADSEL"
# port collision with ollama
check_fail "port collision 11434" render 'ollama,ds4' "$TMP/bad-port" DS4_PORT=11434
# IPv6 host
check_fail "IPv6 host" render 'ds4' "$TMP/bad-v6" DS4_HOST='::1'
# split gguf
mkdir -p "$TMP/split"; printf 'x' > "$TMP/split/model-00001-of-00002.gguf"
SPSHA=$(mss_shasum256 "$TMP/split/model-00001-of-00002.gguf" | awk '{print $1}')
check_fail "split gguf" env MSS_BACKENDS=ds4 OLLAMA_USER=testuser DS4_BIN="$TMP/fix/ds4/ds4-server" DS4_MODEL="$TMP/split/model-00001-of-00002.gguf" DS4_MODEL_SHA256="$SPSHA" sh "$ROOT/scripts/install-backends.sh" --render-only "$TMP/bad-split"
# wrong sha
check_fail "wrong sha" render 'ds4' "$TMP/bad-sha" DS4_MODEL_SHA256="$(printf '0%.0s' $(seq 64))"
# missing model
check_fail "missing model" render 'ds4' "$TMP/bad-model" DS4_MODEL="$TMP/does-not-exist.gguf"
# LAN ds4 without allowlist (192.0.2.10 is RFC 5737; not local → also invalid host)
check_fail "lan ds4 no allowlist" render 'ds4' "$TMP/bad-lan" DS4_HOST=192.0.2.10
# values that would reach backends.conf or a plist unvalidated
check_fail "DS4_CTX with newline" render 'ds4' "$TMP/bad-ctx" DS4_CTX="$(printf '4096\nDS4_ARGS=--trace x')"
check_fail "DS4_BATCHED_SESSIONS non-numeric" render 'ds4' "$TMP/bad-bs" DS4_BATCHED_SESSIONS=four
check_fail "DS4_WORKDIR relative" render 'ds4' "$TMP/bad-wd" DS4_WORKDIR=relative/dir
check_fail "LLAMACPP_PARALLEL non-numeric" render 'llamacpp' "$TMP/bad-np" LLAMACPP_PARALLEL=2x
render 'llamacpp' "$TMP/bad-np" LLAMACPP_PARALLEL=2x 2>&1 | grep -q '^ERROR: LLAMACPP_PARALLEL' \
    && ok "LLAMACPP_PARALLEL non-numeric fails on LLAMACPP_PARALLEL (#21)" || fail "LLAMACPP_PARALLEL non-numeric failed for another reason"
check_fail "OLLAMA_USER root" env MSS_BACKENDS=ollama OLLAMA_USER=root sh "$ROOT/scripts/install-backends.sh" --render-only "$TMP/bad-root"
mkdir -p "$TMP/sp ace"; printf 'x' > "$TMP/sp ace/model.gguf"
SPC=$(mss_shasum256 "$TMP/sp ace/model.gguf" | awk '{print $1}')
check_fail "model path with a space" render 'ds4' "$TMP/bad-space" DS4_MODEL="$TMP/sp ace/model.gguf" DS4_MODEL_SHA256="$SPC"
# a CIDR allowlist renders (LAN host needs the stub ifconfig)
if render 'ds4' "$TMP/render-cidr" DS4_HOST=192.0.2.10 DS4_ALLOW_FROM='192.0.2.0/24 198.51.100.7' \
    MSS_IFCONFIG="$ROOT/tests/stubs/ifconfig-lan" >/dev/null 2>"$TMP/render-cidr.err"; then
    grep -q '^pass in quick proto tcp from 192.0.2.0/24 to any port 8000$' "$TMP/render-cidr/pf.conf" \
        && ok "CIDR allowlist rendered into pf rules" || fail "CIDR pf rule missing"
    check "pf rule count with 2 entries" "MSS_PF_RULE_COUNT=4" "$(grep '^MSS_PF_RULE_COUNT=' "$TMP/render-cidr/backends.conf")"
else
    fail "render with CIDR allowlist: $(cat "$TMP/render-cidr.err")"
fi

# llama.cpp on a LAN address with only an API key: no pf policy, no boot job.
TUSER=$(id -un); [ "$TUSER" != root ] || TUSER=nobody
KEYF="$TMP/test.api-key"
( umask 077; printf 'test-key' > "$KEYF" )
[ "$(id -u)" -ne 0 ] || chown "$TUSER" "$KEYF"
if render 'llamacpp' "$TMP/render-keyonly" OLLAMA_USER="$TUSER" LLAMACPP_HOST=192.0.2.10 LLAMACPP_API_KEY_FILE="$KEYF" \
    MSS_IFCONFIG="$ROOT/tests/stubs/ifconfig-lan" >/dev/null 2>"$TMP/render-keyonly.err"; then
    check "key-only LAN bind has no pf rules" "MSS_PF_RULE_COUNT=0" "$(grep '^MSS_PF_RULE_COUNT=' "$TMP/render-keyonly/backends.conf")"
    [ ! -e "$TMP/render-keyonly/com.mac-studio-server.boot.plist" ] && ok "key-only LAN bind installs no boot job" || fail "key-only LAN bind has a boot job"
else
    fail "render llamacpp LAN key-only: $(cat "$TMP/render-keyonly.err")"
fi
check_fail "llamacpp LAN with neither allowlist nor key" render 'llamacpp' "$TMP/bad-lan-llama" LLAMACPP_HOST=192.0.2.10 \
    MSS_IFCONFIG="$ROOT/tests/stubs/ifconfig-lan"
render 'llamacpp' "$TMP/bad-lan-llama" LLAMACPP_HOST=192.0.2.10 MSS_IFCONFIG="$ROOT/tests/stubs/ifconfig-lan" 2>&1 \
    | grep -q '^ERROR: LLAMACPP_ALLOW_FROM' && ok "llamacpp LAN without allowlist or key fails on LLAMACPP_ALLOW_FROM (#21)" \
    || fail "llamacpp LAN without allowlist or key failed for another reason"

echo "== phase A: ds4 batched sessions default (#19) =="
check "96 GiB exactly defaults to 4" 4 "$(mss_ds4_default_sessions 103079215104)"
check "just under 96 GiB defaults to 2" 2 "$(mss_ds4_default_sessions 103079215103)"
check "unreadable memsize defaults to 2" 2 "$(mss_ds4_default_sessions '')"
for case in "137438953472::4" "68719476736::2" "137438953472:1:1" "68719476736:3:3"; do
    _mem=${case%%:*}; _rest=${case#*:}; _set=${_rest%%:*}; _want=${_rest#*:}
    _d="$TMP/render-bs-$_mem-${_set:-unset}"
    if render 'ds4' "$_d" MSS_HW_MEMSIZE="$_mem" DS4_BATCHED_SESSIONS="$_set" >/dev/null 2>&1; then
        check "memsize $_mem, DS4_BATCHED_SESSIONS='${_set}' renders $_want" "DS4_BATCHED_SESSIONS=$_want" \
            "$(grep '^DS4_BATCHED_SESSIONS=' "$_d/backends.conf")"
    else
        fail "render memsize $_mem, DS4_BATCHED_SESSIONS='$_set'"
    fi
done
# Outside --render-only the host's RAM decides: pick an override that would
# give the other answer and expect the host's own default.
HOSTBS=$(mss_ds4_default_sessions "$(sysctl -n hw.memsize 2>/dev/null)")
[ "$HOSTBS" = 4 ] && OTHERMEM=1 || OTHERMEM=137438953472
OUT=$(env MSS_BACKENDS=ds4 OLLAMA_USER="$TUSER" MSS_HW_MEMSIZE="$OTHERMEM" DS4_BIN="$TMP/fix/ds4/ds4-server" \
    DS4_MODEL="$TMP/fix/ds4/model.gguf" DS4_MODEL_SHA256="$(cat "$TMP/fix/ds4/model.sha")" DS4_PORT=18999 \
    sh "$ROOT/scripts/install-backends.sh" --check-only 2>&1)
printf '%s' "$OUT" | grep -q "DS4_BATCHED_SESSIONS unset: using $HOSTBS " \
    && ok "MSS_HW_MEMSIZE is ignored outside --render-only" || fail "MSS_HW_MEMSIZE outside --render-only: $OUT"

echo "== phase A: --check-only =="
CK="$TMP/check-only"
mkdir -p "$CK"
if env MSS_BACKENDS=ds4 OLLAMA_USER="$TUSER" DS4_BIN="$TMP/fix/ds4/ds4-server" DS4_MODEL="$TMP/fix/ds4/model.gguf" \
    DS4_MODEL_SHA256="$(cat "$TMP/fix/ds4/model.sha")" DS4_PORT=18999 \
    sh "$ROOT/scripts/install-backends.sh" --check-only >"$CK.log" 2>&1; then
    ok "--check-only passes a valid config"
else
    fail "--check-only on a valid config: $(tail -2 "$CK.log")"
fi
check_fail "--check-only rejects a wrong sha" env MSS_BACKENDS=ds4 OLLAMA_USER="$TUSER" DS4_BIN="$TMP/fix/ds4/ds4-server" \
    DS4_MODEL="$TMP/fix/ds4/model.gguf" DS4_MODEL_SHA256="$(printf '0%.0s' $(seq 64))" DS4_PORT=18999 \
    sh "$ROOT/scripts/install-backends.sh" --check-only

# install-backends.sh: only MSS_GPU_PERCENT is read, the exemption stays (A17).
# These rows need the fixtures and TUSER above. stat-bsd lets a Linux runner
# pass the model file's BSD stat and steps aside on macOS; the sysctl stub pins
# hw.memsize at 128 GiB so the wired limit is computed the same everywhere.
mkdir -p "$TMP/h27b/bin-bsd"
cp "$ROOT/tests/stubs/stat-bsd" "$TMP/h27b/bin-bsd/stat"; cp "$ROOT/tests/stubs/sysctl-state" "$TMP/h27b/bin-bsd/sysctl"
chmod +x "$TMP/h27b/bin-bsd/stat" "$TMP/h27b/bin-bsd/sysctl"
a17() { # a17 <extra env...> -- <install-backends args...>
    _a17env=""
    while [ "$1" != -- ]; do _a17env="$_a17env $1"; shift; done
    shift
    # shellcheck disable=SC2086  # the extra env is our own KEY=value words
    env PATH="$TMP/h27b/bin-bsd:$PATH" MSS_STUB_STATE="$TMP/h27b" MSS_BACKENDS=ds4 OLLAMA_USER="$TUSER" DS4_BIN="$TMP/fix/ds4/ds4-server" \
        DS4_MODEL="$TMP/fix/ds4/model.gguf" DS4_MODEL_SHA256="$(cat "$TMP/fix/ds4/model.sha")" DS4_PORT=18997 \
        $_a17env sh "$ROOT/scripts/install-backends.sh" "$@" 2>&1
}
OUT=$(a17 MSS_GPU_PERCENT=80 -- --check-only)
check "A17 --check-only with 80 and no plist still passes" 0 $?
OUT=$(a17 MSS_GPU_PERCENT=80 -- --render-only "$TMP/h27b/ro")
check "A17 --render-only with 80 and no plist still passes" 0 $?
OUT=$(a17 OLLAMA_GPU_PERCENT=80 -- --render-only "$TMP/h27b/ro2")
check "A17 --render-only refuses a legacy key in the environment" 1 $?
printf '%s' "$OUT" | grep -q 'OLLAMA_GPU_PERCENT is replaced by MSS_GPU_PERCENT' && ok "A17 names the replacement" || fail "A17 message: $OUT"

echo "== phase A: wired-limit formula parity (A15b) =="
if [ "$(uname)" = Darwin ]; then
    TOTAL=$(sysctl -n hw.memsize)
    SCRIPT_VAL=$((TOTAL / 1024 / 1024 * 80 / 100))
    check "wired limit formula parity" "$SCRIPT_VAL" "$(mss_wired_limit_mb 80 "$TOTAL")"
else
    TOTAL=17179869184
    check "wired limit formula (fixture)" "$((TOTAL / 1024 / 1024 * 80 / 100))" "$(mss_wired_limit_mb 80 "$TOTAL")"
fi

echo "== phase A: boot fail-closed with stub pfctl (A11b) =="
BDIR="$TMP/render-lan"
mkdir -p "$TMP/stubbin"
cat > "$TMP/stubbin/pfctl-disabled" <<'STUB'
#!/bin/sh
if [ "$1" = "-s" ] && [ "$2" = "info" ]; then echo "Status: Disabled"; exit 0; fi
exit 0
STUB
chmod +x "$TMP/stubbin/pfctl-disabled"
if render 'ds4' "$BDIR" DS4_HOST=192.0.2.10 DS4_ALLOW_FROM='192.0.2.99' MSS_IFCONFIG="$ROOT/tests/stubs/ifconfig-lan" >/dev/null 2>&1; then
    sed -i.bak -e "s|^MSS_PFCTL=.*|MSS_PFCTL=$TMP/stubbin/pfctl-disabled|" "$BDIR/backends.conf"
    OUT=$(MSS_CONF="$BDIR/backends.conf" PF_CONF="$BDIR/pf.conf" MARKER="$TMP/boot.marker" \
        sh "$ROOT/libexec/mss-boot.sh" 2>&1)
    RC=$?
    if [ $RC -ne 0 ] && [ ! -e "$TMP/boot.marker" ] && printf '%s' "$OUT" | grep -q 'pf check (a)'; then
        ok "boot refuses with disabled pf (no marker)"
    else
        fail "boot with disabled pf: rc=$RC marker=$( [ -e "$TMP/boot.marker" ] && echo yes || echo no)"
    fi
else
    echo "skip - LAN render needs the stub ifconfig (macOS only)"
fi


echo "== phase A: backends.env keys match config/backends.env.example (#12) =="
EXAMPLE_KEYS=$(sed -n 's/^#\{0,1\} \{0,1\}\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$ROOT/config/backends.env.example" | tr '\n' ' ' | sed 's/ $//')
check "mss_envfile_keys equals the example's keys, in order" "$EXAMPLE_KEYS" "$(mss_envfile_keys | tr -s ' ')"

echo "== phase A: backends.env parser (A11) =="
EF="$ROOT/tests/fixtures/envfile"
EFT="$TMP/envfile"
mkdir -p "$EFT"
# fixtures are copied so the owner and mode checks see a file this user owns
envload() { ( unset MSS_BACKENDS DS4_PORT DS4_CTX DS4_EXTRA_ARGS; mss_envfile_load "$1" && printf '%s|%s|%s|%s' "$MSS_BACKENDS" "${DS4_PORT:-}" "${DS4_CTX:-}" "${DS4_EXTRA_ARGS:-}" ) }
for f in "$EF"/*.env; do cp "$f" "$EFT/"; chmod 600 "$EFT/$(basename "$f")"; done
check "valid file loads literally" "ds4|8001|32768|--power 60 --threads 8" "$(envload "$EFT/valid.env" 2>/dev/null)"
check "environment wins over the file" "ds4|9000|32768|--power 60 --threads 8" \
    "$( ( unset MSS_BACKENDS DS4_CTX DS4_EXTRA_ARGS; export DS4_PORT=9000; mss_envfile_load "$EFT/valid.env" && printf '%s|%s|%s|%s' "$MSS_BACKENDS" "$DS4_PORT" "$DS4_CTX" "$DS4_EXTRA_ARGS" ) 2>/dev/null)"
for bad in unknown-key duplicate export dollar backtick dquote squote backslash no-backends; do
    OUT=$(envload "$EFT/$bad.env" 2>&1) && fail "parser accepted $bad.env" || {
        case $bad in
            no-backends) ok "parser rejects $bad.env" ;;
            *) printf '%s' "$OUT" | grep -q "line [0-9]" && ok "parser rejects $bad.env naming the line" || fail "parser rejects $bad.env without a line number: $OUT" ;;
        esac
    }
done
printf 'MSS_BACKENDS=ds4\r\n' > "$EFT/cr.env"; chmod 600 "$EFT/cr.env"
check_fail "parser rejects a carriage return" mss_envfile_load "$EFT/cr.env"
cp "$EFT/valid.env" "$EFT/group-writable.env"; chmod 620 "$EFT/group-writable.env"
check_fail "parser rejects a group-writable file" mss_envfile_load "$EFT/group-writable.env"
ln -s "$EFT/valid.env" "$EFT/link.env"
check_fail "parser rejects a symlink" mss_envfile_load "$EFT/link.env"

echo "== phase A: backends.env writer =="
if [ "$(id -u)" -ne 0 ]; then
    WF="$EFT/written.env"
    ( unset MSS_BACKENDS DS4_PORT DS4_CTX DS4_EXTRA_ARGS
      mss_envfile_load "$EFT/valid.env" && export DS4_PORT=8005 && mss_envfile_write "$WF" ) 2>/dev/null
    check "writer mode 0600" "600" "$(stat -f '%Lp' "$WF" 2>/dev/null)"
    check "writer keeps unasked keys, in example order" "MSS_BACKENDS=ds4 DS4_PORT=8005 DS4_CTX=32768 DS4_EXTRA_ARGS=--power 60 --threads 8" \
        "$(grep -v '^#' "$WF" | tr '\n' ' ' | sed 's/ $//')"
    ln -s "$WF" "$EFT/written-link.env"
    check_fail "writer refuses to replace a symlink" env MSS_BACKENDS=ds4 sh -c ". '$ROOT/scripts/lib/mss-common.sh'; mss_envfile_write '$EFT/written-link.env'"
    check_fail "writer refuses a value with a quote" env MSS_BACKENDS=ds4 DS4_BIN='/a"b' sh -c ". '$ROOT/scripts/lib/mss-common.sh'; mss_envfile_write '$EFT/q.env'"
else
    echo "skip - writer tests need a non-root user (the writer refuses root)"
fi

echo "== phase A: render parity with 1.3.0 (A1) =="
OLD_REF=1f9473e84ca592b04a4884a913581fbbd82b0b45
OLD_ISOLATED=0
if git -C "$ROOT" cat-file -e "$OLD_REF^{commit}" 2>/dev/null; then
    mkdir -p "$TMP/old"
    git -C "$ROOT" archive "$OLD_REF" | tar -x -C "$TMP/old"
    # 1.3.0 reads the installed conf at a fixed path. In this extracted copy only,
    # that path moves under the sysroot, so an installed Mac cannot decide the result (#21).
    OLDIB="$TMP/old/scripts/install-backends.sh"
    sed 's|^ETC_DIR="/usr/local/etc/mac-studio-server"$|ETC_DIR="$MSS_TEST_SYSROOT/usr/local/etc/mac-studio-server"|' \
        "$OLDIB" > "$OLDIB.iso"
    if [ "$(diff "$OLDIB" "$OLDIB.iso" | grep -c '^<')" = 1 ] && [ "$(diff "$OLDIB" "$OLDIB.iso" | grep -c '^>')" = 1 ]; then
        mv "$OLDIB.iso" "$OLDIB"
        ok "the 1.3.0 tree reads its conf under the sysroot (one line changed)"
        OLD_ISOLATED=1
    else
        fail "cannot isolate the 1.3.0 tree"
        OLD_ISOLATED=0
    fi
fi
if [ ! -d "$TMP/old" ]; then
    fail "render parity needs commit $OLD_REF (fetch full history: actions/checkout fetch-depth 0)"
elif [ "$OLD_ISOLATED" = 1 ]; then
    for sel in ollama llamacpp ds4 'ollama,llamacpp' 'ollama,ds4' 'llamacpp,ds4'; do
        tag=$(echo "$sel" | tr , -)
        for tree in old new; do
            # The 1.3.0 tree is a fixture that hashes with a bare shasum (Perl), which
            # fails under a locale Perl cannot load, so it alone runs under C (#21).
            # The new tree keeps the inherited locale.
            if [ "$tree" = old ]; then src="$TMP/old"; loc="LC_ALL=C LANG=C"; else src="$ROOT"; loc=""; fi
            d="$TMP/parity-$tree-$tag"
            # DS4_BATCHED_SESSIONS is explicit: its RAM-based default (#19) is
            # the one documented difference from 1.3.0.
            # shellcheck disable=SC2086  # $loc is a word list, empty for the new tree
            env $loc MSS_BACKENDS="$sel" OLLAMA_USER=testuser DS4_BATCHED_SESSIONS=1 \
                LLAMACPP_BIN="$TMP/fix/llamacpp/llamacpp-server" LLAMACPP_MODEL="$TMP/fix/llamacpp/model.gguf" \
                LLAMACPP_MODEL_SHA256="$(cat "$TMP/fix/llamacpp/model.sha")" \
                DS4_BIN="$TMP/fix/ds4/ds4-server" DS4_MODEL="$TMP/fix/ds4/model.gguf" \
                DS4_MODEL_SHA256="$(cat "$TMP/fix/ds4/model.sha")" \
                sh "$src/scripts/install-backends.sh" --render-only "$d" >/dev/null 2>&1
            echo $? > "$d.rc"
        done
        OLDRC=$(cat "$TMP/parity-old-$tag.rc"); NEWRC=$(cat "$TMP/parity-new-$tag.rc")
        check "render '$sel' exit code matches 1.3.0" "$OLDRC" "$NEWRC"
        # Equal exit codes also hold when both trees fail; say which one is expected (#21).
        case $sel in
            llamacpp,ds4)
                [ "$OLDRC" != 0 ] && [ "$NEWRC" != 0 ] && ok "render '$sel' fails in both trees" \
                    || fail "render '$sel' exit codes: 1.3.0 $OLDRC, now $NEWRC" ;;
            *) check "render '$sel' exits 0 in both trees" "0 0" "$OLDRC $NEWRC" ;;
        esac
        # libexec copies are sources (mss-common.sh gains helpers); every
        # rendered conf, pf file, plist and stamp must be identical.
        if [ -d "$TMP/parity-old-$tag" ] || [ -d "$TMP/parity-new-$tag" ]; then
            if diff -r -x '*.sh' "$TMP/parity-old-$tag" "$TMP/parity-new-$tag" >/dev/null 2>&1 \
                && [ "$(cd "$TMP/parity-old-$tag" 2>/dev/null && ls)" = "$(cd "$TMP/parity-new-$tag" 2>/dev/null && ls)" ]; then
                ok "render '$sel' output identical to 1.3.0"
            else
                fail "render '$sel' output differs from 1.3.0: $(diff -r -x '*.sh' "$TMP/parity-old-$tag" "$TMP/parity-new-$tag" 2>&1 | head -5)"
            fi
        fi
    done
fi

echo "== phase A: install.sh arguments and modes =="
"$ROOT/scripts/install.sh" --bogus </dev/null >/dev/null 2>&1; check "unknown argument exits 2" 2 $?
"$ROOT/scripts/install.sh" --help </dev/null >/dev/null 2>&1; check "--help exits 0" 0 $?
A4F="$TMP/a4.env"
MSS_ENV_FILE="$A4F" "$ROOT/scripts/install.sh" --configure-only </dev/null >/dev/null 2>&1; check "--configure-only without a terminal exits 2 (A4)" 2 $?
[ ! -e "$A4F" ] && ok "--configure-only without a terminal writes nothing (A4)" || fail "A4 wrote $A4F"

echo "== phase A: MSS_REPLACE_BACKEND rules (A15) =="
check_fail "MSS_REPLACE_BACKEND with --render-only" render 'ds4' "$TMP/bad-replace" MSS_REPLACE_BACKEND=llamacpp
OUT=$(render 'ds4' "$TMP/bad-replace" MSS_REPLACE_BACKEND=llamacpp 2>&1)
printf '%s' "$OUT" | grep -q 'MSS_REPLACE_BACKEND is accepted only with --check-only' && ok "A15 message names --check-only" || fail "A15 message: $OUT"
TUSER=$(id -un); [ "$TUSER" != root ] || TUSER=nobody
OUT=$(env MSS_BACKENDS=ds4 OLLAMA_USER="$TUSER" MSS_REPLACE_BACKEND=llamacpp DS4_BIN="$TMP/fix/ds4/ds4-server" \
    DS4_MODEL="$TMP/fix/ds4/model.gguf" DS4_MODEL_SHA256="$(cat "$TMP/fix/ds4/model.sha")" DS4_PORT=18999 \
    sh "$ROOT/scripts/install-backends.sh" --check-only 2>&1) && fail "A15 accepted a replace of a backend that is not installed" \
    || { printf '%s' "$OUT" | grep -q 'is not the installed optional backend' && ok "A15 refuses a replace of a backend that is not installed" || fail "A15: $OUT"; }

echo "== phase A: 1.5.0 pure functions and static checks (#15) =="
. "$ROOT/scripts/lib/mss-acquire.sh"
REPO_DIR=$ROOT
check "catalogue starter" "qwen3-4b" "$(mss_catalog_ids llamacpp starter)"
check "catalogue more (llama.cpp)" "gpt-oss-20b-mxfp4" "$(mss_catalog_ids llamacpp more)"
check "catalogue more (ds4)" "qwen38-q2 qwen38-q4" "$(mss_catalog_ids ds4 more | tr '\n' ' ' | sed 's/ $//')"
check "test rows are never menu rows" "" "$( { mss_catalog_ids llamacpp starter; mss_catalog_ids llamacpp more; } | grep stories260k)"
check "catalogue URL pins the revision" \
    "https://huggingface.co/ggml-org/models-moved/resolve/499bc8821c6b12b4e53c5bffcb21ec206f212d81/tinyllamas/stories260K.gguf" \
    "$(mss_catalog_url llamacpp stories260k)"
check_fail "catalogue: unknown id" mss_catalog_get llamacpp nope size
check "sizes: 2.5 GB / 137 GiB / 165 GiB" "2.5 GB|137 GiB|165 GiB" \
    "$(mss_human_size 2497280640)|$(mss_human_size 147207127040)|$(mss_human_size 177280286720)"
check "free space via MSS_DF (A8)" "1073741824" "$(MSS_DF="$ROOT/tests/stubs/df-low" mss_free_bytes /)"
MSS_SW_VERS="$ROOT/tests/stubs/sw-vers-14" mss_ds4_missing_prereqs | grep -q '^macOS 15 or later (this Mac runs 14.7.1)' \
    && ok "the ds4 build needs macOS 15, naming this Mac's version" || fail "ds4 macOS gate on 14"
MSS_SW_VERS="$ROOT/tests/stubs/sw-vers-15" mss_ds4_missing_prereqs | grep -q 'macOS' \
    && fail "macOS 15 refused by the ds4 gate" || ok "macOS 15 passes the ds4 gate"
OUT=$(MSS_SW_VERS="$ROOT/tests/stubs/sw-vers-14" mss_acquire_ds4_build "$TMP/ds4-on-14" 2>&1) && fail "ds4 built on macOS 14" \
    || { printf '%s' "$OUT" | grep -q 'needs: macOS 15 or later (this Mac runs 14.7.1)' && [ ! -e "$TMP/ds4-on-14" ] \
        && ok "on macOS 14 the ds4 build is refused before any clone" || fail "ds4 on 14: $OUT"; }
check_fail "an http:// URL is refused (A10)" mss_url_valid http://example.com/m.gguf
( unset DS4_BIN DS4_BUILD_DIR LLAMACPP_BREW_INSTALL DS4_MODEL_URL DS4_MODEL_SHA256
  LLAMACPP_MODEL_URL=https://example.com/m.gguf mss_d7_validate ) >/dev/null 2>&1 \
    && fail "a URL without a sha256 is accepted (A10)" || ok "a URL without a sha256 is refused before any network call (A10)"
( unset DS4_BUILD_DIR LLAMACPP_MODEL_URL DS4_MODEL_URL
  DS4_BIN=/x DS4_BUILD_DIR=/y mss_d7_validate ) >/dev/null 2>&1 \
    && fail "DS4_BIN with DS4_BUILD_DIR accepted (A13)" || ok "DS4_BIN with DS4_BUILD_DIR is refused (A13)"
( unset DS4_BIN DS4_BUILD_DIR LLAMACPP_MODEL_URL
  DS4_MODEL_URL=catalog:nope mss_d7_validate ) >/dev/null 2>&1 \
    && fail "an unknown catalogue id accepted" || ok "an unknown catalogue id is refused"
printf 'MSS_BACKENDS=ds4\nDS4_MODEL_URL=catalog:qwen38-q4\n' > "$EFT/d7.env"; chmod 600 "$EFT/d7.env"
OUT=$(mss_envfile_load "$EFT/d7.env" 2>&1) && fail "backends.env accepted DS4_MODEL_URL (A14)" \
    || { printf '%s' "$OUT" | grep -q 'unknown key DS4_MODEL_URL' && ok "backends.env rejects DS4_MODEL_URL (A14)" || fail "A14: $OUT"; }
# A15: every curl in these files is HTTPS-only for the request and for redirects; the Homebrew
# installer fetch needs --proto only. sudo in mss-acquire.sh is the CLT install alone.
BADCURL=$(grep -n 'curl ' "$ROOT/bootstrap.sh" "$ROOT/scripts/lib/mss-acquire.sh" "$ROOT/scripts/model.sh" \
    | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -Ev 'printf|echo|mss_brew_install_cmd|manual:|mss_error|mssb_say|mssb_die' \
    | grep -v "\-\-proto '=https'" || true)
BADREDIR=$(grep -n '/usr/bin/curl\|MSSB_CURL' "$ROOT/bootstrap.sh" "$ROOT/scripts/lib/mss-acquire.sh" \
    | grep -v "MSS_BREW_INSTALLER\"\\|--proto-redir '=https'" | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)
[ -z "$BADCURL$BADREDIR" ] && ok "A15 curl calls are HTTPS-only" || fail "A15 curl: $BADCURL $BADREDIR"
check "A15 sudo in mss-acquire.sh is the CLT install only" 'sudo softwareupdate -i "$label" >&2' \
    "$(grep -v '^[[:space:]]*#' "$ROOT/scripts/lib/mss-acquire.sh" | grep -o 'sudo .*' | sed 's/[[:space:]]*$//' | tr '\n' '|' | sed 's/|$//')"
"$ROOT/scripts/install.sh" --help 2>&1 | grep -q 'may leave a verification stamp' \
    && ok "install.sh --help mentions the verification stamp" || fail "install.sh --help wording"

echo "== phase A: bootstrap.sh (B1a, B5) =="
sh -n "$ROOT/bootstrap.sh" && ok "bootstrap.sh sh -n" || fail "bootstrap.sh sh -n"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning -s sh "$ROOT/bootstrap.sh" && ok "shellcheck -s sh bootstrap.sh" || fail "shellcheck bootstrap.sh"
fi
check "the last non-comment line calls main" 'main "$@"' "$(grep -v '^[[:space:]]*#' "$ROOT/bootstrap.sh" | grep -v '^[[:space:]]*$' | tail -n 1)"
BS="$TMP/bootstrap"; mkdir -p "$BS"
sed '$d' "$ROOT/bootstrap.sh" > "$BS/lib.sh"
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in -o) o=$2; shift 2 ;; *) shift ;; esac; done\ncp "$MSSB_FAKE_RAW" "$o"\n' > "$BS/curl"
chmod +x "$BS/curl"
cp "$ROOT/bootstrap.sh" "$BS/same.sh"
{ cat "$ROOT/bootstrap.sh"; printf ' '; } > "$BS/onebyte.sh"
sed 's/^MSS_TAG=.*/MSS_TAG=v0.0.0/' "$ROOT/bootstrap.sh" > "$BS/tag.sh"
B5SHA=0123456789abcdef0123456789abcdef01234567
b5() { ( . "$BS/lib.sh"; MSSB_CURL="$BS/curl" MSSB_FAKE_RAW=$1 mssb_verify "$2" "$3" "$4" ) >/dev/null 2>&1; }
TAG=$(sed -n 's/^MSS_TAG=//p' "$ROOT/bootstrap.sh")
b5 "$BS/same.sh" "$TAG" "$BS/same.sh" x && ok "B5 accepts an identical copy at the tag" || fail "B5 identical copy refused"
b5 "$BS/same.sh" "$B5SHA" "$BS/same.sh" "$B5SHA" && ok "B5 accepts an identical copy at a 40-hex ref" || fail "B5 40-hex refused"
b5 "$BS/onebyte.sh" "$TAG" "$BS/same.sh" x && fail "B5 accepted a 1-byte difference" || ok "B5 refuses a raw file 1 byte off"
b5 "$BS/tag.sh" "$TAG" "$BS/tag.sh" x && fail "B5 accepted another MSS_TAG line" || ok "B5 refuses an MSS_TAG mismatch"
b5 "$BS/same.sh" main "$BS/same.sh" x && fail "B5 accepted --ref main" || ok "B5 refuses --ref main"
b5 "$BS/same.sh" 0123456 "$BS/same.sh" 0123456 && fail "B5 accepted a 7-character sha" || ok "B5 refuses a 7-character sha"
b5 "$BS/same.sh" "$B5SHA" "$BS/same.sh" "$(printf 'f%.0s' $(seq 40))" && fail "B5 accepted a commit that is not the ref" \
    || ok "B5 refuses a clone at another commit"

echo "== phase A: waiting for a model (M4, M6) =="
check_fail "an empty model is the 1.4.0 error without MSS_DEFER_MODEL (M6)" \
    render llamacpp "$TMP/m6-unset" LLAMACPP_MODEL= LLAMACPP_MODEL_SHA256=
OUT=$(render llamacpp "$TMP/m6-unset" LLAMACPP_MODEL= LLAMACPP_MODEL_SHA256= 2>&1)
printf '%s\n' "$OUT" | grep -q '^ERROR: LLAMACPP_MODEL is required' \
    && ok "an empty model fails on LLAMACPP_MODEL (#21)" || fail "an empty model failed for another reason: $OUT"
if render llamacpp "$TMP/m6-yes" MSS_DEFER_MODEL=yes LLAMACPP_MODEL= LLAMACPP_MODEL_SHA256= >/dev/null 2>&1; then
    ok "MSS_DEFER_MODEL=yes renders without a model (M6)"
    grep -qx 'MSS_MODEL_STATE=waiting' "$TMP/m6-yes/backends.conf" && grep -qx 'MSS_GUARD_BACKEND=llamacpp' "$TMP/m6-yes/backends.conf" \
        && ok "conf says waiting and keeps MSS_GUARD_BACKEND (M3)" || fail "waiting conf: $(cat "$TMP/m6-yes/backends.conf")"
    [ ! -e "$TMP/m6-yes/com.mac-studio-server.llamacpp.plist" ] && [ ! -e "$TMP/m6-yes/com.mac-studio-server.guard.plist" ] \
        && [ ! -e "$TMP/m6-yes/llamacpp.model.verified" ] && ok "no backend or guard plist and no stamp (M3)" || fail "waiting render wrote jobs: $(ls "$TMP/m6-yes")"
    OUT=$(MSS_CONF="$TMP/m6-yes/backends.conf" sh "$ROOT/scripts/status.sh" 2>&1); RC=$?
    check "status on a waiting llama.cpp exits 0 (M4)" 0 "$RC"
    printf '%s' "$OUT" | grep -qx 'llamacpp: waiting for a model (run scripts/model.sh)' && ok "status prints the waiting line (M4)" || fail "M4: $OUT"
else
    fail "MSS_DEFER_MODEL=yes render: $(render llamacpp "$TMP/m6-yes" MSS_DEFER_MODEL=yes LLAMACPP_MODEL= 2>&1 | tail -1)"
fi
# the render-only output with the variable unset stays 1.4.0's (A3)
if render llamacpp "$TMP/m6-parity" >/dev/null 2>&1; then
    grep -q MSS_MODEL_STATE "$TMP/m6-parity/backends.conf" && fail "MSS_MODEL_STATE written without MSS_DEFER_MODEL" \
        || ok "no MSS_MODEL_STATE without MSS_DEFER_MODEL"
else
    fail "render llamacpp without MSS_DEFER_MODEL: $(render llamacpp "$TMP/m6-parity" 2>&1 | tail -n 1)"
fi

echo "== phase A: model.sh without a terminal (M7) =="
M7="$TMP/m7"; mkdir -p "$M7"
MSS_ENV_FILE="$M7/b.env" HOME="$M7" "$ROOT/scripts/model.sh" --catalog stories260k </dev/null >"$M7/out" 2>&1
check "model.sh without a terminal exits 2 (M7)" 2 $?
grep -q 'model.sh needs a terminal' "$M7/out" && ok "M7 says it needs a terminal" || fail "M7: $(cat "$M7/out")"
[ -z "$(ls -A "$M7" | grep -v '^out$')" ] && ok "M7 created nothing" || fail "M7 created: $(ls -A "$M7")"

echo "== phase A: one hash, as root only a stamp (D6, U3) =="
if [ "$(uname)" = Darwin ] && [ "$(id -u)" -ne 0 ]; then
    U3="$TMP/u3"; mkdir -p "$U3"
    # A 4 GiB write and hash adds page-cache pressure; on a Mac serving a model, skip it (#21).
    if [ "${MSS_TEST_BIG_FILES:-}" = 1 ]; then
        mkfile 4g "$U3/big.gguf"
        U3SHA=$(mss_shasum256 "$U3/big.gguf" | awk '{print $1}')
        env MSS_BACKENDS=ds4 OLLAMA_USER="$(id -un)" MSS_PROGRESS_SECONDS=1 DS4_BIN="$TMP/fix/ds4/ds4-server" \
            DS4_MODEL="$U3/big.gguf" DS4_MODEL_SHA256="$U3SHA" DS4_PORT=18999 \
            sh "$ROOT/scripts/install-backends.sh" --check-only >"$U3/log" 2>&1
        check "4 GiB check passes (U3)" 0 $?
        PROG=$(grep -c '^hashing ds4 model: [0-9.]* / 4.0 GiB$' "$U3/log")
        [ "$PROG" -ge 2 ] && ok "U3 $PROG progress lines at 1 s" || fail "U3 progress lines: $PROG ($(cat "$U3/log"))"
        check "U3 exactly one done line" 1 "$(grep -c '^hashing ds4 model: done (4.0 GiB)$' "$U3/log")"
        rm -f "$U3/big.gguf"
    else
        echo "skip - U3 writes and hashes a 4 GiB file (set MSS_TEST_BIG_FILES=1)"
    fi
    env MSS_BACKENDS=ds4 OLLAMA_USER="$(id -un)" DS4_BIN="$TMP/fix/ds4/ds4-server" DS4_MODEL="$TMP/fix/ds4/model.gguf" \
        DS4_MODEL_SHA256="$(cat "$TMP/fix/ds4/model.sha")" DS4_PORT=18999 \
        sh "$ROOT/scripts/install-backends.sh" --check-only >"$U3/small" 2>&1
    check "a small model logs only the done line (U3)" "hashing ds4 model: done (0.0 GiB)" "$(grep '^hashing' "$U3/small")"
    [ ! -e "$MSS_TEST_SYSROOT/var/db/mac-studio-server/ds4.model.verified" ] \
        && ok "a non-root check writes no stamp (D6)" || fail "a non-root check wrote a stamp"
else
    echo "skip - U3 needs macOS (mkfile, BSD dd) and a non-root user"
fi


echo "== phase A: #27 D1 resolver and validation =="
mkdir -p "$TMP/h27" "$TMP/h27stub" "$TMP/h27e" "$TMP/h27f" "$TMP/h27g" "$TMP/h27b" "$TMP/h27c" "$TMP/h27d" "$TMP/h27e/state"
cat > "$TMP/h27stub/sysctl" <<'XS'
#!/bin/sh
# sysctl stub: hw.memsize reads 128 GiB, iogpu reads 0; MSS_SYSCTL_MODE=fail
# fails every read (a Mac with no iogpu key).
if [ "${MSS_SYSCTL_MODE:-}" = fail ]; then
    [ "${1:-}" = -n ] && [ "${2:-}" = hw.memsize ] && { echo 137438953472; exit 0; }
    exit 1
fi
[ "${1:-}" = -n ] || exit 1
case $2 in
    hw.memsize) echo 137438953472 ;;
    *) echo 0 ;;
esac
XS
chmod +x "$TMP/h27stub/sysctl"
resolve_case() { # resolve_case <env=...>...: the resolved result, or rc=1
    ( unset MSS_GPU_PERCENT OLLAMA_GPU_PERCENT MSS_DOCKER_AUTOSTART MSS_DOCKER_INSTALL \
          MSS_POWER_AUTORESTART DOCKER_AUTOSTART MSS_ENVFILE_LOADED MSS_CHOICES_RESOLVED
      for _a in "$@"; do export "${_a?}"; done
      mss_choices_resolve 2>/dev/null || { echo rc=1; return 0; }
      printf 'GPU=%s DA=%s DI=%s LEG=%s\n' "${MSS_GPU_PERCENT:-unset}" \
          "${MSS_DOCKER_AUTOSTART:-unset}" "${MSS_DOCKER_INSTALL:-unset}" "${OLLAMA_GPU_PERCENT:-unset}" )
}
check "resolver: both GPU keys unset" "GPU=unset DA=unset DI=unset LEG=unset" "$(resolve_case)"
check "resolver: MSS_GPU_PERCENT alone" "GPU=85 DA=unset DI=unset LEG=unset" "$(resolve_case MSS_GPU_PERCENT=85)"
check "resolver: same values, legacy unset after" "GPU=80 DA=unset DI=unset LEG=unset" "$(resolve_case MSS_GPU_PERCENT=80 OLLAMA_GPU_PERCENT=80)"
OUT=$(resolve_case OLLAMA_GPU_PERCENT=80); check "resolver: legacy alone migrates, legacy unset after" "GPU=80 DA=unset DI=unset LEG=unset" "$OUT"
( unset MSS_GPU_PERCENT MSS_ENVFILE_LOADED MSS_CHOICES_RESOLVED OLLAMA_GPU_PERCENT
  export OLLAMA_GPU_PERCENT=80; mss_choices_resolve >/dev/null 2>"$TMP/h27/dep-env.err" )
grep -q 'OLLAMA_GPU_PERCENT is deprecated; using it as MSS_GPU_PERCENT=80. Set MSS_GPU_PERCENT instead.' "$TMP/h27/dep-env.err" \
    && ok "resolver: the environment notice names where to set it" || fail "env notice: $(cat "$TMP/h27/dep-env.err")"
( unset MSS_GPU_PERCENT MSS_ENVFILE_LOADED MSS_CHOICES_RESOLVED OLLAMA_GPU_PERCENT
  export OLLAMA_GPU_PERCENT=80 MSS_ENVFILE_LOADED=' OLLAMA_GPU_PERCENT '; mss_choices_resolve >/dev/null 2>"$TMP/h27/dep-file.err" )
grep -q 'OLLAMA_GPU_PERCENT is deprecated; using it as MSS_GPU_PERCENT=80. Rename it in backends.env' "$TMP/h27/dep-file.err" \
    && ok "resolver: the file notice names backends.env" || fail "file notice: $(cat "$TMP/h27/dep-file.err")"
( unset MSS_ENVFILE_LOADED MSS_CHOICES_RESOLVED
  export MSS_GPU_PERCENT=85 OLLAMA_GPU_PERCENT=80
  mss_choices_resolve 2>"$TMP/h27/conf.err" ) && _crc=0 || _crc=1
check "resolver: a conflict exits 1" 1 "$_crc"
grep -q 'MSS_GPU_PERCENT=85 (environment) and OLLAMA_GPU_PERCENT=80 (environment) differ; keep one' "$TMP/h27/conf.err" \
    && ok "conflict names both keys and their sources" || fail "conflict: $(cat "$TMP/h27/conf.err")"
check "resolver: DOCKER_AUTOSTART=true sets both" "GPU=unset DA=yes DI=yes LEG=unset" "$(resolve_case DOCKER_AUTOSTART=true)"
check "resolver: true against autostart=no is a conflict" "rc=1" "$(resolve_case DOCKER_AUTOSTART=true MSS_DOCKER_AUTOSTART=no)"
check "resolver: DOCKER_AUTOSTART=false is ignored" "GPU=unset DA=unset DI=unset LEG=unset" "$(resolve_case DOCKER_AUTOSTART=false)"
check "resolver: any other DOCKER_AUTOSTART exits 1" "rc=1" "$(resolve_case DOCKER_AUTOSTART=maybe)"
for bad in 0 101 08 080 8O ' 80'; do
    ( unset MSS_ENVFILE_LOADED MSS_SYSCTL_MODE; MSS_GPU_PERCENT="$bad" MSS_SYSCTL="$TMP/h27stub/sysctl" mss_choices_check_format >/dev/null 2>&1 ) \
        && fail "format accepts '$bad'" || ok "format rejects '$bad'"
done
for good in 1 80 100 system; do
    ( unset MSS_ENVFILE_LOADED; MSS_GPU_PERCENT="$good" MSS_SYSCTL="$TMP/h27stub/sysctl" mss_choices_check_format >/dev/null 2>&1 ) \
        && ok "format accepts $good" || fail "format accepts $good"
done
for bad in Yes true maybe; do
    for k in MSS_DOCKER_INSTALL MSS_DOCKER_AUTOSTART MSS_POWER_AUTORESTART; do
        ( export "$k=$bad"; MSS_GPU_PERCENT= MSS_SYSCTL="$TMP/h27stub/sysctl" mss_choices_check_format >/dev/null 2>&1 ) \
            && fail "$k accepts $bad" || ok "$k rejects $bad"
    done
done
OUT=$( (unset MSS_ENVFILE_LOADED; MSS_SYSCTL_MODE=fail MSS_GPU_PERCENT=80 MSS_SYSCTL="$TMP/h27stub/sysctl" mss_choices_check_format 2>&1) ) \
    && fail 'a Mac with no iogpu key accepted a number' \
    || { printf '%s' "$OUT" | grep -q 'no iogpu.wired_limit_mb; use MSS_GPU_PERCENT=system' && ok 'no iogpu key refuses a number' || fail "iogpu message: $OUT"; }
check "MSS_DOCKER_JOB_PATH equals the colima plist PATH" \
    "$(sed -n 's|.*<string>\(/usr/local/bin[^<]*\)</string>.*|\1|p' "$ROOT/config/com.colima.daemon.plist" | head -n 1)" "$MSS_DOCKER_JOB_PATH"
# A1 validation rows: Docker tools against the boot job's PATH, the root rules
# and the power setting. The caller's PATH drops every directory holding a real
# colima or docker, so the runner's own tools cannot change a row's answer.
V=$TMP/h27v; mkdir -p "$V/job-both" "$V/job-none" "$V/elsewhere" "$V/root" "$V/brew"
cp "$ROOT/tests/stubs/colima" "$ROOT/tests/stubs/docker" "$V/job-both/"; cp "$ROOT/tests/stubs/colima" "$V/elsewhere/"
cp "$ROOT/tests/stubs/brew" "$V/brew/"
printf '#!/bin/sh\n[ "${1:-}" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > "$V/root/id"
chmod +x "$V"/*/*
V_PATH=$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r _d; do
    [ -n "$_d" ] || continue; [ -x "$_d/colima" ] || [ -x "$_d/docker" ] || printf '%s:' "$_d"; done)
V_PATH=${V_PATH%:}
validate_case() { # validate_case <job-dir> <extra-path> <env=...>...: rc=N, then the error
    _vjob=$1; _vpath=$2; shift 2
    ( unset MSS_GPU_PERCENT MSS_DOCKER_INSTALL MSS_DOCKER_AUTOSTART MSS_POWER_AUTORESTART OLLAMA_USER
      export MSS_DOCKER_JOB_PATH="$V/$_vjob" MSS_STUB_LOG="$V/stub.log" MSS_STUB_STATE="$V" \
          MSS_PMSET="$ROOT/tests/stubs/pmset-autorestart-0" PATH="${_vpath:+$_vpath:}${V_PATH:-$PATH}"
      while [ "$#" -gt 0 ]; do export "${1?}"; shift; done
      _verr=$(mss_choices_validate 2>&1); echo "rc=$?"; printf '%s\n' "$_verr" )
}
check "A1 DI=yes with the tools missing and Homebrew present passes" "rc=0" \
    "$(validate_case job-none "$V/brew" MSS_DOCKER_INSTALL=yes | head -n 1)"
check "A1 DI=yes as root with a tool missing exits 1" "rc=1
ERROR: MSS_DOCKER_INSTALL=yes: run install.sh as your user; Homebrew refuses root" \
    "$(validate_case job-none "$V/root:$V/brew" MSS_DOCKER_INSTALL=yes)"
check "A1 DI=yes as root with both tools present passes" "rc=0" \
    "$(validate_case job-both "$V/root" MSS_DOCKER_INSTALL=yes | head -n 1)"
check "A1 DA=yes as root without OLLAMA_USER exits 1" "rc=1
ERROR: MSS_DOCKER_AUTOSTART=yes needs a non-root user: run install.sh as your user or set OLLAMA_USER" \
    "$(validate_case job-both "$V/root" MSS_DOCKER_AUTOSTART=yes)"
check "A1 DA=yes as root with OLLAMA_USER passes" "rc=0" \
    "$(validate_case job-both "$V/root" MSS_DOCKER_AUTOSTART=yes OLLAMA_USER=someone | head -n 1)"
check "A1 DA=yes with the tools missing and DI unset exits 1" "rc=1
ERROR: MSS_DOCKER_AUTOSTART=yes needs Colima and the Docker CLI; set MSS_DOCKER_INSTALL=yes or install them" \
    "$(validate_case job-none "" MSS_DOCKER_AUTOSTART=yes)"
check "A1 DA=yes with DI=yes and the tools missing passes" "rc=0" \
    "$(validate_case job-none "$V/brew" MSS_DOCKER_AUTOSTART=yes MSS_DOCKER_INSTALL=yes | head -n 1)"
for k in MSS_DOCKER_INSTALL MSS_DOCKER_AUTOSTART; do
    check "A1 $k=yes with colima outside the job's PATH exits 1" "rc=1
ERROR: colima is at $V/elsewhere/colima, outside the boot job's PATH; move or link it into /opt/homebrew/bin or /usr/local/bin" \
        "$(validate_case job-none "$V/elsewhere:$V/brew" "$k=yes")"
done
check "A1 DI=no with colima outside the job's PATH passes" "rc=0" \
    "$(validate_case job-none "$V/elsewhere" MSS_DOCKER_INSTALL=no | head -n 1)"
check "A1 power set on a Mac without the setting exits 1" "rc=1
ERROR: this Mac has no restart-after-power-failure setting; unset MSS_POWER_AUTORESTART" \
    "$(validate_case job-none "" MSS_POWER_AUTORESTART=yes MSS_PMSET="$ROOT/tests/stubs/pmset-none")"
check "A1 power set on a Mac with the setting passes" "rc=0" \
    "$(validate_case job-none "" MSS_POWER_AUTORESTART=no | head -n 1)"
check "A1 validation never runs brew, colima or docker" "" "$(cat "$V/stub.log" 2>/dev/null)"


echo "== phase A: #27 D2 backends.env keys =="
# mss_envfile_check_file guards ownership and mode with BSD `stat -f`. For this
# block `stat` is the stat-bsd stub, which answers on Linux and steps aside on
# macOS, so the parser and writer rows run on every runner.
stat() { "$ROOT/tests/stubs/stat-bsd" "$@"; }
mkdir -p "$TMP/h27"
EFH="$TMP/h27/legacy.env"
printf 'MSS_BACKENDS=ds4\nOLLAMA_GPU_PERCENT=80\n' > "$EFH"; chmod 600 "$EFH"
OUT=$( (unset MSS_BACKENDS MSS_GPU_PERCENT OLLAMA_GPU_PERCENT MSS_ENVFILE_LOADED
        mss_envfile_load "$EFH" >/dev/null 2>&1 && printf 'file=%s loaded=%s' "${OLLAMA_GPU_PERCENT:-unset}" "$MSS_ENVFILE_LOADED") 2>/dev/null )
check "the legacy key still loads and is recorded as loaded" "file=80 loaded= MSS_BACKENDS OLLAMA_GPU_PERCENT" "$OUT"
EFH2="$TMP/h27/out.env"
( export MSS_BACKENDS=ds4 MSS_GPU_PERCENT=80; unset OLLAMA_GPU_PERCENT; mss_envfile_write "$EFH2" ) >/dev/null 2>&1
grep -q '^MSS_GPU_PERCENT=80$' "$EFH2" && ! grep -q OLLAMA_GPU_PERCENT "$EFH2" \
    && ok "mss_envfile_write writes the new key and never the legacy" || fail "write: $(cat "$EFH2" 2>/dev/null)"
# A file OLLAMA_GPU_PERCENT beside an environment MSS_GPU_PERCENT: the loader
# exports both names, so the resolver can compare them (the conflict row below).
OUT=$( (unset MSS_GPU_PERCENT OLLAMA_GPU_PERCENT MSS_ENVFILE_LOADED MSS_CHOICES_RESOLVED; \
        export MSS_GPU_PERCENT=85; mss_envfile_load "$EFH" >/dev/null 2>&1
        printf '%s|%s|%s' "${MSS_GPU_PERCENT}" "${OLLAMA_GPU_PERCENT:-unset}" "$MSS_ENVFILE_LOADED") 2>/dev/null )
check "the loader exports the file's legacy key beside an environment MSS_GPU_PERCENT" "85|80| MSS_BACKENDS OLLAMA_GPU_PERCENT" "$OUT"
# The legacy key in both places: the environment wins, as for every other key,
# and the resolver names the environment as the source.
OUT=$( (unset MSS_GPU_PERCENT OLLAMA_GPU_PERCENT MSS_ENVFILE_LOADED MSS_ENVFILE_OVERRIDDEN MSS_CHOICES_RESOLVED
        export OLLAMA_GPU_PERCENT=85; mss_envfile_load "$EFH" >/dev/null 2>&1
        printf '%s|%s|' "$OLLAMA_GPU_PERCENT" "$MSS_ENVFILE_OVERRIDDEN"
        mss_choices_resolve 2>&1 >/dev/null) 2>/dev/null )
check "an environment OLLAMA_GPU_PERCENT beats the file's" \
    "85| OLLAMA_GPU_PERCENT|OLLAMA_GPU_PERCENT is deprecated; using it as MSS_GPU_PERCENT=85. Set MSS_GPU_PERCENT instead." "$OUT"
OUT=$( (unset MSS_GPU_PERCENT OLLAMA_GPU_PERCENT MSS_DOCKER_AUTOSTART MSS_DOCKER_INSTALL \
          MSS_POWER_AUTORESTART DOCKER_AUTOSTART MSS_ENVFILE_LOADED MSS_ENVFILE_OVERRIDDEN MSS_CHOICES_RESOLVED
        export MSS_BACKENDS=ds4 MSS_GPU_PERCENT=85
        mss_envfile_load "$EFH" >/dev/null 2>&1 && mss_choices_resolve) 2>&1 )
printf '%s' "$OUT" | grep -q 'differ; keep one' \
    && ok "a legacy file key against a new env key is a conflict" || fail "conflict row: $OUT"
HS1=$(mss_shasum256 "$EFH" | awk '{print $1}')
( export MSS_BACKENDS=ds4; mss_envfile_load "$EFH" >/dev/null 2>&1 ) ; HS2=$(mss_shasum256 "$EFH" | awk '{print $1}')
check "loaded mode never writes the file" "$HS1" "$HS2"
printf 'MSS_BACKENDS=ollama\nMSS_PMSET=/bin/true\n' > "$TMP/h27/hook.env"; chmod 600 "$TMP/h27/hook.env"
check_fail "the parser refuses a test-only hook key" mss_envfile_load "$TMP/h27/hook.env"
# A test hook outside a test sysroot must not redirect a real call: with the
# sysroot unset, mss-host.sh uses /usr/sbin/sysctl however MSS_SYSCTL is set.
( unset MSS_TEST_SYSROOT; export MSS_SYSCTL="$ROOT/tests/stubs/sysctl-state"
  . "$ROOT/scripts/lib/mss-common.sh"; . "$ROOT/scripts/lib/mss-host.sh"
  _mss_sysctl -n hw.memsize 2>/dev/null ) > "$TMP/h27/hook-off.out" 2>&1
grep -q 137438953472 "$TMP/h27/hook-off.out" \
    && fail "a stray MSS_SYSCTL redirected a call with no sysroot" \
    || ok "a stray MSS_SYSCTL is ignored outside a sysroot"
( export MSS_TEST_SYSROOT=$TMP/h27 MSS_SYSCTL="$ROOT/tests/stubs/sysctl-state" MSS_STUB_STATE=$TMP/h27
  . "$ROOT/scripts/lib/mss-common.sh"; . "$ROOT/scripts/lib/mss-host.sh"
  [ "$(_mss_sysctl -n hw.memsize)" = 137438953472 ] ) \
    && ok "MSS_SYSCTL still works inside a sysroot" || fail "MSS_SYSCTL ignored inside a sysroot"
# mss_host_root_guard is a no-op for a non-root run; CI phase A is never root
# (checked at the top of this file), so a set sysroot must not stop the run.
MSS_TEST_SYSROOT=$TMP/h27 mss_host_root_guard && ok "mss_host_root_guard passes a non-root run" || fail "mss_host_root_guard blocked a non-root run"
# Restored, not merely unset: the apply rows below rely on the exported phase A
# sysroot, and the test hooks in mss-host.sh are honoured only inside it.
MSS_TEST_SYSROOT=$TMP/sysroot; export MSS_TEST_SYSROOT
unset -f stat



echo "== phase A: #27 D4/D5 apply, D9 status, D10 (phase A, launchctl-state) =="
# the apply helpers call sudo when not root; MSS_SUDO points them at a shim
# that runs the command as this user (the picker block reuses the same file).
mkdir -p "$TMP/nosudo"
printf '#!/bin/sh\ncase $1 in -v) exit 0 ;; -n) shift ;; esac\nexec "$@"\n' > "$TMP/nosudo/sudo"
chmod +x "$TMP/nosudo/sudo"
# HS_STATE and HSD are exported: the #27 blocks define the apply/seed
# helpers as functions whose bodies run in a command substitution so
# the caller can read rc. An unexported variable disappears inside that
# subshell, daemon_dir() then resolves to /Library/LaunchDaemons instead
# of the phase A sysroot, and the state file and the plist land in
# different places: every row after the first reads stale.
export HS_STATE=$TMP/h27e/state
export HSD="$TMP/sysroot/Library/LaunchDaemons"
mkdir -p "$HS_STATE" "$HSD"
# stubs first on PATH, kept after the audit dir; sudo stays the picker's nosudo
mkdir -p "$TMP/h27e-bin"
cp "$ROOT/tests/stubs/launchctl-state" "$TMP/h27e-bin/launchctl"
cp "$ROOT/tests/stubs/sysctl-state" "$TMP/h27e-bin/sysctl"
cp "$ROOT/tests/stubs/plutil" "$TMP/h27e-bin/plutil"
chmod +x "$TMP/h27e-bin/"*
# apply_gpu <env=...>...: the D8 line and any mss_error text, then rc. The
# 2>&1 merges the two streams in the order they were written — the unset-row
# migrate note (A10h) and the stuck-row failure (A10e) are stderr-only.
apply_gpu() {
    ( export MSS_STUB_STATE=$HS_STATE MSS_SYSCTL="$TMP/h27e-bin/sysctl" MSS_LAUNCHD_TIMEOUT=1 MSS_SUDO=$TMP/nosudo/sudo PATH="$TMP/h27e-bin:$PATH"
      export MSS_TEST_SYSROOT=$TMP/sysroot
      while [ "$#" -gt 0 ]; do export "${1?}"; shift; done
      mss_gpu_apply "${MSS_GPU_PERCENT:-}" 2>&1; echo "rc=$?" )
}
# seed_new <percent> <mb>: the rendered plist plus the loaded/runs state. The
# plist is also copied to the stub's $HS_STATE/plist-<label>, which is where the
# stub reads the limit from when kickstart asks it to simulate RunAtLoad (a real
# kickstart is given no path either). Seeded without that copy, the job looks
# loaded but the stub cannot apply it, and the row fails on the harness.
seed_new() {
    mss_gpu_render "$1" "$2" > "$HSD/com.mac-studio-server.gpumemory.plist"
    cp "$HSD/com.mac-studio-server.gpumemory.plist" "$HS_STATE/plist-com.mac-studio-server.gpumemory"
    printf 'loaded-com.mac-studio-server.gpumemory\n' > "$HS_STATE/loaded-com.mac-studio-server.gpumemory"
    echo "$2" > "$HS_STATE/live"
}
seed_legacy() { # the legacy job as v1.5.0 installed it, reduced to what is read
    cat > "$HSD/com.ollama.gpumemory.plist" <<LP
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
    <key>Label</key><string>com.ollama.gpumemory</string>
    <key>EnvironmentVariables</key><dict>
        <key>OLLAMA_GPU_PERCENT</key><string>80</string>
    </dict>
</dict></plist>
LP
    printf 'loaded-com.ollama.gpumemory\n' > "$HS_STATE/loaded-com.ollama.gpumemory"
}
rm_gpu() { rm -f "$HSD/com.mac-studio-server.gpumemory.plist" "$HSD/com.ollama.gpumemory.plist" "$HS_STATE"/loaded-com.*gpumemory; }

# (a) identical, loaded, live = MB
rm_gpu; seed_new 80 104857; : > "$HS_STATE/calls.log"
OUT=$(apply_gpu MSS_GPU_PERCENT=80)
check "A10a identical loaded live=MB is unchanged" "GPU memory: 80% (104857 MB), unchanged
rc=0" "$OUT"
grep -Eq 'bootstrap|bootout|kickstart' "$HS_STATE/calls.log" && fail "A10a touched launchctl: $(cat "$HS_STATE/calls.log")" || ok "A10a made no launchctl call"
# (b) identical, loaded, live != MB -> kickstart
seed_new 80 104857; echo 0 > "$HS_STATE/live"; : > "$HS_STATE/calls.log"
OUT=$(apply_gpu MSS_GPU_PERCENT=80)
check "A10b live != MB applies after one kickstart" "GPU memory: 80% (104857 MB), applied
rc=0" "$OUT"
check "A10b exactly one kickstart" 1 "$(grep -c 'kickstart system/com.mac-studio-server.gpumemory' "$HS_STATE/calls.log")"
check "A10b live equals MB now" 104857 "$(cat "$HS_STATE/live")"
# (c) absent -> write, enable, bootstrap
rm_gpu; : > "$HS_STATE/calls.log"
OUT=$(apply_gpu MSS_GPU_PERCENT=80)
check "A10c absent installs and applies" "GPU memory: 80% (104857 MB), applied
rc=0" "$OUT"
cmp -s "$HSD/com.mac-studio-server.gpumemory.plist" "$ROOT/tests/golden/com.mac-studio-server.gpumemory.80.plist" \
    && ok "A10c the plist equals the golden" || fail "A10c plist differs"
check "A10c one enable and one bootstrap" "1 1" \
    "$(grep -c 'enable system/com.mac-studio-server.gpumemory' "$HS_STATE/calls.log") $(grep -c 'bootstrap system' "$HS_STATE/calls.log")"
# (d) legacy seeded -> legacy removal before the new bootstrap
rm_gpu; seed_legacy; : > "$HS_STATE/calls.log"
OUT=$(apply_gpu MSS_GPU_PERCENT=80)
check "A10d legacy migrates" "GPU memory: 80% (104857 MB), applied
rc=0" "$OUT"
_lb=$(grep -n 'bootout system/com.ollama.gpumemory' "$HS_STATE/calls.log" | head -n1 | cut -d: -f1)
_nb=$(grep -n 'bootstrap system' "$HS_STATE/calls.log" | head -n1 | cut -d: -f1)
[ -n "$_lb" ] && [ -n "$_nb" ] && [ "$_lb" -lt "$_nb" ] && ok "A10d the legacy bootout precedes the bootstrap" || fail "A10d order: $(cat "$HS_STATE/calls.log")"
[ ! -e "$HSD/com.ollama.gpumemory.plist" ] && ok "A10d the legacy plist is gone" || fail "A10d legacy plist kept"
check "A10d exactly one GPU plist remains" 1 "$(ls "$HSD" | grep -c gpumemory)"
# (e) stuck -> exit 1 with last exit code, plist kept
rm_gpu; : > "$HS_STATE/calls.log"
export MSS_SYSCTL_MODE=stuck
OUT=$(apply_gpu MSS_GPU_PERCENT=80)
unset MSS_SYSCTL_MODE
RCline=${OUT##*rc=}
check "A10e a stuck sysctl exits 1" 1 "$RCline"
printf '%s' "$OUT" | grep -q 'last exit code' && ok "A10e names the last exit code" || fail "A10e: $OUT"
[ -e "$HSD/com.mac-studio-server.gpumemory.plist" ] && ok "A10e keeps the plist for the next boot" || fail "A10e plist removed"
# (f) system with both -> both removed, no sysctl write
rm_gpu; seed_new 80 104857; seed_legacy; : > "$HS_STATE/calls.log"; echo 104857 > "$HS_STATE/live"
OUT=$(apply_gpu MSS_GPU_PERCENT=system)
check "A10f system removes both jobs" "GPU memory: system default from the next boot
rc=0" "$OUT"
check "A10f both plists are gone" 0 "$(ls "$HSD" | grep -c gpumemory)"
check "A10f system never touches the live value" 0 "$(grep -c 'sysctl iogpu' "$HS_STATE/calls.log")"
# (g) system with none -> no calls, rc 0
rm_gpu; : > "$HS_STATE/calls.log"
OUT=$(apply_gpu MSS_GPU_PERCENT=system)
check "A10g system with nothing installed is a no-op" "GPU memory: system default from the next boot
rc=0" "$OUT"
check "A10g no launchctl call" "" "$(grep -E 'bootout|bootstrap' "$HS_STATE/calls.log" || true)"
# (h) unset with legacy -> no calls + the migrate note
rm_gpu; seed_legacy; : > "$HS_STATE/calls.log"
OUT=$(apply_gpu)
# The migrate note is stderr and the D8 line is stdout; apply_gpu merges them in
# write order, so the note is part of what this row asserts.
check "A10h unset leaves the job and notes the legacy" "com.ollama.gpumemory (80%) is left in place. It runs scripts/set-gpu-memory.sh, a file your user can edit, as root at every boot; set MSS_GPU_PERCENT=80 to migrate it.
GPU memory: left as is
rc=0" "$OUT"
check "A10h no launchctl call" "" "$(grep -E 'bootout|bootstrap|kickstart' "$HS_STATE/calls.log" || true)"
( export MSS_STUB_STATE=$HS_STATE MSS_SYSCTL="$TMP/h27e-bin/sysctl" PATH="$TMP/h27e-bin:$PATH"
  mss_gpu_apply "" 2>"$TMP/h27e/h.err" >/dev/null )
grep -q 'as root at every boot' "$TMP/h27e/h.err" && ok "A10h the note names the root-at-boot risk" || fail "A10h note: $(cat "$TMP/h27e/h.err")"
# (i) unset with nothing -> left as is, no calls
rm_gpu; : > "$HS_STATE/calls.log"
OUT=$(apply_gpu)
check "A10i unset with nothing installed" "GPU memory: left as is
rc=0" "$OUT"
check "A10i no calls" "" "$(cat "$HS_STATE/calls.log")"

echo "== phase A: #27 D5 autostart apply, D10, model.sh pre-check =="
mkdir -p "$TMP/h27f"
# Every helper here addresses the daemon plist by full path under the phase A
# sysroot, and every helper that calls into mss-host.sh re-exports
# MSS_TEST_SYSROOT: the D2 block unset it once, and daemon_dir() falls back to
# the real /Library/LaunchDaemons when it is empty. A row that silently read the
# real path reported "off, unchanged" for a job that was plainly installed.
DA_F="$TMP/sysroot/Library/LaunchDaemons/com.colima.daemon.plist"
da_apply() { # da_apply <env=...>...
    ( export MSS_STUB_STATE=$HS_STATE MSS_LAUNCHD_TIMEOUT=1 MSS_SUDO=$TMP/nosudo/sudo PATH="$TMP/h27e-bin:$PATH"
      export MSS_TEST_SYSROOT=$TMP/sysroot
      while [ "$#" -gt 0 ]; do export "${1?}"; shift; done
      mss_docker_autostart_apply 2>&1; echo "rc=$?" )
}
# seed_daemon / rm_daemon manage the rendered com.colima.daemon plist for the
# A11 rows. Both address $DA_F directly rather than resolving daemon_dir(): a
# helper that called daemon_dir() in the outer scope would pick up whatever
# sysroot an earlier row had left set and touch the wrong file.
seed_daemon() {
    sed "s|<OLLAMA_USER>|$TUSER|g" "$ROOT/config/com.colima.daemon.plist" > "$DA_F"
    printf 'loaded-com.colima.daemon\n' > "$HS_STATE/loaded-com.colima.daemon"
    echo 1 > "$HS_STATE/runs-com.colima.daemon"
}
rm_daemon() {
    rm -f "$DA_F" "$HS_STATE/loaded-com.colima.daemon" "$HS_STATE/runs-com.colima.daemon"
}
# (a) yes, identical and loaded
rm_daemon; seed_daemon; : > "$HS_STATE/calls.log"
OUT=$(da_apply MSS_DOCKER_AUTOSTART=yes USER="$TUSER")
check "A11a identical loaded job is unchanged" "Docker at boot: on, unchanged
rc=0" "$OUT"
grep -Eq 'bootstrap|bootout|kickstart' "$HS_STATE/calls.log" && fail "A11a reloaded the job" || ok "A11a made no launchctl call (constraint 2)"
check "A11a runs unchanged" 1 "$(cat "$HS_STATE/runs-com.colima.daemon")"
# (b) yes and absent
rm_daemon; : > "$HS_STATE/calls.log"
OUT=$(da_apply MSS_DOCKER_AUTOSTART=yes USER="$TUSER")
check "A11b absent installs and starts now if stopped" "Docker at boot: on, changed
rc=0" "$OUT"
check "A11b one enable and one bootstrap" "1 1" \
    "$(grep -c 'enable system/com.colima.daemon' "$HS_STATE/calls.log") $(grep -c 'bootstrap system' "$HS_STATE/calls.log")"
sed "s|<OLLAMA_USER>|$TUSER|g" "$ROOT/config/com.colima.daemon.plist" > "$TMP/h27f/expect-daemon.plist"
cmp -s "$DA_F" "$TMP/h27f/expect-daemon.plist" && ok "A11b the rendered plist is the template with the user" || fail "A11b render differs"
# (c) yes and a different plist: bootout, wait, enable, bootstrap in that order
rm_daemon; printf 'different\n' > "$DA_F"; printf 'loaded-com.colima.daemon\n' > "$HS_STATE/loaded-com.colima.daemon"; : > "$HS_STATE/calls.log"
OUT=$(da_apply MSS_DOCKER_AUTOSTART=yes USER="$TUSER")
check "A11c a changed plist reloads" "Docker at boot: on, changed
rc=0" "$OUT"
# 1 bootout, w the wait (the print polls after it), 2 enable, 3 bootstrap. awk,
# not sed: BSD sed rejects the one-line {…} blocks GNU sed accepts.
_o=$(awk '/bootout system\/com\.colima\.daemon/ { s = 1; printf "1"; next }
    s && /print system\/com\.colima\.daemon/ { if (l != "w") printf "w"; l = "w"; next }
    /enable system\/com\.colima\.daemon/ { printf "2"; l = "" }
    /bootstrap system / { printf "3"; l = "" }' "$HS_STATE/calls.log")
check "A11c bootout, the wait, enable, bootstrap in order" "1w23" "$_o"
# (d) yes, identical but not loaded
rm_daemon; seed_daemon; rm -f "$HS_STATE/loaded-com.colima.daemon"; : > "$HS_STATE/calls.log"
OUT=$(da_apply MSS_DOCKER_AUTOSTART=yes USER="$TUSER")
check "A11d identical but unloaded bootstraps" "Docker at boot: on, changed
rc=0" "$OUT"
check "A11d no bootout" "" "$(grep bootout "$HS_STATE/calls.log" || true)"
# (e) no and present: the job is installed, so `no` removes it, and colima is
# never called. seed_daemon first — "present" has to be true before apply runs.
rm_daemon; seed_daemon; : > "$TMP/h27f/colima.log"
OUT=$( (export MSS_STUB_STATE=$HS_STATE MSS_SUDO=$TMP/nosudo/sudo PATH="$TMP/h27e-bin:$PATH" MSS_STUB_LOG="$TMP/h27f/colima.log" MSS_TEST_SYSROOT=$TMP/sysroot; MSS_DOCKER_AUTOSTART=no mss_docker_autostart_apply 2>&1; echo "rc=$?") )
check "A11e no removes the job" "Docker at boot: off, changed
rc=0" "$OUT"
[ ! -e "$DA_F" ] && ok "A11e the plist is gone" || fail "A11e plist kept"
check "A11e colima was never run (constraint 1)" "" "$(cat "$TMP/h27f/colima.log")"
# (f) no and absent
rm_daemon; : > "$HS_STATE/calls.log"
OUT=$(da_apply MSS_DOCKER_AUTOSTART=no USER="$TUSER")
check "A11f no with nothing installed" "Docker at boot: off, unchanged
rc=0" "$OUT"
check "A11f no calls" "" "$(cat "$HS_STATE/calls.log")"
# (g) unset
: > "$HS_STATE/calls.log"
OUT=$(da_apply USER="$TUSER")
check "A11g unset leaves the job as it is" "Docker at boot: left as is
rc=0" "$OUT"
check "A11g no calls" "" "$(cat "$HS_STATE/calls.log")"

# D7 step 6: brew installs only the missing tools, never upgrade (#27)
H27G="$TMP/h27g"; mkdir -p "$H27G/tools" "$H27G/jobin"
cp "$ROOT/tests/stubs/colima" "$ROOT/tests/stubs/docker" "$H27G/jobin/"
cp "$ROOT/tests/stubs/brew" "$H27G/tools/"   # the "present" run has a brew too
docker_install_case() { # docker_install_case <tools-present...>: brew calls
    _have=$1; : > "$H27G/log"
    rm -f "$H27G/tools"/* "$H27G/jobin"/*
    cp "$ROOT/tests/stubs/brew" "$H27G/tools/"
    for _t in $_have; do printf '#!/bin/sh\nexit 0\n' > "$H27G/jobin/$_t"; chmod +x "$H27G/jobin/$_t"; done
    ( export MSS_STUB_LOG="$H27G/log" MSS_STUB_BREW_PREFIX="$H27G/prefix"
      MSS_DOCKER_JOB_PATH="$H27G/jobin" PATH="$H27G/tools:$PATH"
      MSS_DOCKER_INSTALL=yes mss_choices_validate || echo "validate-failed"
      mss_acquire_docker_brew ) > /dev/null 2>&1
    grep '^brew ' "$H27G/log" | sed 's/^brew //' | tr '\n' '|'
}
check "A7 both present: brew is never called" "" "$(docker_install_case 'colima docker')"
check "A7 both missing: one install of both" "install colima docker|" "$(docker_install_case '')"
check "A7 colima missing: only colima" "install colima|" "$(docker_install_case docker)"
check "A7 docker missing: only docker" "install docker|" "$(docker_install_case colima)"
grep -E 'upgrade|reinstall|uninstall' "$H27G/log" >/dev/null && fail "A7 brew was asked to upgrade/reinstall" || ok "A7 never upgrade/reinstall/uninstall"

# A7b: the picker's Docker skip. _mss_docker_outside_job_path returns 0 when a
# tool exists that the boot job cannot reach and 1 when every Docker choice is
# appliable. Read the wrong way round it dropped DI and DA on every ordinary Mac
# (#27 r3), so both branches are asserted here, not by grepping the source.
docker_skip_case() { # docker_skip_case <caller-tools>|<job-tools>: "rc" then the keys
    _have=$1
    rm -f "$H27G/tools"/* "$H27G/jobin"/*
    # <caller-tools> go on the caller's PATH only, <job-tools> on the boot job's
    # PATH. A tool the caller can run that the job cannot is the conflict that
    # skips both questions; with every tool on the job PATH nothing is skipped.
    # Nothing is put on the caller's PATH in the second case, so the two states
    # are distinguishable: one skips, the other asks.
    _outside=${_have%%|*}; _inj=${_have#*|}
    for _t in $_inj; do
        printf '#!/bin/sh\nexit 0\n' > "$H27G/jobin/$_t"; chmod +x "$H27G/jobin/$_t"
        printf '#!/bin/sh\nexit 0\n' > "$H27G/tools/$_t"; chmod +x "$H27G/tools/$_t"
    done
    for _t in $_outside; do
        [ -f "$H27G/tools/$_t" ] && continue
        printf '#!/bin/sh\nexit 0\n' > "$H27G/tools/$_t"; chmod +x "$H27G/tools/$_t"
    done
    ( export MSS_DOCKER_JOB_PATH="$H27G/jobin" PATH="$H27G/tools:$PATH"
      unset MSS_DOCKER_INSTALL MSS_DOCKER_AUTOSTART
      . "$ROOT/scripts/lib/mss-common.sh"; . "$ROOT/scripts/lib/mss-acquire.sh"
      . "$ROOT/scripts/lib/mss-run.sh"; . "$ROOT/scripts/lib/mss-host.sh"
      . "$ROOT/scripts/lib/mss-picker.sh"
      # mss_ask_yn stands in for the terminal: every question is answered yes.
      mss_ask_yn() { MSS_ANSWER=y; return 0; }
      mss_ask() { MSS_ANSWER="$2"; return 0; }
      _mss_pick_docker_install 2>"$H27G/skip.err"; echo "rc=$?"
      printf 'DI=%s DA=%s\n' "${MSS_DOCKER_INSTALL:-unset}" "${MSS_DOCKER_AUTOSTART:-unset}" )
}
# colima is reachable by the caller but not the job: skip both questions.
OUT=$(docker_skip_case "colima|docker")
printf '%s' "$OUT" | grep -q 'rc=1' \
    && ok "A7b the skip returns 1 so DA is not asked either" \
    || fail "A7b skip rc: $OUT"
check "A7b the skip names the tool and its path (D1)" \
    "colima is at $H27G/tools/colima, outside the boot job's PATH; move or link it into /opt/homebrew/bin or /usr/local/bin" \
    "$(cat "$H27G/skip.err")"
check "A7b the skip leaves both keys unset" "DI=unset DA=unset" "$(printf '%s\n' "$OUT" | tail -n 1)"
# Both tools are on the job PATH: nothing is skipped and DI is asked.
OUT=$(docker_skip_case "|colima docker")
grep -q "outside the boot job's PATH" "$H27G/skip.err" \
    && fail "A7b skipped on an ordinary Mac" || ok "A7b an ordinary Mac is not skipped"
# Nothing is missing here, so DI prints its own line and sets nothing — the
# point of the row is that the skip did not fire and DI ran to its end.
check "A7b the ordinary path reports both tools installed" \
    "Colima and the Docker CLI are installed" "$(cat "$H27G/skip.err")"
check "A7b the ordinary path returns 0" "0" "$(printf '%s\n' "$OUT" | grep -o 'rc=[0-9]*' | cut -d= -f2)"

echo "== phase A: #27 D10 mss_gpu_jobs_remove =="
rm_gpu; seed_new 80 104857; seed_legacy; : > "$HS_STATE/calls.log"
( export MSS_STUB_STATE=$HS_STATE MSS_SUDO=$TMP/nosudo/sudo PATH="$TMP/h27e-bin:$PATH" MSS_TEST_SYSROOT=$TMP/sysroot; mss_gpu_jobs_remove ) && _rc=0 || _rc=1
check "A14a both GPU jobs are removed" 0 "$_rc"
check "A14a one bootout per label" "1 1" \
    "$(grep -c 'bootout system/com.mac-studio-server.gpumemory' "$HS_STATE/calls.log") $(grep -c 'bootout system/com.ollama.gpumemory' "$HS_STATE/calls.log")"
check "A14a both plists are gone" 0 "$(ls "$HSD" | grep -c gpumemory)"
: > "$HS_STATE/calls.log"
( export MSS_STUB_STATE=$HS_STATE MSS_SUDO=$TMP/nosudo/sudo PATH="$TMP/h27e-bin:$PATH" MSS_TEST_SYSROOT=$TMP/sysroot; mss_gpu_jobs_remove ) && _rc=0 || _rc=1
check "A14b removing nothing makes no launchctl call" 0 "$_rc"
check "A14b calls.log stays empty" "" "$(cat "$HS_STATE/calls.log")"

echo "== phase A: #27 D4b model.sh GPU pre-check =="
# precheck_case <MSS_GPU_PERCENT>: "rc=N" plus the message. mss_error writes to
# stderr, so the 2>&1 is what makes the wording assertable. MSS_TEST_SYSROOT is
# re-exported because the rows below unset it once in the D2 block, and the
# pre-check resolves plists through daemon_dir().
precheck_case() {
    ( export MSS_STUB_STATE=$HS_STATE MSS_SUDO=$TMP/nosudo/sudo PATH="$TMP/h27e-bin:$PATH"
      export MSS_TEST_SYSROOT=$TMP/sysroot
      MSS_GPU_PERCENT="$1" mss_gpu_job_precheck 2>&1; echo "rc=$?" )
}
rm_gpu; seed_new 80 104857
check "precheck: matching job passes" "rc=0" "$(precheck_case 80)"
# A job that records 80 while backends.env asks for 85: seeding the same value
# the row asks for would make the pre-check pass, and the row would assert a
# mismatch that never existed.
rm_gpu; mss_gpu_render 80 104857 > "$HSD/com.mac-studio-server.gpumemory.plist"
printf 'loaded-com.mac-studio-server.gpumemory\n' > "$HS_STATE/loaded-com.mac-studio-server.gpumemory"
OUT=$(precheck_case 85)
printf '%s' "$OUT" | grep -q 'the boot job applies 80; run scripts/install.sh first' \
    && check "precheck: a differing job exits 1" 1 "${OUT##*rc=}" || fail "precheck mismatch: $OUT"
rm_gpu; seed_legacy
OUT=$(precheck_case 80)
printf '%s' "$OUT" | grep -q 'still com.ollama.gpumemory; run scripts/install.sh first to migrate it' \
    && check "precheck: legacy only exits 1" 1 "${OUT##*rc=}" || fail "precheck legacy: $OUT"
rm_gpu
OUT=$(precheck_case 80)
printf '%s' "$OUT" | grep -q 'needs com.mac-studio-server.gpumemory; run scripts/install.sh first' \
    && check "precheck: no job exits 1" 1 "${OUT##*rc=}" || fail "precheck none: $OUT"
check "precheck: system runs no pre-check" "rc=0" "$(precheck_case system)"
check "precheck: unset runs no pre-check" "rc=0" "$(precheck_case '')"
rm_gpu; printf 'garbage\n' > "$HSD/com.mac-studio-server.gpumemory.plist"
OUT=$(precheck_case 80)
printf '%s' "$OUT" | grep -q 'cannot read com.mac-studio-server.gpumemory; run scripts/install.sh' \
    && check "precheck: an unreadable plist exits 1" 1 "${OUT##*rc=}" || fail "precheck unreadable: $OUT"
rm_gpu

echo "== phase A: #27 A12 D8 variants, A13 D9 exit codes, A14/A15 pins =="
# A12: every D8 variant string must be produced by at least one scenario in this
# file. The variants are listed here and matched exactly, so a variant that no
# row reaches is a failure rather than a silent gap.
# GPU (D4 apply + D3 summary share the classifier, so both wordings are checked).
gpu_line() { # gpu_line <percent> <env...>: the D8 line
    ( export MSS_STUB_STATE=$HS_STATE MSS_SYSCTL="$TMP/h27e-bin/sysctl" \
          MSS_LAUNCHD_TIMEOUT=1 MSS_SUDO=$TMP/nosudo/sudo PATH="$TMP/h27e-bin:$PATH" \
          MSS_TEST_SYSROOT=$TMP/sysroot
      while [ "$#" -gt 0 ]; do export "${1?}"; shift; done
      mss_gpu_apply "${MSS_GPU_PERCENT:-}" 2>/dev/null )
}
rm_gpu; seed_new 80 104857; echo 104857 > "$HS_STATE/live"
check "A12 gpu unchanged line" "GPU memory: 80% (104857 MB), unchanged" "$(gpu_line MSS_GPU_PERCENT=80)"
rm_gpu; seed_new 80 104857; echo 0 > "$HS_STATE/live"
check "A12 gpu applied line" "GPU memory: 80% (104857 MB), applied" "$(gpu_line MSS_GPU_PERCENT=80)"
rm_gpu; seed_new 80 104857
check "A12 gpu system-default line" "GPU memory: system default from the next boot" "$(gpu_line MSS_GPU_PERCENT=system)"
rm_gpu
check "A12 gpu left-as-is line" "GPU memory: left as is" "$(gpu_line)"
rm_gpu
# Power (D6): every variant, each on its own state directory. power_case emits
# the D8 line and then an rc line, so the first line is the variant.
check "A12 power on, changed" "Restart after power failure: on, changed" \
    "$(power_case pmset-autorestart-0 MSS_POWER_AUTORESTART=yes | head -n 1)"
check "A12 power on, unchanged" "Restart after power failure: on, unchanged" \
    "$(power_case pmset-autorestart-1 MSS_POWER_AUTORESTART=yes | head -n 1)"
check "A12 power off, changed" "Restart after power failure: off, changed" \
    "$(power_case pmset-autorestart-1 MSS_POWER_AUTORESTART=no | head -n 1)"
check "A12 power left as is (off)" "Restart after power failure: left as is (off)" \
    "$(power_case pmset-autorestart-0 | head -n 1)"
check "A12 power left as is (on)" "Restart after power failure: left as is (on)" \
    "$(power_case pmset-autorestart-1 | head -n 1)"
check "A12 power left as is (unsupported)" "Restart after power failure: left as is (unsupported)" \
    "$(power_case pmset-none | head -n 1)"

# Docker install (D5) and Docker at boot (D5): the four install variants and the
# five autostart variants come from the classifier, asserted directly.
dk_line() { # dk_line <install-answer> <seed...>: the D8 install line. <seed>
    # tools are placed on the boot job's PATH before the call, so "already
    # installed" is a seeded state and "installed colima docker" is the run that
    # found nothing there.
    _ans=$1; shift
    rm -f "$H27G/jobin"/*
    for _t in "$@"; do printf '#!/bin/sh\nexit 0\n' > "$H27G/jobin/$_t"; chmod +x "$H27G/jobin/$_t"; done
    cp "$ROOT/tests/stubs/brew" "$H27G/tools/brew"; chmod +x "$H27G/tools/brew"
    : > "$H27G/log"
    ( export MSS_STUB_LOG="$H27G/log" MSS_STUB_BREW_PREFIX="$H27G/prefix" \
          MSS_STUB_STATE=$HS_STATE MSS_SUDO=$TMP/nosudo/sudo \
          MSS_DOCKER_INSTALL=$_ans MSS_DOCKER_JOB_PATH="$H27G/jobin" \
          PATH="$H27G/tools:$TMP/h27e-bin:$PATH"
      mss_docker_install_apply )
}
rm -f "$H27G/tools"/*
check "A12 docker install not requested" "Docker install: not requested" "$(dk_line '' )"
check "A12 docker install installed both" "Docker install: installed colima docker" \
    "$(dk_line yes)"
check "A12 docker install installed colima only" "Docker install: installed colima" \
    "$(dk_line yes docker)"
check "A12 docker install already installed" "Docker install: already installed" \
    "$(dk_line yes colima docker)"
da_line() { # da_line <env...>: the autostart line
    ( export MSS_STUB_STATE=$HS_STATE MSS_SUDO=$TMP/nosudo/sudo PATH="$TMP/h27e-bin:$PATH" \
          MSS_TEST_SYSROOT=$TMP/sysroot
      while [ "$#" -gt 0 ]; do export "${1?}"; shift; done
      mss_docker_autostart_apply )
}
check "A12 docker at boot left as is" "Docker at boot: left as is" "$(da_line MSS_DOCKER_AUTOSTART=)"
rm_daemon; seed_daemon
check "A12 docker at boot on, unchanged" "Docker at boot: on, unchanged" "$(da_line MSS_DOCKER_AUTOSTART=yes)"
rm_daemon; printf 'different\n' > "$DA_F"
check "A12 docker at boot on, changed" "Docker at boot: on, changed" "$(da_line MSS_DOCKER_AUTOSTART=yes)"
rm_daemon
check "A12 docker at boot off, unchanged" "Docker at boot: off, unchanged" "$(da_line MSS_DOCKER_AUTOSTART=no)"
rm_daemon; printf 'different\n' > "$DA_F"; printf 'loaded-com.colima.daemon\n' > "$HS_STATE/loaded-com.colima.daemon"
check "A12 docker at boot off, changed" "Docker at boot: off, changed" "$(da_line MSS_DOCKER_AUTOSTART=no)"
rm_daemon

# A13: the D9 exit code, pinned on every runner. The Ollama service is stubbed
# healthy (launchctl-state marks it loaded, a curl stub answers 200), so the only
# thing that changes between rows is the GPU state, and the code is asserted.
mkdir -p "$TMP/h27a" "$TMP/h27s-bin"
printf 'MSS_BACKENDS=ollama\n' > "$TMP/h27a/ollama.conf"
printf '#!/bin/sh\nprintf 200\n' > "$TMP/h27s-bin/curl"; chmod +x "$TMP/h27s-bin/curl"
status_run() { # status_run [env=...]: status.sh output, then rc=N
    ( export MSS_TEST_SYSROOT=$TMP/sysroot MSS_STUB_STATE=$HS_STATE \
          MSS_SYSCTL="$TMP/h27e-bin/sysctl" MSS_PMSET="$ROOT/tests/stubs/pmset-autorestart-0" \
          PATH="$TMP/h27s-bin:$TMP/h27e-bin:$PATH" MSS_CONF="$TMP/h27a/ollama.conf"
      while [ "$#" -gt 0 ]; do export "${1?}"; shift; done
      sh "$ROOT/scripts/status.sh" 2>&1; echo "rc=$?" )
}
status_rc() { _sr=$(status_run "$@"); echo "${_sr##*rc=}"; }
status_gpu_line() { status_run "$@" | grep 'gpu memory' || true; }
: > "$HS_STATE/loaded-com.ollama.service"
rm_gpu; seed_new 80 104857; echo 104857 > "$HS_STATE/live"
check "A13 live = MB exits 0" 0 "$(status_rc)"
printf '%s' "$(status_gpu_line)" | grep -q '80% (104857 MB), live 104857 MB' \
    && ok "A13 live = MB is healthy" || fail "A13 healthy: $(status_gpu_line)"
rm_gpu; seed_new 80 104857; echo 0 > "$HS_STATE/live"
check "A13 live != MB exits 1" 1 "$(status_rc)"
printf '%s' "$(status_gpu_line)" | grep -q 'wants 104857 MB, live 0 MB' \
    && ok "A13 live != MB is unhealthy" || fail "A13 live: $(status_gpu_line)"
rm_gpu; seed_new 80 104857; seed_legacy
check "A13 both labels exit 1" 1 "$(status_rc)"
printf '%s' "$(status_gpu_line)" | grep -q 'both GPU boot jobs installed' \
    && ok "A13 both labels are unhealthy" || fail "A13 both: $(status_gpu_line)"
rm_gpu; printf 'garbage\n' > "$HSD/com.mac-studio-server.gpumemory.plist"
check "A13 an unreadable plist exits 1" 1 "$(status_rc)"
printf '%s' "$(status_gpu_line)" | grep -q 'is unreadable' \
    && ok "A13 an unreadable plist is unhealthy" || fail "A13 unreadable: $(status_gpu_line)"
# A recorded percent that is not 1-100 never reaches the arithmetic.
for bad in 8O 080 101; do
    rm_gpu; mss_gpu_render "$bad" 104857 > "$HSD/com.mac-studio-server.gpumemory.plist"
    check "A13 a recorded percent of $bad is unreadable and exits 1" "1 unreadable" \
        "$(status_rc) $(status_gpu_line | grep -q 'is unreadable' && echo unreadable || status_gpu_line)"
done
rm_gpu; seed_legacy; echo 0 > "$HS_STATE/live"
check "A13 legacy alone exits 0" 0 "$(status_rc)"
status_run | grep -q 'com.ollama.gpumemory runs a user-editable script as root at boot; re-run install.sh with MSS_GPU_PERCENT to migrate' \
    && ok "A13 legacy alone prints the migrate note" || fail "A13 legacy: $(status_run)"
rm_gpu
check "A13 no job exits 0" 0 "$(status_rc)"
printf '%s' "$(status_gpu_line)" | grep -q 'system default' \
    && ok "A13 no job prints system default" || fail "A13 none: $(status_gpu_line)"
# Docker and power never change the code: no Colima job and no power setting.
rm_daemon
check "A13 Docker off with pmset-none keeps exit 0" 0 "$(status_rc MSS_PMSET="$ROOT/tests/stubs/pmset-none")"
rm_gpu; seed_new 80 104857; echo 0 > "$HS_STATE/live"
check "A13 Docker off with pmset-none keeps exit 1" 1 "$(status_rc MSS_PMSET="$ROOT/tests/stubs/pmset-none")"
rm_gpu; rm -f "$HS_STATE/loaded-com.ollama.service"

# A14 static check: uninstall.sh --all must call mss_gpu_jobs_remove and must
# never touch the Colima boot job.
grep -A40 '^    all)' "$ROOT/scripts/uninstall.sh" | grep -q 'mss_gpu_jobs_remove' \
    && ok "A14 the all) branch calls mss_gpu_jobs_remove" \
    || fail "A14: $(grep -n 'mss_gpu_jobs_remove' "$ROOT/scripts/uninstall.sh")"
grep -q 'com.colima.daemon' "$ROOT/scripts/uninstall.sh" \
    && fail "A14 uninstall.sh touches com.colima.daemon" || ok "A14 uninstall.sh never names com.colima.daemon"
# A15 new pin: install.sh must not use the legacy load/unload verbs for the two
# new boot jobs. The com.ollama.service lines stay and are out of scope.
BADLOAD=$(grep -nE 'launchctl +(load|unload)' "$ROOT/scripts/install.sh" \
    | grep -E 'gpumemory|com\.colima\.daemon' || true)
[ -z "$BADLOAD" ] && ok "A15 install.sh has no load/unload for the new jobs" || fail "A15: $BADLOAD"

echo "== phase A: #27 A16 model.sh order =="
# model.sh must resolve and validate before any download or save, and the save
# must migrate the legacy key. Each row runs the real script with --path and a
# fixture sha, so the order is proved by what it writes, not by reading it.
mkdir -p "$TMP/h27m" "$TMP/h27m/sysroot/Library/LaunchDaemons"
# model.sh reads the env file's owner and mode with BSD `stat -f`.
mkdir -p "$TMP/h27r/bin-bsd"; cp "$ROOT/tests/stubs/stat-bsd" "$TMP/h27r/bin-bsd/stat"
chmod +x "$TMP/h27r/bin-bsd/stat"
MSD="$TMP/h27m/sysroot/Library/LaunchDaemons"
MSTATE=$TMP/h27m/state; mkdir -p "$MSTATE"
# model.sh refuses to run without a terminal, so each row drives it on a pty
# with no prompts expected: every row below must fail before it asks anything.
model_case() { # model_case <env-file> [env=...]: script output, rc, file body
    _ef=$1; shift
    : > "$TMP/h27m/steps"
    env MSS_TEST_SYSROOT=$TMP/h27m/sysroot MSS_STUB_STATE=$MSTATE \
        MSS_SYSCTL="$TMP/h27e-bin/sysctl" MSS_SUDO=$TMP/nosudo/sudo \
        PATH="$TMP/h27r/bin-bsd:$TMP/h27e-bin:$PATH" MSS_ENV_FILE="$_ef" \
        MSS_IFCONFIG="$ROOT/tests/stubs/ifconfig-lan" "$@" \
        expect "$ROOT/tests/expect/drive.exp" "$TMP/h27m/steps" "$TMP/h27m/transcript" \
        /bin/sh "$ROOT/scripts/model.sh" --path "$TMP/fix/llamacpp/model.gguf" \
        --sha256 "$(cat "$TMP/fix/llamacpp/model.sha")" >/dev/null 2>&1
    echo "rc=$?"
    cat "$TMP/h27m/transcript"
    printf 'BODY:%s\n' "$(grep -v '^#' "$_ef" 2>/dev/null | tr '\n' ' ')"
}
# (a) legacy key in the file, new key in the environment: a conflict, and the
# file is untouched.
printf 'MSS_BACKENDS=llamacpp\nOLLAMA_GPU_PERCENT=80\n' > "$TMP/h27m/a.env"; chmod 600 "$TMP/h27m/a.env"
SHA_A=$(mss_shasum256 "$TMP/h27m/a.env" | awk '{print $1}')
OUT=$(model_case "$TMP/h27m/a.env" MSS_GPU_PERCENT=85)
printf '%s' "$OUT" | grep -q 'differ; keep one' \
    && ok "A16a a conflict exits 1 with the conflict line" || fail "A16a: $OUT"
printf '%s' "$OUT" | grep -q 'Saved' && fail "A16a saved before validating" || ok "A16a nothing was saved"
SHA_A2=$(mss_shasum256 "$TMP/h27m/a.env" | awk '{print $1}')
check "A16a the file is unchanged" "$SHA_A" "$SHA_A2"
# (b) legacy key, legacy plist only: the migrate line, before any save.
printf 'MSS_BACKENDS=llamacpp\nOLLAMA_GPU_PERCENT=80\n' > "$TMP/h27m/b.env"; chmod 600 "$TMP/h27m/b.env"
rm -f "$MSD"/*.plist
cat > "$MSD/com.ollama.gpumemory.plist" <<'LPM'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.ollama.gpumemory</string>
<key>EnvironmentVariables</key><dict><key>OLLAMA_GPU_PERCENT</key><string>80</string></dict>
</dict></plist>
LPM
printf 'loaded-com.ollama.gpumemory\n' > "$MSTATE/loaded-com.ollama.gpumemory"
OUT=$(model_case "$TMP/h27m/b.env")
printf '%s' "$OUT" | grep -q 'still com.ollama.gpumemory; run scripts/install.sh first to migrate it' \
    && ok "A16b a legacy job stops model.sh" || fail "A16b: $OUT"
printf '%s' "$OUT" | grep -q 'Saved' && fail "A16b saved over a legacy job" || ok "A16b nothing was saved"
# (c) legacy key, new plist recording 80: saves, and migrates the key.
printf 'MSS_BACKENDS=llamacpp\nOLLAMA_GPU_PERCENT=80\n' > "$TMP/h27m/c.env"; chmod 600 "$TMP/h27m/c.env"
rm -f "$MSD"/*.plist "$MSTATE"/loaded-com.*gpumemory
sed "s|<GPU_PERCENT>|80|;s|<WIRED_LIMIT_MB>|104857|" "$ROOT/config/com.mac-studio-server.gpumemory.plist" > "$MSD/com.mac-studio-server.gpumemory.plist"
printf 'loaded-com.mac-studio-server.gpumemory\n' > "$MSTATE/loaded-com.mac-studio-server.gpumemory"
OUT=$(model_case "$TMP/h27m/c.env")
printf '%s' "$OUT" | grep -q 'Saved' \
    && ok "A16c a matching job lets model.sh save" || fail "A16c: $OUT"
printf '%s' "$OUT" | grep -q 'BODY:.*MSS_GPU_PERCENT=80' \
    && ok "A16c the save writes the new key" || fail "A16c body: $OUT"
printf '%s' "$OUT" | grep -q 'OLLAMA_GPU_PERCENT=80' \
    && fail "A16c the save kept the legacy key" || ok "A16c the legacy key is dropped by the save"
# (d) new plist recording 80, file asking 85: the mismatch line, file unchanged.
printf 'MSS_BACKENDS=llamacpp\nMSS_GPU_PERCENT=85\n' > "$TMP/h27m/d.env"; chmod 600 "$TMP/h27m/d.env"
SHA_D=$(mss_shasum256 "$TMP/h27m/d.env" | awk '{print $1}')
OUT=$(model_case "$TMP/h27m/d.env")
printf '%s' "$OUT" | grep -q 'the boot job applies 80; run scripts/install.sh first' \
    && ok "A16d a differing job stops model.sh" || fail "A16d: $OUT"
SHA_D2=$(mss_shasum256 "$TMP/h27m/d.env" | awk '{print $1}')
check "A16d the file is unchanged" "$SHA_D" "$SHA_D2"

echo "== phase A: #27 r2 entry points (install.sh, install-backends.sh, status.sh) =="
# Every row above exercises a library function through a stub. Findings 1 to 5
# of round 2 all passed that suite, because nothing ran the scripts that call
# these functions. These rows run the real entry points: install.sh end to end
# against a sysroot, and install-backends.sh's render pass.
mkdir -p "$TMP/h27r" "$TMP/h27r-bin"
cp "$ROOT/tests/stubs/launchctl-state" "$TMP/h27r-bin/launchctl"
cp "$ROOT/tests/stubs/sysctl-state" "$TMP/h27r-bin/sysctl"
cp "$ROOT/tests/stubs/plutil" "$TMP/h27r-bin/plutil"
cp "$ROOT/tests/stubs/stat-bsd" "$TMP/h27r-bin/stat"
cp "$ROOT/tests/stubs/sudo-fail" "$TMP/h27r-bin/sudo-fail"
chmod +x "$TMP/h27r-bin/"*
HR_STATE=$TMP/h27r/state
mkdir -p "$HR_STATE" "$TMP/h27r/sysroot/Library/LaunchDaemons"
HSD_R="$TMP/h27r/sysroot/Library/LaunchDaemons"

# install_case <log> [env=...]: run install.sh in env mode against a sysroot,
# with the phase A stubs first on PATH. Ollama is not selected, so the install
# reaches the D7 apply steps without touching the real service.
install_case() {
    _log=$1; shift
    : > "$_log"; : > "$HR_STATE/calls.log"
    ( export MSS_TEST_SYSROOT=$TMP/h27r/sysroot MSS_STUB_STATE=$HR_STATE \
          MSS_LAUNCHD_TIMEOUT=1 MSS_SUDO=$TMP/nosudo/sudo \
          MSS_SYSCTL="$TMP/h27r-bin/sysctl" PATH="$TMP/h27r-bin:$PATH" \
          OLLAMA_BASE_DIR="$TMP/h27r/base" HOME="$TMP/h27r/home" \
          MSS_INSTALL_SANDBOX=1
      mkdir -p "$TMP/h27r/home"
      while [ "$#" -gt 0 ]; do export "${1?}"; shift; done
      sh "$ROOT/scripts/install.sh" ) >"$_log" 2>&1
    echo "rc=$?" >> "$_log"
}

# E1: a failing privileged apply step must stop install.sh. Before the fix the
# step was piped into `tee`, so `|| exit 1` tested tee and the install reported
# success with the job not installed.
rm -f "$HSD_R/"*.plist
install_case "$TMP/h27r/e1.log" MSS_BACKENDS=ollama MSS_GPU_PERCENT=80 \
    MSS_TUNE_MACOS=no MSS_SUDO=$TMP/h27r-bin/sudo-fail
RCline=${RCline:=}
_rc=$(tail -n 1 "$TMP/h27r/e1.log"); _rc=${_rc#rc=}
check "E1 a failing apply step exits non-zero" 1 "$_rc"
grep -q 'Installation completed' "$TMP/h27r/e1.log" \
    && fail "E1 a failed GPU step still reported success" || ok "E1 no 'Installation completed' after a failure"
grep -q 'mss_gpu_apply failed' "$TMP/h27r/e1.log" \
    && ok "E1 the failure names the step" || fail "E1 log: $(tail -5 "$TMP/h27r/e1.log")"

# E2: a successful ollama install reaches the report line and installs the job.
# MSS_INSTALL_SANDBOX redirects the handful of absolute writes in the Ollama
# service block into the phase A sysroot, so install.sh runs end to end here.
rm -f "$HSD_R/"*.plist; echo 0 > "$HR_STATE/live"
install_case "$TMP/h27r/e2.log" MSS_BACKENDS=ollama MSS_GPU_PERCENT=80 \
    MSS_TUNE_MACOS=no
check "E2 an ollama install exits 0" "rc=0" "$(tail -n 1 "$TMP/h27r/e2.log")"
[ -f "$HSD_R/com.mac-studio-server.gpumemory.plist" ] \
    && ok "E2 the GPU job is installed" || fail "E2 no GPU plist: $(cat "$TMP/h27r/e2.log")"
grep -q 'GPU memory: 80% (104857 MB), applied' "$TMP/h27r/e2.log" \
    && ok "E2 the D8 line is reported" || fail "E2 log: $(grep -i 'gpu memory' "$TMP/h27r/e2.log")"
grep -q 'Installation completed' "$TMP/h27r/e2.log" && ok "E2 the install completes" || fail "E2 no completion"

# E3: the plist is rendered outside the daemon dir, then moved in. Creating the
# temp file inside /Library/LaunchDaemons fails for the unprivileged user that
# runs install.sh on a real Mac.
grep -q 'cannot create a temporary plist' "$TMP/h27r/e2.log" \
    && fail "E3 rendered inside the daemon dir" || ok "E3 no in-dir temp file needed"
check "E3 the daemon dir holds no leftover temp file" 0 "$(ls "$HSD_R" | grep -c '\.tmp\|^\.' || true)"

# E9: outside a test sysroot a failed chown stops the step and installs nothing;
# inside one it is best-effort. The sudo stub fails chown only.
mkdir -p "$TMP/h27o"
printf '#!/bin/sh\n[ "$1" = chown ] && exit 1\nexec "$@"\n' > "$TMP/h27o/sudo"; chmod +x "$TMP/h27o/sudo"
printf x > "$TMP/h27o/src"
( unset MSS_TEST_SYSROOT; MSS_SUDO=$TMP/h27o/sudo; export MSS_SUDO
  _mss_install_plist "$TMP/h27o/src" "$TMP/h27o/dest" ) 2>/dev/null; RC=$?
check "E9 a failed chown on a real Mac stops the install" "1 absent" "$RC $([ -e "$TMP/h27o/dest" ] && echo present || echo absent)"
printf x > "$TMP/h27o/src2"
( MSS_TEST_SYSROOT=$TMP/sysroot; MSS_SUDO=$TMP/h27o/sudo; export MSS_TEST_SYSROOT MSS_SUDO
  _mss_install_plist "$TMP/h27o/src2" "$TMP/h27o/dest2" ) 2>/dev/null; RC=$?
check "E9 inside a test sysroot the chown is best-effort" "0 present" "$RC $([ -e "$TMP/h27o/dest2" ] && echo present || echo absent)"

# E10 (A2): loaded mode reads backends.env, applies it and never writes it. The
# run is install.sh on a pty with a saved file and no flag, end to end in the
# sandbox, and it must apply the saved GPU value.
printf 'MSS_BACKENDS=ollama\nMSS_TUNE_MACOS=no\nMSS_GPU_PERCENT=80\n' > "$TMP/h27r/loaded.env"; chmod 600 "$TMP/h27r/loaded.env"
SHA_L1=$(mss_shasum256 "$TMP/h27r/loaded.env" | awk '{print $1}')
rm -f "$HSD_R/"*.plist; echo 0 > "$HR_STATE/live"; : > "$HR_STATE/calls.log"
( export MSS_TEST_SYSROOT=$TMP/h27r/sysroot MSS_STUB_STATE=$HR_STATE MSS_LAUNCHD_TIMEOUT=1 MSS_SUDO=$TMP/nosudo/sudo \
      MSS_SYSCTL="$TMP/h27r-bin/sysctl" PATH="$TMP/nosudo:$TMP/h27r-bin:$PATH" MSS_INSTALL_SANDBOX=1 \
      OLLAMA_BASE_DIR="$TMP/h27r/base" HOME="$TMP/h27r/home" MSS_ENV_FILE="$TMP/h27r/loaded.env" \
      OLLAMA_USER="$(id -un)" MSS_CONF="$TMP/h27r/none.conf"
  unset MSS_BACKENDS
  expect "$ROOT/tests/expect/drive.exp" /dev/null "$TMP/h27r/e10.transcript" /bin/bash "$ROOT/scripts/install.sh" ) \
    >/dev/null 2>"$TMP/h27r/e10.err"
check "E10 loaded mode on a pty exits 0" 0 $?
tr -d '\r' < "$TMP/h27r/e10.transcript" | grep -q 'GPU memory: 80% (104857 MB), applied' \
    && ok "E10 loaded mode applied the saved GPU value" || fail "E10: $(tr -d '\r' < "$TMP/h27r/e10.transcript" | tail -5)"
check "E10 loaded mode leaves the file's shasum unchanged" "$SHA_L1" "$(mss_shasum256 "$TMP/h27r/loaded.env" | awk '{print $1}')"
rm -f "$HSD_R/"*.plist

# E11 (manual step 2 at a44b988): with OLLAMA_BIN unset, the plist gets the
# Ollama already installed, in the picker's order: /usr/local/bin, then PATH,
# then Homebrew's Apple silicon prefix. The PATH drops every directory holding
# a real ollama, so the runner's own install cannot answer for a row.
OB=$TMP/h27ob
mkdir -p "$OB/both/usr/local/bin" "$OB/both/opt/homebrew/bin" "$OB/path" "$OB/brew/opt/homebrew/bin" "$OB/none"
for _d in "$OB/both/usr/local/bin" "$OB/both/opt/homebrew/bin" "$OB/path" "$OB/brew/opt/homebrew/bin"; do
    cp "$ROOT/tests/stubs/fake-ollama.sh" "$_d/ollama"; chmod +x "$_d/ollama"
done
OB_PATH=$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r _d; do
    [ -n "$_d" ] || continue; [ -x "$_d/ollama" ] || printf '%s:' "$_d"; done)
OB_PATH=${OB_PATH%:}
obin() { ( PATH="${1:+$1:}${OB_PATH:-$PATH}"; export PATH; mss_default_ollama_bin "$2"; echo "rc=$?" ) | tr '\n' ' '; }
check "E11 /usr/local/bin/ollama comes first" "$OB/both/usr/local/bin/ollama rc=0 " "$(obin "$OB/path" "$OB/both")"
check "E11 then the ollama on PATH" "$OB/path/ollama rc=0 " "$(obin "$OB/path" "$OB/brew")"
check "E11 then /opt/homebrew/bin/ollama, even off PATH" "$OB/brew/opt/homebrew/bin/ollama rc=0 " "$(obin "" "$OB/brew")"
check "E11 none found keeps /usr/local/bin/ollama and says so" "/usr/local/bin/ollama rc=1 " "$(obin "" "$OB/none")"
# End to end in env mode: a Homebrew-only Ollama, found on PATH (the reported
# Mac) and off PATH (a sudo PATH without /opt/homebrew/bin), is what the plist runs.
mkdir -p "$TMP/h27r/sysroot/opt/homebrew/bin"
cp "$ROOT/tests/stubs/fake-ollama.sh" "$TMP/h27r/sysroot/opt/homebrew/bin/ollama"; chmod +x "$TMP/h27r/sysroot/opt/homebrew/bin/ollama"
# The Ollama block renders from $BASE_DIR/config, so this base links the templates.
mkdir -p "$TMP/h27r/base11"; ln -sf "$ROOT/config" "$TMP/h27r/base11/config"
for _case in on-path off-path; do
    rm -f "$HSD_R/"*.plist
    _pre="$TMP/h27r-bin:"; [ "$_case" = off-path ] || _pre="$TMP/h27r/sysroot/opt/homebrew/bin:$_pre"
    install_case "$TMP/h27r/e11-$_case.log" MSS_BACKENDS=ollama MSS_TUNE_MACOS=no \
        OLLAMA_BASE_DIR="$TMP/h27r/base11" PATH="$_pre${OB_PATH:-$PATH}"
    check "E11 env mode, Homebrew Ollama $_case, exits 0" "rc=0" "$(tail -n 1 "$TMP/h27r/e11-$_case.log")"
    grep -q "<string>$TMP/h27r/sysroot/opt/homebrew/bin/ollama</string>" "$HSD_R/com.ollama.service.plist" 2>/dev/null \
        && ok "E11 com.ollama.service runs the Homebrew Ollama ($_case)" \
        || fail "E11 $_case plist: $(grep -A1 ProgramArguments "$HSD_R/com.ollama.service.plist" 2>&1 | tail -n 1)"
done
rm -rf "$TMP/h27r/sysroot/opt"; rm -f "$HSD_R/"*.plist

# E12 (manual step 9): com.colima.daemon runs the start-colima.sh its template
# names, whichever checkout installed it. Autostart is refused before any change
# unless that file is this checkout's script: an older one resizes the VM.
BU=$(id -un); BJS="$TMP/h27r/sysroot/Users/$BU/mac-studio-server/scripts"
mkdir -p "$BJS" "$TMP/h27r/jobtools"
cp "$ROOT/tests/stubs/colima" "$ROOT/tests/stubs/docker" "$TMP/h27r/jobtools/"; chmod +x "$TMP/h27r/jobtools/"*
jscheck() { ( MSS_TEST_SYSROOT=$TMP/h27r/sysroot OLLAMA_USER=$BU; export MSS_TEST_SYSROOT OLLAMA_USER
    while [ "$#" -gt 0 ]; do export "${1?}"; shift; done
    mss_docker_job_script_check 2>&1; echo "rc=$?" ) | tr '\n' ' '; }
rm -f "$BJS/start-colima.sh"
check "E12 autostart unset never looks at the boot script" "rc=0 " "$(jscheck MSS_DOCKER_AUTOSTART=)"
check "E12 a missing boot script refuses autostart" \
    "ERROR: MSS_DOCKER_AUTOSTART=yes: com.colima.daemon runs /Users/$BU/mac-studio-server/scripts/start-colima.sh at every boot, and that is not this checkout's start-colima.sh; run install.sh from /Users/$BU/mac-studio-server, or bring that checkout to this version rc=1 " \
    "$(jscheck MSS_DOCKER_AUTOSTART=yes)"
git -C "$ROOT" show 8975c9f:scripts/start-colima.sh > "$BJS/start-colima.sh" 2>/dev/null \
    || printf '#!/bin/bash\ncolima start --cpu 4 --memory 8 --disk 50\n' > "$BJS/start-colima.sh"
jscheck MSS_DOCKER_AUTOSTART=yes | grep -q 'rc=1 $' && ok "E12 an older boot script refuses autostart" || fail "E12 older: $(jscheck MSS_DOCKER_AUTOSTART=yes)"
cp "$ROOT/scripts/start-colima.sh" "$BJS/start-colima.sh"
check "E12 this checkout's boot script passes" "rc=0 " "$(jscheck MSS_DOCKER_AUTOSTART=yes)"
# End to end: an older boot script stops install.sh before anything is loaded.
printf '#!/bin/bash\ncolima start --cpu 4 --memory 8 --disk 50\n' > "$BJS/start-colima.sh"
rm -f "$HSD_R/"*.plist
install_case "$TMP/h27r/e12.log" MSS_BACKENDS=ollama MSS_TUNE_MACOS=no MSS_DOCKER_AUTOSTART=yes \
    MSS_DOCKER_JOB_PATH="$TMP/h27r/jobtools" MSS_STUB_LOG="$TMP/h27r/e12.stub"
check "E12 install.sh with an older boot script exits 1" "rc=1" "$(tail -n 1 "$TMP/h27r/e12.log")"
check "E12 nothing was loaded" "" "$(cat "$HR_STATE/calls.log")"
grep -q 'is not this checkout' "$TMP/h27r/e12.log" && ok "E12 the refusal says why" || fail "E12 log: $(tail -3 "$TMP/h27r/e12.log")"
cp "$ROOT/scripts/start-colima.sh" "$BJS/start-colima.sh"
install_case "$TMP/h27r/e12b.log" MSS_BACKENDS=ollama MSS_TUNE_MACOS=no MSS_DOCKER_AUTOSTART=yes \
    MSS_DOCKER_JOB_PATH="$TMP/h27r/jobtools" MSS_STUB_LOG="$TMP/h27r/e12.stub"
check "E12 with this checkout's boot script the install completes" "rc=0" "$(tail -n 1 "$TMP/h27r/e12b.log")"
grep -q 'Docker at boot: on, changed' "$TMP/h27r/e12b.log" && ok "E12 the Colima job is installed" || fail "E12b: $(grep 'Docker at boot' "$TMP/h27r/e12b.log")"
check "E12 install.sh never ran colima or docker" "" "$(cat "$TMP/h27r/e12.stub" 2>/dev/null)"
rm -rf "$TMP/h27r/sysroot/Users/$BU/mac-studio-server"; rm -f "$HSD_R/"*.plist

# E8 (D7 step 6): the Docker install runs before the switch removal, the Ollama
# steps and every launchd or pmset change. A brew that fails must stop install.sh
# with nothing loaded; the static pin below checks the same order in the source.
mkdir -p "$TMP/h27r/brewfail" "$TMP/h27r/job-none"
printf '#!/bin/sh\necho "brew $*" >> "$MSS_STUB_LOG"\nexit 1\n' > "$TMP/h27r/brewfail/brew"; chmod +x "$TMP/h27r/brewfail/brew"
rm -f "$HSD_R/"*.plist
install_case "$TMP/h27r/e8.log" MSS_BACKENDS=ollama MSS_TUNE_MACOS=no MSS_DOCKER_INSTALL=yes \
    MSS_DOCKER_JOB_PATH="$TMP/h27r/job-none" MSS_STUB_LOG="$TMP/h27r/e8.stub" \
    PATH="$TMP/h27r/brewfail:$TMP/h27r-bin:${V_PATH:-$PATH}"
check "E8 a failing brew stops install.sh" "rc=1" "$(tail -n 1 "$TMP/h27r/e8.log")"
check "E8 brew was asked for the missing tools only" "brew install colima docker" "$(cat "$TMP/h27r/e8.stub" 2>/dev/null)"
check "E8 nothing was loaded or booted out" "" "$(cat "$HR_STATE/calls.log")"
grep -q 'Loading Ollama service' "$TMP/h27r/e8.log" && fail "E8 the Ollama steps ran before the Docker install" \
    || ok "E8 the Docker install runs before the Ollama steps"
_d7() { grep -nF -- "$1" "$ROOT/scripts/install.sh" | head -n 1 | cut -d: -f1; }
D7ORDER="$(_d7 'if [ "$MSS_FLAG" = --configure-only ]; then') $(_d7 'mss_apply_step mss_docker_install_apply') \
$(_d7 'uninstall.sh" --backend "$MSS_SWITCH_FROM"') $(_d7 'launchctl load -w') $(_d7 'mss_apply_step mss_gpu_apply') \
$(_d7 'mss_apply_step mss_power_apply') $(_d7 'mss_apply_step mss_docker_autostart_apply') $(_d7 '    mss_check || exit 1')"
check "E8 install.sh keeps the D7 order (steps 4, 6, 7, 8, 9, 10, 11, 12)" "sorted" \
    "$(printf '%s\n' $D7ORDER | awk 'NF { if (n++ && $1 <= p) bad = 1; p = $1 } END { print (n == 8 && !bad) ? "sorted" : "out of order: " n }')"

# E4: `system` with an optional backend selected must not reach mss_validate_uint.
# install-backends.sh validates a percent; system means no wired limit.
# MSS_HW_MEMSIZE plus the BSD-stat stub make the render pass runnable here.
e4_render() { # e4_render <dir> <percent>: render with the BSD-stat stub first on
# PATH and a fixed RAM size, so the wired-limit branch runs on a Linux runner.
# The assignment is scoped to the command, so nothing has to be restored.
    mkdir -p "$TMP/h27r/bin-bsd"; cp "$ROOT/tests/stubs/stat-bsd" "$TMP/h27r/bin-bsd/stat"
    chmod +x "$TMP/h27r/bin-bsd/stat"
    PATH="$TMP/h27r/bin-bsd:$PATH" MSS_HW_MEMSIZE=137438953472 \
        render ollama,llamacpp "$1" MSS_GPU_PERCENT="$2"
}
if e4_render "$TMP/h27r/e4" system >/dev/null 2>&1; then
    ok "E4 system with an optional backend renders"
else
    fail "E4 system with an optional backend: $(e4_render "$TMP/h27r/e4b" system 2>&1 | tail -2)"
fi
grep -q 'MSS_WIRED_LIMIT_MB' "$TMP/h27r/e4/backends.conf" \
    && fail "E4 system wrote a wired limit" || ok "E4 system writes no MSS_WIRED_LIMIT_MB"
# A number still produces the limit, so the case above did not just skip the branch.
if e4_render "$TMP/h27r/e4n" 80 >/dev/null 2>&1; then
    grep -q '^MSS_WIRED_LIMIT_MB=104857$' "$TMP/h27r/e4n/backends.conf" \
        && ok "E4 a number still writes the wired limit" \
        || fail "E4 80 wrote: $(grep MSS_WIRED_LIMIT_MB "$TMP/h27r/e4n/backends.conf")"
else
    fail "E4 render with 80: $(e4_render "$TMP/h27r/e4nb" 80 2>&1 | tail -2)"
fi

# E5: the guard and the exemption are both still in the file, and `system` never
# reaches them. A full --check-only pass needs a rendered conf, which is what
# the rows at #12/#15 already cover; here the point is that system is excluded
# before the guard, not that the guard is gone.
grep -q 'MSS_GPU_PERCENT:-}" != system' "$ROOT/scripts/install-backends.sh" \
    && ok "E5 system is excluded before the wired-limit branch" \
    || fail "E5 the exclusion is missing"
grep -q 'com.mac-studio-server.gpumemory is not installed; run scripts/install.sh' "$ROOT/scripts/install-backends.sh" \
    && ok "E5 the missing-plist guard is still there" || fail "E5 the guard was dropped"

# E6: the picker path resolves after loading backends.env, so a legacy file key
# migrates with its notice and a conflicting environment value is a conflict.
if [ "$(id -u)" -ne 0 ]; then
    # mss_envfile_check_file reads the owner and mode with BSD `stat -f`.
    mkdir -p "$TMP/h27r/bin-bsd"
    cp "$ROOT/tests/stubs/stat-bsd" "$TMP/h27r/bin-bsd/stat"; chmod +x "$TMP/h27r/bin-bsd/stat"
    PKG="$TMP/h27r/pkgen"; mkdir -p "$PKG"
    printf 'MSS_BACKENDS=ollama\nOLLAMA_GPU_PERCENT=80\n' > "$PKG/legacy.env"; chmod 600 "$PKG/legacy.env"
    ( unset MSS_GPU_PERCENT OLLAMA_GPU_PERCENT MSS_CHOICES_RESOLVED MSS_ENVFILE_LOADED
      export HOME="$TMP/h27r/home" MSS_ENV_FILE="$PKG/legacy.env" PATH="$TMP/h27r/bin-bsd:$PATH"
      . "$ROOT/scripts/lib/mss-common.sh"; . "$ROOT/scripts/lib/mss-acquire.sh"
      . "$ROOT/scripts/lib/mss-run.sh"; . "$ROOT/scripts/lib/mss-host.sh"
      . "$ROOT/scripts/lib/mss-picker.sh"
      mss_envfile_load "$PKG/legacy.env" && mss_choices_resolve ) > "$PKG/legacy.out" 2>&1
    grep -q 'OLLAMA_GPU_PERCENT is deprecated; using it as MSS_GPU_PERCENT=80. Rename it in backends.env' "$PKG/legacy.out" \
        && ok "E6 a legacy key in the file migrates with its notice" || fail "E6: $(cat "$PKG/legacy.out")"
    ( unset MSS_GPU_PERCENT OLLAMA_GPU_PERCENT MSS_DOCKER_AUTOSTART MSS_DOCKER_INSTALL \
          MSS_POWER_AUTORESTART DOCKER_AUTOSTART MSS_ENVFILE_LOADED MSS_ENVFILE_OVERRIDDEN
      export MSS_GPU_PERCENT=85 PATH="$TMP/h27r/bin-bsd:$PATH"
      MSS_CHOICES_RESOLVED=''
      export MSS_CHOICES_RESOLVED
      . "$ROOT/scripts/lib/mss-common.sh"; . "$ROOT/scripts/lib/mss-acquire.sh"
      . "$ROOT/scripts/lib/mss-run.sh"; . "$ROOT/scripts/lib/mss-host.sh"
      . "$ROOT/scripts/lib/mss-picker.sh"
      mss_envfile_load "$PKG/legacy.env" && mss_choices_resolve ) > "$PKG/conf.out" 2>&1
    grep -q 'differ; keep one' "$PKG/conf.out" \
        && ok "E6 a file legacy key against a new env key is a conflict" || fail "E6 conflict: $(cat "$PKG/conf.out")"
    # A file holding both keys is a conflict too: the loader reads both, the
    # resolver compares them.
    printf 'MSS_BACKENDS=ollama\nOLLAMA_GPU_PERCENT=80\nMSS_GPU_PERCENT=85\n' > "$PKG/both.env"; chmod 600 "$PKG/both.env"
    ( unset MSS_GPU_PERCENT OLLAMA_GPU_PERCENT MSS_CHOICES_RESOLVED MSS_ENVFILE_LOADED
      export PATH="$TMP/h27r/bin-bsd:$PATH"
      . "$ROOT/scripts/lib/mss-common.sh"; . "$ROOT/scripts/lib/mss-acquire.sh"
      . "$ROOT/scripts/lib/mss-run.sh"; . "$ROOT/scripts/lib/mss-host.sh"
      mss_envfile_load "$PKG/both.env" && mss_choices_resolve ) > "$PKG/both.out" 2>&1
    grep -q 'differ; keep one' "$PKG/both.out" \
        && ok "E6 both keys in one file is a conflict" || fail "E6 both: $(cat "$PKG/both.out")"
else
    echo "skip - E6 needs a non-root user (the loader refuses a file it does not own)"
fi

# E6b: question G saves the answer the user gave. Grepping the comment would
# prove nothing, so this runs the picker function and then the apply step with
# whatever the picker left behind. Unsetting `system` instead of saving it would
# save nothing, print "left as is", and leave an installed job in place.
rm_gpu_r() { rm -f "$HSD_R/com.mac-studio-server.gpumemory.plist" "$HSD_R/com.ollama.gpumemory.plist" "$HR_STATE"/loaded-com.*gpumemory; }
gpu_pick_case() { # gpu_pick_case <answer>: the saved key, then the apply line
    ( export MSS_TEST_SYSROOT=$TMP/h27r/sysroot MSS_STUB_STATE=$HR_STATE \
          MSS_SYSCTL="$TMP/h27r-bin/sysctl" PATH="$TMP/h27r-bin:$PATH"
      unset MSS_GPU_PERCENT
      . "$ROOT/scripts/lib/mss-common.sh"; . "$ROOT/scripts/lib/mss-acquire.sh"
      . "$ROOT/scripts/lib/mss-run.sh"; . "$ROOT/scripts/lib/mss-host.sh"
      . "$ROOT/scripts/lib/mss-picker.sh"
      # Only the terminal is replaced: mss_ask(prompt, default, validator) reads
      # the answer, so the stub feeds the answer under test through the real
      # validator and sets MSS_ANSWER exactly as the terminal would.
      mss_ask() { "$3" "$MSS_PICK_ANSWER" || return 1; MSS_ANSWER=$MSS_PICK_ANSWER; return 0; }
      MSS_PICK_ANSWER=$1
      _mss_pick_gpu
      # The apply step runs in a subshell, so the saved key is passed out as the
      # first line and the caller applies it against the seeded state.
      printf '%s\n' "${MSS_GPU_PERCENT:-unset}" )
}
gpu_apply_line() { # gpu_apply_line <percent>: the D8 line for that answer
    ( export MSS_TEST_SYSROOT=$TMP/h27r/sysroot MSS_STUB_STATE=$HR_STATE \
          MSS_SYSCTL="$TMP/h27r-bin/sysctl" PATH="$TMP/h27r-bin:$PATH" \
          MSS_SUDO=$TMP/nosudo/sudo MSS_LAUNCHD_TIMEOUT=1
      mss_gpu_apply "${1:-}" 2>/dev/null )
}
rm_gpu_r; echo 104857 > "$HR_STATE/live"
mss_gpu_render 80 104857 > "$HSD_R/com.mac-studio-server.gpumemory.plist"
printf 'loaded-com.mac-studio-server.gpumemory\n' > "$HR_STATE/loaded-com.mac-studio-server.gpumemory"
SAVED=$(gpu_pick_case system)
check "E6b answering system saves the word system" "system" "$SAVED"
check "E6b applying system removes the installed job" \
    "GPU memory: system default from the next boot" "$(gpu_apply_line "$SAVED")"
check "E6b the job is gone after applying system" 0 "$(ls "$HSD_R" | grep -c gpumemory)"
# And a number still round-trips, so the row above is not just an empty key.
rm_gpu_r; echo 0 > "$HR_STATE/live"
SAVED=$(gpu_pick_case 80)
check "E6b answering 80 saves 80" "80" "$SAVED"
gpu_apply_line "$SAVED" >/dev/null
[ -f "$HSD_R/com.mac-studio-server.gpumemory.plist" ] \
    && ok "E6b a number installs the job" || fail "E6b: 80 installed nothing"
rm_gpu_r

# E7: status.sh reads the sysroot, and a legacy job alone is still healthy.
# MSS_CONF points at a conf selecting ollama only, so the backend health probes
# (which need a running service) are the only rows the stubs cannot answer.
rm -f "$HSD_R/"*.plist; echo 0 > "$HR_STATE/live"
mkdir -p "$TMP/h27r/conf"
printf 'MSS_BACKENDS=ollama\n' > "$TMP/h27r/conf/ollama.conf"
status_case() {
    ( export MSS_TEST_SYSROOT=$TMP/h27r/sysroot MSS_STUB_STATE=$HR_STATE \
          MSS_SYSCTL="$TMP/h27r-bin/sysctl" PATH="$TMP/h27r-bin:$PATH" \
          MSS_CONF="$TMP/h27r/conf/ollama.conf"
      sh "$ROOT/scripts/status.sh" ) 2>&1
    echo "rc=$?"
}
rm_gpu_r
OUT=$(status_case)
printf '%s' "$OUT" | grep -q 'system default' && ok "E7 no job prints system default" || fail "E7: $OUT"
rm_gpu_r
cat > "$HSD_R/com.ollama.gpumemory.plist" <<'LP'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
    <key>Label</key><string>com.ollama.gpumemory</string>
    <key>EnvironmentVariables</key><dict>
        <key>OLLAMA_GPU_PERCENT</key><string>80</string>
    </dict>
</dict></plist>
LP
printf 'loaded-com.ollama.gpumemory\n' > "$HR_STATE/loaded-com.ollama.gpumemory"
OUT=$(status_case)
printf '%s' "$OUT" | grep -q 'user-editable script as root' \
    && ok "E7 a legacy job alone prints the migrate note" || fail "E7 note: $OUT"
# "healthy" here means the gpu memory row itself, not the process exit code: the
# ollama service probe in the same run cannot pass on a test runner.
printf '%s' "$OUT" | grep -A1 'gpu memory' | grep -q 'via com.ollama.gpumemory' \
    && ok "E7 the legacy job is reported healthy, not unhealthy" || fail "E7 gpu row: $OUT"
# Both labels at once is the one GPU state that must fail the run.
seed_legacy_r() {
    cat > "$HSD_R/com.ollama.gpumemory.plist" <<'LPL'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.ollama.gpumemory</string>
<key>EnvironmentVariables</key><dict><key>OLLAMA_GPU_PERCENT</key><string>80</string></dict>
</dict></plist>
LPL
    printf 'loaded-com.ollama.gpumemory\n' > "$HR_STATE/loaded-com.ollama.gpumemory"
}
rm_gpu_r; seed_legacy_r
mss_gpu_render 80 104857 > "$HSD_R/com.mac-studio-server.gpumemory.plist"
printf 'loaded-com.mac-studio-server.gpumemory\n' > "$HR_STATE/loaded-com.mac-studio-server.gpumemory"
OUT=$(status_case)
printf '%s' "$OUT" | grep -q 'both GPU boot jobs installed' \
    && ok "E7 two GPU labels are reported" || fail "E7 both: $OUT"
rm_gpu_r

rm_gpu_r


echo "== phase A: docs (R1, R2, S2, S3) =="
R1=$(awk '/^# /{s="title"} /^## /{s=$0} NF{c[s]++} END{for (k in c) print k"|"c[k]}' "$ROOT/README.md")
cap() { printf '%s\n' "$R1" | awk -F'|' -v k="$1" '$1==k{print $2}'; }
check "README sections in order (R1)" \
    "## Install|## What the installer asks|## After install|## Options|## Requirements|## Updates|## Contributing|## License" \
    "$(grep '^## ' "$ROOT/README.md" | tr '\n' '|' | sed 's/|$//')"
for sc in "title:3:1" "## Install:8:0" "## What the installer asks:12:0" "## After install:12:0" "## Options:25:0" \
    "## Requirements:5:0" "## Updates:6:0"; do
    name=${sc%%:*}; rest=${sc#*:}; max=${rest%%:*}; extra=${rest#*:}
    n=$(cap "$name"); n=$(( ${n:-0} - extra ))
    [ "$n" -le "$max" ] && ok "README '$name' within $max lines ($n)" || fail "README '$name' has $n lines, cap $max"
done
check "README Contributing + License within 4 lines" "4" "$(( $(cap '## Contributing') + $(cap '## License') ))"
[ "$(wc -l < "$ROOT/README.md")" -le 120 ] && ok "README ≤ 120 lines" || fail "README is $(wc -l < "$ROOT/README.md") lines"
for gone in 'launchctl unload' 'sudo cp config/' 'Customizing Configuration' 'Performance Considerations' 'Troubleshooting Docker'; do
    grep -q "$gone" "$ROOT/README.md" && fail "README still has '$gone' (R2)" || ok "README has no '$gone' (R2)"
done
awk '/^## Options/{f=1;next} /^## /{f=0} f' "$ROOT/README.md" | grep -q '0\.0\.0\.0.*OLLAMA_BIND=127\.0\.0\.1' \
    && ok "README Options keeps the Ollama exposure line (R2)" || fail "README exposure line missing"
for word in OLLAMA_BIND ./scripts/optimize-mac-server.sh MSS_GPU_PERCENT MSS_DOCKER_INSTALL MSS_DOCKER_AUTOSTART MSS_POWER_AUTORESTART OLLAMA_GPU_PERCENT; do
    grep -q -- "$word" "$ROOT/docs/options.md" && ok "docs/options.md has $word (R2, F6, #27)" || fail "docs/options.md lacks $word"
done
[ "$(wc -l < "$ROOT/docs/options.md")" -le 100 ] && ok "docs/options.md ≤ 100 lines" || fail "docs/options.md too long"
# A9: the legacy names appear only where the migration needs them.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    A9BAD=$(git -C "$ROOT" grep -lE 'com\.ollama\.gpumemory|OLLAMA_GPU_PERCENT' | grep -vxE \
        'scripts/lib/mss-host\.sh|scripts/lib/mss-common\.sh|scripts/set-gpu-memory\.sh|scripts/install-backends\.sh|docs/options\.md|docs/backends\.md|CHANGELOG\.md|tests/.*' || true)
    check "A9 the legacy names appear only in the allowed files" "" "$A9BAD"
else
    echo "skip - A9 grep set needs a git checkout"
fi
S2=$(awk '/^## \[1\.5\.0\]/{f=1;next} /^## \[/{f=0} f && /^- /' "$ROOT/CHANGELOG.md")
[ "$(printf '%s\n' "$S2" | grep -c .)" -le 5 ] && ok "CHANGELOG 1.5.0 has ≤ 5 bullets (S2)" || fail "CHANGELOG bullets: $S2"
[ -z "$(printf '%s\n' "$S2" | awk 'length($0) > 100')" ] && ok "CHANGELOG bullets ≤ 100 characters (S2)" || fail "long CHANGELOG bullet"
printf '%s\n' "$S2" | grep -Eq '\.sh|/|\(\)|_[a-z]' && fail "CHANGELOG names internals (S2)" || ok "CHANGELOG names no internals (S2)"
printf '%s\n' "$S2" | grep -qi 'headless.*asked once' && ok "CHANGELOG says the headless tweaks are asked once (F6)" || fail "F6 CHANGELOG line"
S3=$(awk '/^## One-line install/{f=1} /^## Status/{f=0} f' "$ROOT/docs/backends.md" | wc -l)
[ "$S3" -le 30 ] && ok "docs/backends.md new section ≤ 30 lines ($S3) (S3)" || fail "docs/backends.md section is $S3 lines"
grep -q "configure-only.*may leave a verification stamp" "$ROOT/docs/backends.md" && ok "backends.md --configure-only wording (S3)" || fail "S3 wording"

echo "== phase A: picker on a pty (A3b, A12, A13, F5, M4, I2) =="
if [ "$(id -u)" -eq 0 ]; then
    echo "skip - picker tests need a non-root user (interactive modes refuse root)"
elif ! command -v expect >/dev/null 2>&1; then
    fail "expect is not installed (the picker tests need it)"
else
    # sudo runs the --check-only pass as this user here: no system change. -v (the run's one
    # password prompt) and the keep-alive's -n pass through.
    mkdir -p "$TMP/nosudo"
    printf '#!/bin/sh\ncase $1 in -v) exit 0 ;; -n) shift ;; esac\nexec "$@"\n' > "$TMP/nosudo/sudo"; chmod +x "$TMP/nosudo/sudo"
    cp "$ROOT/tests/stubs/fake-ollama.sh" "$TMP/nosudo/ollama"; chmod +x "$TMP/nosudo/ollama"
    PK="$TMP/picker"; mkdir -p "$PK" "$PK/bin" "$PK/jobbin" "$PK/sysroot/Library/LaunchDaemons"
    # The #27 host questions read the Mac, so every row pins what they see: a
    # sysroot of its own (no GPU or Colima job), autorestart reading 0, both
    # Docker tools on the boot job's PATH (so DI is skipped and DA reads
    # "Currently off"), and stat-bsd so a saved backends.env loads on Linux too.
    cp "$ROOT/tests/stubs/stat-bsd" "$PK/bin/stat"; chmod +x "$PK/bin/stat"
    cp "$ROOT/tests/stubs/colima" "$ROOT/tests/stubs/docker" "$PK/jobbin/"; chmod +x "$PK/jobbin/"*
    drive() { # drive <name> <steps...> -- <env...>: run install.sh on a pty.
        # DRIVE_PATH, when set, goes first on PATH; DRIVE_BASE_PATH replaces the
        # inherited PATH after the harness directories.
        _name=$1; shift
        : > "$PK/$_name.steps"
        while [ "$1" != -- ]; do printf '%s\n' "$1" >> "$PK/$_name.steps"; shift; done
        shift
        rm -rf "$PK/state-$_name"; mkdir -p "$PK/state-$_name"; : > "$PK/$_name.stublog"
        env PATH="${DRIVE_PATH:+$DRIVE_PATH:}$PK/bin:$TMP/nosudo:${DRIVE_BASE_PATH:-$PATH}" MSS_CONF="$PK/none.conf" OLLAMA_USER="$(id -un)" \
            MSS_IFCONFIG="$ROOT/tests/stubs/ifconfig-lan" MSS_TEST_SYSROOT="$PK/sysroot" \
            MSS_STUB_STATE="$PK/state-$_name" MSS_STUB_LOG="$PK/$_name.stublog" \
            MSS_PMSET="$ROOT/tests/stubs/pmset-autorestart-0" MSS_SYSCTL="$ROOT/tests/stubs/sysctl-state" \
            MSS_DOCKER_JOB_PATH="$PK/jobbin" "$@" \
            expect "$ROOT/tests/expect/drive.exp" "$PK/$_name.steps" "$PK/$_name.transcript" \
            /bin/bash "$ROOT/scripts/install.sh" --configure-only >/dev/null 2>"$PK/$_name.err"
        # A prefix assignment before a function call persists in a POSIX-mode
        # shell, so the two are cleared here or they would leak into later rows.
        _drc=$?; unset DRIVE_PATH DRIVE_BASE_PATH; return "$_drc"
    }
    T=$(printf '\t')
    # The three host prompts every row below sees, answered with their defaults.
    G_ENTER="or system [system]: ${T}@ENTER"; P_ENTER="power failure? [y/N]: ${T}@ENTER"
    DA_ENTER="Currently off. [y/N]: ${T}@ENTER"
    DS4B="$TMP/fix/ds4/ds4-server"; DS4M="$TMP/fix/ds4/model.gguf"; DS4S=$(cat "$TMP/fix/ds4/model.sha")
    LLB="$TMP/fix/llamacpp/llamacpp-server"; LLM="$TMP/fix/llamacpp/model.gguf"

    drive menu3 "Choose [1]: ${T}9" "Choose [1]: ${T}x" "Choose [1]: ${T}0" -- MSS_ENV_FILE="$PK/menu3.env"
    check "3 bad menu answers exit 2 (A12)" 2 $?
    [ ! -e "$PK/menu3.env" ] && ok "3 bad menu answers write nothing (A12)" || fail "A12 menu wrote a file"

    drive noallow "Choose [1]: ${T}5" "later [4]: ${T}3" "path or https URL: ${T}$DS4M" "[Y/n]: ${T}@ENTER" "[Y/n]: ${T}@ENTER" \
        "LAN access to ds4? [y/N]: ${T}y" "listen on [192.0.2.10]: ${T}@ENTER" \
        "(space-separated): ${T}@ENTER" "(space-separated): ${T}@ENTER" "(space-separated): ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/noallow.env" DS4_BIN="$DS4B"
    check "LAN ds4 with an empty allowlist cannot complete (A12)" 2 $?
    [ ! -e "$PK/noallow.env" ] && ok "LAN ds4 with an empty allowlist writes nothing" || fail "A12 allowlist wrote a file"

    drive keyfile "Choose [1]: ${T}4" "later [1]: ${T}3" "path or https URL: ${T}$LLM" "[Y/n]: ${T}@ENTER" "[Y/n]: ${T}@ENTER" \
        "LAN access to llamacpp? [y/N]: ${T}y" "listen on [192.0.2.10]: ${T}@ENTER" \
        "use an allowlist instead): ${T}sk-test123" "use an allowlist instead): ${T}@ENTER" \
        "(space-separated): ${T}192.0.2.99" "auto-updates)? ${T}@ENTER" "$G_ENTER" "$P_ENTER" "$DA_ENTER" \
        "Save? [Y/n]: ${T}n" -- \
        MSS_ENV_FILE="$PK/keyfile.env" LLAMACPP_BIN="$LLB"
    check "declining the summary exits 1" 1 $?
    grep -q 'not the key itself' "$PK/keyfile.transcript" && ok "key prompt rejects a key typed as a path (A12)" || fail "A12 key prompt: $(tail -5 "$PK/keyfile.transcript")"
    # once is the terminal echoing the typed answer; any more is the installer printing it
    check "the rejected key is never printed back" 1 "$(grep -o 'sk-test123' "$PK/keyfile.transcript" | wc -l | tr -d ' ')"
    # Saved and installed files must not hold it. The pty transcript records
    # the typed answer by design; the printed-back count above covers output.
    # The installed conf and $ROOT/backends.env are the live-state guard's (#21).
    LEAK=$(grep -l 'sk-test123' "$PK"/*.env "$MSS_CONF" 2>/dev/null || true)
    [ -z "$LEAK" ] && ok "the rejected key is in no file (A12)" || fail "sk-test123 found in: $LEAK"

    drive intr "Choose [1]: ${T}5" "later [4]: ${T}3" "path or https URL: ${T}@INTR" -- MSS_ENV_FILE="$PK/intr.env" DS4_BIN="$DS4B"
    check "Ctrl-C at the model prompt exits 130 (A13)" 130 $?
    [ ! -e "$PK/intr.env" ] && ok "Ctrl-C writes nothing (A13)" || fail "A13 wrote a file"

    drive envdef "Choose [5]: ${T}@ENTER" "later [4]: ${T}3" "path or https URL: ${T}$DS4M" "[Y/n]: ${T}@ENTER" "[Y/n]: ${T}@ENTER" \
        "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" "$G_ENTER" "$P_ENTER" "$DA_ENTER" \
        "Save? [Y/n]: ${T}@ENTER" -- MSS_ENV_FILE="$PK/envdef.env" MSS_BACKENDS=ds4 DS4_PORT=8001 DS4_BIN="$DS4B"
    check "--configure-only with MSS_BACKENDS set shows the menu with env defaults (A3b)" 0 $?
    grep -q '^MSS_BACKENDS=ds4$' "$PK/envdef.env" 2>/dev/null && grep -q '^DS4_PORT=8001$' "$PK/envdef.env" \
        && ok "A3b saved MSS_BACKENDS=ds4 and DS4_PORT=8001" || fail "A3b saved: $(cat "$PK/envdef.env" 2>&1)"
    check "A3b file mode 0600" 600 "$(stat -f '%Lp' "$PK/envdef.env" 2>/dev/null)"
    grep -q "^DS4_MODEL_SHA256=$DS4S\$" "$PK/envdef.env" && ok "A3b saved the computed sha256" || fail "A3b sha"
    grep -q 'Port' "$PK/envdef.transcript" && fail "the port was asked (I6)" || ok "no port prompt (I6)"

    drive saved "Choose [5]: ${T}@ENTER" "(.gguf) path [$DS4M]: ${T}@ENTER" \
        "c computes it now) [$DS4S]: ${T}@ENTER" "LAN access to ds4? [y/N]: ${T}@ENTER" \
        "auto-updates)? ${T}@ENTER" "$G_ENTER" "$P_ENTER" "$DA_ENTER" "Save? [Y/n]: ${T}@ENTER" -- MSS_ENV_FILE="$PK/envdef.env"
    check "--configure-only reuses every saved answer as its default" 0 $?
    grep -q 'Hashing' "$PK/saved.transcript" && fail "a saved sha256 was re-hashed by the picker" || ok "a saved sha256 is not re-hashed by the picker"
    grep -q 'binary path' "$PK/saved.transcript" && fail "a saved binary was asked for again (I7)" || ok "a saved binary is used without asking (I7)"

    # F5: a llama-server found on PATH and the default port: neither is asked.
    mkdir -p "$TMP/found"; cp "$ROOT/tests/stubs/fake-server.sh" "$TMP/found/llama-server"; chmod +x "$TMP/found/llama-server"
    DRIVE_PATH="$TMP/found" drive found "Choose [1]: ${T}4" "later [1]: ${T}4" "LAN access to llamacpp? [y/N]: ${T}@ENTER" \
        "auto-updates)? ${T}@ENTER" "$G_ENTER" "$P_ENTER" "$DA_ENTER" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/found.env"
    check "F5 found llama-server, later" 0 $?
    grep -q 'binary path\|Port' "$PK/found.transcript" && fail "F5 asked for the binary or the port" || ok "F5 no binary or port prompt"
    grep -q "^LLAMACPP_BIN=$TMP/found/llama-server\$" "$PK/found.env" && grep -q '^LLAMACPP_PORT=8080$' "$PK/found.env" \
        && ok "F5 saved the found binary and port 8080" || fail "F5 saved: $(cat "$PK/found.env")"
    grep -q '^MSS_DEFER_MODEL=yes$' "$PK/found.env" && ok "later saves MSS_DEFER_MODEL=yes (M3)" || fail "later not saved"
    grep -q '^MSS_TUNE_MACOS=no$' "$PK/found.env" && ok "I2 is asked without Ollama too and saved as no (A1)" || fail "I2 without Ollama"

    # M4: ds4 with nothing found: the build offer (declined), the manual command, then the menu.
    drive ds4menu "Choose [1]: ${T}5" "in ~/ds4? [y/N]: ${T}@ENTER" "binary path: ${T}$DS4B" "later [4]: ${T}@ENTER" \
        "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" "$G_ENTER" "$P_ENTER" "$DA_ENTER" \
        "Save? [Y/n]: ${T}@ENTER" -- MSS_ENV_FILE="$PK/ds4menu.env" HOME="$PK/home"
    check "M4 ds4 with the build declined and a model later" 0 $?
    grep -q 'no small one exists).*later \[4\]: ' "$PK/ds4menu.transcript" && ok "M4 ds4 menu says no small model and defaults to later" \
        || fail "M4 menu: $(grep 'ds4 (' "$PK/ds4menu.transcript")"
    grep -q '^manual: git clone https://github.com/antirez/ds4.git' "$PK/ds4menu.transcript" && ok "declining the build prints the manual command" \
        || fail "no manual build command"
    [ ! -e "$PK/home/ds4" ] && ok "declining the build creates nothing" || fail "declined build created ~/ds4"

    # I2: with Ollama, the headless tweaks are asked once and saved; default no.
    drive tweaks "Choose [1]: ${T}1" "auto-updates)? ${T}@ENTER" "$G_ENTER" "$P_ENTER" "$DA_ENTER" \
        "Save? [Y/n]: ${T}@ENTER" -- MSS_ENV_FILE="$PK/tweaks.env"
    check "I2 ollama only" 0 $?
    grep -q '^MSS_TUNE_MACOS=no$' "$PK/tweaks.env" && ok "I2 saved MSS_TUNE_MACOS=no" || fail "I2 saved: $(cat "$PK/tweaks.env")"
    grep -q "^OLLAMA_BIN=$TMP/nosudo/ollama\$" "$PK/tweaks.env" && ok "an ollama on PATH is saved as OLLAMA_BIN (P2)" || fail "P2 OLLAMA_BIN"
    check "I2 asked once" 1 "$(grep -c 'headless macOS tweaks' "$PK/tweaks.transcript")"

    # ── A8: the #27 host questions on a pty ───────────────────────────────────
    # Each row pins what the questions read: its own sysroot, a pmset stub, and
    # a boot-job PATH holding the Docker tools the row asks for. Rows with a tool
    # missing also drop every PATH directory that has colima or docker, so a tool
    # installed on the runner cannot turn "missing" into "elsewhere".
    NODOCKER_PATH=$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r _d; do
        [ -n "$_d" ] || continue; [ -x "$_d/colima" ] || [ -x "$_d/docker" ] || printf '%s:' "$_d"; done)
    NODOCKER_PATH=${NODOCKER_PATH%:}
    mkdir -p "$PK/job-none" "$PK/job-docker" "$PK/job-colima" "$PK/brewbin" "$PK/elsewhere" "$PK/statebin"
    cp "$ROOT/tests/stubs/docker" "$PK/job-docker/"; cp "$ROOT/tests/stubs/colima" "$PK/job-colima/"
    cp "$ROOT/tests/stubs/brew" "$PK/brewbin/"; cp "$ROOT/tests/stubs/colima" "$PK/elsewhere/"
    cp "$ROOT/tests/stubs/launchctl-state" "$PK/statebin/launchctl"
    cp "$ROOT/tests/stubs/sysctl-state" "$PK/statebin/sysctl"; cp "$ROOT/tests/stubs/plutil" "$PK/statebin/plutil"
    chmod +x "$PK/job-docker/"* "$PK/job-colima/"* "$PK/brewbin/"* "$PK/elsewhere/"* "$PK/statebin/"*
    envfile() { printf "$2" > "$PK/$1"; chmod 600 "$PK/$1"; }  # envfile <name> <printf body>
    tr_of() { tr -d '\r' < "$PK/$1.transcript"; }
    saved() { grep "^$2=" "$PK/$1" 2>/dev/null | cut -d= -f2-; }
    SUMMARY_SEEN="$PK/summary.seen"; : > "$SUMMARY_SEEN"
    summary_of() { tr_of "$1" | grep -E '^  (gpu memory|power restore|docker install|docker at boot): ' | tee -a "$SUMMARY_SEEN"; }
    TOOLS_STEP="Colima and the Docker CLI are installed"

    # (a) a legacy file: G offers 80, Enter saves MSS_GPU_PERCENT=80 and no legacy line.
    envfile a8a.env 'MSS_BACKENDS=ollama\nOLLAMA_GPU_PERCENT=80\n'
    drive a8a "Choose [1]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" "or system [80]: ${T}@ENTER" "$P_ENTER" "$DA_ENTER" \
        "Save? [Y/n]: ${T}@ENTER" -- MSS_ENV_FILE="$PK/a8a.env"
    check "A8a a legacy file completes" 0 $?
    check "A8a saves MSS_GPU_PERCENT=80" 80 "$(saved a8a.env MSS_GPU_PERCENT)"
    grep -q OLLAMA_GPU_PERCENT "$PK/a8a.env" && fail "A8a the save kept the legacy key" || ok "A8a the save drops the legacy key"
    tr_of a8a | grep -q 'OLLAMA_GPU_PERCENT is deprecated; using it as MSS_GPU_PERCENT=80. Rename it in backends.env' \
        && ok "A8a the notice names backends.env" || fail "A8a notice: $(tr_of a8a | grep -i deprecated)"
    check "A8a summary" "  gpu memory: 80% of RAM (applied now and at every boot)
  power restore: off (unchanged)
  docker install: no
  docker at boot: off (unchanged)" "$(summary_of a8a)"

    # (b) 0 and 101 are re-asked, then system is accepted; abc too.
    drive a8b1 "Choose [1]: ${T}1" "auto-updates)? ${T}@ENTER" "or system [system]: ${T}0" "or system [system]: ${T}101" \
        "or system [system]: ${T}system" "$P_ENTER" "$DA_ENTER" "Save? [Y/n]: ${T}@ENTER" -- MSS_ENV_FILE="$PK/a8b1.env"
    check "A8b 0 and 101 are re-asked, system accepted" "0 3 system" \
        "$? $(tr_of a8b1 | grep -c 'or system \[system\]: ') $(saved a8b1.env MSS_GPU_PERCENT)"
    drive a8b2 "Choose [1]: ${T}1" "auto-updates)? ${T}@ENTER" "or system [system]: ${T}abc" "or system [system]: ${T}@ENTER" \
        "$P_ENTER" "$DA_ENTER" "Save? [Y/n]: ${T}@ENTER" -- MSS_ENV_FILE="$PK/a8b2.env"
    check "A8b abc is re-asked, Enter takes system" "0 2 system" \
        "$? $(tr_of a8b2 | grep -c 'or system \[system\]: ') $(saved a8b2.env MSS_GPU_PERCENT)"

    # (c) both tools on the job PATH (every row above): DI is not shown, DA is, off by default.
    tr_of tweaks | grep -q "^$TOOLS_STEP" && ok "A8c DI prints the installed line" || fail "A8c no installed line"
    tr_of tweaks | grep -q 'with Homebrew?' && fail "A8c DI was asked" || ok "A8c DI is not asked"
    tr_of tweaks | grep -q 'Start Colima (Docker) at every boot? Currently off. \[y/N\]: ' \
        && ok "A8c DA reads Currently off with default N" || fail "A8c DA: $(tr_of tweaks | grep 'every boot')"

    # (d, f) no tools and no power setting: DI defaults to N, n skips DA, P is skipped.
    DRIVE_BASE_PATH=$NODOCKER_PATH drive a8d "Choose [1]: ${T}1" "auto-updates)? ${T}@ENTER" "$G_ENTER" \
        "Install Colima and the Docker CLI with Homebrew? [y/N]: ${T}@ENTER" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/a8d.env" MSS_DOCKER_JOB_PATH="$PK/job-none" MSS_PMSET="$ROOT/tests/stubs/pmset-none"
    check "A8d no tools, DI n completes" 0 $?
    tr_of a8d | grep -q 'every boot?' && fail "A8d DA was asked after DI = n" || ok "A8d DA is not asked after DI = n"
    check "A8d saves DI=no and no DA or power line" "no||" \
        "$(saved a8d.env MSS_DOCKER_INSTALL)|$(saved a8d.env MSS_DOCKER_AUTOSTART)|$(saved a8d.env MSS_POWER_AUTORESTART)"
    tr_of a8d | grep -q '^This Mac has no restart-after-power-failure setting; skipped' \
        && ok "A8f P prints the skip line" || fail "A8f no skip line"
    tr_of a8d | grep -q 'power failure?' && fail "A8f P was asked" || ok "A8f P is not asked"
    check "A8d summary (no power line on a Mac without the setting)" "  gpu memory: system default (from the next boot)
  docker install: no
  docker at boot: left as is" "$(summary_of a8d)"

    # Stale keys: a saved file holding MSS_DOCKER_AUTOSTART=yes and
    # MSS_POWER_AUTORESTART=yes, on a Mac where DA and P are both skipped. The
    # picker must drop both: saved again, step 2 would refuse the file on every
    # later run and --configure could never clear it. The run's own step 2 is
    # what exits 0 here.
    envfile a8st.env 'MSS_BACKENDS=ollama\nMSS_POWER_AUTORESTART=yes\nMSS_DOCKER_AUTOSTART=yes\n'
    DRIVE_BASE_PATH=$NODOCKER_PATH drive a8st "Choose [1]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" "$G_ENTER" \
        "Install Colima and the Docker CLI with Homebrew? [y/N]: ${T}@ENTER" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/a8st.env" MSS_DOCKER_JOB_PATH="$PK/job-none" MSS_PMSET="$ROOT/tests/stubs/pmset-none"
    check "A8 stale DA and P keys: the run passes its own validation" 0 $?
    check "A8 stale keys are dropped when DA and P are skipped" "no||" \
        "$(saved a8st.env MSS_DOCKER_INSTALL)|$(saved a8st.env MSS_DOCKER_AUTOSTART)|$(saved a8st.env MSS_POWER_AUTORESTART)"
    tr_of a8st | grep -Eq 'every boot\?|power failure\?' && fail "A8 stale keys: DA or P was asked" || ok "A8 stale keys: neither DA nor P was asked"
    # The saved file now loads and validates: a second --configure-only run reaches the save again.
    DRIVE_BASE_PATH=$NODOCKER_PATH drive a8st2 "Choose [1]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" "$G_ENTER" \
        "Install Colima and the Docker CLI with Homebrew? [y/N]: ${T}@ENTER" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/a8st.env" MSS_DOCKER_JOB_PATH="$PK/job-none" MSS_PMSET="$ROOT/tests/stubs/pmset-none"
    check "A8 stale keys: the saved file is accepted on the next run" 0 $?

    # (e, h) DI = y shows DA; --configure-only never runs brew for Docker.
    DRIVE_BASE_PATH=$NODOCKER_PATH DRIVE_PATH="$PK/brewbin" drive a8e "Choose [1]: ${T}1" "auto-updates)? ${T}@ENTER" \
        "$G_ENTER" "power failure? [y/N]: ${T}y" "Install Colima and the Docker CLI with Homebrew? [y/N]: ${T}y" \
        "Currently off. [y/N]: ${T}y" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/a8e.env" MSS_DOCKER_JOB_PATH="$PK/job-none"
    check "A8e DI = y shows DA and saves both" "0 yes yes yes" \
        "$? $(saved a8e.env MSS_DOCKER_INSTALL) $(saved a8e.env MSS_DOCKER_AUTOSTART) $(saved a8e.env MSS_POWER_AUTORESTART)"
    check "A8h --configure-only never calls brew or colima" "" "$(grep -E '^(brew|colima)' "$PK/a8e.stublog")"
    check "A8e summary" "  gpu memory: system default (from the next boot)
  power restore: on (changed)
  docker install: Colima and the Docker CLI with Homebrew
  docker at boot: on (starts now if stopped)" "$(summary_of a8e)"

    # One tool missing: DI names only that tool.
    DRIVE_BASE_PATH=$NODOCKER_PATH DRIVE_PATH="$PK/brewbin" drive a8col "Choose [1]: ${T}1" "auto-updates)? ${T}@ENTER" \
        "$G_ENTER" "$P_ENTER" "Install Colima with Homebrew? [y/N]: ${T}y" "$DA_ENTER" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/a8col.env" MSS_DOCKER_JOB_PATH="$PK/job-docker"
    check "A8 docker present, colima missing: DI names Colima" 0 $?
    summary_of a8col | grep -qx '  docker install: Colima with Homebrew' && ok "A8 summary: Colima with Homebrew" || fail "A8 colima summary: $(summary_of a8col)"
    DRIVE_BASE_PATH=$NODOCKER_PATH DRIVE_PATH="$PK/brewbin" drive a8dock "Choose [1]: ${T}1" "auto-updates)? ${T}@ENTER" \
        "$G_ENTER" "$P_ENTER" "Install the Docker CLI with Homebrew? [y/N]: ${T}y" "$DA_ENTER" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/a8dock.env" MSS_DOCKER_JOB_PATH="$PK/job-colima"
    check "A8 colima present, docker missing: DI names the Docker CLI" 0 $?
    summary_of a8dock | grep -qx '  docker install: the Docker CLI with Homebrew' && ok "A8 summary: the Docker CLI with Homebrew" || fail "A8 docker summary: $(summary_of a8dock)"

    # A tool outside the job's PATH: neither Docker question, both keys dropped (D1).
    DRIVE_BASE_PATH=$NODOCKER_PATH DRIVE_PATH="$PK/elsewhere" drive a8out "Choose [1]: ${T}1" "auto-updates)? ${T}@ENTER" \
        "$G_ENTER" "$P_ENTER" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/a8out.env" MSS_DOCKER_JOB_PATH="$PK/job-none" MSS_DOCKER_AUTOSTART=yes
    check "A8 a tool outside the job PATH asks neither Docker question" 0 $?
    tr_of a8out | grep -q "^colima is at $PK/elsewhere/colima, outside the boot job's PATH; move or link it into /opt/homebrew/bin or /usr/local/bin" \
        && ok "A8 the skip line names the tool and path" || fail "A8 skip line: $(tr_of a8out | grep -i colima)"
    check "A8 neither Docker key is saved" "|" "$(saved a8out.env MSS_DOCKER_INSTALL)|$(saved a8out.env MSS_DOCKER_AUTOSTART)"

    # (g) a conflict between the environment and the file exits before the first prompt.
    envfile a8g.env 'MSS_BACKENDS=ollama\nOLLAMA_GPU_PERCENT=80\n'
    SHA_G=$(mss_shasum256 "$PK/a8g.env" | awk '{print $1}')
    drive a8g -- MSS_ENV_FILE="$PK/a8g.env" MSS_GPU_PERCENT=85
    check "A8g a legacy conflict exits 1" 1 $?
    tr_of a8g | grep -q 'MSS_GPU_PERCENT=85 (environment) and OLLAMA_GPU_PERCENT=80 (backends.env) differ; keep one' \
        && ok "A8g the message names both sources" || fail "A8g: $(tr_of a8g)"
    tr_of a8g | grep -q 'Choose' && fail "A8g a prompt was shown" || ok "A8g no prompt was shown"
    check "A8g the file is unchanged" "$SHA_G" "$(mss_shasum256 "$PK/a8g.env" | awk '{print $1}')"

    # (i) no iogpu key: the default is system even when 80 is set, and 80 is refused.
    drive a8i "Choose [1]: ${T}1" "auto-updates)? ${T}@ENTER" "or system [system]: ${T}80" "or system [system]: ${T}@ENTER" \
        "$P_ENTER" "$DA_ENTER" "Save? [Y/n]: ${T}@ENTER" -- MSS_ENV_FILE="$PK/a8i.env" MSS_GPU_PERCENT=80 MSS_SYSCTL_MODE=missing
    check "A8i no iogpu key: 80 refused, system saved" "0 system" "$? $(saved a8i.env MSS_GPU_PERCENT)"
    tr_of a8i | grep -q 'this Mac has no iogpu.wired_limit_mb; answer system' && ok "A8i the refusal names system" || fail "A8i refusal"

    # (j) the unchanged variants: an identical, loaded GPU job and Colima job
    # under the sysroot, autorestart already 1, and Docker already installed.
    S2=$PK/sysroot-s2; S2S=$PK/state-s2
    rm -rf "$S2" "$S2S"; mkdir -p "$S2/Library/LaunchDaemons" "$S2S"
    mss_gpu_render 80 104857 > "$S2/Library/LaunchDaemons/com.mac-studio-server.gpumemory.plist"
    sed "s|<OLLAMA_USER>|$(id -un)|g" "$ROOT/config/com.colima.daemon.plist" > "$S2/Library/LaunchDaemons/com.colima.daemon.plist"
    : > "$S2S/loaded-com.mac-studio-server.gpumemory"; : > "$S2S/loaded-com.colima.daemon"; echo 104857 > "$S2S/live"
    DRIVE_PATH="$PK/statebin" drive a8j "Choose [1]: ${T}1" "auto-updates)? ${T}@ENTER" "or system [80]: ${T}@ENTER" \
        "power failure? [Y/n]: ${T}@ENTER" "Currently on. [Y/n]: ${T}@ENTER" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/a8j.env" MSS_TEST_SYSROOT="$S2" MSS_STUB_STATE="$S2S" \
        MSS_PMSET="$ROOT/tests/stubs/pmset-autorestart-1" MSS_DOCKER_INSTALL=yes
    check "A8j the unchanged row completes" 0 $?
    check "A8j summary" "  gpu memory: 80% of RAM (unchanged)
  power restore: on (unchanged)
  docker install: already installed
  docker at boot: on (unchanged)" "$(summary_of a8j)"
    grep -Eq 'bootstrap|bootout|kickstart' "$S2S/calls.log" 2>/dev/null \
        && fail "A8j --configure-only touched launchd" || ok "A8j --configure-only made no launchd change"
    # The removal variants: a Colima job present and answered n, power 1 answered n, G system.
    S3=$PK/sysroot-s3; rm -rf "$S3"; mkdir -p "$S3/Library/LaunchDaemons"
    cp "$S2/Library/LaunchDaemons/com.colima.daemon.plist" "$S3/Library/LaunchDaemons/"
    drive a8j2 "Choose [1]: ${T}1" "auto-updates)? ${T}@ENTER" "or system [system]: ${T}system" \
        "power failure? [Y/n]: ${T}n" "Currently off. [Y/n]: ${T}n" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/a8j2.env" MSS_TEST_SYSROOT="$S3" MSS_PMSET="$ROOT/tests/stubs/pmset-autorestart-1"
    check "A8j the removal row completes" 0 $?
    check "A8j removal summary" "  gpu memory: system default (from the next boot)
  power restore: off (changed)
  docker install: no
  docker at boot: off (boot job removed; a running Colima keeps running)" "$(summary_of a8j2)"
    # Every D3 variant is matched exactly by at least one row. G always sets a
    # value, so the picker cannot reach "gpu memory: left as is"; that line is
    # checked through the shared summary function instead.
    ( MSS_TEST_SYSROOT=$PK/sysroot; export MSS_TEST_SYSROOT; mss_gpu_summary_line '' ) >> "$SUMMARY_SEEN" 2>&1
    for v in "gpu memory: 80% of RAM (unchanged)" "gpu memory: 80% of RAM (applied now and at every boot)" \
        "gpu memory: system default (from the next boot)" "gpu memory: left as is" \
        "power restore: on (unchanged)" "power restore: on (changed)" "power restore: off (unchanged)" "power restore: off (changed)" \
        "docker install: Colima and the Docker CLI with Homebrew" "docker install: Colima with Homebrew" \
        "docker install: the Docker CLI with Homebrew" "docker install: already installed" "docker install: no" \
        "docker at boot: on (unchanged)" "docker at boot: on (starts now if stopped)" \
        "docker at boot: off (boot job removed; a running Colima keeps running)" "docker at boot: off (unchanged)" \
        "docker at boot: left as is"; do
        grep -qxF "  $v" "$SUMMARY_SEEN" && ok "A8j variant seen: $v" || fail "A8j variant never produced: $v"
    done

    # S4: prompt lines stay within 100 characters.
    LONG=$(cat "$PK"/found.transcript "$PK"/ds4menu.transcript "$PK"/tweaks.transcript | tr -d '\r' \
        | sed -n 's/^\(.*\]: \).*/\1/p' | awk 'length($0) > 100')
    [ -z "$LONG" ] && ok "prompts ≤ 100 characters (S4)" || fail "long prompt: $LONG"

    # Every saved binary is one these tests made, never one found on the host (#21).
    PKBIN=$(grep -h '^[A-Z0-9_]*_BIN=' "$PK"/*.env 2>/dev/null)
    BADBIN=$(printf '%s\n' "$PKBIN" | awk -v t="$TMP/" -v p="$PTMP/" 'NF { v = substr($0, index($0, "=") + 1)
        if (index(v, t) != 1 && index(v, p) != 1) print }')
    [ -n "$PKBIN" ] && [ -z "$BADBIN" ] && ok "the picker saved only test binaries (#21)" \
        || fail "picker binaries outside the test directory: ${BADBIN:-no *_BIN line saved}"
fi

echo "== phase A: an installed Mac and the hashing locale (#21) =="
# D7 against a fixture conf: MSS_CONF decides in a non-root pass.
printf 'MSS_GUARD_BACKEND=ds4\n' > "$TMP/installed-ds4.conf"
OUT=$(render llamacpp "$TMP/d7-render" MSS_CONF="$TMP/installed-ds4.conf" 2>&1) && fail "D7 rendered llama.cpp over an installed ds4" \
    || { printf '%s' "$OUT" | grep -q "installed optional backend is 'ds4'" && ok "D7 reads MSS_CONF without root" || fail "D7 with a fixture conf: $OUT"; }
OUT=$(env MSS_BACKENDS=llamacpp OLLAMA_USER="$TUSER" MSS_CONF="$TMP/installed-ds4.conf" MSS_REPLACE_BACKEND=ds4 \
    LLAMACPP_BIN="$TMP/fix/llamacpp/llamacpp-server" LLAMACPP_MODEL="$TMP/fix/llamacpp/model.gguf" \
    LLAMACPP_MODEL_SHA256="$(cat "$TMP/fix/llamacpp/model.sha")" LLAMACPP_PORT=18998 \
    sh "$ROOT/scripts/install-backends.sh" --check-only 2>&1) && ok "the switch check replaces the fixture's ds4" \
    || fail "switch check with a fixture conf: $OUT"
OUT=$(env MSS_BACKENDS=ds4 OLLAMA_USER="$TUSER" MSS_CONF="$TMP/installed-ds4.conf" MSS_REPLACE_BACKEND=llamacpp \
    DS4_BIN="$TMP/fix/ds4/ds4-server" DS4_MODEL="$TMP/fix/ds4/model.gguf" DS4_MODEL_SHA256="$(cat "$TMP/fix/ds4/model.sha")" \
    DS4_PORT=18999 sh "$ROOT/scripts/install-backends.sh" --check-only 2>&1) && fail "replace of a backend the fixture does not have accepted" \
    || { printf '%s' "$OUT" | grep -q "('ds4')" && ok "a replace of a backend not in the fixture conf is refused" || fail "replace check: $OUT"; }
# The hash under a locale Perl cannot load, the first field against FIPS 180-2 "abc".
check "mss_shasum256 under C.UTF-8 gives the abc digest" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" \
    "$(printf abc | env LC_ALL=C.UTF-8 LANG=C.UTF-8 sh -c '. "$1/scripts/lib/mss-common.sh"; mss_shasum256' sh "$ROOT" | awk '{print $1}')"
OUT=$(env LC_ALL=C.UTF-8 LANG=C.UTF-8 MSS_BACKENDS=ds4 OLLAMA_USER="$TUSER" DS4_BIN="$TMP/fix/ds4/ds4-server" \
    DS4_MODEL="$TMP/fix/ds4/model.gguf" DS4_MODEL_SHA256="$(cat "$TMP/fix/ds4/model.sha")" DS4_PORT=18999 \
    sh "$ROOT/scripts/install-backends.sh" --check-only 2>&1) && printf '%s' "$OUT" | grep -q 'hashing ds4 model: done' \
    && ok "a ds4 --check-only under C.UTF-8 hashes the model" || fail "--check-only under C.UTF-8: $OUT"

echo "== phase A: live state and hash audit (#21) =="
if [ "$(uname)" = Darwin ]; then
    live_paths | live_snap > "$TMP/live.after"
    live_diff "$TMP/live.before" "$TMP/live.after" > "$TMP/live.diff"
    while IFS="$(printf '\t')" read -r _lp _lr; do
        [ "$_lr" = same ] && ok "live state unchanged: $_lp" || fail "live state changed: $_lp"
    done < "$TMP/live.diff"
    echo one > "$TMP/live-self"
    printf '%s\n' "$TMP/live-self" | live_snap > "$TMP/live-self.before"
    echo two >> "$TMP/live-self"
    printf '%s\n' "$TMP/live-self" | live_snap > "$TMP/live-self.after"
    check "the live-state guard reports a changed file (self-test)" "$(printf '%s\tchanged' "$TMP/live-self")" \
        "$(live_diff "$TMP/live-self.before" "$TMP/live-self.after")"
else
    echo "skip - the live-state guard needs macOS (BSD stat)"
fi
if [ "$AUDIT" = 1 ]; then
    NDD=$(awk '$1 == "dd" && $2 != "-"' "$AUDIT_LOG" | wc -l | tr -d ' ')
    NSHA=$(awk '$1 == "shasum" && $2 != "-"' "$AUDIT_LOG" | wc -l | tr -d ' ')
    BADH=$(audit_bad "$AUDIT_LOG")
    [ "$NDD" -ge 1 ] && [ "$NSHA" -ge 1 ] && [ -z "$BADH" ] \
        && ok "hash audit: $NDD dd and $NSHA shasum inputs, all under the test directory" \
        || fail "hash audit: $NDD dd, $NSHA shasum; outside the test directory: $BADH"
    printf 'dd /Users/example/models/x.gguf\n' > "$TMP/audit-self.log"
    check "the hash audit flags a model outside the test directory (self-test)" "dd /Users/example/models/x.gguf" \
        "$(audit_bad "$TMP/audit-self.log")"
fi
echo
echo "phase A: $PASS passed, $FAIL failed"
unset MSS_TEST_SYSROOT MSS_CONF
HOME=$SAVED_HOME; PATH=$SAVED_PATH; export HOME PATH
fi

if [ "$PHASE" = A ]; then
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
fi
if [ "${CI:-}" != true ] && [ "${MSS_TEST_ALLOW_SYSTEM:-}" != 1 ]; then
    echo "phase B skipped (set CI=true or MSS_TEST_ALLOW_SYSTEM=1 for system tests)"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
fi

echo "== phase B: system tests (stub servers, sudo launchd) =="
# These run only on macOS with sudo (CI=true). They bootstrap real launchd
# labels whose program is the fake-server stub, with a tiny fake GGUF whose
# sha256 is computed at test time. Model files are never committed.
SYST="$TMP/system"
mkdir -p "$SYST"
cp "$ROOT/tests/stubs/fake-server.sh" "$SYST/ds4-server"
chmod +x "$SYST/ds4-server"
printf 'fake-gguf-system-test' > "$SYST/model.gguf"
SYSSHA=$(mss_shasum256 "$SYST/model.gguf" | awk '{print $1}')

if sudo env MSS_BACKENDS=ds4 OLLAMA_USER="$(id -un)" \
    DS4_BIN="$SYST/ds4-server" DS4_MODEL="$SYST/model.gguf" DS4_MODEL_SHA256="$SYSSHA" \
    DS4_HOST=127.0.0.1 DS4_PORT=18000 \
    sh "$ROOT/scripts/install-backends.sh" >"$SYST/install.log" 2>&1; then
    ok "system install ds4"
else
    fail "system install ds4: $(tail -3 "$SYST/install.log")"
fi

sleep 2
if launchctl print system/com.mac-studio-server.ds4 >/dev/null 2>&1; then ok "ds4 label loaded"; else fail "ds4 label loaded"; fi
if launchctl print system/com.mac-studio-server.guard >/dev/null 2>&1; then ok "guard label loaded"; else fail "guard label loaded"; fi
if nc -z 127.0.0.1 18000 >/dev/null 2>&1; then ok "stub listening on 18000"; else fail "stub listening on 18000"; fi

STARTS=$(sudo grep -c 'START:' /var/log/mac-studio-server/ds4.log 2>/dev/null || echo 0)
[ "${STARTS:-0}" -ge 1 ] && ok "wrapper START logged" || fail "wrapper START logged"
STUB_ARGV=$(cat /tmp/mss-stub-argv 2>/dev/null | tail -1)
echo "$STUB_ARGV" | grep -q -- "-m $PTMP/system/model.gguf --host 127.0.0.1 --port 18000 --ctx 65536" \
    && ok "stub argv: resolved model path + contract flags" || fail "stub argv: $STUB_ARGV"
BS=$(mss_ds4_default_sessions "$(sysctl -n hw.memsize)")
echo "$STUB_ARGV" | grep -q -- "--ctx 65536 --batched-session $BS" \
    && ok "stub argv: default --batched-session $BS for this runner's RAM (#19)" || fail "stub argv batched session: $STUB_ARGV"

# Re-install while the backend is running: its own listener is not a conflict.
if sudo env MSS_BACKENDS=ds4 OLLAMA_USER="$(id -un)" \
    DS4_BIN="$SYST/ds4-server" DS4_MODEL="$SYST/model.gguf" DS4_MODEL_SHA256="$SYSSHA" \
    DS4_HOST=127.0.0.1 DS4_PORT=18000 \
    sh "$ROOT/scripts/install-backends.sh" >"$SYST/reinstall.log" 2>&1; then
    ok "re-install while running"
else
    fail "re-install while running: $(tail -3 "$SYST/reinstall.log")"
fi
grep -q 'stamp unchanged for ds4' "$SYST/reinstall.log" && ok "re-install skipped the re-hash" || fail "re-install re-hashed"
sleep 3

# simulate trip: bootout + root marker; enable recovers (A16 core)
if sudo "$ROOT/libexec/mss-guard.sh" --simulate-trip >/dev/null 2>&1; then ok "simulate-trip ran"; else fail "simulate-trip ran"; fi
sleep 1
[ -e /var/db/mac-studio-server/guard.tripped ] && ok "trip marker written" || fail "trip marker written"
sleep 2
if nc -z 127.0.0.1 18000 >/dev/null 2>&1; then fail "backend stayed down after trip"; else ok "backend down after trip"; fi
if sh "$ROOT/scripts/status.sh" >/dev/null 2>&1; then fail "status unhealthy after trip"; else ok "status unhealthy after trip"; fi
# a guard run with the backend stopped logs a pid:null sample, not sample_error
sudo /usr/local/libexec/mac-studio-server/mss-guard.sh >/dev/null 2>&1
LAST=$(tail -n 1 /var/log/mac-studio-server/guard.jsonl 2>/dev/null)
case $LAST in *'"event":"sample"'*'"pid":null'*) ok "stopped backend logs a pid:null sample" ;; *) fail "stopped backend sample: $LAST" ;; esac

if sudo /usr/local/libexec/mac-studio-server/mss-enable.sh >/dev/null 2>&1; then ok "mss-enable ran"; else fail "mss-enable ran"; fi
sleep 3
if nc -z 127.0.0.1 18000 >/dev/null 2>&1; then ok "backend back after enable"; else fail "backend back after enable"; fi

INODE_BEFORE=$(stat -f %i /var/log/mac-studio-server/ds4.log)
if sudo /usr/local/libexec/mac-studio-server/mss-guard.sh --rotate-now >/dev/null 2>&1; then ok "rotate-now ran"; else fail "rotate-now ran"; fi
[ -f /var/log/mac-studio-server/ds4.log.1 ] && ok "rotation produced .1" || fail "rotation produced .1"
sudo test -f /var/log/mac-studio-server/guard.jsonl.1 && ok "guard.jsonl rotated" || fail "guard.jsonl rotated"
check "live log keeps its inode" "$INODE_BEFORE" "$(stat -f %i /var/log/mac-studio-server/ds4.log)"

# uninstall --backend ds4 (A19), then --all twice (A20)
if sudo sh "$ROOT/scripts/uninstall.sh" --backend ds4 >/dev/null 2>&1; then ok "uninstall --backend ds4"; else fail "uninstall --backend ds4"; fi
launchctl print system/com.mac-studio-server.ds4 >/dev/null 2>&1 && fail "ds4 label gone" || ok "ds4 label gone"
if sudo sh "$ROOT/scripts/uninstall.sh" --all >/dev/null 2>&1; then ok "uninstall --all"; else fail "uninstall --all"; fi
if sudo sh "$ROOT/scripts/uninstall.sh" --all >/dev/null 2>&1; then ok "uninstall --all idempotent"; else fail "uninstall --all idempotent"; fi

echo "== phase B: install.sh modes, picker installs and switching (#12) =="
# install.sh's Ollama steps use $HOME/mac-studio-server (BASE_DIR) for its
# scripts and log directory, as on a real install.
[ -e "$HOME/mac-studio-server" ] || ln -s "$ROOT" "$HOME/mac-studio-server"
IS="$HOME/mac-studio-server/scripts/install.sh"
sudo install -m 0755 "$ROOT/tests/stubs/fake-ollama.sh" /usr/local/bin/ollama
PB="$TMP/pb"; mkdir -p "$PB"
T=$(printf '\t')
# The #27 host prompts this runner will show (G, then P, DI or DA as pmset and
# the Docker tools decide), each answered with its default. Every bdrive row
# that reaches the picker lists "$HS" right after the tweaks answer.
HS=$(sh "$ROOT/tests/expect/host-steps.sh")
for b in llamacpp ds4; do
    cp "$ROOT/tests/stubs/fake-server.sh" "$PB/$b-server"; chmod +x "$PB/$b-server"
    printf 'phase-b-model-%s' "$b" > "$PB/$b.gguf"
done
LLB="$PB/llamacpp-server"; LLM="$PB/llamacpp.gguf"; LLS=$(mss_shasum256 "$LLM" | awk '{print $1}')
DS4B="$PB/ds4-server"; DS4M="$PB/ds4.gguf"; DS4S=$(mss_shasum256 "$DS4M" | awk '{print $1}')
ZERO=$(printf '0%.0s' $(seq 64))
EFB="$PB/backends.env"
CONFB=/usr/local/etc/mac-studio-server/backends.conf
loaded() { launchctl print "system/$1" >/dev/null 2>&1; }
wait_listen() { _i=0; while [ "$_i" -lt 30 ]; do nc -z 127.0.0.1 "$1" >/dev/null 2>&1 && return 0; sleep 1; _i=$((_i + 1)); done; return 1; }
daemons() { ls /Library/LaunchDaemons | grep -E 'mac-studio-server|ollama' | sort | tr '\n' ' '; }
# bdrive <name> "<install.sh args>" <steps...> -- <env...>: install.sh on a pty, real sudo
bdrive() {
    _name=$1; _args=$2; shift 2
    : > "$PB/$_name.steps"
    while [ "$1" != -- ]; do printf '%s\n' "$1" >> "$PB/$_name.steps"; shift; done
    shift
    # shellcheck disable=SC2086  # _args is a word list
    env MSS_ENV_FILE="$EFB" OLLAMA_USER="$(id -un)" "$@" MSS_EXPECT_TIMEOUT=180 \
        expect "$ROOT/tests/expect/drive.exp" "$PB/$_name.steps" "$PB/$_name.transcript" /bin/bash "$IS" $_args \
        >/dev/null 2>"$PB/$_name.err"
    _rc=$?
    # 124/125 are the driver's own timeout / early exit: show where the dialogue stopped.
    if [ "$_rc" = 124 ] || [ "$_rc" = 125 ]; then
        echo "--- $_name: $(cat "$PB/$_name.err"); transcript tail:"
        tr -d '\r' < "$PB/$_name.transcript" | tail -n 12
    fi
    return "$_rc"
}
has() { grep -q -- "$2" "$PB/$1.transcript"; }

sudo sh "$ROOT/scripts/uninstall.sh" --all >/dev/null 2>&1

# A2: no terminal, MSS_BACKENDS unset, a poisoned backends.env: the 1.3.0 flow.
printf 'MSS_BACKENDS=ds4\nNOT_A_KEY=1\n' > "$PB/poison.env"; chmod 600 "$PB/poison.env"
MSS_ENV_FILE="$PB/poison.env" "$IS" </dev/null >"$PB/a2.log" 2>&1
grep -q 'Which backends' "$PB/a2.log" && fail "A2 prompted without a terminal" || ok "A2 no prompt without a terminal"
grep -Eq 'NOT_A_KEY|unknown key' "$PB/a2.log" && fail "A2 read the poisoned backends.env" || ok "A2 did not read backends.env"
loaded com.ollama.service && ok "A2 com.ollama.service loaded" || fail "A2 com.ollama.service not loaded"
wait_listen 11434 && curl -s http://127.0.0.1:11434/api/version | grep -q stub && ok "A2 stub ollama answers /api/version" || fail "A2 stub ollama unreachable"

# O1 (#27 manual step 2): Ollama only at /opt/homebrew/bin, as Homebrew installs
# it on Apple silicon, OLLAMA_BIN unset, env mode. The plist must run that
# binary, launchd must start it, and status.sh must exit 0.
if [ -e /opt/homebrew/bin/ollama ]; then
    echo "skip - O1 needs a runner without /opt/homebrew/bin/ollama"
else
    sudo mv /usr/local/bin/ollama "$PB/ollama.usrlocal"
    sudo mkdir -p /opt/homebrew/bin
    sudo install -m 0755 "$ROOT/tests/stubs/fake-ollama.sh" /opt/homebrew/bin/ollama
    MSS_BACKENDS=ollama MSS_TUNE_MACOS=no "$IS" </dev/null >"$PB/o1.log" 2>&1
    check "O1 env mode with a Homebrew-only Ollama exits 0" 0 $?
    grep -q '<string>/opt/homebrew/bin/ollama</string>' /Library/LaunchDaemons/com.ollama.service.plist \
        && ok "O1 com.ollama.service runs /opt/homebrew/bin/ollama" \
        || fail "O1 plist: $(grep -A1 ProgramArguments /Library/LaunchDaemons/com.ollama.service.plist | tail -n 1)"
    loaded com.ollama.service && ok "O1 com.ollama.service is loaded" || fail "O1 not loaded"
    wait_listen 11434 && curl -s http://127.0.0.1:11434/api/version | grep -q stub \
        && ok "O1 the Homebrew Ollama answers /api/version" || fail "O1 no /api/version"
    sh "$ROOT/scripts/status.sh" >"$PB/o1.status" 2>&1
    check "O1 status.sh exits 0" 0 $?
    # Back to the /usr/local/bin stub the rest of phase B expects, re-rendered.
    sudo rm -f /opt/homebrew/bin/ollama
    sudo mv "$PB/ollama.usrlocal" /usr/local/bin/ollama
    MSS_BACKENDS=ollama MSS_TUNE_MACOS=no "$IS" </dev/null >"$PB/o1b.log" 2>&1
    grep -q '<string>/usr/local/bin/ollama</string>' /Library/LaunchDaemons/com.ollama.service.plist \
        && ok "O1 /usr/local/bin/ollama wins again once it is back" || fail "O1 restore: $(tail -3 "$PB/o1b.log")"
fi

# A3: MSS_BACKENDS set, no flag, on a pty: no menu, conf as rendered.
bdrive a3 "" -- MSS_BACKENDS=ds4 DS4_BIN="$DS4B" DS4_MODEL="$DS4M" DS4_MODEL_SHA256="$DS4S" DS4_PORT=18000
check "A3 install with MSS_BACKENDS set on a pty" 0 $?
has a3 'Which backends' && fail "A3 showed the menu" || ok "A3 no menu with MSS_BACKENDS set"
env MSS_BACKENDS=ds4 OLLAMA_USER="$(id -un)" OLLAMA_BIND=0.0.0.0 DS4_BIN="$DS4B" DS4_MODEL="$DS4M" DS4_MODEL_SHA256="$DS4S" DS4_PORT=18000 \
    sh "$ROOT/scripts/install-backends.sh" --render-only "$PB/a3r" >/dev/null 2>&1
cmp -s "$CONFB" "$PB/a3r/backends.conf" && ok "A3 installed conf equals the render" || fail "A3 conf differs: $(diff "$CONFB" "$PB/a3r/backends.conf")"

# #21 on an installed Mac: ds4 is installed through install.sh, with its conf,
# stamp and plists, and a stub /usr/local/bin/ollama.
stamps() { for _sf in /var/db/mac-studio-server/*.model.verified; do printf '%s\n' "$_sf"; done | live_snap; }
stamps > "$PB/stamps.before"
OUT=$(sudo env MSS_TEST_SYSROOT="$TMP/x" MSS_BACKENDS=ds4 OLLAMA_USER="$(id -un)" DS4_BIN="$DS4B" DS4_MODEL="$DS4M" \
    DS4_MODEL_SHA256="$DS4S" DS4_PORT=18000 sh "$ROOT/scripts/install-backends.sh" --check-only 2>&1) \
    && fail "root accepted MSS_TEST_SYSROOT" \
    || { printf '%s' "$OUT" | grep -q MSS_TEST_SYSROOT && ok "root refuses MSS_TEST_SYSROOT (#21)" || fail "root with MSS_TEST_SYSROOT: $OUT"; }
stamps > "$PB/stamps.after"
cmp -s "$PB/stamps.before" "$PB/stamps.after" && ok "the refused root pass left the stamps alone (#21)" \
    || fail "stamps changed: $(diff "$PB/stamps.before" "$PB/stamps.after")"
OUT=$(sudo env MSS_CONF=/nonexistent MSS_BACKENDS=llamacpp OLLAMA_USER="$(id -un)" LLAMACPP_BIN="$LLB" LLAMACPP_MODEL="$LLM" \
    LLAMACPP_MODEL_SHA256="$LLS" LLAMACPP_PORT=18083 sh "$ROOT/scripts/install-backends.sh" --check-only 2>&1) \
    && fail "root honoured MSS_CONF and passed D7" \
    || { printf '%s' "$OUT" | grep -q "installed optional backend is 'ds4'" && ok "root ignores MSS_CONF: D7 still refuses (#21)" || fail "root with MSS_CONF: $OUT"; }
OUT=$(sudo env MSS_TEST_PHASE=A sh "$ROOT/tests/run.sh" 2>&1); RC=$?
check "phase A as root exits 2 (#21)" 2 "$RC"
printf '%s\n' "$OUT" | grep -q '^ok - ' && fail "phase A as root printed an ok line" || ok "phase A as root prints no ok line (#21)"
env LANG=C.UTF-8 LC_ALL=C.UTF-8 MSS_TEST_PHASE=A MSS_TEST_BIG_FILES= sh "$ROOT/tests/run.sh" >"$PB/phase-a-installed.log" 2>&1
RC=$?
SUM=$(grep '^phase A: [0-9]* passed, [0-9]* failed$' "$PB/phase-a-installed.log")
if [ "$RC" = 0 ] && printf '%s' "$SUM" | grep -q ', 0 failed$' && ! grep -Eq 'panic|Setting locale failed' "$PB/phase-a-installed.log"; then
    ok "phase A on an installed host under C.UTF-8: $SUM (#21)"
else
    fail "phase A on an installed host under C.UTF-8 (exit $RC): $(tail -n 20 "$PB/phase-a-installed.log")"
fi
sudo sh "$ROOT/scripts/uninstall.sh" --backend ds4 >/dev/null 2>&1

# A PATH without llama-server, so "nothing found" is deterministic on any runner.
PATH_NOLL=$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r d; do [ -x "$d/llama-server" ] || printf '%s:' "$d"; done)
PATH_NOLL=${PATH_NOLL%:}
LOGS="$HOME/mac-studio-server/logs"

# A5 / A1 / U2: first run on a pty with no backends.env, llama.cpp only. Nothing is found, the
# brew offer is declined, the path is asked, and the model is the user's own file.
rm -f "$EFB"
bdrive a5ll "" "Choose [1]: ${T}4" "brew install llama.cpp)? [y/N]: ${T}n" "binary path: ${T}$LLB" "later [1]: ${T}3" \
    "path or https URL: ${T}$LLM" "[Y/n]: ${T}@ENTER" "[Y/n]: ${T}@ENTER" "LAN access to llamacpp? [y/N]: ${T}@ENTER" \
    "auto-updates)? ${T}n" "$HS" "Install with these settings? [Y/n]: ${T}@ENTER" -- LLAMACPP_PORT=18080 PATH="$PATH_NOLL"
check "A5 first-run picker install (llama.cpp only)" 0 $?
check "A5 backends.env mode and owner" "600 $(id -un)" "$(stat -f '%Lp %Su' "$EFB" 2>/dev/null)"
loaded com.mac-studio-server.llamacpp && loaded com.mac-studio-server.guard && ! loaded com.mac-studio-server.ds4 \
    && ok "A5 labels match llama.cpp only" || fail "A5 labels: $(daemons)"
wait_listen 18080 && ok "A5 llama.cpp stub listening" || fail "A5 llama.cpp stub not listening"
has a5ll '^manual: brew install llama.cpp' && ok "A1 declining brew prints the manual command" || fail "A1 manual command"
check "U2 exactly one hashing line across check and install" 1 "$(tr -d '\r' < "$PB/a5ll.transcript" | grep -c '^hashing llamacpp model')"
grep -q '^MSS_TUNE_MACOS=no$' "$EFB" && ok "A1 saved MSS_TUNE_MACOS=no" || fail "A1 MSS_TUNE_MACOS: $(cat "$EFB")"

# A6 / A5: re-run with the saved file: no prompts (the password is not asked with NOPASSWD
# sudo), same conf, no hash.
cp "$CONFB" "$PB/conf.a5"; SHA_A6=$(mss_shasum256 "$EFB" | awk '{print $1}')
bdrive a6 "" --
check "A6 re-run with saved backends.env" 0 $?
check "A2 loaded mode leaves backends.env's shasum unchanged" "$SHA_A6" "$(mss_shasum256 "$EFB" | awk '{print $1}')"
has a6 'Choose' && fail "A6 prompted" || ok "A6 zero prompts"
cmp -s "$CONFB" "$PB/conf.a5" && ok "A6 backends.conf byte-identical" || fail "A6 conf changed"
has a6 'hashing ' && fail "A6 re-hashed the model" || ok "A6 model not re-hashed"

# A7: edit one key in backends.env: only that conf line changes.
sed -i '' 's/^LLAMACPP_PORT=18080$/LLAMACPP_PORT=18081/' "$EFB"
bdrive a7 "" --
check "A7 re-run after editing LLAMACPP_PORT" 0 $?
has a7 'Choose' && fail "A7 prompted" || ok "A7 zero prompts"
check "A7 conf differs only in LLAMACPP_PORT" "<LLAMACPP_PORT=18080 >LLAMACPP_PORT=18081 " \
    "$(diff "$PB/conf.a5" "$CONFB" | sed -n 's/^\([<>]\) /\1/p' | tr '\n' ' ')"
wait_listen 18081 && ok "A7 llama.cpp moved to 18081" || fail "A7 not listening on 18081"

# A10c: --configure-only choosing ds4 while llama.cpp is installed. The ds4 build is declined.
BEFORE=$(daemons)
bdrive a10c "--configure-only" "Choose [4]: ${T}5" "in ~/ds4? [y/N]: ${T}n" "binary path: ${T}$DS4B" "later [4]: ${T}3" \
    "path or https URL: ${T}$DS4M" "[Y/n]: ${T}@ENTER" "[Y/n]: ${T}@ENTER" "LAN access to ds4? [y/N]: ${T}@ENTER" \
    "auto-updates)? ${T}@ENTER" "$HS" "Save? [Y/n]: ${T}@ENTER" -- DS4_PORT=18000
check "A10c --configure-only with another backend installed" 0 $?
has a10c 'Remove it first' && fail "A10c asked the switch question" || ok "A10c no switch question"
has a10c 'install.sh --configure will offer to replace it' && ok "A10c message names install.sh --configure" || fail "A10c message missing"
grep -q '^MSS_BACKENDS=ds4$' "$EFB" && ok "A10c saved MSS_BACKENDS=ds4" || fail "A10c saved: $(grep MSS_BACKENDS "$EFB")"
loaded com.mac-studio-server.llamacpp && ok "A10c llama.cpp still loaded" || fail "A10c llama.cpp gone"
check "A10c /Library/LaunchDaemons unchanged" "$BEFORE" "$(daemons)"
[ -e "$HOME/ds4" ] && fail "A10c the declined build created ~/ds4" || ok "A10c the declined build created nothing"

# A9: --configure switch to ds4, answer n.
BEFORE=$(daemons); cp "$CONFB" "$PB/conf.a9"
bdrive a9 "--configure" "Choose [4]: ${T}5" "(.gguf) path [$DS4M]: ${T}@ENTER" "c computes it now) [$DS4S]: ${T}@ENTER" \
    "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" "$HS" \
    "Install with these settings? [Y/n]: ${T}@ENTER" "--backend llamacpp? [y/N]: ${T}n" --
check "A9 declining the switch exits 1" 1 $?
has a9 'binary path' && fail "A9 asked for a saved binary (I7)" || ok "A9 a saved binary is not asked (I7)"
loaded com.mac-studio-server.llamacpp && wait_listen 18081 && ok "A9 llama.cpp still running" || fail "A9 llama.cpp not running"
check "A9 /Library/LaunchDaemons unchanged" "$BEFORE" "$(daemons)"
cmp -s "$CONFB" "$PB/conf.a9" && ok "A9 backends.conf unchanged" || fail "A9 conf changed"

# A10 / A9 (sha): switch with a wrong ds4 sha256, answer y: stops at the check with exit 1.
bdrive a10 "--configure" "Choose [4]: ${T}5" "(.gguf) path [$DS4M]: ${T}@ENTER" "c computes it now) [$DS4S]: ${T}$ZERO" \
    "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" "$HS" \
    "Install with these settings? [Y/n]: ${T}@ENTER" "--backend llamacpp? [y/N]: ${T}y" --
check "A10 wrong sha stops the switch with exit 1" 1 $?
has a10 'sha256 mismatch' && ok "A10 failed at the check" || fail "A10 did not fail at the check"
has a10 'Removing llamacpp' && fail "A10 ran uninstall" || ok "A10 uninstall never ran"
[ -e "$DS4M" ] && [ ! -e "$DS4M.sha-mismatch" ] && ok "A10 a model not downloaded in this run is never renamed" || fail "A10 renamed the user's model"
loaded com.mac-studio-server.llamacpp && wait_listen 18081 && ok "A10 llama.cpp still running" || fail "A10 llama.cpp not running"

# A10b / F7 (switch): a foreign listener on ds4's port stops the switch at the root check.
nc -l 127.0.0.1 18000 >/dev/null 2>&1 &
NCPID=$!
sleep 1
bdrive a10b "--configure" "Choose [4]: ${T}5" "(.gguf) path [$DS4M]: ${T}@ENTER" "c computes it now) [$ZERO]: ${T}$DS4S" \
    "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" "$HS" \
    "Install with these settings? [Y/n]: ${T}@ENTER" "--backend llamacpp? [y/N]: ${T}y" --
check "A10b foreign listener stops the switch with exit 1" 1 $?
has a10b "port 18000 is in use (pid $NCPID); set DS4_PORT in backends.env and re-run" && ok "A10b names the pid and the variable (I6)" \
    || fail "A10b: $(grep -i 'in use' "$PB/a10b.transcript")"
has a10b 'Removing llamacpp' && fail "A10b ran uninstall" || ok "A10b uninstall never ran"
loaded com.mac-studio-server.llamacpp && ok "A10b llama.cpp still loaded" || fail "A10b llama.cpp gone"
kill "$NCPID" 2>/dev/null; wait "$NCPID" 2>/dev/null

# A8: switch llama.cpp -> ds4, answer y.
bdrive a8 "--configure" "Choose [4]: ${T}5" "(.gguf) path [$DS4M]: ${T}@ENTER" "c computes it now) [$DS4S]: ${T}@ENTER" \
    "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" "$HS" \
    "Install with these settings? [Y/n]: ${T}@ENTER" "--backend llamacpp? [y/N]: ${T}y" --
check "A8 switch llama.cpp -> ds4" 0 $?
loaded com.mac-studio-server.ds4 && loaded com.mac-studio-server.guard && ! loaded com.mac-studio-server.llamacpp \
    && ok "A8 only ds4 and guard loaded" || fail "A8 labels: $(daemons)"
[ ! -e /Library/LaunchDaemons/com.mac-studio-server.llamacpp.plist ] && [ ! -e /var/db/mac-studio-server/llamacpp.model.verified ] \
    && ok "A8 llama.cpp plist and stamp gone" || fail "A8 llama.cpp leftovers"
wait_listen 18000 && ok "A8 ds4 listening" || fail "A8 ds4 not listening"

# A5 / F3: ollama + ds4 (same optional backend: no switch), headless tweaks answered y.
touch "$PB/f3.marker"; sleep 1
bdrive a5o3 "--configure" "Choose [5]: ${T}3" "(.gguf) path [$DS4M]: ${T}@ENTER" "c computes it now) [$DS4S]: ${T}@ENTER" \
    "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}y" "$HS" \
    "Install with these settings? [Y/n]: ${T}@ENTER" "(starter) 2) later [1]: ${T}2" --
check "A5 ollama + ds4" 0 $?
loaded com.ollama.service && loaded com.mac-studio-server.ds4 && ok "A5 ollama + ds4 labels" || fail "A5 option 3 labels: $(daemons)"
[ "$LOGS/optimization.log" -nt "$PB/f3.marker" ] && ok "F3 tweaks answered y run the optimizer" || fail "F3 optimization.log not written"
pmset -g custom 2>/dev/null | grep -Eq '^[[:space:]]*sleep[[:space:]]+0$' && ok "F3 pmset shows sleep 0" || fail "F3 pmset: $(pmset -g custom | grep -w sleep)"
has a5o3 '^later: ollama pull qwen3:4b' && ok "M5 declining the Ollama starter prints the pull command" || fail "M5 no pull command"

# A5 / F2: ollama + llama.cpp (switch ds4 -> llama.cpp), tweaks answered N: nothing it covers changes.
snap() { pmset -g custom 2>/dev/null; mdutil -s / 2>/dev/null; tmutil destinationinfo 2>/dev/null
    defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled 2>/dev/null; }
snap > "$PB/f2.before"; touch "$PB/f2.marker"; sleep 1
bdrive a5o2 "--configure" "Choose [3]: ${T}2" "(.gguf) path [$LLM]: ${T}@ENTER" "c computes it now) [$LLS]: ${T}@ENTER" \
    "LAN access to llamacpp? [y/N]: ${T}@ENTER" "auto-updates)? ${T}n" "$HS" \
    "Install with these settings? [Y/n]: ${T}@ENTER" "--backend ds4? [y/N]: ${T}y" "(starter) 2) later [1]: ${T}2" --
check "A5 ollama + llama.cpp" 0 $?
loaded com.ollama.service && loaded com.mac-studio-server.llamacpp && ! loaded com.mac-studio-server.ds4 \
    && ok "A5 ollama + llama.cpp labels" || fail "A5 option 2 labels: $(daemons)"
snap > "$PB/f2.after"
cmp -s "$PB/f2.before" "$PB/f2.after" && ok "F2 pmset, mdutil, tmutil and update settings unchanged" || fail "F2 settings changed"
[ "$LOGS/optimization.log" -nt "$PB/f2.marker" ] && fail "F2 the optimizer ran" || ok "F2 optimization.log not written"

# A5: ollama only (removes llama.cpp; no check to run).
bdrive a5o1 "--configure" "Choose [2]: ${T}1" "auto-updates)? ${T}n" "$HS" "Install with these settings? [Y/n]: ${T}@ENTER" \
    "--backend llamacpp? [y/N]: ${T}y" "(starter) 2) later [1]: ${T}2" --
check "A5 ollama only" 0 $?
loaded com.ollama.service && ! loaded com.mac-studio-server.llamacpp && ! loaded com.mac-studio-server.guard \
    && ok "A5 ollama-only labels" || fail "A5 option 1 labels: $(daemons)"

# A5: MSS_BACKENDS set in the environment, --configure choosing ds4 only.
bdrive a5env "--configure" "Choose [4]: ${T}5" "(.gguf) path [$DS4M]: ${T}@ENTER" "c computes it now) [$DS4S]: ${T}@ENTER" \
    "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}n" "$HS" \
    "Install with these settings? [Y/n]: ${T}@ENTER" -- MSS_BACKENDS=llamacpp
check "A5 --configure overrides MSS_BACKENDS from the environment" 0 $?
loaded com.mac-studio-server.ds4 && ! loaded com.mac-studio-server.llamacpp && ok "A5 env run installed ds4" || fail "A5 env run labels: $(daemons)"
grep -q '^MSS_BACKENDS=ds4$' "$EFB" && ok "A5 env run saved MSS_BACKENDS=ds4" || fail "A5 env run saved: $(grep MSS_BACKENDS "$EFB")"

# A11: a backends.env owned by someone else is refused.
sudo chown root "$EFB"
bdrive a11 "" --
check "A11 backends.env owned by root is refused" 1 $?
has a11 'not by you' && ok "A11 names the owner check" || fail "A11: $(tail -3 "$PB/a11.transcript")"
sudo chown "$(id -un)" "$EFB"

# A14: interactive modes refuse root.
env MSS_ENV_FILE="$EFB" expect "$ROOT/tests/expect/drive.exp" /dev/null "$PB/a14.transcript" sudo /bin/bash "$IS" --configure >/dev/null 2>&1
check "A14 sudo install.sh --configure exits 1" 1 $?
grep -q 'run install.sh as your user' "$PB/a14.transcript" && ok "A14 says run as your user" || fail "A14: $(cat "$PB/a14.transcript")"

# A15: MSS_REPLACE_BACKEND is refused outside --check-only.
OUT=$(sudo env MSS_BACKENDS=ds4 OLLAMA_USER="$(id -un)" MSS_REPLACE_BACKEND=ds4 DS4_BIN="$DS4B" DS4_MODEL="$DS4M" \
    DS4_MODEL_SHA256="$DS4S" DS4_PORT=18000 sh "$ROOT/scripts/install-backends.sh" 2>&1) \
    && fail "A15 full install accepted MSS_REPLACE_BACKEND" \
    || { printf '%s' "$OUT" | grep -q 'only with --check-only' && ok "A15 full install refuses MSS_REPLACE_BACKEND" || fail "A15: $OUT"; }

echo "== phase B: 1.5.0 model later, model.sh, stamp and prompts (#15) =="
# M1: llama.cpp with a model later: the conf says waiting and no backend or guard job exists.
EFM="$PB/m.env"
bdrive m1 "--configure" "Choose [5]: ${T}4" "brew install llama.cpp)? [y/N]: ${T}n" "binary path: ${T}$LLB" "later [1]: ${T}4" \
    "LAN access to llamacpp? [y/N]: ${T}@ENTER" "auto-updates)? ${T}n" "$HS" \
    "Install with these settings? [Y/n]: ${T}@ENTER" "--backend ds4? [y/N]: ${T}y" -- \
    MSS_ENV_FILE="$EFM" LLAMACPP_PORT=18082 PATH="$PATH_NOLL"
check "M1 install with a model later" 0 $?
! loaded com.mac-studio-server.llamacpp && ! loaded com.mac-studio-server.guard \
    && [ ! -e /Library/LaunchDaemons/com.mac-studio-server.llamacpp.plist ] && [ ! -e /Library/LaunchDaemons/com.mac-studio-server.guard.plist ] \
    && ok "M1 no llama.cpp or guard plist or label" || fail "M1 labels: $(daemons)"
grep -qx 'MSS_MODEL_STATE=waiting' "$CONFB" && grep -qx 'MSS_GUARD_BACKEND=llamacpp' "$CONFB" \
    && ok "M1 conf says waiting and keeps MSS_GUARD_BACKEND" || fail "M1 conf: $(cat "$CONFB")"
OUT=$(sh "$ROOT/scripts/status.sh" 2>&1); RC=$?
printf '%s' "$OUT" | grep -qx 'llamacpp: waiting for a model (run scripts/model.sh)' && ok "M1 status prints the waiting line" || fail "M1 status: $OUT"
check "M1 status exits 0 with the backend waiting" 0 "$RC"

# M7: model.sh without a terminal changes nothing, even with a waiting backend and Ollama loaded.
cp "$EFM" "$PB/m7.env"; cp "$CONFB" "$PB/m7.conf"
OLLPID() { launchctl print system/com.ollama.service 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9]*\).*/\1/p' | head -n 1; }
P0=$(OLLPID)
MSS_ENV_FILE="$EFM" "$ROOT/scripts/model.sh" --catalog stories260k </dev/null >/dev/null 2>&1
check "M7 model.sh without a terminal exits 2" 2 $?
cmp -s "$EFM" "$PB/m7.env" && cmp -s "$CONFB" "$PB/m7.conf" && [ ! -e "$HOME/models/stories260K.gguf.part" ] \
    && ok "M7 backends.env, conf and models unchanged" || fail "M7 changed something"
check "M7 Ollama PID unchanged" "$P0" "$(OLLPID)"

# M2 / M9: model.sh --catalog downloads, hashes once as root, and loads the backend and guard,
# never touching Ollama.
env MSS_ENV_FILE="$EFM" OLLAMA_USER="$(id -un)" MSS_EXPECT_TIMEOUT=300 \
    expect "$ROOT/tests/expect/drive.exp" /dev/null "$PB/m2.transcript" /bin/bash "$ROOT/scripts/model.sh" --catalog stories260k \
    >/dev/null 2>"$PB/m2.err"
check "M2 model.sh --catalog stories260k" 0 $?
check "M2 exactly one hashing line" 1 "$(tr -d '\r' < "$PB/m2.transcript" | grep -c '^hashing llamacpp model')"
loaded com.mac-studio-server.llamacpp && loaded com.mac-studio-server.guard && ok "M2 backend and guard loaded" || fail "M2 labels: $(daemons)"
grep -q MSS_DEFER_MODEL "$EFM" && fail "M2 MSS_DEFER_MODEL still saved" || ok "M2 MSS_DEFER_MODEL removed"
wait_listen 18082 && sh "$ROOT/scripts/status.sh" >/dev/null 2>&1 && ok "M2 status healthy" || fail "M2 status: $(sh "$ROOT/scripts/status.sh" 2>&1)"
check "M9 Ollama PID unchanged by model.sh" "$P0" "$(OLLPID)"

# M3: switch to another model by path: one hash, the new -m, the old file untouched.
OLDM="$HOME/models/stories260K.gguf"; OLDT=$(stat -f %m "$OLDM" 2>/dev/null)
printf 'phase-b-other-model' > "$PB/other.gguf"; OTHS=$(mss_shasum256 "$PB/other.gguf" | awk '{print $1}')
env MSS_ENV_FILE="$EFM" OLLAMA_USER="$(id -un)" MSS_EXPECT_TIMEOUT=180 \
    expect "$ROOT/tests/expect/drive.exp" /dev/null "$PB/m3.transcript" /bin/bash "$ROOT/scripts/model.sh" \
    --path "$PB/other.gguf" --sha256 "$OTHS" >/dev/null 2>"$PB/m3.err"
check "M3 model.sh --path" 0 $?
check "M3 exactly one hashing line" 1 "$(tr -d '\r' < "$PB/m3.transcript" | grep -c '^hashing llamacpp model')"
sleep 3
tail -n 1 /tmp/mss-stub-argv | grep -q -- "-m $(cd "$PB" && pwd -P)/other.gguf" && ok "M3 the backend runs the new model" \
    || fail "M3 argv: $(tail -n 1 /tmp/mss-stub-argv)"
check "M3 the old model's mtime is unchanged" "$OLDT" "$(stat -f %m "$OLDM" 2>/dev/null)"
check "M9 Ollama PID unchanged after a switch" "$P0" "$(OLLPID)"

# M8(b) / M3: a deferred re-install removes the backend and guard jobs; uninstall of a waiting
# backend removes its conf and exits 0.
sudo env MSS_BACKENDS=llamacpp OLLAMA_USER="$(id -un)" MSS_DEFER_MODEL=yes LLAMACPP_BIN="$LLB" LLAMACPP_PORT=18082 \
    sh "$ROOT/scripts/install-backends.sh" >"$PB/m8.log" 2>&1
check "M8 deferred re-install" 0 $?
! loaded com.mac-studio-server.llamacpp && ! loaded com.mac-studio-server.guard && ok "M8 deferred re-install unloads the backend and guard" \
    || fail "M8 labels: $(daemons)"
sudo sh "$ROOT/scripts/uninstall.sh" --backend llamacpp >/dev/null 2>&1
check "M8 uninstall of a waiting backend exits 0" 0 $?
[ ! -e "$CONFB" ] && ok "M8 conf removed" || fail "M8 conf left: $(cat "$CONFB")"

# A18: a root --check-only writes only the stamp (and its directory).
printf 'phase-b-a18-model' > "$PB/a18.gguf"; A18S=$(mss_shasum256 "$PB/a18.gguf" | awk '{print $1}')
sudo rm -f /var/db/mac-studio-server/ds4.model.verified
touch "$PB/a18.marker"; sleep 1
sudo env MSS_BACKENDS=ds4 OLLAMA_USER="$(id -un)" DS4_BIN="$DS4B" DS4_MODEL="$PB/a18.gguf" DS4_MODEL_SHA256="$A18S" DS4_PORT=18000 \
    sh "$ROOT/scripts/install-backends.sh" --check-only >"$PB/a18.log" 2>&1
check "A18 root --check-only" 0 $?
NEW=$(sudo find /var/db/mac-studio-server /usr/local/etc/mac-studio-server /usr/local/libexec/mac-studio-server /Library/LaunchDaemons \
    -newer "$PB/a18.marker" 2>/dev/null | sort | tr '\n' ' ')
check "A18 only the stamp directory and the stamp are new" "/var/db/mac-studio-server /var/db/mac-studio-server/ds4.model.verified " "$NEW"
check "A18 stamp root:wheel 0644" "root:wheel 644" "$(stat -f '%Su:%Sg %Lp' /var/db/mac-studio-server/ds4.model.verified 2>/dev/null)"
check "A18 directory root:wheel 755" "root:wheel 755" "$(stat -f '%Su:%Sg %Lp' /var/db/mac-studio-server 2>/dev/null)"

# F7: a foreign listener on llama.cpp's default port refuses at the check, before any change.
nc -l 127.0.0.1 8080 >/dev/null 2>&1 &
NCPID=$!
sleep 1; BEFORE=$(daemons)
bdrive f7 "--configure" "Choose [1]: ${T}4" "later [1]: ${T}3" "path or https URL: ${T}$LLM" "[Y/n]: ${T}@ENTER" "[Y/n]: ${T}@ENTER" \
    "LAN access to llamacpp? [y/N]: ${T}@ENTER" "auto-updates)? ${T}n" "$HS" "Install with these settings? [Y/n]: ${T}@ENTER" -- \
    MSS_ENV_FILE="$PB/f7.env" LLAMACPP_BIN="$LLB"
check "F7 a busy default port exits 1" 1 $?
has f7 "port 8080 is in use (pid $NCPID); set LLAMACPP_PORT in backends.env and re-run" && ok "F7 names the pid, LLAMACPP_PORT and backends.env" \
    || fail "F7: $(grep -i 'in use' "$PB/f7.transcript")"
has f7 'Port' && fail "F7 showed a port prompt" || ok "F7 no port prompt"
check "F7 /Library/LaunchDaemons unchanged" "$BEFORE" "$(daemons)"
kill "$NCPID" 2>/dev/null; wait "$NCPID" 2>/dev/null

# F4: non-interactive Ollama with MSS_TUNE_MACOS=no skips the optimizer; unset ran it (A2).
touch "$PB/f4.marker"; sleep 1
MSS_BACKENDS=ollama MSS_TUNE_MACOS=no "$IS" </dev/null >"$PB/f4.log" 2>&1
check "F4 non-interactive with MSS_TUNE_MACOS=no" 0 $?
[ "$LOGS/optimization.log" -nt "$PB/f4.marker" ] && fail "F4 the optimizer ran" || ok "F4 MSS_TUNE_MACOS=no skips the optimizer"

# U1 / U4: one sudo -v, before every other sudo call; the keep-alive is gone after the run.
mkdir -p "$PB/shim"
printf '#!/bin/sh\necho "$(date +%%s) $*" >> "%s/sudo.log"\nexec /usr/bin/sudo "$@"\n' "$PB" > "$PB/shim/sudo"; chmod +x "$PB/shim/sudo"
: > "$PB/sudo.log"
bdrive u1 "" -- PATH="$PB/shim:$PATH"
check "U1 loaded-mode run through the sudo shim" 0 $?
check "U1 exactly one sudo -v" 1 "$(grep -c ' -v -p ' "$PB/sudo.log")"
head -n 1 "$PB/sudo.log" | grep -q ' -v -p \[sudo\] password (asked once): ' && ok "U1 sudo -v comes first" \
    || fail "U1 first sudo call: $(head -n 1 "$PB/sudo.log")"
sleep 60
pgrep -f 'sudo -n true' >/dev/null && fail "U4 the keep-alive is still running" || ok "U4 no keep-alive 60 s after the run"

echo "== phase B: re-install and enable while the backend is stopping (#18) =="
# On TERM the stub sleeps for the seconds in $DELAY, like ds4 releasing a large
# model. launchd keeps the label until the job has exited. Each test deletes its
# /tmp/mss-stub-* flags at its start and at its end.
DELAY=/tmp/mss-stub-term-delay
RB="$TMP/stopping"; mkdir -p "$RB"
jobpid() { launchctl print "system/$1" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -n 1; }
# wait_newpid <label> <old pid> <seconds>: prints the job's PID once it has one other than old.
wait_newpid() {
    _i=0
    while [ "$_i" -lt "$3" ]; do
        _wp=$(jobpid "$1"); [ -n "$_wp" ] && [ "$_wp" != "$2" ] && { echo "$_wp"; return 0; }
        sleep 1; _i=$((_i + 1))
    done
    return 1
}
# rbinstall <log> [env...]: ds4 on loopback 18000, output to log.
rbinstall() {
    _log=$1; shift
    sudo env MSS_BACKENDS=ds4 OLLAMA_USER="$(id -un)" DS4_BIN="$DS4B" DS4_MODEL="$DS4M" DS4_MODEL_SHA256="$DS4S" \
        DS4_HOST=127.0.0.1 DS4_PORT=18000 "$@" sh "$ROOT/scripts/install-backends.sh" >"$_log" 2>&1
}
sudo sh "$ROOT/scripts/uninstall.sh" --all >/dev/null 2>&1
rm -f "$DELAY"
rbinstall "$RB/setup.log" && wait_listen 18000 && ok "loopback ds4 running on 18000" || fail "ds4 setup: $(tail -3 "$RB/setup.log")"

# B1: re-install while ds4 takes 8 s to stop succeeds on the first run.
rm -f "$DELAY"; echo 8 > "$DELAY"
OLD=$(jobpid com.mac-studio-server.ds4)
if rbinstall "$RB/b1.log" DS4_BATCHED_SESSIONS=3; then ok "B1 re-install while ds4 is stopping exits 0 on the first run"
else fail "B1 re-install while ds4 is stopping: $(tail -3 "$RB/b1.log")"; fi
grep -q 'waiting for com.mac-studio-server.ds4 to stop' "$RB/b1.log" && grep -q 'com.mac-studio-server.ds4 stopped' "$RB/b1.log" \
    && ok "B1 the installer waited for ds4 to stop" || fail "B1 no wait logged: $(grep -i ds4 "$RB/b1.log" | tail -3)"
NEW=$(wait_newpid com.mac-studio-server.ds4 "$OLD" 30)
[ -n "$NEW" ] && ok "B1 ds4 runs as a new pid ($OLD -> $NEW)" || fail "B1 no new ds4 pid (old $OLD)"
wait_listen 18000 >/dev/null
tail -n 1 /tmp/mss-stub-argv | grep -q -- '--batched-session 3' && ok "B1 the new argv has --batched-session 3" \
    || fail "B1 argv: $(tail -n 1 /tmp/mss-stub-argv)"
rm -f "$DELAY"

# B5: a trip, then mss-enable at once while ds4 takes 8 s to stop.
rm -f "$DELAY"; wait_listen 18000 >/dev/null; echo 8 > "$DELAY"
OLD=$(jobpid com.mac-studio-server.ds4)
sudo "$ROOT/libexec/mss-guard.sh" --simulate-trip >/dev/null 2>&1
if sudo /usr/local/libexec/mac-studio-server/mss-enable.sh >"$RB/b5.log" 2>&1; then ok "B5 mss-enable right after a trip exits 0"
else fail "B5 mss-enable right after a trip: $(tail -3 "$RB/b5.log")"; fi
wait_newpid com.mac-studio-server.ds4 "$OLD" 10 >/dev/null && ok "B5 ds4 has a new pid within 10 s" || fail "B5 no new ds4 pid within 10 s (old $OLD)"
[ ! -e /var/db/mac-studio-server/guard.tripped ] && ok "B5 guard.tripped removed" || fail "B5 guard.tripped still present"
rm -f "$DELAY"

# B2: ds4 takes 30 s to stop and the installer waits 3 s: it stops before starting
# anything, and a re-install succeeds once the old job has gone.
rm -f "$DELAY"; wait_listen 18000 >/dev/null; echo 30 > "$DELAY"
rbinstall "$RB/b2.log" MSS_LAUNCHD_TIMEOUT=3 && fail "B2 a 3 s timeout accepted a backend that was still stopping" \
    || { grep -q 'com.mac-studio-server.ds4 did not stop within 3s' "$RB/b2.log" && ok "B2 the install stops and names ds4 and 3s" \
        || fail "B2: $(tail -3 "$RB/b2.log")"; }
_i=0; while loaded com.mac-studio-server.ds4 && [ "$_i" -lt 45 ]; do sleep 1; _i=$((_i + 1)); done
! loaded com.mac-studio-server.ds4 && ! loaded com.mac-studio-server.guard \
    && ok "B2 neither ds4 nor guard is loaded after the old job exits" || fail "B2 ds4 or guard is loaded after the timeout"
rm -f "$DELAY"
rbinstall "$RB/b2-again.log" && loaded com.mac-studio-server.ds4 && ok "B2 a re-install after the old job exits succeeds" \
    || fail "B2 re-install: $(tail -3 "$RB/b2-again.log")"

# B3: ds4 on a LAN address with an allowlist. pf goes through a copy of the
# pfctl-ok stub, so the runner's pf is never changed. In each run the boot job
# verifies pf before ds4 is bootstrapped, and the marker is this run's.
MARKER=/var/run/com.mac-studio-server.boot.ok
PFSTUB="$RB/pfctl-ok"; cp "$ROOT/tests/stubs/pfctl-ok" "$PFSTUB"; chmod 0755 "$PFSTUB"
# laninstall <log> [env...]
laninstall() {
    _log=$1; shift
    sudo env MSS_BACKENDS=ds4 OLLAMA_USER="$(id -un)" DS4_BIN="$DS4B" DS4_MODEL="$DS4M" DS4_MODEL_SHA256="$DS4S" \
        DS4_HOST=192.0.2.10 DS4_ALLOW_FROM=192.0.2.99 DS4_PORT=18001 \
        MSS_IFCONFIG="$ROOT/tests/stubs/ifconfig-lan" MSS_PFCTL="$PFSTUB" "$@" \
        sh "$ROOT/scripts/install-backends.sh" >"$_log" 2>&1
}
# precedes <log> <first> <second>: the first line matching <first> comes before
# the first line matching <second>.
precedes() {
    _pa=$(grep -n -- "$2" "$1" | head -n 1 | cut -d: -f1)
    _pb=$(grep -n -- "$3" "$1" | head -n 1 | cut -d: -f1)
    [ -n "$_pa" ] && [ -n "$_pb" ] && [ "$_pa" -lt "$_pb" ]
}
# The stub writes one argv line when it starts. wait_argv <count> waits up to
# 30 s for a line after <count>, so a test never reads the count while a job it
# just bootstrapped is still starting.
argv_lines() { cat /tmp/mss-stub-argv 2>/dev/null | wc -l | tr -d ' '; }
wait_argv() {
    _i=0
    while [ "$(argv_lines)" -le "$1" ] && [ "$_i" -lt 30 ]; do sleep 1; _i=$((_i + 1)); done
    [ "$(argv_lines)" -gt "$1" ]
}
PFV='pf verified by com.mac-studio-server.boot'
sudo rm -f "$DELAY" /tmp/mss-stub-pfctl-fail /tmp/mss-stub-pf.rules
sudo sh "$ROOT/scripts/uninstall.sh" --all >/dev/null 2>&1
N=$(argv_lines)
if laninstall "$RB/b3.log"; then ok "B3 LAN install"; else fail "B3 LAN install: $(tail -3 "$RB/b3.log")"; fi
precedes "$RB/b3.log" "$PFV" 'bootstrapped com.mac-studio-server.ds4' && ok "B3 install: pf verified before ds4 was bootstrapped" \
    || fail "B3 install order: $(grep -E 'pf verified|bootstrapped' "$RB/b3.log" | tr '\n' ' ')"
wait_argv "$N" && ok "B3 ds4 started after the install" || fail "B3 ds4 did not start after the install"
echo 5 > "$DELAY"
START=$(date +%s)
N=$(argv_lines)
if laninstall "$RB/b3-again.log"; then ok "B3 LAN re-install while ds4 takes 5 s to stop"; else fail "B3 LAN re-install: $(tail -3 "$RB/b3-again.log")"; fi
precedes "$RB/b3-again.log" 'com.mac-studio-server.ds4 stopped after' 'bootstrapped com.mac-studio-server.boot' \
    && ok "B3 re-install: the old ds4 stopped before boot was bootstrapped" \
    || fail "B3 re-install stop order: $(grep -E 'stopped after|bootstrapped' "$RB/b3-again.log" | tr '\n' ' ')"
precedes "$RB/b3-again.log" "$PFV" 'bootstrapped com.mac-studio-server.ds4' && ok "B3 re-install: pf verified before ds4 was bootstrapped" \
    || fail "B3 re-install order: $(grep -E 'pf verified|bootstrapped' "$RB/b3-again.log" | tr '\n' ' ')"
check "B3 the marker holds this kern.boottime" "$(sysctl -n kern.boottime)" "$(cat "$MARKER" 2>/dev/null)"
MT=$(stat -f %m "$MARKER" 2>/dev/null || echo 0)
[ "$MT" -ge "$START" ] && ok "B3 the re-install wrote the marker" || fail "B3 marker mtime $MT is before the re-install ($START)"
wait_argv "$N" && ok "B3 ds4 started after the re-install" || fail "B3 ds4 did not start after the re-install"
sudo rm -f "$DELAY" /tmp/mss-stub-pf.rules

# B4: pf fails to enable. The re-install stops before ds4 and guard, and leaves no marker.
sudo rm -f "$DELAY" /tmp/mss-stub-pfctl-fail; touch /tmp/mss-stub-pfctl-fail
ARGV_BEFORE=$(argv_lines)
laninstall "$RB/b4.log" && fail "B4 the re-install passed with pf failing" \
    || { grep -q 'pf boot check failed' "$RB/b4.log" && ok "B4 the re-install stops at the pf boot check" || fail "B4: $(tail -3 "$RB/b4.log")"; }
! loaded com.mac-studio-server.ds4 && ! loaded com.mac-studio-server.guard && ok "B4 ds4 and guard are not loaded" \
    || fail "B4 ds4 or guard is loaded"
[ ! -e "$MARKER" ] && ok "B4 no pf marker" || fail "B4 the pf marker exists"
sleep 2
check "B4 ds4 did not start (no new argv line)" "$ARGV_BEFORE" "$(argv_lines)"
sudo rm -f /tmp/mss-stub-pfctl-fail
N=$(argv_lines)
if laninstall "$RB/b4-again.log"; then ok "B4 re-install once pf works again"; else fail "B4 re-install: $(tail -3 "$RB/b4-again.log")"; fi
wait_argv "$N" && ok "B4 ds4 started after pf works again" || fail "B4 ds4 did not start after pf works again"
sudo rm -f "$DELAY" /tmp/mss-stub-pfctl-fail /tmp/mss-stub-pf.rules

# B3 (deferred): a LAN re-install without a model boots ds4 out and waits for it
# before boot loads the new anchor (MUST NOT 3).
sudo rm -f "$DELAY" /tmp/mss-stub-pf.rules; echo 5 > "$DELAY"
if laninstall "$RB/b3-defer.log" MSS_DEFER_MODEL=yes DS4_MODEL= DS4_MODEL_SHA256=; then ok "B3 deferred LAN re-install"
else fail "B3 deferred LAN re-install: $(tail -3 "$RB/b3-defer.log")"; fi
precedes "$RB/b3-defer.log" 'com.mac-studio-server.ds4 stopped after' 'bootstrapped com.mac-studio-server.boot' \
    && ok "B3 deferred: the old ds4 stopped before boot was bootstrapped" \
    || fail "B3 deferred stop order: $(grep -E 'stopped after|bootstrapped' "$RB/b3-defer.log" | tr '\n' ' ')"
! loaded com.mac-studio-server.ds4 && ! loaded com.mac-studio-server.guard && ok "B3 deferred: ds4 and guard are not loaded" \
    || fail "B3 deferred: ds4 or guard is loaded"
sudo rm -f "$DELAY" /tmp/mss-stub-pf.rules

echo "== phase B: #27 B1 GPU boot job, B2 Colima boot job (real launchd) =="
# These rows run against the real launchd and the real kernel key. A row that
# the runner cannot answer is skipped by name, never passed silently.
B27=$TMP/b27; mkdir -p "$B27"
b27_install() { # b27_install <log> <env=...>...: install.sh in env mode as root
    _bl=$1; shift
    sudo env MSS_BACKENDS=ollama OLLAMA_USER="$(id -un)" MSS_TUNE_MACOS=no "$@" \
        sh "$ROOT/scripts/install.sh" </dev/null >"$_bl" 2>&1
}
LIVE27=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo '')
if [ -z "$LIVE27" ]; then
    echo "skip - B1 needs iogpu.wired_limit_mb (not readable on this runner)"
elif ! sudo sysctl iogpu.wired_limit_mb="$LIVE27" >/dev/null 2>&1; then
    echo "skip - B1 needs iogpu.wired_limit_mb to be writable (rewriting $LIVE27 failed on this runner)"
else
    MB27=$(mss_wired_limit_mb 80)
    # (a) the legacy job as a v1.5.0 machine has it: loaded, recording 80. Its
    # program only reads the key, so seeding it changes nothing.
    cat > "$B27/legacy.plist" <<'LEGACY'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ollama.gpumemory</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/sbin/sysctl</string>
        <string>-n</string>
        <string>iogpu.wired_limit_mb</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>OLLAMA_GPU_PERCENT</key>
        <string>80</string>
    </dict>
</dict>
</plist>
LEGACY
    sudo install -m 644 -o root -g wheel "$B27/legacy.plist" /Library/LaunchDaemons/com.ollama.gpumemory.plist
    sudo launchctl bootstrap system /Library/LaunchDaemons/com.ollama.gpumemory.plist 2>/dev/null
    loaded com.ollama.gpumemory && ok "B1 the legacy job is seeded and loaded" || fail "B1 could not seed the legacy job"
    b27_install "$B27/gpu1.log" MSS_GPU_PERCENT=80 && ok "B1 install with MSS_GPU_PERCENT=80 exits 0" \
        || fail "B1 install: $(tail -3 "$B27/gpu1.log")"
    loaded com.mac-studio-server.gpumemory && ok "B1 the new job is loaded" || fail "B1 new job not loaded"
    ! loaded com.ollama.gpumemory && ok "B1 the legacy job is booted out" || fail "B1 legacy job still loaded"
    [ ! -e /Library/LaunchDaemons/com.ollama.gpumemory.plist ] && ok "B1 the legacy plist is gone" || fail "B1 legacy plist kept"
    check "B1 the live limit equals MB" "$MB27" "$(sysctl -n iogpu.wired_limit_mb 2>/dev/null)"
    launchctl print system/com.mac-studio-server.gpumemory 2>/dev/null \
        | grep -q 'last exit code = 0' && ok "B1 the job exited 0" || fail "B1 job exit code"
    # (b) a second run leaves the plist untouched and reports unchanged.
    INODE1=$(stat -f '%i %m' /Library/LaunchDaemons/com.mac-studio-server.gpumemory.plist)
    b27_install "$B27/gpu2.log" MSS_GPU_PERCENT=80 && ok "B1 a second install exits 0" \
        || fail "B1 second install: $(tail -3 "$B27/gpu2.log")"
    check "B1 the plist is not rewritten" "$INODE1" \
        "$(stat -f '%i %m' /Library/LaunchDaemons/com.mac-studio-server.gpumemory.plist)"
    grep -q "GPU memory: 80% ($MB27 MB), unchanged" "$B27/gpu2.log" \
        && ok "B1 the second run says unchanged" || fail "B1 second run: $(grep 'GPU memory' "$B27/gpu2.log")"
    # (c) system removes both jobs; seed the legacy one again so "both" is real.
    sudo install -m 644 -o root -g wheel "$B27/legacy.plist" /Library/LaunchDaemons/com.ollama.gpumemory.plist
    sudo launchctl bootstrap system /Library/LaunchDaemons/com.ollama.gpumemory.plist 2>/dev/null
    b27_install "$B27/gpu3.log" MSS_GPU_PERCENT=system && ok "B1 install with system exits 0" \
        || fail "B1 system install: $(tail -3 "$B27/gpu3.log")"
    [ ! -e /Library/LaunchDaemons/com.mac-studio-server.gpumemory.plist ] \
        && ok "B1 system removed the new plist" || fail "B1 new plist kept"
    [ ! -e /Library/LaunchDaemons/com.ollama.gpumemory.plist ] \
        && ok "B1 system removed the legacy plist" || fail "B1 legacy plist kept"
    ! loaded com.mac-studio-server.gpumemory && ! loaded com.ollama.gpumemory \
        && ok "B1 system left neither label loaded" || fail "B1 a GPU label is still loaded"
    # (d) the runner's own live value comes back.
    sudo sysctl iogpu.wired_limit_mb="$LIVE27" >/dev/null 2>&1
    check "B1 the original live value is restored" "$LIVE27" "$(sysctl -n iogpu.wired_limit_mb 2>/dev/null)"
fi

# B2: the Colima boot job. A runner with a real colima would start a VM, so it
# is skipped. Otherwise stub colima and docker go on the boot job's PATH (the
# validation needs both, D1). The docker stub answers `info` unless
# /tmp/mss-b2-docker-down exists, and the colima stub prints
# /tmp/mss-b2-colima-list for `list`; both log every call.
if [ -e /opt/homebrew/bin/colima ] || [ -e /usr/local/bin/colima ]; then
    echo "skip - B2 needs a runner without colima in /opt/homebrew/bin or /usr/local/bin"
else
    B2LOG=/tmp/mss-b2-tools.log; sudo rm -f "$B2LOG" /tmp/mss-b2-docker-down /tmp/mss-b2-colima-list
    cat > "$B27/colima" <<STUB
#!/bin/sh
echo "colima \$*" >> $B2LOG
[ "\${1:-}" = list ] && [ -f /tmp/mss-b2-colima-list ] && cat /tmp/mss-b2-colima-list
exit 0
STUB
    cat > "$B27/docker" <<STUB
#!/bin/sh
echo "docker \$*" >> $B2LOG
[ "\${1:-}" = info ] && [ -e /tmp/mss-b2-docker-down ] && exit 1
exit 0
STUB
    B2STUBS=""
    sudo mkdir -p /usr/local/bin
    for t in colima docker; do
        [ -e "/opt/homebrew/bin/$t" ] || [ -e "/usr/local/bin/$t" ] && continue
        sudo install -m 755 "$B27/$t" "/usr/local/bin/$t" && B2STUBS="$B2STUBS /usr/local/bin/$t"
    done
    b2_runs() { # the job's run count, waiting up to 20 s for the first run
        _r=0
        for _i in $(seq 1 40); do
            _r=$(launchctl print system/com.colima.daemon 2>/dev/null | awk '$1 == "runs" { print $3; exit }')
            [ "${_r:-0}" -ge 1 ] && break
            sleep 0.5
        done
        echo "${_r:-0}"
    }
    b27_install "$B27/da1.log" MSS_DOCKER_AUTOSTART=yes && ok "B2 autostart=yes installs the job" \
        || fail "B2 autostart install: $(tail -3 "$B27/da1.log")"
    loaded com.colima.daemon && ok "B2 the job is loaded" || fail "B2 job not loaded"
    check "B2 the job ran once" 1 "$(b2_runs)"
    DA_STAT=$(stat -f '%i %m' /Library/LaunchDaemons/com.colima.daemon.plist 2>/dev/null)
    b27_install "$B27/da2.log" MSS_DOCKER_AUTOSTART=yes && ok "B2 a second autostart run exits 0" \
        || fail "B2 second run: $(tail -3 "$B27/da2.log")"
    check "B2 a re-run keeps runs = 1" 1 "$(b2_runs)"
    check "B2 the plist is not rewritten" "$DA_STAT" "$(stat -f '%i %m' /Library/LaunchDaemons/com.colima.daemon.plist 2>/dev/null)"
    grep -q 'Docker at boot: on, unchanged' "$B27/da2.log" \
        && ok "B2 the second run says unchanged" || fail "B2 second run: $(grep 'Docker at boot' "$B27/da2.log")"
    b27_install "$B27/da3.log" && ok "B2 autostart unset exits 0" || fail "B2 unset run: $(tail -3 "$B27/da3.log")"
    grep -q 'Docker at boot: left as is' "$B27/da3.log" \
        && ok "B2 unset says left as is" || fail "B2 unset: $(grep 'Docker at boot' "$B27/da3.log")"
    check "B2 unset keeps runs = 1" 1 "$(b2_runs)"
    check "B2 unset leaves the plist" "$DA_STAT" "$(stat -f '%i %m' /Library/LaunchDaemons/com.colima.daemon.plist 2>/dev/null)"
    # So far the job ran start-colima.sh once, which stopped at `docker info`;
    # install.sh ran neither tool.
    check "B2 colima was never called" "" "$(grep '^colima' "$B2LOG" 2>/dev/null)"
    check "B2 docker was called only by the job's check" "docker info" "$(sort -u "$B2LOG" 2>/dev/null)"

    # B2 boot run (manual step 9 at a44b988): Docker down and an existing VM, as
    # after a reboot. launchd runs the real job, which must start Colima with no
    # sizing flags whether the list shows the VM or comes back empty.
    if [ -z "$B2STUBS" ] || [ "$(printf '%s\n' $B2STUBS | wc -l | tr -d ' ')" != 2 ]; then
        echo "skip - B2 boot run needs both stub tools (a real docker or colima is on this runner)"
    else
        B2CH=0
        if [ ! -e "$HOME/.colima" ]; then
            mkdir -p "$HOME/.colima/default"; printf 'cpu: 6\nmemory: 12\ndisk: 80\n' > "$HOME/.colima/default/colima.yaml"; B2CH=1
        fi
        B2YAML=$(mss_shasum256 "$HOME/.colima/default/colima.yaml" 2>/dev/null | awk '{print $1}')
        for listing in listed empty; do
            if [ "$listing" = listed ]; then printf '{"name":"default","status":"Stopped","cpus":6}\n' > /tmp/mss-b2-colima-list
            else : > /tmp/mss-b2-colima-list; fi
            : > /tmp/mss-b2-docker-down; : > "$B2LOG"
            sudo launchctl kickstart -k system/com.colima.daemon
            for _i in $(seq 1 40); do grep -q '^colima start' "$B2LOG" 2>/dev/null && break; sleep 0.5; done
            check "B2 boot run with the VM $listing starts Colima with no sizing flags" "colima start" \
                "$(grep '^colima start' "$B2LOG" | head -n 1)"
            grep -q '^colima list --json' "$B2LOG" && ok "B2 boot run ($listing) looked the VM up first" || fail "B2 boot run ($listing): $(cat "$B2LOG")"
            # Docker comes up, so the job's wait loop ends.
            rm -f /tmp/mss-b2-docker-down
            for _i in $(seq 1 20); do
                launchctl print system/com.colima.daemon 2>/dev/null | grep -q 'state = running' || break; sleep 0.5
            done
        done
        check "B2 boot runs left colima.yaml untouched" "$B2YAML" \
            "$(mss_shasum256 "$HOME/.colima/default/colima.yaml" 2>/dev/null | awk '{print $1}')"
        rm -f /tmp/mss-b2-colima-list
        [ "$B2CH" = 0 ] || rm -rf "$HOME/.colima"
    fi

    b27_install "$B27/da4.log" MSS_DOCKER_AUTOSTART=no && ok "B2 autostart=no exits 0" \
        || fail "B2 no run: $(tail -3 "$B27/da4.log")"
    [ ! -e /Library/LaunchDaemons/com.colima.daemon.plist ] && ok "B2 no removed the plist" || fail "B2 no kept the plist"
    ! loaded com.colima.daemon && ok "B2 no removed the label" || fail "B2 label still loaded"
    sudo launchctl bootout system/com.colima.daemon 2>/dev/null
    sudo rm -f /Library/LaunchDaemons/com.colima.daemon.plist "$B2LOG" /tmp/mss-b2-docker-down /tmp/mss-b2-colima-list
    # shellcheck disable=SC2086  # our own list of stub paths
    [ -z "$B2STUBS" ] || sudo rm -f $B2STUBS
fi

sudo sh "$ROOT/scripts/uninstall.sh" --all >/dev/null 2>&1

[ "$FAIL" -eq 0 ] || exit 1
exit 0
