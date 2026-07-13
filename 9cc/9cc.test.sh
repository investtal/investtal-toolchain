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

source "$DIR/sandbox.sh" 2>/dev/null || true

echo "Cycle sandbox-1: agent-proxy.mjs exists and is valid ESM"
[ -f "$DIR/agent-proxy.mjs" ] && \
    grep -q 'import http from "node:http"' "$DIR/agent-proxy.mjs" && \
    grep -q '/healthz' "$DIR/agent-proxy.mjs" && \
    grep -q 'listen(PORT, "127.0.0.1"' "$DIR/agent-proxy.mjs" && \
    { echo "  ok: agent-proxy.mjs present"; PASS=$((PASS+1)); } || \
    { echo "  FAIL: agent-proxy.mjs missing or invalid"; FAIL=$((FAIL+1)); }

echo "Cycle sandbox-2: Dockerfile stanzas"
[ -f "$DIR/Dockerfile" ] && \
    grep -q "FROM node:24-slim" "$DIR/Dockerfile" && \
    grep -q "COPY claude-local" "$DIR/Dockerfile" && \
    grep -q "COPY claude-source.mode" "$DIR/Dockerfile" && \
    grep -q '@anthropic-ai/claude-code' "$DIR/Dockerfile" && \
    grep -q "COPY agent-proxy.mjs" "$DIR/Dockerfile" && \
    grep -q "COPY investtal" "$DIR/Dockerfile" && \
    grep -q "COPY proto" "$DIR/Dockerfile" && \
    grep -q "COPY prototools" "$DIR/Dockerfile" && \
    grep -q "ENTRYPOINT" "$DIR/Dockerfile" && \
    if grep 'apt-get install' "$DIR/Dockerfile" | grep -q 'gh'; then \
        echo "  FAIL: Dockerfile apt-get still installs gh"; FAIL=$((FAIL+1)); \
    else \
        { echo "  ok: Dockerfile stanzas"; PASS=$((PASS+1)); }; \
    fi || \
    { echo "  FAIL: Dockerfile stanzas"; FAIL=$((FAIL+1)); }


echo "Cycle sandbox-3: guard rejects home and root"
if is_guarded_dir "$HOME" >/dev/null 2>&1; then echo "  FAIL: home dir allowed"; FAIL=$((FAIL+1)); else echo "  ok: home dir rejected"; PASS=$((PASS+1)); fi
if is_guarded_dir "/" >/dev/null 2>&1; then echo "  FAIL: root dir allowed"; FAIL=$((FAIL+1)); else echo "  ok: root dir rejected"; PASS=$((PASS+1)); fi
if is_guarded_dir "$DIR" >/dev/null 2>&1; then echo "  ok: project dir allowed"; PASS=$((PASS+1)); else echo "  FAIL: project dir rejected"; FAIL=$((FAIL+1)); fi

echo "Cycle sandbox-3b: find_claude_source resolves CC9_CLAUDE_LOCAL / BIN / npm"
mkdir -p /tmp/9cc-claude-dir/bin
printf '#!/bin/sh\necho claude-stub\n' > /tmp/9cc-claude-dir/bin/claude
chmod +x /tmp/9cc-claude-dir/bin/claude
SRC="$(CC9_CLAUDE_LOCAL=/tmp/9cc-claude-dir find_claude_source)"
assert_eq "$SRC" "dir|/tmp/9cc-claude-dir" "CC9_CLAUDE_LOCAL dir"
printf '#!/bin/sh\necho bin-stub\n' > /tmp/9cc-claude-bin
chmod +x /tmp/9cc-claude-bin
SRC="$(CC9_CLAUDE_BIN=/tmp/9cc-claude-bin find_claude_source)"
SRC_KIND="${SRC%%|*}"
SRC_PATH="${SRC#*|}"
if [ "$SRC_KIND" = "bin" ] && { [ "$SRC_PATH" = "/tmp/9cc-claude-bin" ] || [ "$SRC_PATH" = "/private/tmp/9cc-claude-bin" ]; }; then
    echo "  ok: CC9_CLAUDE_BIN shebang"; PASS=$((PASS+1))
else
    echo "  FAIL: CC9_CLAUDE_BIN shebang — got '$SRC'"; FAIL=$((FAIL+1))
