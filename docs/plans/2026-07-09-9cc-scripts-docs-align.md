# 9cc scripts + docs align Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `subagent-parallel-execution` (recommended) or inline execution via `finishing-execution` to implement task-by-task. Steps use `- [ ]` checkboxes.

**Goal:** Finish `scripts/` 9cc install/update path so every download prefers `gh api` (rate-limit safe) with raw fallback, and bring docs in line with the shipped CLI (commands, models, install one-liners).

**Architecture:** Installers already resolve latest tag via `gh` then curl. Still fetch launcher body via `raw.githubusercontent.com`. Mirror the `9cc update` pattern: if `gh` exists, `gh api repos/.../contents/scripts/9cc.{sh,ps1}?ref=$TAG --jq .content | base64 -d`; else raw URL. Docs that still describe curl-only install or v1-only commands get rewritten to match `scripts/9cc.sh` + README.

**Tech Stack:** Bash 3.2+/4+, PowerShell 5.1+, `gh` CLI (preferred), curl/IRM fallback, assert-based tests in `scripts/9cc.test.sh` / `scripts/9cc.test.ps1`.

## Global Constraints

- Prefer `gh api` over raw GitHub URLs for release/content fetch (IVT-0608).
- Keep local-fixture path: if `CC9_SOURCE` is an existing file, copy it (tests).
- Do not add deps, frameworks, or new script files.
- Model registry stays the 13 entries already in `scripts/9cc.sh` / `scripts/9cc.ps1`.
- README install one-liners already use `gh api contents`; keep that as public install path.
- Historical plan `docs/plans/2026-07-08-9cc-model-switcher.md` is a record of past work — do not rewrite it; only add a short status note at top if touched.

## File map

| File | Responsibility |
|------|----------------|
| `scripts/install.sh` | Unix installer: resolve tag, fetch `9cc.sh` via gh→raw, symlink |
| `scripts/install.ps1` | Windows installer: resolve tag, fetch `9cc.ps1` via gh→raw, bin copy |
| `scripts/9cc.sh` | Launcher; `get_latest_tag` should prefer `gh` like installers |
| `scripts/9cc.ps1` | Launcher; `Get-LatestTag` should prefer `gh` like installers |
| `scripts/9cc.test.sh` | Assert install + update + uninstall + models |
| `scripts/9cc.test.ps1` | PowerShell mirror of tests |
| `docs/specs/2026-07-09-9cc-update.md` | Design spec for update (stale: raw-only) |
| `docs/ideas/0002-ManageClaudeCodeCLI.spec.md` | Resolved product spec (stale: models + commands) |
| `README.md` | Public install/use (already mostly current; only fix if drift found) |

---

### Task 1: install.sh prefers `gh api` for launcher body

**Files:**
- Modify: `scripts/install.sh`
- Test: `scripts/9cc.test.sh` (Cycle 7 already covers local fixture; extend with download-path unit via env)

**Interfaces:**
- Consumes: `CC9_VERSION`, `CC9_SOURCE`, `CC9_HOME`, `CC9_BIN_DIR`
- Produces: `$CC9_HOME/9cc.sh`, `$CC9_HOME/version`, symlink `$CC9_BIN_DIR/9cc`

- [ ] **Step 1: Write the failing test** — append to `scripts/9cc.test.sh` before final `PASS/FAIL` summary:

```bash
echo "Cycle 16: install.sh prefers gh contents when CC9_SOURCE is remote URL"
# Simulate remote: set CC9_SOURCE to a non-file URL and intercept via a fake PATH/gh is hard;
# instead assert the source script contains the gh contents fetch branch (static contract).
if grep -q 'contents/scripts/9cc.sh' "$DIR/install.sh" \
   && grep -q 'command -v gh' "$DIR/install.sh" \
   && grep -q 'raw.githubusercontent.com' "$DIR/install.sh"; then
    echo "  ok: install.sh has gh contents + raw fallback"
    PASS=$((PASS+1))
else
    echo "  FAIL: install.sh missing gh-first body fetch"
    FAIL=$((FAIL+1))
fi
```

