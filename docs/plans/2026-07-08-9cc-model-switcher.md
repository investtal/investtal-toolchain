# 9cc — Claude Code Model Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `subagent-parallel-execution` (recommended) or inline execution via `finishing-execution` to implement task-by-task. Steps use `- [ ]` checkboxes. Every code task follows **RED → GREEN → REFACTOR** (TDD): write failing test, run it (fails), write minimal code, run it (passes), refactor, commit.

**Goal:** Ship `9cc` CLI (2 launchers: `9cc.sh` + `9cc.ps1`) + one-liner installers (`install.sh` + `install.ps1`). Launch Claude Code with dynamic model + compact-window over 9Router, reading auth from `settings.json` without mutating it.

**Architecture:** Each launcher holds a 13-model registry (alias → 9Router ID + context window). On `run <alias>`, it reads `ANTHROPIC_BASE_URL` + `ANTHROPIC_API_KEY` from `~/.claude/settings.json` (via `node -e` in bash — Node guaranteed because `claude` requires it; via `ConvertFrom-Json` in PowerShell), exports `ANTHROPIC_MODEL` + `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` + `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, then `exec claude`. No file writes anywhere. Shell env overrides the `settings.json` `env` block (Claude Code precedence: shell env > settings env block).

Installers: `curl | bash` (mac/linux) and `irm | iex` (windows) download the launcher into `~/.9cc/` and symlink into a PATH dir (`/usr/local/bin` or `~/.local/bin` on unix; a PATH dir on windows). Mirrors the `bun`/`rust` install pattern.

**Tech Stack:** Bash 3.2+/4+, PowerShell 5.1+, Node.js (JSON parse in bash). No jq, no test framework — assert-based self-checks (`assert_eq` helpers).

## Global Constraints

- **Two launchers only:** `9cc.sh` (mac/linux/wsl), `9cc.ps1` (windows). Identical behavior.
- **Two installers only:** `install.sh` (curl|bash), `install.ps1` (irm|iex).
- **Auth var:** `ANTHROPIC_API_KEY` (NOT `ANTHROPIC_AUTH_TOKEN`).
- **No config mutation:** Never write to `~/.claude/settings.json`. Read-only.
- **Secret source:** Read `env.ANTHROPIC_BASE_URL` + `env.ANTHROPIC_API_KEY` from `~/.claude/settings.json`. No `9cc.env`, no `setup` command.
- **JSON parse in bash:** `node -e` (Node guaranteed — `claude` needs it). Error if node missing.
- **Uniform model:** `run <alias>` sets `ANTHROPIC_MODEL` AND all 3 `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` to same value.
- **Dual alias:** accept short (`fable`) and full ID (`glm/glm-5.2`).
- **Pass-through:** `run <alias> [args...]` forwards extra args to `claude`.
- **Registry:** exactly 13 models + windows in spec table. Verbatim IDs.
- **TDD:** every registry/dispatch behavior gets a failing test first. `claude` itself is never invoked in tests (stub it).

---

## File Structure

- **Create** `scripts/9cc.sh` — Bash launcher. Registry, `list`/`run`/`help` dispatch, node JSON read, env export + exec.
- **Create** `scripts/9cc.ps1` — PowerShell launcher. Mirror of `9cc.sh`.
- **Create** `scripts/9cc.test.sh` — Bash TDD test harness (assert-based). Guards registry, dispatch, arg-parse.
- **Create** `scripts/9cc.test.ps1` — PowerShell TDD harness. Mirror.
- **Create** `scripts/install.sh` — curl|bash installer. Downloads `9cc.sh`, symlinks into PATH.
- **Create** `scripts/install.ps1` — irm|iex installer. Downloads `9cc.ps1`, symlinks/copies into PATH.
- **Modify** `README.md` — one-liner install + usage.

---

## Task 1: 9cc.sh — TDD registry + dispatch

**Files:**
- Create: `scripts/9cc.test.sh` (test first)
- Create: `scripts/9cc.sh` (impl)
- Stub: `scripts/claude-stub` (fake `claude` binary so tests never hit network)

**Interfaces:**
- Produces: `9cc.sh` functions `get_model <key>` (echoes `<id>|<window>`), `list_models`, `run_session`, `show_help`. Sourcing-safe (dispatch only when executed directly).

**TDD cycles:**
1. Registry: 13 aliases map to correct id+window.
2. Full-ID resolves (`glm/glm-5.2`).
3. Unknown alias → `get_model` exit 1.
4. `list` prints all 13.
5. `run` no arg → exit 1.
6. `run <alias>` with `claude` stubbed exports the 5 env vars correctly + calls claude with forwarded args.

- [ ] **Step 1 (RED): Write failing test harness** — create `scripts/9cc.test.sh`:
```bash
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
declare -A WANT=( [fable]=cc/fable-5|200000 [opus]=cc/claude-opus-4-8|200000 [sonnet]=cc/claude-sonnet-5|200000
  [haiku]=cc/claude-haiku-4-5-20251001|200000 [gpt5]=cx/gpt-5.5|128000 [glm5]=glm/glm-5.2|1000000
  [glmturbo]=glm/glm-5-turbo|1000000 [deepseek]=ds/deepseek-v4-pro|1000000 [dsflash]=ds/deepseek-v4-flash|1000000
  [kimi]=kimi/kimi-k2.7|1000000 [grok]=gc/grok-build|500000 [grokcomposer]=gc/grok-composer-2.5-fast|500000
  [minimax]=minimax/MiniMax-M3|1000000 )