fi
# Mach-O-like non-runnable binary -> npm
printf '\xcf\xfa\xed\xfe' > /tmp/9cc-claude-macho
SRC="$(CC9_CLAUDE_BIN=/tmp/9cc-claude-macho find_claude_source 2>/dev/null)"
assert_eq "$SRC" "npm|" "non-Linux binary falls back to npm"
# stage_claude_local writes mode file
rm -rf /tmp/9cc-stage-ctx
mkdir -p /tmp/9cc-stage-ctx
CC9_CLAUDE_LOCAL=/tmp/9cc-claude-dir stage_claude_local /tmp/9cc-stage-ctx
assert_eq "$(cat /tmp/9cc-stage-ctx/claude-source.mode)" "host" "stage host mode"
[ -x /tmp/9cc-stage-ctx/claude-local/bin/claude ] && { echo "  ok: staged bin/claude"; PASS=$((PASS+1)); } || { echo "  FAIL: staged bin/claude missing"; FAIL=$((FAIL+1)); }
rm -rf /tmp/9cc-stage-ctx
CC9_CLAUDE_BIN=/tmp/9cc-claude-macho stage_claude_local /tmp/9cc-stage-ctx 2>/dev/null
assert_eq "$(cat /tmp/9cc-stage-ctx/claude-source.mode)" "npm" "stage npm mode"
rm -rf /tmp/9cc-claude-dir /tmp/9cc-claude-bin /tmp/9cc-claude-macho /tmp/9cc-stage-ctx
unset CC9_CLAUDE_LOCAL CC9_CLAUDE_BIN 2>/dev/null || true

echo "Cycle sandbox-4: 9cc sandbox build invokes docker build and scrubs secrets"
mkdir -p /tmp/9cc-test-bin
mkdir -p /tmp/9cc-test-home/.claude/local/bin
# Runnable shebang so classic ~/.claude/local layout is host-copyable.
printf '#!/bin/sh\necho claude-test\n' > /tmp/9cc-test-home/.claude/local/bin/claude
chmod +x /tmp/9cc-test-home/.claude/local/bin/claude
mkdir -p /tmp/9cc-test-home/.claude/secrets
touch /tmp/9cc-test-home/.claude/settings.json
cat > /tmp/9cc-test-bin/docker <<'STUB'
#!/usr/bin/env bash
echo "DOCKER_BUILD args:$*"
exit 0
STUB
chmod +x /tmp/9cc-test-bin/docker
BUILD_OUT="$(PATH="/tmp/9cc-test-bin:$PATH" HOME=/tmp/9cc-test-home CC9_SANDBOX_CONTEXT=/tmp/9cc-sandbox-ctx CLAUDE_SETTINGS=/tmp/9cc-test-settings.json "$CC" sandbox build 2>&1 || true)"
assert_match "DOCKER_BUILD" "$BUILD_OUT" "sandbox build calls docker"
if [ -f /tmp/9cc-sandbox-ctx/claude/settings.json ]; then
    echo "  FAIL: settings.json baked into context"; FAIL=$((FAIL+1));
else
    echo "  ok: settings.json scrubbed from context"; PASS=$((PASS+1));
fi
if [ -d /tmp/9cc-sandbox-ctx/claude/local ]; then
    echo "  FAIL: host binary baked into context"; FAIL=$((FAIL+1));
else
    echo "  ok: host binary scrubbed from context"; PASS=$((PASS+1));
fi
if [ -f /tmp/9cc-sandbox-ctx/claude-source.mode ]; then
    echo "  ok: claude-source.mode present"; PASS=$((PASS+1));
else
    echo "  FAIL: claude-source.mode missing"; FAIL=$((FAIL+1));
fi
if [ -x /tmp/9cc-sandbox-ctx/claude-local/bin/claude ]; then
    echo "  ok: claude-local staged from host"; PASS=$((PASS+1));
else
    echo "  FAIL: claude-local not staged"; FAIL=$((FAIL+1));
fi
# Refuse to wipe an unmanaged CC9_SANDBOX_CONTEXT (data-loss guard).
BAD_CTX="$DIR/9cc-test-bad-ctx"
mkdir -p "$BAD_CTX"
if PATH="/tmp/9cc-test-bin:$PATH" HOME=/tmp/9cc-test-home CC9_SANDBOX_CONTEXT="$BAD_CTX" CLAUDE_SETTINGS=/tmp/9cc-test-settings.json "$CC" sandbox build >/tmp/9cc-bad-ctx.log 2>&1; then
    echo "  FAIL: build wiped unmanaged context"; FAIL=$((FAIL+1));
else
    echo "  ok: refuses unmanaged context"; PASS=$((PASS+1));
fi
[ -d "$BAD_CTX" ] && { echo "  ok: unmanaged context preserved"; PASS=$((PASS+1)); } || { echo "  FAIL: unmanaged context wiped"; FAIL=$((FAIL+1)); }
rm -rf /tmp/9cc-test-bin /tmp/9cc-test-home /tmp/9cc-sandbox-ctx "$BAD_CTX" /tmp/9cc-bad-ctx.log "$DIR/9cc-test-bad-ctx"

