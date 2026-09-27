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
        /Library/LaunchDaemons/com.ollama.gpumemory.plist "$ROOT/backends.env"
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
    if shellcheck -S warning -s sh "$ROOT"/libexec/*.sh "$ROOT"/scripts/lib/mss-common.sh "$ROOT"/scripts/install-backends.sh "$ROOT"/scripts/status.sh "$ROOT"/scripts/uninstall.sh; then
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
check "MSS_TEST_SYSROOT is read by exactly three files (#21)" \
    "scripts/install-backends.sh scripts/lib/mss-picker.sh tests/run.sh" \
    "$(cd "$ROOT" && grep -rl --exclude-dir=.git MSS_TEST_SYSROOT . | sed 's|^\./||' | sort | tr '\n' ' ' | sed 's/ $//')"
# Every PATH= keeps $PATH, so the hash-audit shims stay first (#21). tests/run.sh
# counts from the phase A header to its summary line.
PATHRE='(^|[^A-Za-z0-9_])PATH='
BADPATH=$( { grep -rnE "$PATHRE" "$ROOT/scripts" "$ROOT/libexec" "$ROOT/bootstrap.sh"
    awk '/^if \[ "\$PHASE" != B \]; then$/ { a = 1 } a { print FILENAME ":" FNR ":" $0 } /^echo "phase A: \$PASS passed/ { a = 0 }' \
        "$ROOT/tests/run.sh" | grep -E "$PATHRE"
    } | grep -Ev '\$(PATH|\{PATH\})([^A-Za-z0-9_]|$)' | grep -vF "PATHRE='" || true)
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
check "launchctl bootstrap appears only in install-backends.sh and mss-enable.sh" \
    "libexec/mss-enable.sh scripts/install-backends.sh" "$BOOTS"
for f in libexec/mss-enable.sh scripts/install-backends.sh; do
    grep -q 'mss_launchd_wait_gone "' "$ROOT/$f" && ok "$f calls mss_launchd_wait_gone" || fail "$f never calls mss_launchd_wait_gone"
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
for word in OLLAMA_BIND ./scripts/optimize-mac-server.sh OLLAMA_GPU_PERCENT DOCKER_AUTOSTART; do
    grep -q -- "$word" "$ROOT/docs/options.md" && ok "docs/options.md has $word (R2, F6)" || fail "docs/options.md lacks $word"
done
[ "$(wc -l < "$ROOT/docs/options.md")" -le 80 ] && ok "docs/options.md ≤ 80 lines" || fail "docs/options.md too long"
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
    PK="$TMP/picker"; mkdir -p "$PK"
    drive() { # drive <name> <steps...> -- <env...>: run install.sh on a pty
        _name=$1; shift
        : > "$PK/$_name.steps"
        while [ "$1" != -- ]; do printf '%s\n' "$1" >> "$PK/$_name.steps"; shift; done
        shift
        env PATH="$TMP/nosudo:$PATH" MSS_CONF="$PK/none.conf" OLLAMA_USER="$(id -un)" \
            MSS_IFCONFIG="$ROOT/tests/stubs/ifconfig-lan" "$@" \
            expect "$ROOT/tests/expect/drive.exp" "$PK/$_name.steps" "$PK/$_name.transcript" \
            /bin/bash "$ROOT/scripts/install.sh" --configure-only >/dev/null 2>"$PK/$_name.err"
    }
    T=$(printf '\t')
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
        "(space-separated): ${T}192.0.2.99" "auto-updates)? ${T}@ENTER" "Save? [Y/n]: ${T}n" -- \
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
        "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/envdef.env" MSS_BACKENDS=ds4 DS4_PORT=8001 DS4_BIN="$DS4B"
    check "--configure-only with MSS_BACKENDS set shows the menu with env defaults (A3b)" 0 $?
    grep -q '^MSS_BACKENDS=ds4$' "$PK/envdef.env" 2>/dev/null && grep -q '^DS4_PORT=8001$' "$PK/envdef.env" \
        && ok "A3b saved MSS_BACKENDS=ds4 and DS4_PORT=8001" || fail "A3b saved: $(cat "$PK/envdef.env" 2>&1)"
    check "A3b file mode 0600" 600 "$(stat -f '%Lp' "$PK/envdef.env" 2>/dev/null)"
    grep -q "^DS4_MODEL_SHA256=$DS4S\$" "$PK/envdef.env" && ok "A3b saved the computed sha256" || fail "A3b sha"
    grep -q 'Port' "$PK/envdef.transcript" && fail "the port was asked (I6)" || ok "no port prompt (I6)"

    drive saved "Choose [5]: ${T}@ENTER" "(.gguf) path [$DS4M]: ${T}@ENTER" \
        "c computes it now) [$DS4S]: ${T}@ENTER" "LAN access to ds4? [y/N]: ${T}@ENTER" \
        "auto-updates)? ${T}@ENTER" "Save? [Y/n]: ${T}@ENTER" -- MSS_ENV_FILE="$PK/envdef.env"
    check "--configure-only reuses every saved answer as its default" 0 $?
    grep -q 'Hashing' "$PK/saved.transcript" && fail "a saved sha256 was re-hashed by the picker" || ok "a saved sha256 is not re-hashed by the picker"
    grep -q 'binary path' "$PK/saved.transcript" && fail "a saved binary was asked for again (I7)" || ok "a saved binary is used without asking (I7)"

    # F5: a llama-server found on PATH and the default port: neither is asked.
    mkdir -p "$TMP/found"; cp "$ROOT/tests/stubs/fake-server.sh" "$TMP/found/llama-server"; chmod +x "$TMP/found/llama-server"
    drive found "Choose [1]: ${T}4" "later [1]: ${T}4" "LAN access to llamacpp? [y/N]: ${T}@ENTER" \
        "auto-updates)? ${T}@ENTER" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/found.env" PATH="$TMP/found:$TMP/nosudo:$PATH"
    check "F5 found llama-server, later" 0 $?
    grep -q 'binary path\|Port' "$PK/found.transcript" && fail "F5 asked for the binary or the port" || ok "F5 no binary or port prompt"
    grep -q "^LLAMACPP_BIN=$TMP/found/llama-server\$" "$PK/found.env" && grep -q '^LLAMACPP_PORT=8080$' "$PK/found.env" \
        && ok "F5 saved the found binary and port 8080" || fail "F5 saved: $(cat "$PK/found.env")"
    grep -q '^MSS_DEFER_MODEL=yes$' "$PK/found.env" && ok "later saves MSS_DEFER_MODEL=yes (M3)" || fail "later not saved"
    grep -q '^MSS_TUNE_MACOS=no$' "$PK/found.env" && ok "I2 is asked without Ollama too and saved as no (A1)" || fail "I2 without Ollama"

    # M4: ds4 with nothing found: the build offer (declined), the manual command, then the menu.
    drive ds4menu "Choose [1]: ${T}5" "in ~/ds4? [y/N]: ${T}@ENTER" "binary path: ${T}$DS4B" "later [4]: ${T}@ENTER" \
        "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/ds4menu.env" HOME="$PK/home"
    check "M4 ds4 with the build declined and a model later" 0 $?
    grep -q 'no small one exists).*later \[4\]: ' "$PK/ds4menu.transcript" && ok "M4 ds4 menu says no small model and defaults to later" \
        || fail "M4 menu: $(grep 'ds4 (' "$PK/ds4menu.transcript")"
    grep -q '^manual: git clone https://github.com/antirez/ds4.git' "$PK/ds4menu.transcript" && ok "declining the build prints the manual command" \
        || fail "no manual build command"
    [ ! -e "$PK/home/ds4" ] && ok "declining the build creates nothing" || fail "declined build created ~/ds4"

    # I2: with Ollama, the headless tweaks are asked once and saved; default no.
    drive tweaks "Choose [1]: ${T}1" "auto-updates)? ${T}@ENTER" "Save? [Y/n]: ${T}@ENTER" -- MSS_ENV_FILE="$PK/tweaks.env"
    check "I2 ollama only" 0 $?
    grep -q '^MSS_TUNE_MACOS=no$' "$PK/tweaks.env" && ok "I2 saved MSS_TUNE_MACOS=no" || fail "I2 saved: $(cat "$PK/tweaks.env")"
    grep -q "^OLLAMA_BIN=$TMP/nosudo/ollama\$" "$PK/tweaks.env" && ok "an ollama on PATH is saved as OLLAMA_BIN (P2)" || fail "P2 OLLAMA_BIN"
    check "I2 asked once" 1 "$(grep -c 'headless macOS tweaks' "$PK/tweaks.transcript")"

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
    "auto-updates)? ${T}n" "Install with these settings? [Y/n]: ${T}@ENTER" -- LLAMACPP_PORT=18080 PATH="$PATH_NOLL"
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
cp "$CONFB" "$PB/conf.a5"
bdrive a6 "" --
check "A6 re-run with saved backends.env" 0 $?
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
    "auto-updates)? ${T}@ENTER" "Save? [Y/n]: ${T}@ENTER" -- DS4_PORT=18000
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
    "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" \
    "Install with these settings? [Y/n]: ${T}@ENTER" "--backend llamacpp? [y/N]: ${T}n" --
check "A9 declining the switch exits 1" 1 $?
has a9 'binary path' && fail "A9 asked for a saved binary (I7)" || ok "A9 a saved binary is not asked (I7)"
loaded com.mac-studio-server.llamacpp && wait_listen 18081 && ok "A9 llama.cpp still running" || fail "A9 llama.cpp not running"
check "A9 /Library/LaunchDaemons unchanged" "$BEFORE" "$(daemons)"
cmp -s "$CONFB" "$PB/conf.a9" && ok "A9 backends.conf unchanged" || fail "A9 conf changed"

# A10 / A9 (sha): switch with a wrong ds4 sha256, answer y: stops at the check with exit 1.
bdrive a10 "--configure" "Choose [4]: ${T}5" "(.gguf) path [$DS4M]: ${T}@ENTER" "c computes it now) [$DS4S]: ${T}$ZERO" \
    "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" \
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
    "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" \
    "Install with these settings? [Y/n]: ${T}@ENTER" "--backend llamacpp? [y/N]: ${T}y" --
check "A10b foreign listener stops the switch with exit 1" 1 $?
has a10b "port 18000 is in use (pid $NCPID); set DS4_PORT in backends.env and re-run" && ok "A10b names the pid and the variable (I6)" \
    || fail "A10b: $(grep -i 'in use' "$PB/a10b.transcript")"
has a10b 'Removing llamacpp' && fail "A10b ran uninstall" || ok "A10b uninstall never ran"
loaded com.mac-studio-server.llamacpp && ok "A10b llama.cpp still loaded" || fail "A10b llama.cpp gone"
kill "$NCPID" 2>/dev/null; wait "$NCPID" 2>/dev/null

# A8: switch llama.cpp -> ds4, answer y.
bdrive a8 "--configure" "Choose [4]: ${T}5" "(.gguf) path [$DS4M]: ${T}@ENTER" "c computes it now) [$DS4S]: ${T}@ENTER" \
    "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}@ENTER" \
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
    "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}y" \
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
    "LAN access to llamacpp? [y/N]: ${T}@ENTER" "auto-updates)? ${T}n" \
    "Install with these settings? [Y/n]: ${T}@ENTER" "--backend ds4? [y/N]: ${T}y" "(starter) 2) later [1]: ${T}2" --
check "A5 ollama + llama.cpp" 0 $?
loaded com.ollama.service && loaded com.mac-studio-server.llamacpp && ! loaded com.mac-studio-server.ds4 \
    && ok "A5 ollama + llama.cpp labels" || fail "A5 option 2 labels: $(daemons)"
snap > "$PB/f2.after"
cmp -s "$PB/f2.before" "$PB/f2.after" && ok "F2 pmset, mdutil, tmutil and update settings unchanged" || fail "F2 settings changed"
[ "$LOGS/optimization.log" -nt "$PB/f2.marker" ] && fail "F2 the optimizer ran" || ok "F2 optimization.log not written"

# A5: ollama only (removes llama.cpp; no check to run).
bdrive a5o1 "--configure" "Choose [2]: ${T}1" "auto-updates)? ${T}n" "Install with these settings? [Y/n]: ${T}@ENTER" \
    "--backend llamacpp? [y/N]: ${T}y" "(starter) 2) later [1]: ${T}2" --
check "A5 ollama only" 0 $?
loaded com.ollama.service && ! loaded com.mac-studio-server.llamacpp && ! loaded com.mac-studio-server.guard \
    && ok "A5 ollama-only labels" || fail "A5 option 1 labels: $(daemons)"

# A5: MSS_BACKENDS set in the environment, --configure choosing ds4 only.
bdrive a5env "--configure" "Choose [4]: ${T}5" "(.gguf) path [$DS4M]: ${T}@ENTER" "c computes it now) [$DS4S]: ${T}@ENTER" \
    "LAN access to ds4? [y/N]: ${T}@ENTER" "auto-updates)? ${T}n" \
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
    "LAN access to llamacpp? [y/N]: ${T}@ENTER" "auto-updates)? ${T}n" \
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
    "LAN access to llamacpp? [y/N]: ${T}@ENTER" "auto-updates)? ${T}n" "Install with these settings? [Y/n]: ${T}@ENTER" -- \
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
# pf_first <log>: "pf verified" is logged before ds4 is bootstrapped.
pf_first() {
    _pv=$(grep -n 'pf verified by com.mac-studio-server.boot' "$1" | head -n 1 | cut -d: -f1)
    _bd=$(grep -n 'bootstrapped com.mac-studio-server.ds4' "$1" | head -n 1 | cut -d: -f1)
    [ -n "$_pv" ] && [ -n "$_bd" ] && [ "$_pv" -lt "$_bd" ]
}
sudo rm -f "$DELAY" /tmp/mss-stub-pfctl-fail /tmp/mss-stub-pf.rules
sudo sh "$ROOT/scripts/uninstall.sh" --all >/dev/null 2>&1
if laninstall "$RB/b3.log"; then ok "B3 LAN install"; else fail "B3 LAN install: $(tail -3 "$RB/b3.log")"; fi
pf_first "$RB/b3.log" && ok "B3 install: pf verified before ds4 was bootstrapped" \
    || fail "B3 install order: $(grep -E 'pf verified|bootstrapped' "$RB/b3.log" | tr '\n' ' ')"
echo 5 > "$DELAY"
START=$(date +%s)
if laninstall "$RB/b3-again.log"; then ok "B3 LAN re-install while ds4 takes 5 s to stop"; else fail "B3 LAN re-install: $(tail -3 "$RB/b3-again.log")"; fi
pf_first "$RB/b3-again.log" && ok "B3 re-install: pf verified before ds4 was bootstrapped" \
    || fail "B3 re-install order: $(grep -E 'pf verified|bootstrapped' "$RB/b3-again.log" | tr '\n' ' ')"
check "B3 the marker holds this kern.boottime" "$(sysctl -n kern.boottime)" "$(cat "$MARKER" 2>/dev/null)"
MT=$(stat -f %m "$MARKER" 2>/dev/null || echo 0)
[ "$MT" -ge "$START" ] && ok "B3 the re-install wrote the marker" || fail "B3 marker mtime $MT is before the re-install ($START)"
sudo rm -f "$DELAY" /tmp/mss-stub-pf.rules

# B4: pf fails to enable. The re-install stops before ds4 and guard, and leaves no marker.
sudo rm -f "$DELAY" /tmp/mss-stub-pfctl-fail; touch /tmp/mss-stub-pfctl-fail
ARGV_BEFORE=$(wc -l < /tmp/mss-stub-argv | tr -d ' ')
laninstall "$RB/b4.log" && fail "B4 the re-install passed with pf failing" \
    || { grep -q 'pf boot check failed' "$RB/b4.log" && ok "B4 the re-install stops at the pf boot check" || fail "B4: $(tail -3 "$RB/b4.log")"; }
! loaded com.mac-studio-server.ds4 && ! loaded com.mac-studio-server.guard && ok "B4 ds4 and guard are not loaded" \
    || fail "B4 ds4 or guard is loaded"
[ ! -e "$MARKER" ] && ok "B4 no pf marker" || fail "B4 the pf marker exists"
sleep 2
check "B4 ds4 did not start (no new argv line)" "$ARGV_BEFORE" "$(wc -l < /tmp/mss-stub-argv | tr -d ' ')"
sudo rm -f /tmp/mss-stub-pfctl-fail
if laninstall "$RB/b4-again.log"; then ok "B4 re-install once pf works again"; else fail "B4 re-install: $(tail -3 "$RB/b4-again.log")"; fi
sudo rm -f "$DELAY" /tmp/mss-stub-pfctl-fail /tmp/mss-stub-pf.rules

sudo sh "$ROOT/scripts/uninstall.sh" --all >/dev/null 2>&1

[ "$FAIL" -eq 0 ] || exit 1
exit 0