for alias in "${!WANT[@]}"; do assert_eq "$(get_model "$alias")" "${WANT[$alias]}" "alias $alias"; done

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
# fake settings.json with auth
export CLAUDE_SETTINGS=/tmp/9cc-test-settings.json
printf '{"env":{"ANTHROPIC_BASE_URL":"https://gw.example/v1","ANTHROPIC_API_KEY":"sk-test"}}' > "$CLAUDE_SETTINGS"
RUN_OUT="$(PATH="/tmp/9cc-test-bin:$PATH" "$CC" run glm5 --resume extra 2>/dev/null || true)"
assert_match "MODEL=glm/glm-5.2" "$RUN_OUT" "run sets ANTHROPIC_MODEL"
assert_match "OPUS=glm/glm-5.2"  "$RUN_OUT" "run sets OPUS_MODEL"
assert_match "SONNET=glm/glm-5.2" "$RUN_OUT" "run sets SONNET_MODEL"
assert_match "HAIKU=glm/glm-5.2" "$RUN_OUT" "run sets HAIKU_MODEL"
assert_match "WIN=1000000"       "$RUN_OUT" "run sets compact window"
assert_match "args:--resume extra" "$RUN_OUT" "run forwards extra args"
# claude never called on unknown alias
if PATH="/tmp/9cc-test-bin:$PATH" "$CC" run bogus >/tmp/9cc-bogus 2>&1; then
    echo "  FAIL: run-bogus should exit 1"; FAIL=$((FAIL+1));
elif grep -q STUB_CALLED /tmp/9cc-bogus; then echo "  FAIL: claude called on bad alias"; FAIL=$((FAIL+1));
else echo "  ok: run-bogus exits 1, no claude call"; PASS=$((PASS+1)); fi
rm -rf /tmp/9cc-test-bin "$CLAUDE_SETTINGS" /tmp/9cc-bogus

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2 (RED): Run, verify fail** — Run: `bash scripts/9cc.test.sh`
Expected: FAIL (`9cc.sh` missing → source errors, assertions fail).