echo "Cycle sandbox-5: 9cc run --sandbox resolves model/auth and invokes docker run with correct mounts"
mkdir -p /tmp/9cc-test-bin
mkdir -p /tmp/9cc-test-claude-local
mkdir -p /tmp/9cc-sandbox-ctx
mkdir -p /tmp/9cc-test-home
mkdir -p /tmp/9cc-test-proj
cat > /tmp/9cc-test-bin/docker <<'STUB'
#!/usr/bin/env bash
echo "DOCKER_RUN args:$*"
for a in "$@"; do echo "ARG:$a"; done
exit 0
STUB
chmod +x /tmp/9cc-test-bin/docker
export CLAUDE_SETTINGS=/tmp/9cc-test-settings.json
printf '{"env":{"ANTHROPIC_BASE_URL":"https://gw.example/v1","ANTHROPIC_API_KEY":"sk-test"}}' > "$CLAUDE_SETTINGS"
RUN_OUT="$(cd /tmp/9cc-test-proj && PATH="/tmp/9cc-test-bin:$PATH" HOME=/tmp/9cc-test-home CC9_SANDBOX_CONTEXT=/tmp/9cc-sandbox-ctx CC9_SANDBOX_NO_BUILD=1 "$CC" run --sandbox sonnet --version 2>&1 || true)"
assert_match "DOCKER_RUN" "$RUN_OUT" "run --sandbox calls docker"
assert_match "ARG:--user" "$RUN_OUT" "docker run uses --user"
assert_match "ARG:/workspace" "$RUN_OUT" "docker run mounts /workspace"
assert_match "ARG:ANTHROPIC_MODEL=cc/claude-sonnet-5" "$RUN_OUT" "passes ANTHROPIC_MODEL"
assert_match "ARG:ANTHROPIC_BASE_URL=https://gw.example/v1" "$RUN_OUT" "passes ANTHROPIC_BASE_URL"
assert_match "ARG:ANTHROPIC_API_KEY=sk-test" "$RUN_OUT" "passes ANTHROPIC_API_KEY"
assert_match "ARG:CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000" "$RUN_OUT" "passes compact window"
assert_match "ARG:ANTHROPIC_DEFAULT_OPUS_MODEL=cc/claude-opus-4-8" "$RUN_OUT" "passes OPUS default"
assert_match "ARG:ANTHROPIC_DEFAULT_HAIKU_MODEL=cc/claude-haiku-4-5-20251001" "$RUN_OUT" "passes HAIKU default"
assert_match "ARG:claude" "$RUN_OUT" "docker run execs claude"
assert_match "ARG:--version" "$RUN_OUT" "forwards extra args"
# model-before-flag order: 9cc run sonnet --sandbox --version
RUN_OUT2="$(cd /tmp/9cc-test-proj && PATH="/tmp/9cc-test-bin:$PATH" HOME=/tmp/9cc-test-home CC9_SANDBOX_CONTEXT=/tmp/9cc-sandbox-ctx CC9_SANDBOX_NO_BUILD=1 "$CC" run sonnet --sandbox --version 2>&1 || true)"
assert_match "DOCKER_RUN" "$RUN_OUT2" "run model --sandbox calls docker"
assert_match "ARG:ANTHROPIC_MODEL=cc/claude-sonnet-5" "$RUN_OUT2" "model-before-flag resolves model"
assert_match "ARG:--version" "$RUN_OUT2" "model-before-flag forwards args"
rm -rf /tmp/9cc-test-bin /tmp/9cc-test-claude-local /tmp/9cc-sandbox-ctx /tmp/9cc-test-home /tmp/9cc-test-proj "$CLAUDE_SETTINGS"
unset CLAUDE_SETTINGS

echo "Cycle sandbox-6: help text mentions sandbox"
HELP_OUT="$($CC help)"
assert_match "sandbox" "$HELP_OUT" "help mentions sandbox"

echo "Cycle 1: registry maps all 13 aliases"
# plain list (POSIX): "alias|expected_id|expected_window" — no associative array (macOS bash 3.2)
WANT_LIST="\
fable|cc/claude-fable-5|500000
opus|cc/claude-opus-4-8|500000
sonnet|cc/claude-sonnet-5|200000
haiku|cc/claude-haiku-4-5-20251001|200000
gpt5|cx/gpt-5.5|128000
glm5|glm/glm-5.2|500000
glmturbo|glm/glm-5-turbo|500000
deepseek|ds/deepseek-v4-pro|500000
dsflash|ds/deepseek-v4-flash|500000
kimi|kimi/kimi-k2.7|500000
grok|xai/grok-4.5|500000
grokcomposer|xai/grok-composer-2.5-fast|500000
minimax|minimax/MiniMax-M3|500000"
while IFS='|' read -r alias exp_id exp_win; do
    [ -z "$alias" ] && continue
    assert_eq "$(get_model "$alias")" "$exp_id|$exp_win" "alias $alias"
done <<<"$WANT_LIST"

echo "Cycle 2: full-ID resolves to same id|window"
assert_eq "$(get_model 'glm/glm-5.2')"           "glm/glm-5.2|500000" "full glm"
assert_eq "$(get_model 'cc/claude-fable-5')"     "cc/claude-fable-5|500000"   "full fable"
assert_eq "$(get_model 'minimax/MiniMax-M3')"    "minimax/MiniMax-M3|500000" "full minimax"

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
assert_match "WIN=500000"       "$RUN_OUT" "run sets compact window"
assert_match "args:--resume extra" "$RUN_OUT" "run forwards extra args"
if PATH="/tmp/9cc-test-bin:$PATH" "$CC" run bogus >/tmp/9cc-bogus 2>&1; then
    echo "  FAIL: run-bogus should exit 1"; FAIL=$((FAIL+1));