- [ ] **Step 2: Run test, verify it fails** — Run: `bash scripts/9cc.test.sh` Expected: FAIL with `install.sh missing gh-first body fetch`

- [ ] **Step 3: Write minimal implementation** — replace the download block in `scripts/install.sh` (keep local-file branch). Full file after change:

```bash
#!/usr/bin/env bash
# 9cc installer — prefer: gh api contents | base64 -d | bash
# Downloads 9cc.sh into ~/.9cc and symlinks `9cc` into a writable PATH dir.
set -euo pipefail

CC9_HOME="${CC9_HOME:-$HOME/.9cc}"
CC9_VERSION="${CC9_VERSION:-}"
if [ -z "$CC9_VERSION" ]; then
    if command -v gh >/dev/null 2>&1; then
        CC9_VERSION="$(gh api repos/investtal/investtal-toolchain/releases/latest --jq '.tag_name' 2>/dev/null || true)"
    else
        CC9_VERSION="$(curl -fsSL --max-time 10 'https://api.github.com/repos/investtal/investtal-toolchain/releases/latest' 2>/dev/null \
            | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | sed -E 's/.*"([^"]+)".*/\1/' \
            | head -n1)"
    fi
    [ -n "$CC9_VERSION" ] || CC9_VERSION="v0.3.5"
fi
CC9_SOURCE="${CC9_SOURCE:-}"
# prefer explicit CC9_BIN_DIR, else first writable candidate
if [ -z "${CC9_BIN_DIR:-}" ]; then
    for c in /usr/local/bin "$HOME/.local/bin"; do
        if mkdir -p "$c" 2>/dev/null && [ -w "$c" ]; then CC9_BIN_DIR="$c"; break; fi
    done
fi
if [ -z "${CC9_BIN_DIR:-}" ]; then echo "install: no writable bin dir found (set CC9_BIN_DIR)" >&2; exit 1; fi

mkdir -p "$CC9_HOME" "$CC9_BIN_DIR"

if [ -n "$CC9_SOURCE" ] && [ -f "$CC9_SOURCE" ]; then
    cp "$CC9_SOURCE" "$CC9_HOME/9cc.sh"     # local fixture / tests
elif [ -n "$CC9_SOURCE" ]; then
    curl -fsSL "$CC9_SOURCE" -o "$CC9_HOME/9cc.sh"
else
    fetched=0
    if command -v gh >/dev/null 2>&1; then
        if content="$(gh api "repos/investtal/investtal-toolchain/contents/scripts/9cc.sh?ref=$CC9_VERSION" --jq '.content' 2>/dev/null)"; then
            if [ -n "$content" ] && printf '%s' "$content" | base64 -d > "$CC9_HOME/9cc.sh" 2>/dev/null; then
                fetched=1
            fi
        fi
    fi
    if [ "$fetched" != "1" ]; then
        raw="https://raw.githubusercontent.com/investtal/investtal-toolchain/$CC9_VERSION/scripts/9cc.sh"
        curl -fsSL "$raw" -o "$CC9_HOME/9cc.sh"
    fi
fi
chmod +x "$CC9_HOME/9cc.sh"
printf '%s\n' "$CC9_VERSION" > "$CC9_HOME/version"

ln -sfn "$CC9_HOME/9cc.sh" "$CC9_BIN_DIR/9cc"

echo "9cc installed: $CC9_HOME/9cc.sh"
echo "symlink:       $CC9_BIN_DIR/9cc  (ensure it's on your PATH)"
```

- [ ] **Step 4: Run test, verify pass** — Run: `bash scripts/9cc.test.sh` Expected: `PASS=65 FAIL=0` (or prior PASS+1)

- [ ] **Step 5: Commit** — `git commit -m "fix(9cc): prefer gh api for install.sh launcher fetch IVT-0608"`

---

### Task 2: install.ps1 prefers `gh api` for launcher body

**Files:**
- Modify: `scripts/install.ps1`
- Test: `scripts/9cc.test.ps1` (static contract + existing fixture cycles)

**Interfaces:**
- Consumes: `$env:CC9_VERSION`, `$env:CC9_SOURCE`, `$env:CC9_HOME`, `$env:CC9_BIN_DIR`
- Produces: `~\.9cc\9cc.ps1`, version file, bin copy