- [ ] **Step 3 (GREEN): Minimal 9cc.sh** — create `scripts/9cc.sh`:
```bash
#!/usr/bin/env bash
# 9cc — launch Claude Code with a dynamic model over the 9Router gateway.
# Reads auth from ~/.claude/settings.json (read-only). Mac/Linux/WSL.
# Usage: 9cc list | 9cc run <alias-or-id> [claude args...] | 9cc help
set -euo pipefail

CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

# get_model <alias-or-id> -> echo "<9RouterID>|<window>"; exit 1 if unknown.
get_model() {
    case "$1" in
        fable|cc/fable-5)                       echo "cc/fable-5|200000" ;;
        opus|cc/claude-opus-4-8)                echo "cc/claude-opus-4-8|200000" ;;
        sonnet|cc/claude-sonnet-5)              echo "cc/claude-sonnet-5|200000" ;;
        haiku|cc/claude-haiku-4-5-20251001)     echo "cc/claude-haiku-4-5-20251001|200000" ;;
        gpt5|cx/gpt-5.5)                        echo "cx/gpt-5.5|128000" ;;
        glm5|glm/glm-5.2)                       echo "glm/glm-5.2|1000000" ;;
        glmturbo|glm/glm-5-turbo)               echo "glm/glm-5-turbo|1000000" ;;
        deepseek|ds/deepseek-v4-pro)            echo "ds/deepseek-v4-pro|1000000" ;;
        dsflash|ds/deepseek-v4-flash)           echo "ds/deepseek-v4-flash|1000000" ;;
        kimi|kimi/kimi-k2.7)                    echo "kimi/kimi-k2.7|1000000" ;;
        grok|gc/grok-build)                     echo "gc/grok-build|500000" ;;
        grokcomposer|gc/grok-composer-2.5-fast) echo "gc/grok-composer-2.5-fast|500000" ;;
        minimax|minimax/MiniMax-M3)             echo "minimax/MiniMax-M3|1000000" ;;
        *) return 1 ;;
    esac
}

show_help() {
    cat <<'EOF'
9cc — Claude Code model switcher over 9Router
Usage:
  9cc list                       List supported models
  9cc run <alias|id> [args...]   Launch claude with that model (extra args forwarded)
  9cc help                       Show this help
Shortcuts: fable opus sonnet haiku gpt5 glm5 glmturbo deepseek dsflash kimi grok grokcomposer minimax
In-session: type /model <id> (e.g. /model glm/glm-5.2) to switch without restarting.
EOF
}

list_models() {
    printf '%-14s %-32s %s\n' "ALIAS" "9ROUTER_ID" "WINDOW"
    local id win
    for row in \
        "fable|cc/fable-5|200000" "opus|cc/claude-opus-4-8|200000" "sonnet|cc/claude-sonnet-5|200000" \
        "haiku|cc/claude-haiku-4-5-20251001|200000" "gpt5|cx/gpt-5.5|128000" "glm5|glm/glm-5.2|1000000" \
        "glmturbo|glm/glm-5-turbo|1000000" "deepseek|ds/deepseek-v4-pro|1000000" "dsflash|ds/deepseek-v4-flash|1000000" \
        "kimi|kimi/kimi-k2.7|1000000" "grok|gc/grok-build|500000" "grokcomposer|gc/grok-composer-2.5-fast|500000" \
        "minimax|minimax/MiniMax-M3|1000000"; do
        local a="${row%%|*}"; local rest="${row#*|}"; id="${rest%%|*}"; win="${rest##*|}"
        printf '%-14s %-32s %s\n' "$a" "$id" "$win"
    done
}

read_setting() {
    command -v node >/dev/null 2>&1 || { echo "9cc: node not found (required to read settings.json)" >&2; return 1; }
    local v; v="$(CLAUDE_SETTINGS="$CLAUDE_SETTINGS" node -e '
        const fs=require("fs"); let s={};
        try{ s=JSON.parse(fs.readFileSync(process.env.CLAUDE_SETTINGS,"utf8")); }catch(e){ process.exit(1); }
        const v=(s.env||{})[process.argv[1]];
        if(!v) process.exit(1);
        process.stdout.write(v);
    ' "$1")" || { echo "9cc: '$1' not found in $CLAUDE_SETTINGS env" >&2; return 1; }
    printf '%s' "$v"
}

run_session() {
    local key="$1"; shift || true
    local props; props="$(get_model "$key")" || { echo "9cc: unknown model '$key'. Run '9cc list'." >&2; return 1; }
    local id="${props%%|*}"; local win="${props##*|}"
    local base token
    base="$(read_setting ANTHROPIC_BASE_URL)" || return 1
    token="$(read_setting ANTHROPIC_API_KEY)" || return 1
    export ANTHROPIC_BASE_URL="$base"
    export ANTHROPIC_API_KEY="$token"
    export ANTHROPIC_MODEL="$id"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$id"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$id"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$id"
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$win"
    echo "9cc -> $id (window $win)" >&2
    exec claude "$@"
}

main() {
    case "${1:-help}" in
        list) list_models ;;
        run)  shift || true; [ "${1:-}" ] || { echo "9cc: missing model. Usage: 9cc run <alias|id>" >&2; return 1; }; run_session "$@" ;;
        help|-h|--help) show_help ;;
        *) echo "9cc: unknown command '$1'. Run '9cc help'." >&2; return 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then main "$@"; fi
```