elif grep -q STUB_CALLED /tmp/9cc-bogus; then echo "  FAIL: claude called on bad alias"; FAIL=$((FAIL+1));
else echo "  ok: run-bogus exits 1, no claude call"; PASS=$((PASS+1)); fi
rm -rf /tmp/9cc-test-bin "$CLAUDE_SETTINGS" /tmp/9cc-bogus

echo "Cycle 6b: family-aware DEFAULT_{OPUS,SONNET,HAIKU} tiers"
mkdir -p /tmp/9cc-test-bin
cat > /tmp/9cc-test-bin/claude <<'STUB'
#!/usr/bin/env bash
echo "MODEL=$ANTHROPIC_MODEL"
echo "OPUS=$ANTHROPIC_DEFAULT_OPUS_MODEL"
echo "SONNET=$ANTHROPIC_DEFAULT_SONNET_MODEL"
echo "HAIKU=$ANTHROPIC_DEFAULT_HAIKU_MODEL"
STUB
chmod +x /tmp/9cc-test-bin/claude
export CLAUDE_SETTINGS=/tmp/9cc-test-settings.json
printf '{"env":{"ANTHROPIC_BASE_URL":"https://gw.example/v1","ANTHROPIC_API_KEY":"sk-test"}}' > "$CLAUDE_SETTINGS"

# Claude: fable keeps OPUS=fable; SONNET/HAIKU stay family defaults
FABLE_OUT="$(PATH="/tmp/9cc-test-bin:$PATH" "$CC" run fable 2>/dev/null || true)"
assert_match "MODEL=cc/claude-fable-5" "$FABLE_OUT" "fable MODEL"
assert_match "OPUS=cc/claude-fable-5" "$FABLE_OUT" "fable OPUS=fable"
assert_match "SONNET=cc/claude-sonnet-5" "$FABLE_OUT" "fable SONNET=sonnet"
assert_match "HAIKU=cc/claude-haiku-4-5-20251001" "$FABLE_OUT" "fable HAIKU=haiku"

# Claude: non-fable (opus/sonnet/haiku) → OPUS defaults to opus-4-8
OPUS_OUT="$(PATH="/tmp/9cc-test-bin:$PATH" "$CC" run opus 2>/dev/null || true)"
assert_match "MODEL=cc/claude-opus-4-8" "$OPUS_OUT" "opus MODEL"
assert_match "OPUS=cc/claude-opus-4-8" "$OPUS_OUT" "opus OPUS"
assert_match "SONNET=cc/claude-sonnet-5" "$OPUS_OUT" "opus SONNET=sonnet"
assert_match "HAIKU=cc/claude-haiku-4-5-20251001" "$OPUS_OUT" "opus HAIKU=haiku"

SONNET_OUT="$(PATH="/tmp/9cc-test-bin:$PATH" "$CC" run sonnet 2>/dev/null || true)"
assert_match "MODEL=cc/claude-sonnet-5" "$SONNET_OUT" "sonnet MODEL"
assert_match "OPUS=cc/claude-opus-4-8" "$SONNET_OUT" "sonnet OPUS=opus default"
assert_match "SONNET=cc/claude-sonnet-5" "$SONNET_OUT" "sonnet SONNET"
assert_match "HAIKU=cc/claude-haiku-4-5-20251001" "$SONNET_OUT" "sonnet HAIKU"

# Grok family: OPUS+SONNET=grok-4.5, HAIKU=composer
GROK_OUT="$(PATH="/tmp/9cc-test-bin:$PATH" "$CC" run grok 2>/dev/null || true)"
assert_match "MODEL=xai/grok-4.5" "$GROK_OUT" "grok MODEL"
assert_match "OPUS=xai/grok-4.5" "$GROK_OUT" "grok OPUS"
assert_match "SONNET=xai/grok-4.5" "$GROK_OUT" "grok SONNET"
assert_match "HAIKU=xai/grok-composer-2.5-fast" "$GROK_OUT" "grok HAIKU=composer"

COMP_OUT="$(PATH="/tmp/9cc-test-bin:$PATH" "$CC" run grokcomposer 2>/dev/null || true)"
assert_match "MODEL=xai/grok-composer-2.5-fast" "$COMP_OUT" "composer MODEL"
assert_match "OPUS=xai/grok-4.5" "$COMP_OUT" "composer OPUS=grok"
assert_match "SONNET=xai/grok-4.5" "$COMP_OUT" "composer SONNET=grok"
assert_match "HAIKU=xai/grok-composer-2.5-fast" "$COMP_OUT" "composer HAIKU"

# Non-family (glm): all three stay selected id (Cycle 6 already covers; re-assert)
GLM_OUT="$(PATH="/tmp/9cc-test-bin:$PATH" "$CC" run glm5 2>/dev/null || true)"
assert_match "OPUS=glm/glm-5.2" "$GLM_OUT" "glm OPUS=id"
assert_match "SONNET=glm/glm-5.2" "$GLM_OUT" "glm SONNET=id"
assert_match "HAIKU=glm/glm-5.2" "$GLM_OUT" "glm HAIKU=id"