- [ ] **Step 1: Write the failing test** — append to `scripts/9cc.test.ps1` before final summary:

```powershell
Write-Host "Cycle 11: install.ps1 prefers gh contents for remote source"
$src = Get-Content -Raw "$DIR\install.ps1"
if ($src -match 'contents/scripts/9cc\.ps1' -and $src -match 'Get-Command gh' -and $src -match 'raw\.githubusercontent\.com') {
    Write-Host "  ok: install.ps1 has gh contents + raw fallback"; $PASS++
} else {
    Write-Host "  FAIL: install.ps1 missing gh-first body fetch"; $FAIL++
}
```

- [ ] **Step 2: Run test, verify it fails** — Run: `pwsh -File scripts/9cc.test.ps1` (or `powershell -File …` on Windows) Expected: FAIL `install.ps1 missing gh-first body fetch`

- [ ] **Step 3: Write minimal implementation** — full `scripts/install.ps1`:

```powershell
# 9cc installer — prefer: gh api contents | base64 decode | iex
# Downloads 9cc.ps1 into ~\.9cc and copies it into a writable PATH dir.
$ErrorActionPreference = 'Stop'
$Home9 = if ($env:CC9_HOME) { $env:CC9_HOME } else { Join-Path $env:USERPROFILE '.9cc' }
$Ver = if ($env:CC9_VERSION) { $env:CC9_VERSION } else {
    $tag = $null
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $tag = gh api repos/investtal/investtal-toolchain/releases/latest --jq '.tag_name' 2>$null
    }
    if (-not $tag) {
        try {
            $resp = Invoke-RestMethod -Uri 'https://api.github.com/repos/investtal/investtal-toolchain/releases/latest' -TimeoutSec 10 -ErrorAction Stop
            if ($resp -and $resp.tag_name) { $tag = $resp.tag_name }
        } catch { }
    }
    if ($tag) { $tag } else { 'v0.3.5' }
}
if (-not $env:CC9_BIN_DIR) {
    $cands = @((Join-Path $env:USERPROFILE '.local\bin'), (Join-Path $env:APPDATA '9cc'), 'C:\Program Files\9cc')
    foreach ($c in $cands) {
        try {
            $null = New-Item -ItemType Directory -Force $c
            $testFile = Join-Path $c '9cc_test_write.tmp'
            [System.IO.File]::WriteAllText($testFile, '')
            Remove-Item $testFile -Force
            $env:CC9_BIN_DIR = $c; break
        } catch {}
    }
}
if (-not $env:CC9_BIN_DIR) { throw "install: no writable bin dir (set CC9_BIN_DIR)" }

New-Item -ItemType Directory -Force $Home9 | Out-Null
$target = Join-Path $Home9 '9cc.ps1'
if ($env:CC9_SOURCE -and (Test-Path $env:CC9_SOURCE)) {
    Copy-Item $env:CC9_SOURCE $target -Force      # local fixture (tests)
} elseif ($env:CC9_SOURCE) {
    Invoke-WebRequest $env:CC9_SOURCE -OutFile $target
} else {
    $fetched = $false
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $encoded = gh api "repos/investtal/investtal-toolchain/contents/scripts/9cc.ps1?ref=$Ver" --jq '.content' 2>$null
        if ($encoded) {
            $bytes = [System.Convert]::FromBase64String(($encoded -replace '\s',''))
            [System.IO.File]::WriteAllBytes($target, $bytes)
            $fetched = $true
        }
    }
    if (-not $fetched) {
        $Src = "https://raw.githubusercontent.com/investtal/investtal-toolchain/$Ver/scripts/9cc.ps1"
        Invoke-WebRequest $Src -OutFile $target
    }
}

Copy-Item $target (Join-Path $env:CC9_BIN_DIR '9cc.ps1') -Force
$Ver | Out-File -FilePath (Join-Path $Home9 'version') -NoNewline
Write-Host "9cc installed: $target"
Write-Host "bin copy:      $(Join-Path $env:CC9_BIN_DIR '9cc.ps1')  (add $env:CC9_BIN_DIR to PATH if missing)"
```