- [ ] **Step 4 (GREEN): Run, verify pass** — Run: `bash scripts/9cc.test.sh`
Expected: `PASS=<N> FAIL=0`.

- [ ] **Step 5 (REFACTOR): Review for dup** — registry appears in both `get_model` (case) and `list_models` (loop). If maintainability concern, leave as-is (case-stmt fast path + list rendering differ; merging adds complexity for 13 entries). Document with `# ponytail: registry duplicated in get_model + list_models — acceptable at 13 entries; extract to data table if grows past 30`.
Run: `bash scripts/9cc.test.sh` → still PASS.

- [ ] **Step 6: chmod + commit** — `chmod +x scripts/9cc.sh && git add scripts/9cc.sh scripts/9cc.test.sh && git commit -m "feat(9cc): bash launcher with TDD-covered registry, list/run/help"`

---

## Task 2: 9cc.ps1 — TDD mirror of 9cc.sh

**Files:**
- Create: `scripts/9cc.test.ps1` (test first)
- Create: `scripts/9cc.ps1` (impl)

**Interfaces:**
- Consumes: identical contract to Task 1 `9cc.sh`.
- Produces: `Get-Model <key>` returns `@{Id;Window}` or `$null`; `List-Models`; `Invoke-Session`; `Show-Help`. Dot-source-safe via `-DotSource`.

**TDD cycles:** registry 13, full-ID resolve, unknown→null, `list` has all, `run` no-arg errors.

- [ ] **Step 1 (RED): Write failing test** — create `scripts/9cc.test.ps1`:
```powershell
# 9cc.ps1 TDD harness. Assert-based. Run: pwsh -File scripts/9cc.test.ps1
$ErrorActionPreference = 'Stop'
$DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Pass = 0; $script:Fail = 0
function Assert-Eq($a, $b, $label) {
    if ($a -eq $b) { Write-Host "  ok: $label"; $script:Pass++ }
    else { Write-Host "  FAIL: $label - want '$b' got '$a'"; $script:Fail++ }
}
. "$DIR/9cc.ps1" -DotSource

Write-Host "Cycle 1: registry 13 aliases"
$want = @{
  fable=@{Id='cc/fable-5';Window='200000'}; opus=@{Id='cc/claude-opus-4-8';Window='200000'}
  sonnet=@{Id='cc/claude-sonnet-5';Window='200000'}; haiku=@{Id='cc/claude-haiku-4-5-20251001';Window='200000'}
  gpt5=@{Id='cx/gpt-5.5';Window='128000'}; glm5=@{Id='glm/glm-5.2';Window='1000000'}
  glmturbo=@{Id='glm/glm-5-turbo';Window='1000000'}; deepseek=@{Id='ds/deepseek-v4-pro';Window='1000000'}
  dsflash=@{Id='ds/deepseek-v4-flash';Window='1000000'}; kimi=@{Id='kimi/kimi-k2.7';Window='1000000'}
  grok=@{Id='gc/grok-build';Window='500000'}; grokcomposer=@{Id='gc/grok-composer-2.5-fast';Window='500000'}
  minimax=@{Id='minimax/MiniMax-M3';Window='1000000'}
}
foreach ($k in $want.Keys) {
    $m = Get-Model $k
    Assert-Eq $m.Id $want[$k].Id "$k id"
    Assert-Eq $m.Window $want[$k].Window "$k window"
}

Write-Host "Cycle 2: full-ID resolve"
$f = Get-Model 'glm/glm-5.2'; Assert-Eq $f.Id 'glm/glm-5.2' "full glm"
$f2 = Get-Model 'cc/fable-5'; Assert-Eq $f2.Id 'cc/fable-5' "full fable"

Write-Host "Cycle 3: unknown -> null"
if ($null -eq (Get-Model 'nope')) { Write-Host "  ok: unknown null"; $script:Pass++ } else { Write-Host "  FAIL"; $script:Fail++ }

Write-Host "Cycle 4: list prints all"
$out = List-Models
foreach ($k in $want.Keys) { if ($out -match $k) { Write-Host "  ok: list has $k"; $script:Pass++ } else { Write-Host "  FAIL: list missing $k"; $script:Fail++ } }

Write-Host "----"
Write-Host "PASS=$script:Pass FAIL=$script:Fail"
if ($script:Fail -ne 0) { exit 1 }
```