rm -rf /tmp/9cc-test-bin "$CLAUDE_SETTINGS"

echo "Cycle 7: install.sh downloads + symlinks (fixture source)"
export CC9_VERSION="v0.3.5"
export CC9_SOURCE="$CC"
export CC9_HOME=/tmp/9cc-home
export CC9_BIN_DIR=/tmp/9cc-bin
rm -rf "$CC9_HOME" "$CC9_BIN_DIR"; mkdir -p "$CC9_BIN_DIR"
bash "$DIR/install.sh" >/tmp/9cc-install.log 2>&1 || { echo "  FAIL: install.sh exit $?"; cat /tmp/9cc-install.log; FAIL=$((FAIL+1)); }
assert_match "cc/claude-fable-5" "$(cat "$CC9_HOME/9cc.sh" 2>/dev/null || true)" "installer wrote 9cc.sh"
[ -x "$CC9_BIN_DIR/9cc" ] && { echo "  ok: symlink created"; PASS=$((PASS+1)); } || { echo "  FAIL: no symlink"; FAIL=$((FAIL+1)); }
if [ -f "$CC9_HOME/sandbox.sh" ] && [ -f "$CC9_HOME/Dockerfile" ] && [ -f "$CC9_HOME/agent-proxy.mjs" ]; then
    echo "  ok: sandbox assets installed next to launcher"; PASS=$((PASS+1));
else
    echo "  FAIL: sandbox assets missing from install layout"; FAIL=$((FAIL+1));
fi
bash "$DIR/install.sh" >>/tmp/9cc-install.log 2>&1 && { echo "  ok: re-run idempotent"; PASS=$((PASS+1)); } || { echo "  FAIL: re-run errored"; FAIL=$((FAIL+1)); }
rm -rf "$CC9_HOME" "$CC9_BIN_DIR" /tmp/9cc-install.log
unset CC9_SOURCE CC9_HOME CC9_BIN_DIR

echo "Cycle 8: cascade_for tiers"
assert_eq "$(cascade_for opus)" "cc/claude-opus-4-8 cx/gpt-5.5-high glm/glm-5.2-max" "opus fallback chain"
assert_eq "$(cascade_for free | wc -w | tr -d ' ')" "10" "free cascade has 10 models"
assert_eq "$(cascade_for free | head -c 38)" "openrouter/poolside/laguna-xs-2.1:free" "free[0]"

echo "Cycle 9: next_model walks opus chain then exits"
assert_eq "$(next_model 'cc/claude-opus-4-8')"        "cx/gpt-5.5-high" "next after opus"
assert_eq "$(next_model 'cx/gpt-5.5-high')"           "glm/glm-5.2-max" "next after gpt"
assert_eq "$(next_model 'glm/glm-5.2-max')"           "openrouter/poolside/laguna-xs-2.1:free" "next chains into free"
assert_eq "$(next_model 'openrouter/nousresearch/hermes-3-llama-3.1-405b:free')" "" "last free -> empty (exit 1)"
if next_model 'openrouter/nousresearch/hermes-3-llama-3.1-405b:free' >/dev/null 2>&1; then echo "  FAIL: exhausted should exit 1"; FAIL=$((FAIL+1)); else echo "  ok: exhausted exits 1"; PASS=$((PASS+1)); fi

echo "Cycle 10: next_model --no-free stops at paid boundary"
assert_eq "$(next_model 'glm/glm-5.2-max' --no-free)" "" "--no-free: no free successor"
if next_model 'glm/glm-5.2-max' --no-free >/dev/null 2>&1; then echo "  FAIL: --no-free at boundary should exit 1"; FAIL=$((FAIL+1)); else echo "  ok: --no-free exits 1 at boundary"; PASS=$((PASS+1)); fi

echo "Cycle 11: next_model unknown current -> exit 1"
if next_model 'nope/model' >/dev/null 2>&1; then echo "  FAIL: unknown should exit 1"; FAIL=$((FAIL+1)); else echo "  ok: unknown exits 1"; PASS=$((PASS+1)); fi

echo "Cycle 12: next subcommand wraps next_model"
assert_match "^cx/gpt-5.5-high$" "$("$CC" next cc/claude-opus-4-8)" "9cc next subcommand"

echo "Cycle 12b: next_model resolves alias -> full id before walking chain"
assert_eq "$(next_model opus)" "cx/gpt-5.5-high" "next accepts alias 'opus'"
# glm5 -> glm/glm-5.2 is NOT on any cascade chain (chain has glm/glm-5.2-MAX) -> exhausted
if next_model glm5 >/dev/null 2>&1; then echo "  FAIL: off-chain alias should exit 1"; FAIL=$((FAIL+1)); else echo "  ok: off-chain alias exits 1"; PASS=$((PASS+1)); fi

