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

if [ "$PHASE" != B ]; then
echo "== phase A: static =="
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning -s sh "$ROOT"/libexec/*.sh "$ROOT"/scripts/lib/*.sh "$ROOT"/scripts/install-backends.sh "$ROOT"/scripts/status.sh "$ROOT"/scripts/uninstall.sh; then
        ok "shellcheck -s sh"
    else
        fail "shellcheck -s sh"
    fi
    if shellcheck -S warning "$ROOT"/scripts/install.sh; then ok "shellcheck install.sh"; else fail "shellcheck install.sh"; fi
else
    echo "skip - shellcheck not installed"
fi

for f in "$ROOT"/libexec/*.sh "$ROOT"/scripts/lib/*.sh "$ROOT"/scripts/*.sh; do
    sh -n "$f" || fail "sh -n $f"
done
ok "sh -n on all scripts"

BAD=$(grep -nE 'stat -c|sha256sum|readlink -f|date -d' "$ROOT"/libexec/*.sh "$ROOT"/scripts/lib/*.sh "$ROOT"/scripts/install-backends.sh "$ROOT"/scripts/status.sh "$ROOT"/scripts/uninstall.sh 2>/dev/null || true)
[ -z "$BAD" ] && ok "no GNU-only spellings" || fail "GNU-only spellings found: $BAD"

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
for bad in '--mtp-model x' '--trace f' '--mtp' '--mtp-draft 2' '--mtp-exact-sampling' '--power 0' '--power 101'; do
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
    shasum -a 256 "$_d/model.gguf" | awk '{print $1}' > "$_d/model.sha"
}
render() { # render <backends> <dir> [extra env...]
    _sel=$1; _dir=$2; shift 2
    mkdir -p "$_dir"
    env MSS_BACKENDS="$_sel" OLLAMA_USER=testuser "$@" \
        LLAMACPP_BIN="$TMP/fix/llamacpp/llamacpp-server" \
        LLAMACPP_MODEL="$TMP/fix/llamacpp/model.gguf" \
        LLAMACPP_MODEL_SHA256="$(cat "$TMP/fix/llamacpp/model.sha")" \
        DS4_BIN="$TMP/fix/ds4/ds4-server" \
        DS4_MODEL="$TMP/fix/ds4/model.gguf" \
        DS4_MODEL_SHA256="$(cat "$TMP/fix/ds4/model.sha")" \
        sh "$ROOT/scripts/install-backends.sh" --render-only "$_dir"
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
sed -e 's|<OLLAMA_USER>|mssgolden|g' -e 's|<OLLAMA_BIND>|0.0.0.0|g' \
    "$ROOT/config/com.ollama.service.plist" > "$TMP/ollama-rendered.plist"
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
SPSHA=$(shasum -a 256 "$TMP/split/model-00001-of-00002.gguf" | awk '{print $1}')
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
check_fail "OLLAMA_USER root" env MSS_BACKENDS=ollama OLLAMA_USER=root sh "$ROOT/scripts/install-backends.sh" --render-only "$TMP/bad-root"
mkdir -p "$TMP/sp ace"; printf 'x' > "$TMP/sp ace/model.gguf"
SPC=$(shasum -a 256 "$TMP/sp ace/model.gguf" | awk '{print $1}')
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

echo
echo "phase A: $PASS passed, $FAIL failed"
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
SYSSHA=$(shasum -a 256 "$SYST/model.gguf" | awk '{print $1}')

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

[ "$FAIL" -eq 0 ] || exit 1
exit 0