- [ ] **Step 2 (RED): Run, verify fail** — Run: `pwsh -File scripts/9cc.test.ps1` (or `powershell`)
Expected: FAIL (`9cc.ps1` missing).

- [ ] **Step 3 (GREEN): Minimal 9cc.ps1** — create `scripts/9cc.ps1`:
```powershell
# 9cc — launch Claude Code with a dynamic model over the 9Router gateway.
# Reads auth from ~/.claude/settings.json (read-only). Windows native.
# Usage: 9cc.ps1 list | 9cc.ps1 run <alias-or-id> [claude args...] | 9cc.ps1 help
[CmdletBinding()]
param([switch]$DotSource)
$ErrorActionPreference = 'Stop'
$SettingsPath = if ($env:CLAUDE_SETTINGS) { $env:CLAUDE_SETTINGS } else { Join-Path ([System.Environment]::GetFolderPath('UserProfile')) '.claude\settings.json' }

$Script:ModelMap = [ordered]@{
    'fable'        = @{ Id='cc/fable-5';                    Window='200000' }
    'opus'         = @{ Id='cc/claude-opus-4-8';            Window='200000' }
    'sonnet'       = @{ Id='cc/claude-sonnet-5';            Window='200000' }
    'haiku'        = @{ Id='cc/claude-haiku-4-5-20251001';  Window='200000' }
    'gpt5'         = @{ Id='cx/gpt-5.5';                    Window='128000' }
    'glm5'         = @{ Id='glm/glm-5.2';                   Window='1000000' }
    'glmturbo'     = @{ Id='glm/glm-5-turbo';               Window='1000000' }
    'deepseek'     = @{ Id='ds/deepseek-v4-pro';            Window='1000000' }
    'dsflash'      = @{ Id='ds/deepseek-v4-flash';          Window='1000000' }
    'kimi'         = @{ Id='kimi/kimi-k2.7';                Window='1000000' }
    'grok'         = @{ Id='gc/grok-build';                 Window='500000' }
    'grokcomposer' = @{ Id='gc/grok-composer-2.5-fast';     Window='500000' }
    'minimax'      = @{ Id='minimax/MiniMax-M3';            Window='1000000' }
}

function Get-Model { param([string]$Key)
    if ($Script:ModelMap.ContainsKey($Key)) { return $Script:ModelMap[$Key] }
    foreach ($v in $Script:ModelMap.Values) { if ($v.Id -eq $Key) { return $v } }
    return $null
}

function Show-Help {
    Write-Host "9cc - Claude Code model switcher over 9Router"
    Write-Host "Usage:"
    Write-Host "  9cc.ps1 list                    List supported models"
    Write-Host "  9cc.ps1 run <alias|id> [args]   Launch claude with that model (extra args forwarded)"
    Write-Host "  9cc.ps1 help                    Show this help"
    Write-Host "Shortcuts: fable opus sonnet haiku gpt5 glm5 glmturbo deepseek dsflash kimi grok grokcomposer minimax"
    Write-Host "In-session: type /model <id> (e.g. /model glm/glm-5.2) to switch without restarting."
}

function List-Models {
    "{0,-14} {1,-32} {2}" -f 'ALIAS','9ROUTER_ID','WINDOW'
    foreach ($k in $Script:ModelMap.Keys) { $v = $Script:ModelMap[$k]; "{0,-14} {1,-32} {2}" -f $k,$v.Id,$v.Window }
}

function Read-Setting { param([string]$Name)
    if (-not (Test-Path $SettingsPath)) { throw "9cc: settings not found at $SettingsPath" }
    $cfg = Get-Content -Raw $SettingsPath | ConvertFrom-Json
    $val = $cfg.env.$Name
    if (-not $val) { throw "9cc: '$Name' not found in $SettingsPath env block" }
    return $val
}

function Invoke-Session { param([string]$Key,[string[]]$ExtraArgs)
    $m = Get-Model $Key
    if (-not $m) { Write-Error "9cc: unknown model '$Key'. Run '9cc.ps1 list'."; exit 1 }
    $env:CLAUDE_SETTINGS = $SettingsPath
    $env:ANTHROPIC_BASE_URL = Read-Setting 'ANTHROPIC_BASE_URL'
    $env:ANTHROPIC_API_KEY   = Read-Setting 'ANTHROPIC_API_KEY'
    $env:ANTHROPIC_MODEL              = $m.Id
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL   = $m.Id
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $m.Id
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = $m.Id
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $m.Window
    Write-Host "9cc -> $($m.Id) (window $($m.Window))" -ForegroundColor Cyan
    if ($ExtraArgs) { & claude @ExtraArgs } else { & claude }
}

if (-not $DotSource) {
    if ($args.Count -eq 0) { Show-Help; return }
    switch ($args[0]) {
        'list' { List-Models }
        'run'  { if ($args.Count -lt 2) { Write-Error "9cc: missing model. Usage: 9cc.ps1 run <alias|id>"; exit 1 }
                 Invoke-Session -Key $args[1] -ExtraArgs ($args | Select-Object -Skip 2) }
        { $_ -in 'help','-h','--help' } { Show-Help }
        default { Write-Error "9cc: unknown command '$($args[0])'. Run '9cc.ps1 help'."; exit 1 }
    }
}
```