echo "Cycle 13: list --json is valid JSON, 13 entries, correct shape"
JSON="$("$CC" list --json)"
if command -v node >/dev/null 2>&1; then
    echo "$JSON" | node -e '
        const d = JSON.parse(require("fs").readFileSync(0,"utf8"));
        if (!Array.isArray(d) || d.length !== 13) { console.error("FAIL: want 13 entries, got", d.length); process.exit(1); }
        const f = d.find(x => x.alias === "fable");
        if (!f || f.id !== "cc/claude-fable-5" || f.window !== 500000) { console.error("FAIL: fable entry wrong", JSON.stringify(f)); process.exit(1); }
        if (!d.every(x => typeof x.window === "number")) { console.error("FAIL: window not numeric"); process.exit(1); }
        console.log("  ok: list --json valid, 13 entries, fable correct, windows numeric");
    ' && PASS=$((PASS+1)) || { echo "  FAIL: list --json"; FAIL=$((FAIL+1)); }
elif command -v python3 >/dev/null 2>&1; then
    echo "$JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert isinstance(d,list) and len(d)==13, ("len", len(d))
f=[x for x in d if x["alias"]=="fable"][0]
assert f["id"]=="cc/claude-fable-5" and f["window"]==500000, f
assert all(isinstance(x["window"],int) for x in d), "window not int"
print("  ok: list --json valid, 13 entries, fable correct, windows numeric")
' && PASS=$((PASS+1)) || { echo "  FAIL: list --json"; FAIL=$((FAIL+1)); }
else
    # No JSON parser: validate shape via grep (array, 13 alias fields, fable entry).
    if printf '%s' "$JSON" | grep -q '^\[{' \
       && [ "$(printf '%s' "$JSON" | grep -o '"alias"' | wc -l)" = "13" ] \
       && printf '%s' "$JSON" | grep -q '"alias":"fable","id":"cc/claude-fable-5"'; then
        echo "  ok: list --json shape valid (no parser)"; PASS=$((PASS+1))
    else
        echo "  FAIL: list --json shape"; FAIL=$((FAIL+1))
    fi
fi

echo "Cycle 14: update command"

API_UP="/tmp/9cc-latest-up.json"
echo '{"tag_name":"v0.1.0"}' > "$API_UP"
OUT="$(CC9_LATEST_API_FIXTURE="$API_UP" CC9_VERSION="v0.1.0" "$CC" update 2>&1 || true)"
assert_eq "$OUT" "9cc is up to date (v0.1.0)" "update up-to-date"

API_NEW="/tmp/9cc-latest-new.json"
echo '{"tag_name":"v0.2.0"}' > "$API_NEW"
INST_DIR="/tmp/9cc-update-install"
rm -rf "$INST_DIR"; mkdir -p "$INST_DIR"
cat > "$INST_DIR/install.sh" <<'STUB'
#!/usr/bin/env bash
echo "INSTALLER_RAN version=$CC9_VERSION"
STUB
chmod +x "$INST_DIR/install.sh"
OUT="$(CC9_LATEST_API_FIXTURE="$API_NEW" CC9_VERSION="v0.1.0" CC9_INSTALL_SOURCE="$INST_DIR/install.sh" "$CC" update 2>&1 || true)"
assert_match "INSTALLER_RAN version=v0.2.0" "$OUT" "update runs installer with new version"
assert_match "9cc updated to v0.2.0" "$OUT" "update reports success"

if CC9_LATEST_API_FIXTURE="/tmp/no-such-fixture-9cc.json" CC9_VERSION="v0.1.0" "$CC" update >/tmp/9cc-update-fail 2>&1; then
    echo "  FAIL: update should exit 1 on API failure"; FAIL=$((FAIL+1))
elif grep -q "9cc update: failed to reach GitHub" /tmp/9cc-update-fail; then
    echo "  ok: update reports API failure"; PASS=$((PASS+1))
else
    echo "  FAIL: update did not report API failure"; cat /tmp/9cc-update-fail; FAIL=$((FAIL+1))
fi

rm -rf "$API_UP" "$API_NEW" "$INST_DIR" /tmp/9cc-update-fail

echo "Cycle 14b: update decodes gh base64 content with embedded whitespace"
GH_BIN_DIR="/tmp/9cc-update-ghbin"
rm -rf "$GH_BIN_DIR"; mkdir -p "$GH_BIN_DIR"
# Fake gh: emit install.sh content base64-encoded with line breaks (as GitHub does).
cat > "$GH_BIN_DIR/gh" <<'GHSTUB'
#!/usr/bin/env bash
# Args: api repos/.../contents/.../install.sh?ref=... --jq '.content'
# Mimic real gh: emit ONLY the .content field (wrapped base64), as GitHub does.
payload=$'#!/usr/bin/env bash\necho "INSTALLER_RAN version=$CC9_VERSION"\n'
b64="$(printf '%s' "$payload" | base64 | fold -w 30)"
printf '%s\n' "$b64"
GHSTUB
chmod +x "$GH_BIN_DIR/gh"
API_NEW2="/tmp/9cc-latest-new2.json"
echo '{"tag_name":"v0.2.0"}' > "$API_NEW2"
OUT="$(CC9_LATEST_API_FIXTURE="$API_NEW2" CC9_VERSION="v0.1.0" PATH="$GH_BIN_DIR:$PATH" "$CC" update 2>&1 || true)"
assert_match "INSTALLER_RAN version=v0.2.0" "$OUT" "update decodes whitespace-laden base64"
rm -rf "$GH_BIN_DIR" "$API_NEW2"

