#!/usr/bin/env bash
# 9cc.sh TDD harness. Assert-based, no framework. claude stubbed.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
CC="$DIR/9cc.sh"
PASS=0; FAIL=0
assert_eq() { # <actual> <expected> <label>
    if [ "$1" = "$2" ]; then echo "  ok: $3"; PASS=$((PASS+1));
    else echo "  FAIL: $3 — want '$2' got '$1'"; FAIL=$((FAIL+1)); fi
}
assert_match() { # <pattern> <text> <label>
    if echo "$2" | grep -q "$1"; then echo "  ok: $3"; PASS=$((PASS+1));
    else echo "  FAIL: $3 — pattern '$1' not in '$2'"; FAIL=$((FAIL+1)); fi
}

# source registry functions (no dispatch because we source, not exec)
source "$CC"

echo "Cycle 1: registry maps all 13 aliases"
# plain list (POSIX): "alias|expected_id|expected_window" — no associative array (macOS bash 3.2)
WANT_LIST="\
fable|cc/fable-5|200000
opus|cc/claude-opus-4-8|200000
sonnet|cc/claude-sonnet-5|200000
haiku|cc/claude-haiku-4-5-20251001|200000
gpt5|cx/gpt-5.5|128000
glm5|glm/glm-5.2|1000000
glmturbo|glm/glm-5-turbo|1000000
deepseek|ds/deepseek-v4-pro|1000000
dsflash|ds/deepseek-v4-flash|1000000
kimi|kimi/kimi-k2.7|1000000
grok|gc/grok-build|500000
grokcomposer|gc/grok-composer-2.5-fast|500000
minimax|minimax/MiniMax-M3|1000000"
while IFS='|' read -r alias exp_id exp_win; do
    [ -z "$alias" ] && continue
    assert_eq "$(get_model "$alias")" "$exp_id|$exp_win" "alias $alias"
done <<<"$WANT_LIST"

echo "Cycle 2: full-ID resolves to same id|window"
assert_eq "$(get_model 'glm/glm-5.2')"           "glm/glm-5.2|1000000" "full glm"
assert_eq "$(get_model 'cc/fable-5')"            "cc/fable-5|200000"   "full fable"
assert_eq "$(get_model 'minimax/MiniMax-M3')"    "minimax/MiniMax-M3|1000000" "full minimax"

echo "Cycle 3: unknown alias exits non-zero"
if get_model 'nope' >/dev/null 2>&1; then echo "  FAIL: unknown should exit 1"; FAIL=$((FAIL+1)); else echo "  ok: unknown exits 1"; PASS=$((PASS+1)); fi

echo "Cycle 4: list prints all 13 aliases"
OUT="$(list_models)"
for alias in fable opus sonnet haiku gpt5 glm5 glmturbo deepseek dsflash kimi grok grokcomposer minimax; do
    assert_match "^$alias " "$OUT" "list has $alias"
done

echo "Cycle 5: run with no model exits 1"
if "$CC" run >/dev/null 2>&1; then echo "  FAIL: run-no-arg should exit 1"; FAIL=$((FAIL+1)); else echo "  ok: run-no-arg exits 1"; PASS=$((PASS+1)); fi

echo "Cycle 5b: version prints 9cc <ver>"
assert_match "^9cc " "$("$CC" version)" "version prints 9cc <ver>"
assert_match "^9cc " "$("$CC" --version)" "version flag alias"

echo "Cycle 6: run sets env vars + forwards args (claude stubbed)"
mkdir -p /tmp/9cc-test-bin
cat > /tmp/9cc-test-bin/claude <<'STUB'
#!/usr/bin/env bash
echo "STUB_CALLED args:$*"
echo "MODEL=$ANTHROPIC_MODEL"
echo "OPUS=$ANTHROPIC_DEFAULT_OPUS_MODEL"
echo "SONNET=$ANTHROPIC_DEFAULT_SONNET_MODEL"
echo "HAIKU=$ANTHROPIC_DEFAULT_HAIKU_MODEL"
echo "WIN=$CLAUDE_CODE_AUTO_COMPACT_WINDOW"
STUB
chmod +x /tmp/9cc-test-bin/claude
export CLAUDE_SETTINGS=/tmp/9cc-test-settings.json
printf '{"env":{"ANTHROPIC_BASE_URL":"https://gw.example/v1","ANTHROPIC_API_KEY":"sk-test"}}' > "$CLAUDE_SETTINGS"
RUN_OUT="$(PATH="/tmp/9cc-test-bin:$PATH" "$CC" run glm5 --resume extra 2>/dev/null || true)"
assert_match "MODEL=glm/glm-5.2" "$RUN_OUT" "run sets ANTHROPIC_MODEL"
assert_match "OPUS=glm/glm-5.2"  "$RUN_OUT" "run sets OPUS_MODEL"
assert_match "SONNET=glm/glm-5.2" "$RUN_OUT" "run sets SONNET_MODEL"
assert_match "HAIKU=glm/glm-5.2" "$RUN_OUT" "run sets HAIKU_MODEL"
assert_match "WIN=1000000"       "$RUN_OUT" "run sets compact window"
assert_match "args:--resume extra" "$RUN_OUT" "run forwards extra args"
if PATH="/tmp/9cc-test-bin:$PATH" "$CC" run bogus >/tmp/9cc-bogus 2>&1; then
    echo "  FAIL: run-bogus should exit 1"; FAIL=$((FAIL+1));
elif grep -q STUB_CALLED /tmp/9cc-bogus; then echo "  FAIL: claude called on bad alias"; FAIL=$((FAIL+1));
else echo "  ok: run-bogus exits 1, no claude call"; PASS=$((PASS+1)); fi
rm -rf /tmp/9cc-test-bin "$CLAUDE_SETTINGS" /tmp/9cc-bogus

echo "Cycle 7: install.sh downloads + symlinks (fixture source)"
export CC9_SOURCE="$CC"
export CC9_HOME=/tmp/9cc-home
export CC9_BIN_DIR=/tmp/9cc-bin
rm -rf "$CC9_HOME" "$CC9_BIN_DIR"; mkdir -p "$CC9_BIN_DIR"
bash "$DIR/install.sh" >/tmp/9cc-install.log 2>&1 || { echo "  FAIL: install.sh exit $?"; cat /tmp/9cc-install.log; FAIL=$((FAIL+1)); }
assert_match "cc/fable-5" "$(cat "$CC9_HOME/9cc.sh" 2>/dev/null || true)" "installer wrote 9cc.sh"
[ -x "$CC9_BIN_DIR/9cc" ] && { echo "  ok: symlink created"; PASS=$((PASS+1)); } || { echo "  FAIL: no symlink"; FAIL=$((FAIL+1)); }
bash "$DIR/install.sh" >>/tmp/9cc-install.log 2>&1 && { echo "  ok: re-run idempotent"; PASS=$((PASS+1)); } || { echo "  FAIL: re-run errored"; FAIL=$((FAIL+1)); }
rm -rf "$CC9_HOME" "$CC9_BIN_DIR" /tmp/9cc-install.log
unset CC9_SOURCE CC9_HOME CC9_BIN_DIR

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