- [ ] **Step 4 (GREEN): Run, verify pass** — Run: `pwsh -File scripts/9cc.test.ps1`
Expected: `PASS=<N> FAIL=0`. *(If no `pwsh`/Windows host: run bash test only, note in commit — bash test guards the shared registry values verbatim.)*

- [ ] **Step 5: Commit** — `git add scripts/9cc.ps1 scripts/9cc.test.ps1 && git commit -m "feat(9cc): powershell launcher with TDD mirror of bash launcher"`

---

## Task 3: install.sh — curl|bash one-liner

**Files:**
- Create: `scripts/install.sh`

**Interfaces:**
- Produces: downloads `9cc.sh` into `~/.9cc/9cc.sh`, symlinks into first writable of `/usr/local/bin`, `$HOME/.local/bin`. Idempotent.

**TDD cycle:**
1. Creates `~/.9cc/9cc.sh` from a local fixture (test points `9CC_SOURCE` at fixture).
2. Symlinks `9cc` into a writable bin dir.
3. Re-run is idempotent (no error).

- [ ] **Step 1 (RED): Extend test harness** — append to `scripts/9cc.test.sh` before the final `echo "----"`:
```bash
echo "Cycle 7: install.sh downloads + symlinks (fixture source)"
# point installer at local 9cc.sh as the "download" source
export 9CC_SOURCE="$CC"               # installer reads from here instead of curl
export 9CC_HOME=/tmp/9cc-home
export 9CC_BIN_DIR=/tmp/9cc-bin
rm -rf "$9CC_HOME" "$9CC_BIN_DIR"; mkdir -p "$9CC_BIN_DIR"
bash "$DIR/install.sh" >/tmp/9cc-install.log 2>&1 || { echo "  FAIL: install.sh exit $?"; cat /tmp/9cc-install.log; FAIL=$((FAIL+1)); }
assert_match "cc/fable-5" "$(cat "$9CC_HOME/9cc.sh" 2>/dev/null || true)" "installer wrote 9cc.sh"
[ -x "$9CC_BIN_DIR/9cc" ] && { echo "  ok: symlink created"; PASS=$((PASS+1)); } || { echo "  FAIL: no symlink"; FAIL=$((FAIL+1)); }
# idempotent re-run
bash "$DIR/install.sh" >>/tmp/9cc-install.log 2>&1 && { echo "  ok: re-run idempotent"; PASS=$((PASS+1)); } || { echo "  FAIL: re-run errored"; FAIL=$((FAIL+1)); }
rm -rf "$9CC_HOME" "$9CC_BIN_DIR" /tmp/9cc-install.log
unset 9CC_SOURCE 9CC_HOME 9CC_BIN_DIR
```