echo "Cycle 14c: update survives a macOS-strict base64 (rejects embedded whitespace)"
# Simulate the macOS base64 binary, which errors on line-wrapped base64. On a
# Linux-only CI this is the only way to prove the decode path does not regress.
SHIM_DIR="/tmp/9cc-b64-shim"; rm -rf "$SHIM_DIR"; mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/base64" <<'SHIMSTUB'
#!/usr/bin/env bash
# macOS-style: accept only single-line input; any whitespace -> fail decode.
input="$(cat)"
if printf '%s' "$input" | grep -q '[[:space:]]'; then exit 1; fi
printf '%s' "$input" | /usr/bin/base64 "$@"
SHIMSTUB
chmod +x "$SHIM_DIR/base64"
GH_BIN_DIR2="/tmp/9cc-update-ghbin2"
rm -rf "$GH_BIN_DIR2"; mkdir -p "$GH_BIN_DIR2"
cat > "$GH_BIN_DIR2/gh" <<'GHSTUB'
#!/usr/bin/env bash
payload=$'#!/usr/bin/env bash\necho "INSTALLER_RAN version=$CC9_VERSION"\n'
printf '%s' "$payload" | /usr/bin/base64 | fold -w 30
GHSTUB
chmod +x "$GH_BIN_DIR2/gh"
API_NEW3="/tmp/9cc-latest-new3.json"; echo '{"tag_name":"v0.2.0"}' > "$API_NEW3"
OUT="$(CC9_LATEST_API_FIXTURE="$API_NEW3" CC9_VERSION="v0.1.0" PATH="$GH_BIN_DIR2:$SHIM_DIR:$PATH" "$CC" update 2>&1 || true)"
assert_match "INSTALLER_RAN version=v0.2.0" "$OUT" "update decodes even with strict base64"
rm -rf "$SHIM_DIR" "$GH_BIN_DIR2" "$API_NEW3"

echo "Cycle 14d: install.sh uses atomic temp+mv for launcher (self-update safety)"
if grep -q 'atomic_install' "$DIR/install.sh" \
   && grep -q 'mktemp' "$DIR/install.sh" \
   && grep -q 'mv -f' "$DIR/install.sh" \
   && ! grep -E 'base64 -d > "\$CC9_HOME/9cc\.sh"' "$DIR/install.sh"; then
    echo "  ok: install.sh uses atomic install (no in-place truncate of launcher)"; PASS=$((PASS+1))
else
    echo "  FAIL: install.sh missing atomic launcher install"; FAIL=$((FAIL+1))
fi
if grep -q 'exit 0' "$DIR/9cc.sh" \
   && awk '/^do_update\(\)/,/^do_uninstall\(\)/' "$DIR/9cc.sh" | grep -q 'exit 0'; then
    echo "  ok: do_update exits after successful install"; PASS=$((PASS+1))
else
    echo "  FAIL: do_update does not exit after install"; FAIL=$((FAIL+1))
fi

echo "Cycle 14e: live self-overwrite — update replaces running 9cc.sh without syntax error"
# Repro for macOS bash 3.2: overwriting the executing script in place corrupts the
# parse stream ("syntax error near ;;"). Real install.sh must replace atomically,
# and do_update must complete cleanly while the old process is still alive.
SO_WORK=/tmp/9cc-self-overwrite
rm -rf "$SO_WORK"
mkdir -p "$SO_WORK/home" "$SO_WORK/bin"
# Seed an "installed" copy of the current launcher (this is the running file).
cp "$CC" "$SO_WORK/home/9cc.sh"
chmod +x "$SO_WORK/home/9cc.sh"
printf 'v0.1.0\n' > "$SO_WORK/home/version"
ln -sfn "$SO_WORK/home/9cc.sh" "$SO_WORK/bin/9cc"
# New payload: same launcher but with a trailing comment so content length differs.
cp "$CC" "$SO_WORK/new-9cc.sh"
printf '\n# self-overwrite-marker v0.2.0\n' >> "$SO_WORK/new-9cc.sh"
API_SO="$SO_WORK/latest.json"
echo '{"tag_name":"v0.2.0"}' > "$API_SO"
set +e
SO_OUT="$(
  CC9_HOME="$SO_WORK/home" \
  CC9_BIN_DIR="$SO_WORK/bin" \
  CC9_VERSION="v0.1.0" \
  CC9_LATEST_API_FIXTURE="$API_SO" \
  CC9_INSTALL_SOURCE="$DIR/install.sh" \
  CC9_SOURCE="$SO_WORK/new-9cc.sh" \
  PATH="$SO_WORK/bin:$PATH" \
  "$SO_WORK/bin/9cc" update 2>&1
)"
SO_EC=$?
set -e
if [ "$SO_EC" -eq 0 ] \
   && ! echo "$SO_OUT" | grep -qi 'syntax error' \
   && echo "$SO_OUT" | grep -q '9cc updated to v0.2.0' \
   && echo "$SO_OUT" | grep -q '9cc v0.2.0' \
   && grep -q 'self-overwrite-marker' "$SO_WORK/home/9cc.sh" \
   && [ "$(cat "$SO_WORK/home/version")" = "v0.2.0" ]; then
    echo "  ok: self-overwrite update completes without syntax error"; PASS=$((PASS+1))