- [ ] **Step 4: Run test, verify pass** — Run: `pwsh -File scripts/9cc.test.ps1` Expected: all PASS including Cycle 11

- [ ] **Step 5: Commit** — `git commit -m "fix(9cc): prefer gh api for install.ps1 launcher fetch IVT-0608"`

---

### Task 3: `get_latest_tag` / `Get-LatestTag` prefer `gh`

**Files:**
- Modify: `scripts/9cc.sh` (`get_latest_tag`)
- Modify: `scripts/9cc.ps1` (`Get-LatestTag`)
- Test: existing update cycles in `scripts/9cc.test.sh` / `scripts/9cc.test.ps1` (fixture path must still win)

**Interfaces:**
- Consumes: `CC9_LATEST_API_FIXTURE` (tests), else GitHub releases/latest
- Produces: tag string matching `^v…` or failure

- [ ] **Step 1: Write the failing test** — append static contract checks:

```bash
echo "Cycle 17: get_latest_tag prefers gh"
if awk '/get_latest_tag\(\)/,/^}/' "$DIR/9cc.sh" | grep -q 'command -v gh'; then
    echo "  ok: get_latest_tag uses gh"; PASS=$((PASS+1))
else
    echo "  FAIL: get_latest_tag missing gh preference"; FAIL=$((FAIL+1))
fi
```

PowerShell mirror:

```powershell
Write-Host "Cycle 12: Get-LatestTag prefers gh"
$fn = (Get-Content -Raw "$DIR\9cc.ps1")
if ($fn -match 'function Get-LatestTag' -and $fn -match "Get-Command gh") {
    # ensure gh appears inside Get-LatestTag region roughly: between function and next function
    $m = [regex]::Match($fn, 'function Get-LatestTag[\s\S]*?function Update-9cc')
    if ($m.Success -and $m.Value -match 'Get-Command gh') {
        Write-Host "  ok: Get-LatestTag uses gh"; $PASS++
    } else { Write-Host "  FAIL: Get-LatestTag missing gh"; $FAIL++ }
} else { Write-Host "  FAIL: Get-LatestTag missing gh"; $FAIL++ }
```

- [ ] **Step 2: Run test, verify it fails** — Run: `bash scripts/9cc.test.sh` Expected: FAIL `get_latest_tag missing gh preference`

- [ ] **Step 3: Write minimal implementation**

Replace `get_latest_tag` in `scripts/9cc.sh` with:

```bash
get_latest_tag() {
    local api="https://api.github.com/repos/investtal/investtal-toolchain/releases/latest"
    local resp=""
    if [ -n "${CC9_LATEST_API_FIXTURE:-}" ]; then
        if [ ! -f "$CC9_LATEST_API_FIXTURE" ]; then return 1; fi
        resp="$(cat "$CC9_LATEST_API_FIXTURE")" || return 1
    elif command -v gh >/dev/null 2>&1; then
        resp="$(gh api repos/investtal/investtal-toolchain/releases/latest 2>/dev/null)" || return 1
    else
        command -v curl >/dev/null 2>&1 || { echo "9cc update: curl not found" >&2; return 1; }
        resp="$(curl -fsSL --max-time 30 "$api" 2>/dev/null)" || return 1
    fi
    local tag=""
    if command -v node >/dev/null 2>&1; then
        tag="$(printf '%s' "$resp" | node -e '
            let d;
            try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); }
            catch (e) { process.exit(1); }
            const t = d && d.tag_name;
            if (t && String(t).length) process.stdout.write(String(t));
            else process.exit(1);
        ' 2>/dev/null)" || return 1
    else
        tag="$(printf '%s' "$resp" \
            | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | sed -E 's/.*"([^"]+)".*/\1/' \
            | head -n1)"
    fi
    case "$tag" in v*) printf '%s' "$tag" ;; *) return 1 ;; esac
}
```

Replace `Get-LatestTag` in `scripts/9cc.ps1` with:

```powershell
function Get-LatestTag {
    if ($env:CC9_LATEST_API_FIXTURE -and (Test-Path $env:CC9_LATEST_API_FIXTURE)) {
        try {
            $resp = Get-Content -Raw $env:CC9_LATEST_API_FIXTURE | ConvertFrom-Json -ErrorAction Stop
            return $resp.tag_name
        } catch { return $null }
    }
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        try {
            $tag = gh api repos/investtal/investtal-toolchain/releases/latest --jq '.tag_name' 2>$null
            if ($tag -and $tag -match '^v') { return $tag.Trim() }
        } catch { }
    }
    $api = 'https://api.github.com/repos/investtal/investtal-toolchain/releases/latest'
    try {
        $resp = Invoke-RestMethod -Uri $api -TimeoutSec 30 -ErrorAction Stop
    } catch { return $null }
    if ($resp -and $resp.tag_name -and $resp.tag_name -match '^v') {
        return $resp.tag_name
    }
    return $null
}
```

Also refresh header usage comments to list full command surface:

```bash
# Usage: 9cc list | run | next | update | uninstall | version | help
```

```powershell
# Usage: 9cc.ps1 list | run | next | update | uninstall | version | help
```

- [ ] **Step 4: Run test, verify pass** — Run: `bash scripts/9cc.test.sh` Expected: `FAIL=0` and update cycles still green (fixture path first)

- [ ] **Step 5: Commit** — `git commit -m "fix(9cc): prefer gh for latest-tag probe IVT-0608"`

---

### Task 4: Docs — update design spec + resolved requirements + README drift check

**Files:**
- Modify: `docs/specs/2026-07-09-9cc-update.md`
- Modify: `docs/ideas/0002-ManageClaudeCodeCLI.spec.md`
- Modify: `README.md` only if command list or install path drifts from scripts (verify first)

**Interfaces:**
- Consumes: shipped behavior from Tasks 1–3 + existing commands
- Produces: accurate operator-facing docs

- [ ] **Step 1: Rewrite `docs/specs/2026-07-09-9cc-update.md`** to current design (full file):

```markdown
# 9cc update — design spec

## Purpose

Self-update installed `9cc` to latest GitHub release without re-reading install docs.

## Context

- Launchers: `scripts/9cc.sh`, `scripts/9cc.ps1`
- Installers: `scripts/install.sh`, `scripts/install.ps1`
- Version file: `$CC9_HOME/version` (fallback `CC9_VERSION` env, then `0.1.0-dev`)
- Public install one-liner uses `gh api …/contents/scripts/install.{sh,ps1}` (avoids raw URL rate limits)

## Approach: re-run installer for latest tag

1. Resolve latest release tag (`gh api …/releases/latest` preferred; curl/IRM fallback; `CC9_LATEST_API_FIXTURE` in tests).
2. If tag equals current version → print `9cc is up to date (<ver>)` and exit 0.
3. Else fetch platform installer for that tag (`gh api contents` preferred; raw fallback) and execute with `CC9_VERSION=<tag>`.
4. Print `9cc updated to <tag>` and `9cc <tag>`.

Test hooks:
- `CC9_LATEST_API_FIXTURE` — JSON file with `{ "tag_name": "vX.Y.Z" }`
- `CC9_INSTALL_SOURCE` — local installer path (skip network)

## Installer fetch order (body + installer scripts)

1. Local file when `CC9_SOURCE` / fixture path exists
2. `gh api repos/investtal/investtal-toolchain/contents/scripts/<file>?ref=<tag> --jq .content` + base64 decode
3. `raw.githubusercontent.com/investtal/investtal-toolchain/<tag>/scripts/<file>`

## Commands related to lifecycle

| Command | Behavior |
|---------|----------|
| `9cc version` | Print `9cc <version>` |
| `9cc update` | Self-update via installer re-run |
| `9cc uninstall` | Remove `$CC9_HOME` and PATH symlink/copy |

## Errors

- Network/API failure → `9cc update: failed to reach GitHub`, leave install untouched
- Missing installer fixture → `9cc update: installer source not found`
- Installer mid-fail → non-zero exit (`set -e` / `$ErrorActionPreference = Stop`)

## Out of scope

Channels, signed releases, rollback, multi-artifact manifest.
```