- [ ] **Step 2 (RED): Run, verify fail** — Run: `bash scripts/9cc.test.sh`
Expected: FAIL (Cycle 7 — `install.sh` missing).

- [ ] **Step 3 (GREEN): install.sh** — create `scripts/install.sh`:
```bash
#!/usr/bin/env bash
# 9cc installer — curl -fsSL <raw url>/install.sh | bash
# Downloads 9cc.sh into ~/.9cc and symlinks `9cc` into a writable PATH dir.
set -euo pipefail

9CC_HOME="${9CC_HOME:-$HOME/.9cc}"
9CC_SOURCE="${9CC_SOURCE:-https://raw.githubusercontent.com/investtal/investtal-toolchain/main/scripts/9cc.sh}"
# prefer explicit 9CC_BIN_DIR, else first writable candidate
if [ -z "${9CC_BIN_DIR:-}" ]; then
    for c in /usr/local/bin "$HOME/.local/bin"; do
        if [ -w "$c" ] || mkdir -p "$c" 2>/dev/null && [ -w "$c" ]; then 9CC_BIN_DIR="$c"; break; fi
    done
fi
if [ -z "${9CC_BIN_DIR:-}" ]; then echo "install: no writable bin dir found (set 9CC_BIN_DIR)" >&2; exit 1; fi

mkdir -p "$9CC_HOME" "$9CC_BIN_DIR"

if [ -f "$9CC_SOURCE" ]; then cp "$9CC_SOURCE" "$9CC_HOME/9cc.sh";     # local fixture / file:// (tests)
else curl -fsSL "$9CC_SOURCE" -o "$9CC_HOME/9cc.sh"; fi
chmod +x "$9CC_HOME/9cc.sh"

ln -sfn "$9CC_HOME/9cc.sh" "$9CC_BIN_DIR/9cc"

echo "9cc installed: $9CC_HOME/9cc.sh"
echo "symlink:       $9CC_BIN_DIR/9cc  (ensure it's on your PATH)"
```

- [ ] **Step 4 (GREEN): Run, verify pass** — Run: `bash scripts/9cc.test.sh`
Expected: all cycles PASS=... FAIL=0.

- [ ] **Step 5: Commit** — `chmod +x scripts/install.sh && git add scripts/install.sh scripts/9cc.test.sh && git commit -m "feat(9cc): curl|bash installer with PATH symlink"`

---

## Task 4: install.ps1 — irm|iex one-liner

**Files:**
- Create: `scripts/install.ps1`

**Interfaces:**
- Produces: downloads `9cc.ps1` into `$env:USERPROFILE\.9cc\9cc.ps1`, copies/symlinks `9cc.ps1` into a writable PATH dir.

**TDD cycle:** download into fixture dir + verify file present + re-run idempotent.

- [ ] **Step 1 (RED): Extend ps1 harness** — append to `scripts/9cc.test.ps1` before final summary:
```powershell
Write-Host "Cycle 5: install.ps1 downloads (fixture source)"
$env:9CC_SOURCE = "$DIR\9cc.ps1"      # local file, no network
$env:9CC_HOME   = Join-Path $env:TEMP "9cc-home"
$env:9CC_BIN_DIR = Join-Path $env:TEMP "9cc-bin"
Remove-Item -Recurse -Force $env:9CC_HOME,$env:9CC_BIN_DIR -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $env:9CC_BIN_DIR | Out-Null
& "$DIR\install.ps1"
if (Test-Path (Join-Path $env:9CC_HOME '9cc.ps1')) { Write-Host "  ok: downloaded"; $script:Pass++ } else { Write-Host "  FAIL: not downloaded"; $script:Fail++ }
if (Test-Path (Join-Path $env:9CC_BIN_DIR '9cc.ps1')) { Write-Host "  ok: bin copy"; $script:Pass++ } else { Write-Host "  FAIL: no bin copy"; $script:Fail++ }
& "$DIR\install.ps1"  # idempotent
Write-Host "  ok: re-run ok"; $script:Pass++
Remove-Item -Recurse -Force $env:9CC_HOME,$env:9CC_BIN_DIR -ErrorAction SilentlyContinue
Remove-Item Env:9CC_SOURCE,Env:9CC_HOME,Env:9CC_BIN_DIR -ErrorAction SilentlyContinue
```