else
    echo "  FAIL: self-overwrite update broken (ec=$SO_EC)"; echo "$SO_OUT"; FAIL=$((FAIL+1))
fi
# Negative control: in-place truncate of a running script must produce the classic error
# (documents why atomic install is required; skips if bash fully buffers the script).
NEG="$SO_WORK/neg.sh"
cat > "$NEG" <<'NEGS'
#!/usr/bin/env bash
set -euo pipefail
# pad so mid-file rewrite lands past the overwrite point
x=1
# OVERWRITE_POINT
echo BEFORE_OVERWRITE
# Truncate+rewrite this same file while running (old broken installer behaviour).
cat > "$0" <<'NEW'
#!/usr/bin/env bash
echo REPLACED_CONTENT
NEW
# More statements bash must re-read after the rewrite — often "syntax error".
case x in
  x) echo AFTER_CASE ;;
  *) echo NOPE ;;
esac
echo AFTER_OVERWRITE
NEGS
chmod +x "$NEG"
set +e
NEG_OUT="$(bash "$NEG" 2>&1)"
NEG_EC=$?
set -e
if echo "$NEG_OUT" | grep -qi 'syntax error' || [ "$NEG_EC" -ne 0 ]; then
    echo "  ok: negative control — in-place self-overwrite is unsafe (ec=$NEG_EC)"; PASS=$((PASS+1))
else
    # Some bash builds fully buffer short scripts; still record as skip-ok if AFTER never prints.
    if echo "$NEG_OUT" | grep -q 'AFTER_OVERWRITE'; then
        echo "  FAIL: negative control did not break (bash fully buffered?)"; echo "$NEG_OUT"; FAIL=$((FAIL+1))
    else
        echo "  ok: negative control — in-place overwrite disrupted execution"; PASS=$((PASS+1))
    fi
fi
rm -rf "$SO_WORK"

echo "Cycle 15: uninstall command"
export CC9_VERSION="v0.3.5"
export CC9_HOME=/tmp/9cc-uninstall-home
export CC9_BIN_DIR=/tmp/9cc-uninstall-bin
rm -rf "$CC9_HOME" "$CC9_BIN_DIR"; mkdir -p "$CC9_BIN_DIR"
CC9_SOURCE="$CC" bash "$DIR/install.sh" >/tmp/9cc-uninstall-install.log 2>&1 || { echo "  FAIL: install.sh exit $?"; cat /tmp/9cc-uninstall-install.log; FAIL=$((FAIL+1)); }
PATH="$CC9_BIN_DIR:$PATH" "$CC" uninstall >/tmp/9cc-uninstall.log 2>&1 || true
if [ -d "$CC9_HOME" ]; then echo "  FAIL: $CC9_HOME still exists"; FAIL=$((FAIL+1)); else echo "  ok: home removed"; PASS=$((PASS+1)); fi
if [ -L "$CC9_BIN_DIR/9cc" ] || [ -e "$CC9_BIN_DIR/9cc" ]; then echo "  FAIL: symlink not removed"; FAIL=$((FAIL+1)); else echo "  ok: symlink removed"; PASS=$((PASS+1)); fi
rm -rf "$CC9_HOME" "$CC9_BIN_DIR" /tmp/9cc-uninstall-install.log /tmp/9cc-uninstall.log
unset CC9_SOURCE CC9_HOME CC9_BIN_DIR

echo "Cycle 16: install.sh prefers gh contents when CC9_SOURCE is remote URL"
# Simulate remote: set CC9_SOURCE to a non-file URL and intercept via a fake PATH/gh is hard;
# instead assert the source script contains the gh contents fetch branch (static contract).
if grep -q 'contents/9cc/9cc.sh' "$DIR/install.sh" \
   && grep -q 'command -v gh' "$DIR/install.sh" \
   && grep -q 'raw.githubusercontent.com' "$DIR/install.sh"; then
    echo "  ok: install.sh has gh contents + raw fallback"
    PASS=$((PASS+1))
else
    echo "  FAIL: install.sh missing gh-first body fetch"
    FAIL=$((FAIL+1))
fi

echo "Cycle 17: get_latest_tag prefers gh"
if awk '/get_latest_tag\(\)/,/^}/' "$DIR/9cc.sh" | grep -q 'command -v gh'; then
    echo "  ok: get_latest_tag uses gh"; PASS=$((PASS+1))
else
    echo "  FAIL: get_latest_tag missing gh preference"; FAIL=$((FAIL+1))
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
