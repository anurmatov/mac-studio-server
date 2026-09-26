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
    if shellcheck -S warning -s sh "$ROOT"/libexec/*.sh "$ROOT"/scripts/lib/mss-common.sh "$ROOT"/scripts/install-backends.sh "$ROOT"/scripts/status.sh "$ROOT"/scripts/uninstall.sh; then
        ok "shellcheck -s sh"
    else
        fail "shellcheck -s sh"
    fi
    if shellcheck -S warning "$ROOT"/scripts/install.sh "$ROOT"/scripts/lib/mss-picker.sh; then ok "shellcheck install.sh + mss-picker.sh (bash)"; else fail "shellcheck install.sh + mss-picker.sh"; fi
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
if git -C "$ROOT" cat-file -e "$OLD_REF^{commit}" 2>/dev/null; then
    mkdir -p "$TMP/old"
    git -C "$ROOT" archive "$OLD_REF" | tar -x -C "$TMP/old"
    for sel in ollama llamacpp ds4 'ollama,llamacpp' 'ollama,ds4' 'llamacpp,ds4'; do
        tag=$(echo "$sel" | tr , -)
        for tree in old new; do
            [ "$tree" = old ] && src="$TMP/old" || src="$ROOT"
            d="$TMP/parity-$tree-$tag"
            env MSS_BACKENDS="$sel" OLLAMA_USER=testuser \
                LLAMACPP_BIN="$TMP/fix/llamacpp/llamacpp-server" LLAMACPP_MODEL="$TMP/fix/llamacpp/model.gguf" \
                LLAMACPP_MODEL_SHA256="$(cat "$TMP/fix/llamacpp/model.sha")" \
                DS4_BIN="$TMP/fix/ds4/ds4-server" DS4_MODEL="$TMP/fix/ds4/model.gguf" \
                DS4_MODEL_SHA256="$(cat "$TMP/fix/ds4/model.sha")" \
                sh "$src/scripts/install-backends.sh" --render-only "$d" >/dev/null 2>&1
            echo $? > "$d.rc"
        done
        check "render '$sel' exit code matches 1.3.0" "$(cat "$TMP/parity-old-$tag.rc")" "$(cat "$TMP/parity-new-$tag.rc")"
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
else
    fail "render parity needs commit $OLD_REF (fetch full history: actions/checkout fetch-depth 0)"
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

echo "== phase A: picker on a pty (A3b, A12, A13) =="
if [ "$(id -u)" -eq 0 ]; then
    echo "skip - picker tests need a non-root user (interactive modes refuse root)"
elif ! command -v expect >/dev/null 2>&1; then
    fail "expect is not installed (the picker tests need it)"
else
    # sudo runs the --check-only pass as this user here: no system change.
    mkdir -p "$TMP/nosudo"
    printf '#!/bin/sh\nexec "$@"\n' > "$TMP/nosudo/sudo"; chmod +x "$TMP/nosudo/sudo"
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

    drive noallow "Choose [1]: ${T}5" "binary path: ${T}$DS4B" "(.gguf) path: ${T}$DS4M" "[Y/n]: ${T}@ENTER" "[Y/n]: ${T}@ENTER" \
        "LAN access to ds4? [y/N]: ${T}y" "listen on [192.0.2.10]: ${T}@ENTER" \
        "(space-separated): ${T}@ENTER" "(space-separated): ${T}@ENTER" "(space-separated): ${T}@ENTER" -- MSS_ENV_FILE="$PK/noallow.env"
    check "LAN ds4 with an empty allowlist cannot complete (A12)" 2 $?
    [ ! -e "$PK/noallow.env" ] && ok "LAN ds4 with an empty allowlist writes nothing" || fail "A12 allowlist wrote a file"

    drive keyfile "Choose [1]: ${T}4" "binary path${T}$LLB" "(.gguf) path: ${T}$LLM" "[Y/n]: ${T}@ENTER" "[Y/n]: ${T}@ENTER" \
        "LAN access to llamacpp? [y/N]: ${T}y" "listen on [192.0.2.10]: ${T}@ENTER" \
        "use an allowlist instead): ${T}sk-test123" "use an allowlist instead): ${T}@ENTER" \
        "(space-separated): ${T}192.0.2.99" "Port [8080]: ${T}@ENTER" "Save? [Y/n]: ${T}n" -- MSS_ENV_FILE="$PK/keyfile.env"
    check "declining the summary exits 1" 1 $?
    grep -q 'not the key itself' "$PK/keyfile.transcript" && ok "key prompt rejects a key typed as a path (A12)" || fail "A12 key prompt: $(tail -5 "$PK/keyfile.transcript")"
    # once is the terminal echoing the typed answer; any more is the installer printing it
    check "the rejected key is never printed back" 1 "$(grep -o 'sk-test123' "$PK/keyfile.transcript" | wc -l | tr -d ' ')"
    # the test's own inputs (.steps) and the pty transcript hold it by design
    LEAK=$(grep -rl 'sk-test123' "$TMP" "$ROOT/backends.env" 2>/dev/null | grep -v '\.transcript$\|\.steps$' || true)
    [ -z "$LEAK" ] && ok "the rejected key is in no file (A12)" || fail "sk-test123 found in: $LEAK"

    drive intr "Choose [1]: ${T}5" "binary path: ${T}$DS4B" "(.gguf) path: ${T}@INTR" -- MSS_ENV_FILE="$PK/intr.env"
    check "Ctrl-C at the model prompt exits 130 (A13)" 130 $?
    [ ! -e "$PK/intr.env" ] && ok "Ctrl-C writes nothing (A13)" || fail "A13 wrote a file"

    drive envdef "Choose [5]: ${T}@ENTER" "binary path: ${T}$DS4B" "(.gguf) path: ${T}$DS4M" "[Y/n]: ${T}@ENTER" "[Y/n]: ${T}@ENTER" \
        "LAN access to ds4? [y/N]: ${T}@ENTER" "Port [8001]: ${T}@ENTER" "Save? [Y/n]: ${T}@ENTER" -- \
        MSS_ENV_FILE="$PK/envdef.env" MSS_BACKENDS=ds4 DS4_PORT=8001
    check "--configure-only with MSS_BACKENDS set shows the menu with env defaults (A3b)" 0 $?
    grep -q '^MSS_BACKENDS=ds4$' "$PK/envdef.env" 2>/dev/null && grep -q '^DS4_PORT=8001$' "$PK/envdef.env" \
        && ok "A3b saved MSS_BACKENDS=ds4 and DS4_PORT=8001" || fail "A3b saved: $(cat "$PK/envdef.env" 2>&1)"
    check "A3b file mode 0600" 600 "$(stat -f '%Lp' "$PK/envdef.env" 2>/dev/null)"
    grep -q "^DS4_MODEL_SHA256=$DS4S\$" "$PK/envdef.env" && ok "A3b saved the computed sha256" || fail "A3b sha"

    drive saved "Choose [5]: ${T}@ENTER" "binary path [$DS4B]: ${T}@ENTER" "(.gguf) path [$DS4M]: ${T}@ENTER" \
        "c computes it now) [$DS4S]: ${T}@ENTER" "LAN access to ds4? [y/N]: ${T}@ENTER" "Port [8001]: ${T}@ENTER" \
        "Save? [Y/n]: ${T}@ENTER" -- MSS_ENV_FILE="$PK/envdef.env"
    check "--configure-only reuses every saved answer as its default" 0 $?
    grep -q 'Hashing' "$PK/saved.transcript" && fail "a saved sha256 was re-hashed by the picker" || ok "a saved sha256 is not re-hashed by the picker"
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