- [ ] **Step 2 (RED): Run, verify fail** — Run: `pwsh -File scripts/9cc.test.ps1`
Expected: FAIL (Cycle 5 — `install.ps1` missing).

- [ ] **Step 3 (GREEN): install.ps1** — create `scripts/install.ps1`:
```powershell
# 9cc installer — powershell -c "irm <raw url>/install.ps1 | iex"
# Downloads 9cc.ps1 into ~\.9cc and copies it into a writable PATH dir.
$ErrorActionPreference = 'Stop'
$Home9 = if ($env:9CC_HOME) { $env:9CC_HOME } else { Join-Path $env:USERPROFILE '.9cc' }
$Src   = if ($env:9CC_SOURCE) { $env:9CC_SOURCE } else { 'https://raw.githubusercontent.com/investtal/investtal-toolchain/main/scripts/9cc.ps1' }
if (-not $env:9CC_BIN_DIR) {
    $cands = @('C:\Program Files\9cc', (Join-Path $env:USERPROFILE '.local\bin'), (Join-Path $env:APPDATA '9cc'))
    foreach ($c in $cands) { try { New-Item -ItemType Directory -Force $c | Out-Null; $env:9CC_BIN_DIR = $c; break } catch {} }
}
if (-not $env:9CC_BIN_DIR) { throw "install: no writable bin dir (set 9CC_BIN_DIR)" }

New-Item -ItemType Directory -Force $Home9 | Out-Null
$target = Join-Path $Home9 '9cc.ps1'
if (Test-Path $Src) { Copy-Item $Src $target -Force }      # local fixture (tests)
else { Invoke-WebRequest $Src -OutFile $target }

Copy-Item $target (Join-Path $env:9CC_BIN_DIR '9cc.ps1') -Force
Write-Host "9cc installed: $target"
Write-Host "bin copy:      $(Join-Path $env:9CC_BIN_DIR '9cc.ps1')  (add $env:9CC_BIN_DIR to PATH if missing)"
```

- [ ] **Step 4 (GREEN): Run, verify pass** — Run: `pwsh -File scripts/9cc.test.ps1`
Expected: `PASS=<N> FAIL=0`. *(No pwsh host → bash test guards launchers; note install.ps1 smoke deferred.)*

- [ ] **Step 5: Commit** — `git add scripts/install.ps1 scripts/9cc.test.ps1 && git commit -m "feat(9cc): irm|iex installer mirroring curl|bash"`

---

## Task 5: README — one-liner install + usage

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: all 4 scripts from Tasks 1–4.

- [ ] **Step 1: Read README tail** — Run: `tail -20 README.md`
Expected: current last lines so section appends cleanly.

- [ ] **Step 2: Append section** — add to `README.md`:
```markdown

## 9cc — Claude Code model switcher

Launch Claude Code with a dynamic model over the 9Router gateway. Reads auth from `~/.claude/settings.json` (read-only — never mutates it).

**Install (mac/linux/wsl):**
```sh
curl -fsSL https://raw.githubusercontent.com/investtal/investtal-toolchain/main/scripts/install.sh | bash
```
**Install (windows, PowerShell):**
```powershell
powershell -c "irm https://raw.githubusercontent.com/investtal/investtal-toolchain/main/scripts/install.ps1 | iex"
```

**Use:**
```sh
9cc list                 # list models
9cc run fable            # launch with cc/fable-5
9cc run glm/glm-5.2      # full 9Router ID also works
9cc run minimax --resume # extra args forwarded to claude
```
In a live session, switch without restart: `/model <id>` (e.g. `/model glm/glm-5.2`).

Full design: `docs/ideas/0002-ManageClaudeCodeCLI.spec.md`. Overnight auto-pilot deferred to a follow-up.
```

- [ ] **Step 3: Verify** — Run: `grep -n "## 9cc" README.md`
Expected: one match.

- [ ] **Step 4: Final regression** — Run: `bash scripts/9cc.test.sh`
Expected: `PASS=... FAIL=0`.

- [ ] **Step 5: Commit** — `git add README.md && git commit -m "docs(9cc): one-liner install + usage in README"`