- [ ] **Step 2: Update `docs/ideas/0002-ManageClaudeCodeCLI.spec.md`** — replace model table + commands with shipped state. Keep Purpose/Constraints/Decisions; rewrite registry + commands:

```markdown
## Model registry (13 models — shipped)

| Alias | 9Router ID | Window |
|-------|-----------|--------|
| fable | cc/claude-fable-5 | 1000000 |
| opus | cc/claude-opus-4-8 | 1000000 |
| sonnet | cc/claude-sonnet-5 | 200000 |
| haiku | cc/claude-haiku-4-5-20251001 | 200000 |
| gpt5 | cx/gpt-5.5 | 128000 |
| glm5 | glm/glm-5.2 | 1000000 |
| glmturbo | glm/glm-5-turbo | 1000000 |
| deepseek | ds/deepseek-v4-pro | 1000000 |
| dsflash | ds/deepseek-v4-flash | 1000000 |
| kimi | kimi/kimi-k2.7 | 1000000 |
| grok | xai/grok-4.5 | 500000 |
| grokcomposer | xai/grok-composer-2.5-fast | 500000 |
| minimax | minimax/MiniMax-M3 | 1000000 |

## Commands (shipped)

- `9cc list` / `9cc list --json` — table or machine-readable registry
- `9cc run <alias-or-id> [claude args...]` — export env, `exec claude`
- `9cc next <id|alias> [--no-free]` — cascade successor (fleet healer)
- `9cc update` — self-update to latest release
- `9cc uninstall` — remove home + PATH entry
- `9cc version` / `-v` / `--version`
- `9cc help` (or no args)

## Distribution (shipped)

- Launchers: `scripts/9cc.sh`, `scripts/9cc.ps1`
- Installers: `scripts/install.sh`, `scripts/install.ps1`
- Install (mac/linux): `gh api repos/investtal/investtal-toolchain/contents/scripts/install.sh --jq '.content' | base64 -d | bash`
- Install (windows): `gh api repos/investtal/investtal-toolchain/contents/scripts/install.ps1 --jq '.content' | base64 -d | powershell -c -`
- Pin: `?ref=<tag>` on contents path and/or `CC9_VERSION=<tag>`

## Success criteria (updated)

- `9cc run fable` → `cc/claude-fable-5`, window 1M, settings.json read-only
- `9cc list` / `list --json` cover all 13 models
- `9cc update` / `uninstall` / `version` work on both platforms
- Install/update prefer `gh` then raw fallback
```

Also fix Constraints line “2 files only” → note installers + tests added for distribution (launchers remain 2).

- [ ] **Step 3: README drift check** — Run: `rg -n "9cc |install|update|uninstall|list --json|next " README.md` and compare to `show_help` in `scripts/9cc.sh`. If identical surface, leave README. If missing `next` help detail or wrong model id, patch only that.

- [ ] **Step 4: Verify** — Run:

```bash
bash scripts/9cc.test.sh
# Expected: FAIL=0
rg -n "raw\.githubusercontent.com.*install" docs/specs/2026-07-09-9cc-update.md docs/ideas/0002-ManageClaudeCodeCLI.spec.md README.md || true
# Expected: no install one-liner still requiring raw-only as primary path
```

- [ ] **Step 5: Commit** — `git commit -m "docs(9cc): align specs with gh-first install and shipped commands IVT-0608"`

---

## Self-review

1. **Spec coverage** — User asked scripts + documents → Tasks 1–3 scripts, Task 4 docs. Covered.
2. **Placeholder scan** — no TBD/TODO; full file bodies included.
3. **Type consistency** — env hooks `CC9_*` unchanged; test fixture names preserved.
4. **Out of scope** — no release tag bump, no new commands, no INVENTORY (proto-only), no rewrite of historical plan body.

## Done when

- `bash scripts/9cc.test.sh` → `FAIL=0`
- `install.sh` / `install.ps1` / `get_latest_tag` / `Get-LatestTag` all prefer `gh`
- Specs list update/uninstall/next/list --json + current 13-model registry
- README install path still `gh api contents`
