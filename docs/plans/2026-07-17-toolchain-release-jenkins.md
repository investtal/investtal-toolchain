# Toolchain Release on Jenkins — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `subagent-parallel-execution` (recommended) or inline execution via `finishing-execution` to implement task-by-task. Steps use `- [ ]` checkboxes.

**Goal:** Move all toolchain CI/CD off GitHub Actions onto Jenkins: per-tool auto-release on main (`{tool}-v*`), atlassian multi-arch packages + GitHub Releases, 9cc `9cc-v*` install/update.

**Architecture:** One `jenkins/Jenkinsfile` runs tests always; on `main` only it detects changed tools from `scripts/release/tools.manifest`, bumps version from the associated PR title (conventional commits), tags `{tool}-vX.Y.Z`, packages binary tools via Zig cross-compile on Linux, and creates GitHub Releases with `gh`. GitHub is distribution only.

**Tech Stack:** Bash, Jenkins declarative pipeline, Zig 0.16, `gh` CLI, GitHub REST API, existing credential `github-token-userpass`.

**Spec:** [`docs/specs/2026-07-17-toolchain-release-jenkins-design.md`](../specs/2026-07-17-toolchain-release-jenkins-design.md)

## Global Constraints

- Tag format: `{tool}-v{MAJOR}.{MINOR}.{PATCH}` only (no new bare `v*` for 9cc).
- Bump from **PR title** only: `feat`→minor, `!`/BREAKING→major, else patch; no PR→`none` (skip).
- Release commits: `chore(release): {tool} v{ver} [skip ci]` — must skip auto-release loop.
- Asset names for atlassian must stay compatible with `proto/atlassian/plugin.toml`.
- No new GitHub Actions workflows; delete `atlassian-release.yml`.
- PR builds never create tags or releases.
- Prefer portable bash (`set -euo pipefail`); scripts runnable locally with env vars.
- Zig version pin: **0.16.0** (matches `build.zig.zon` / former GHA).

---

### Task 1: Release core scripts + unit tests

**Files:**
- Create: `scripts/release/tools.manifest`
- Create: `scripts/release/lib.sh`
- Create: `scripts/release/detect-changed-tools.sh`
- Create: `scripts/release/detect-bump-level.sh`
- Create: `scripts/release/bump-version.sh`
- Create: `scripts/release/tests/run.sh`
- Create: `scripts/release/tests/fixtures/` (as needed inline in tests)

**Interfaces:**
- Consumes: git, bash, standard Unix tools
- Produces:
  - `tools.manifest` lines: `name|kind|version_file|version_kind|path_globs`
  - `detect-changed-tools.sh` stdin or args: list of paths → stdout tool names (one per line)
  - `detect-bump-level.sh` arg: PR title → stdout `major|minor|patch|none`
  - `bump-version.sh TOOL LEVEL` → updates version file; stdout new bare semver

- [ ] **Step 1: Write tools.manifest**

```text
# name|kind|version_file|version_kind|path_globs (comma-separated)
atlassian|binary|atlassian/build.zig.zon|zig.zon|atlassian/**,proto/atlassian/**
9cc|source-tag|9cc/VERSION|plain|9cc/**
```

- [ ] **Step 2: Write lib.sh helpers**

```bash
#!/usr/bin/env bash
# Shared helpers for scripts/release/*
set -euo pipefail

RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$RELEASE_ROOT/../.." && pwd)"
MANIFEST="${RELEASE_ROOT}/tools.manifest"

die() { echo "release: $*" >&2; exit 1; }

# Read manifest line for tool → sets NAME KIND VERSION_FILE VERSION_KIND PATH_GLOBS
load_tool() {
  local tool="$1" line
  line="$(grep -E "^${tool}\\|" "$MANIFEST" | head -n1 || true)"
  [[ -n "$line" ]] || die "unknown tool: $tool"
  IFS='|' read -r NAME KIND VERSION_FILE VERSION_KIND PATH_GLOBS <<<"$line"
}

semver_bump() {
  local ver="$1" level="$2"
  local major minor patch
  IFS='.' read -r major minor patch <<<"$ver"
  major=${major//[^0-9]/}
  minor=${minor//[^0-9]/}
  patch=${patch//[^0-9]/}
  [[ -n "$major" && -n "$minor" && -n "$patch" ]] || die "invalid semver: $ver"
  case "$level" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) die "invalid bump level: $level" ;;
  esac
  printf '%s.%s.%s' "$major" "$minor" "$patch"
}

read_version() {
  local file="$1" kind="$2"
  case "$kind" in
    plain)
      tr -d '[:space:]' <"$file"
      ;;
    zig.zon)
      # .version = "0.1.0",
      grep -E '^\s*\.version\s*=' "$file" | head -n1 \
        | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/'
      ;;
    *) die "unknown version_kind: $kind" ;;
  esac
}

write_version() {
  local file="$1" kind="$2" ver="$3"
  case "$kind" in
    plain)
      printf '%s\n' "$ver" >"$file"
      ;;
    zig.zon)
      # portable: rewrite .version line only
      local tmp
      tmp="$(mktemp)"
      sed -E "s/^(\\s*\\.version\\s*=\\s*\")[0-9]+\\.[0-9]+\\.[0-9]+(\".*)/\\1${ver}\\2/" \
        "$file" >"$tmp"
      mv "$tmp" "$file"
      ;;
    *) die "unknown version_kind: $kind" ;;
  esac
}
```

- [ ] **Step 3: Write detect-bump-level.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Usage: detect-bump-level.sh "<pr title>"
# Prints: major | minor | patch | none
title="${1-}"
if [[ -z "$title" || "$title" == "none" ]]; then
  echo none
  exit 0
fi
# BREAKING CHANGE token or type!
if [[ "$title" =~ ^(BREAKING[- ]CHANGE:)|(^[[:alnum:]]+(\([^)]*\))?!:) ]]; then
  echo major
  exit 0
fi
if [[ "$title" =~ ^feat(\([^)]*\))?: ]]; then
  echo minor
  exit 0
fi
# any other conventional type or free text → patch (caller decides skip via PR existence)
echo patch
```

Note: when there is **no PR**, the Jenkins orchestrator prints `none` without calling this with an empty title — or call with literal `none`. Document in Jenkins stage.

- [ ] **Step 4: Write detect-changed-tools.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Usage: detect-changed-tools.sh
# Env: BASE_SHA (required), HEAD_SHA (default HEAD)
# Or: paths on stdin (one per line) for tests
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

match_glob() {
  # fnmatch-ish: support trailing /** only
  local path="$1" glob="$2"
  if [[ "$glob" == */** ]]; then
    local prefix="${glob%/**}"
    [[ "$path" == "$prefix" || "$path" == "$prefix"/* ]]
  else
    [[ "$path" == $glob ]]
  fi
}

paths=()
if [[ -n "${BASE_SHA:-}" ]]; then
  HEAD_SHA="${HEAD_SHA:-HEAD}"
  while IFS= read -r p; do paths+=("$p"); done < <(git -C "$REPO_ROOT" diff --name-only "$BASE_SHA" "$HEAD_SHA")
else
  while IFS= read -r p; do [[ -n "$p" ]] && paths+=("$p"); done
fi

declare -A seen=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^#|^$ ]] && continue
  IFS='|' read -r name _k _vf _vk globs <<<"$line"
  IFS=',' read -ra garr <<<"$globs"
  for path in "${paths[@]+"${paths[@]}"}"; do
    for g in "${garr[@]}"; do
      g="$(echo "$g" | xargs)" # trim
      if match_glob "$path" "$g"; then
        seen["$name"]=1
      fi
    done
  done
done <"$MANIFEST"

for t in "${!seen[@]}"; do echo "$t"; done | sort
```

- [ ] **Step 5: Write bump-version.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Usage: bump-version.sh <tool> <major|minor|patch>
# Prints new bare semver on stdout
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
tool="${1:?tool}"; level="${2:?level}"
load_tool "$tool"
file="$REPO_ROOT/$VERSION_FILE"
[[ -f "$file" ]] || die "missing version file: $file"
cur="$(read_version "$file" "$VERSION_KIND")"
new="$(semver_bump "$cur" "$level")"
write_version "$file" "$VERSION_KIND" "$new"
printf '%s\n' "$new"
```

- [ ] **Step 6: Write tests/run.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
assert_eq() {
  local want="$1" got="$2" msg="$3"
  if [[ "$want" == "$got" ]]; then
    echo "  ✓ $msg"; pass=$((pass+1))
  else
    echo "  ✗ $msg (want=$want got=$got)"; fail=$((fail+1))
  fi
}

echo "== detect-bump-level =="
assert_eq major "$("$ROOT/detect-bump-level.sh" 'feat!: drop api')" "feat!"
assert_eq major "$("$ROOT/detect-bump-level.sh" 'BREAKING CHANGE: x')" "BREAKING"
assert_eq minor "$("$ROOT/detect-bump-level.sh" 'feat(atlassian): add x')" "feat"
assert_eq patch "$("$ROOT/detect-bump-level.sh" 'fix: bug')" "fix"
assert_eq patch "$("$ROOT/detect-bump-level.sh" 'chore: stuff')" "chore"
assert_eq none "$("$ROOT/detect-bump-level.sh" 'none')" "none sentinel"

echo "== detect-changed-tools =="
got="$(printf '%s\n' 'atlassian/src/main.zig' 'README.md' | "$ROOT/detect-changed-tools.sh" | tr '\n' ' ' | xargs)"
assert_eq atlassian "$got" "atlassian path"

got="$(printf '%s\n' '9cc/9cc.sh' | "$ROOT/detect-changed-tools.sh" | tr '\n' ' ' | xargs)"
assert_eq 9cc "$got" "9cc path"

got="$(printf '%s\n' 'docs/specs/x.md' | "$ROOT/detect-changed-tools.sh" | tr '\n' ' ' | xargs)"
assert_eq "" "$got" "docs only → empty"

echo "== semver_bump via lib =="
# shellcheck source=/dev/null
source "$ROOT/lib.sh"
assert_eq 0.2.0 "$(semver_bump 0.1.5 minor)" "minor"
assert_eq 1.0.0 "$(semver_bump 0.9.9 major)" "major"
assert_eq 0.1.6 "$(semver_bump 0.1.5 patch)" "patch"

echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
```

- [ ] **Step 7: Run tests** — `bash scripts/release/tests/run.sh`  
  Expected: all ✓, exit 0

- [ ] **Step 8: Commit** — `git add scripts/release && git commit -m "feat(release): core detect/bump scripts for multi-tool releases"`

---

### Task 2: Tag, push, and GitHub publish scripts

**Files:**
- Create: `scripts/release/create-tag-and-push.sh`
- Create: `scripts/release/publish-github-release.sh`
- Create: `scripts/release/run-auto-release.sh` (orchestrator for Jenkins + local)

**Interfaces:**
- Consumes: Task 1 scripts; env `GH_TOKEN` or `GITHUB_TOKEN`; `GIT_USERNAME` optional for push URL
- Produces: git tag `{tool}-v{ver}`; GitHub Release; orchestrator exit 0 if nothing to do

- [ ] **Step 1: create-tag-and-push.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Usage: create-tag-and-push.sh <tool> <bare-version>
# Expects version file already bumped and staged/uncommitted changes present.
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
tool="${1:?}"; ver="${2:?}"
load_tool "$tool"
tag="${tool}-v${ver}"
cd "$REPO_ROOT"

git config user.name "${GIT_AUTHOR_NAME:-investtal-infra}"
git config user.email "${GIT_AUTHOR_EMAIL:-infra.dev@investtal.com}"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "tag $tag already exists — skip create"
  exit 0
fi

git add "$VERSION_FILE"
# include only version file for clean release commits
git commit -m "chore(release): ${tool} v${ver} [skip ci]" || {
  # nothing to commit (already at version)
  echo "no version commit needed"
}
git tag -a "$tag" -m "Release ${tag}"

if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
  user="${GIT_USERNAME:-x-access-token}"
  token="${GH_TOKEN:-$GITHUB_TOKEN}"
  git remote set-url origin "https://${user}:${token}@github.com/investtal/investtal-toolchain.git"
fi
git push origin HEAD:main
git push origin "$tag"
echo "pushed $tag"
```

- [ ] **Step 2: publish-github-release.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Usage: publish-github-release.sh <tag> [asset-dir]
# asset-dir optional: upload all files inside
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
tag="${1:?}"
asset_dir="${2:-}"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN required"
REPO="${GITHUB_REPOSITORY:-investtal/investtal-toolchain}"

if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
  echo "release $tag exists"
else
  gh release create "$tag" --repo "$REPO" --title "$tag" --generate-notes
fi

if [[ -n "$asset_dir" && -d "$asset_dir" ]]; then
  # shellcheck disable=SC2046
  gh release upload "$tag" --repo "$REPO" --clobber $(find "$asset_dir" -type f)
fi
echo "published $tag"
```

- [ ] **Step 3: run-auto-release.sh orchestrator**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Jenkins main-only entry. Env: GH_TOKEN, optional BASE_SHA (default origin/main^ or before merge)
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
cd "$REPO_ROOT"

subject="$(git log -1 --pretty=%s)"
if [[ "$subject" =~ \[skip\ ci\]|\[ci\ skip\] ]] || [[ "$subject" =~ ^chore\(release\): ]]; then
  echo "skip release: $subject"
  exit 0
fi

BASE_SHA="${BASE_SHA:-$(git rev-parse HEAD^)}"
export BASE_SHA HEAD_SHA=HEAD
mapfile -t tools < <("$RELEASE_ROOT/detect-changed-tools.sh" || true)
if [[ ${#tools[@]} -eq 0 ]]; then
  echo "no releasable tools changed"
  exit 0
fi

# Resolve PR title for HEAD
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
sha="$(git rev-parse HEAD)"
title=""
if [[ -n "$token" ]]; then
  pulls="$(curl -fsSL \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/investtal/investtal-toolchain/commits/${sha}/pulls" || echo '[]')"
  title="$(printf '%s' "$pulls" | node -e '
    let d=""; process.stdin.on("data",c=>d+=c); process.stdin.on("end",()=>{
      try { const a=JSON.parse(d); if(!a.length){console.log("none"); process.exit(0)}
        console.log(a[0].title||"none");
      } catch { console.log("none"); }
    });
  ')"
else
  title="none"
fi

level="$("$RELEASE_ROOT/detect-bump-level.sh" "$title")"
if [[ "$level" == "none" ]]; then
  echo "no PR / none bump — skip"
  exit 0
fi

for tool in "${tools[@]}"; do
  echo "=== releasing $tool (level=$level) ==="
  load_tool "$tool"
  new_ver="$("$RELEASE_ROOT/bump-version.sh" "$tool" "$level")"
  tag="${tool}-v${new_ver}"
  "$RELEASE_ROOT/create-tag-and-push.sh" "$tool" "$new_ver"

  asset_dir=""
  if [[ "$KIND" == "binary" ]]; then
    asset_dir="$REPO_ROOT/dist/${tool}-${new_ver}"
    mkdir -p "$asset_dir"
    case "$tool" in
      atlassian)
        VERSION="$new_ver" OUT_DIR="$asset_dir" "$RELEASE_ROOT/package-atlassian.sh"
        ;;
      *) die "no package script for $tool" ;;
    esac
  fi
  "$RELEASE_ROOT/publish-github-release.sh" "$tag" "${asset_dir:-}"
done
```

Note: `package-atlassian.sh` lands in Task 3 — orchestrator may call it only after that file exists; implement Task 3 before wiring binary path if sequencing requires, or stub package script first.

- [ ] **Step 4: Commit** — `git commit -m "feat(release): tag push and GitHub publish scripts"`

---

### Task 3: package-atlassian.sh (Zig cross-build + checksums)

**Files:**
- Create: `scripts/release/package-atlassian.sh`
- Create: `atlassian/scripts/package-release.sh` — thin wrapper calling monorepo script (optional, for local use)

**Interfaces:**
- Consumes: env `VERSION` (bare semver), `OUT_DIR`, Zig 0.16.0
- Produces: six archives + `atlassian_${VERSION}_checksums.txt` in `OUT_DIR`

- [ ] **Step 1: Implement package-atlassian.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

VERSION="${VERSION:?VERSION bare semver required}"
OUT_DIR="${OUT_DIR:?}"
ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
mkdir -p "$OUT_DIR"

ensure_zig() {
  if command -v zig >/dev/null 2>&1; then
    local v
    v="$(zig version)"
    if [[ "$v" == "$ZIG_VERSION"* ]] || [[ "$v" == "0.16."* ]]; then
      return 0
    fi
  fi
  local os arch tarball url cache
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=x86_64 ;;
    arm64|aarch64) arch=aarch64 ;;
  esac
  case "$os" in
    darwin) os=macos ;;
    linux) os=linux ;;
    *) die "unsupported host OS for zig bootstrap: $os" ;;
  esac
  tarball="zig-${arch}-${os}-${ZIG_VERSION}.tar.xz"
  # Official naming: zig-x86_64-linux-0.16.0.tar.xz
  tarball="zig-${arch}-${os}-${ZIG_VERSION}.tar.xz"
  url="https://ziglang.org/download/${ZIG_VERSION}/${tarball}"
  cache="${REPO_ROOT}/.cache/zig-sdk"
  mkdir -p "$cache"
  if [[ ! -x "$cache/zig" ]]; then
    curl -fsSL "$url" -o "$cache/$tarball"
    tar -xJf "$cache/$tarball" -C "$cache" --strip-components=1
  fi
  export PATH="$cache:$PATH"
  zig version
}

ensure_zig

# target|asset_os|asset_arch|ext
MATRIX=(
  "x86_64-linux-gnu|linux|amd64|tar.gz"
  "aarch64-linux-gnu|linux|arm64|tar.gz"
  "x86_64-macos|macos|amd64|tar.gz"
  "aarch64-macos|macos|arm64|tar.gz"
  "x86_64-windows|windows|amd64|zip"
  "aarch64-windows|windows|arm64|zip"
)

cd "$REPO_ROOT/atlassian"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

for row in "${MATRIX[@]}"; do
  IFS='|' read -r triple aos aarch ext <<<"$row"
  echo "building $triple …"
  zig build -Doptimize=ReleaseSafe -Dtarget="$triple"
  name="atlassian_${VERSION}_${aos}_${aarch}"
  if [[ "$ext" == "tar.gz" ]]; then
    bin="zig-out/bin/atlassian"
    [[ -f "$bin" ]] || die "missing $bin"
    mkdir -p "$workdir/pkg"
    cp "$bin" "$workdir/pkg/atlassian"
    tar -C "$workdir/pkg" -czf "$OUT_DIR/${name}.tar.gz" atlassian
    rm -rf "$workdir/pkg"
  else
    bin="zig-out/bin/atlassian.exe"
    [[ -f "$bin" ]] || die "missing $bin"
    mkdir -p "$workdir/pkg"
    cp "$bin" "$workdir/pkg/atlassian.exe"
    (cd "$workdir/pkg" && zip -q "$OUT_DIR/${name}.zip" atlassian.exe)
    rm -rf "$workdir/pkg"
  fi
done

cd "$OUT_DIR"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum atlassian_"${VERSION}"_* >"atlassian_${VERSION}_checksums.txt"
else
  shasum -a 256 atlassian_"${VERSION}"_* >"atlassian_${VERSION}_checksums.txt"
fi
ls -la
cat "atlassian_${VERSION}_checksums.txt"
```

Verify official Zig tarball name against https://ziglang.org/download/ when implementing (adjust `tarball=` if needed for 0.16.0).

- [ ] **Step 2: Local dry-run one target** (optional quick check)

```bash
cd atlassian && zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos
```

Expected: binary at `zig-out/bin/atlassian`.

- [ ] **Step 3: Commit** — `git commit -m "feat(release): atlassian multi-arch package script"`

---

### Task 4: 9cc VERSION + install/update for `9cc-v*`

**Files:**
- Create: `9cc/VERSION` with `0.5.4` (current fallback line)
- Modify: `9cc/install.sh` — latest tag resolution
- Modify: `9cc/install.ps1` — same
- Modify: `9cc/9cc.sh` — `get_latest_tag`
- Modify: `9cc/9cc.ps1` — same
- Modify: `9cc/9cc.test.sh` — cases for tag filter
- Modify: `9cc/README.md` — pin examples use `9cc-v…`

**Interfaces:**
- Produces: `get_latest_9cc_tag` logic: prefer highest `9cc-v*`, else highest legacy `v*`

- [ ] **Step 1: Add 9cc/VERSION** — content: `0.5.4\n`

- [ ] **Step 2: Add shared resolve helper in install.sh** (near top)

Replace the `CC9_VERSION` default block with:

```bash
# Resolve latest 9cc release tag: prefer 9cc-v*, else legacy v*
resolve_latest_9cc_tag() {
  local json tags=""
  if command -v gh >/dev/null 2>&1; then
    json="$(gh api "repos/investtal/investtal-toolchain/releases?per_page=100" --jq '.[].tag_name' 2>/dev/null || true)"
  else
    json="$(curl -fsSL --max-time 15 \
      'https://api.github.com/repos/investtal/investtal-toolchain/releases?per_page=100' 2>/dev/null \
      | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  fi
  # Prefer 9cc-v*
  tags="$(printf '%s\n' "$json" | grep -E '^9cc-v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^9cc-v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1 || true)"
  if [[ -n "$tags" ]]; then
    printf '9cc-v%s' "$tags"
    return 0
  fi
  # Legacy bare v*
  tags="$(printf '%s\n' "$json" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1 || true)"
  if [[ -n "$tags" ]]; then
    printf 'v%s' "$tags"
    return 0
  fi
  return 1
}

CC9_HOME="${CC9_HOME:-$HOME/.9cc}"
CC9_VERSION="${CC9_VERSION:-}"
if [ -z "$CC9_VERSION" ]; then
  CC9_VERSION="$(resolve_latest_9cc_tag 2>/dev/null || true)"
  [ -n "$CC9_VERSION" ] || CC9_VERSION="v0.5.4"
fi
```

Mirror the same prefer/`9cc-v*` logic in `9cc.sh` `get_latest_tag` and PowerShell counterparts.

- [ ] **Step 3: Update 9cc.sh get_latest_tag** to call the same preference rules (duplicate small function or source is fine for bash; keep self-contained in 9cc.sh since install copies the script).

- [ ] **Step 4: Extend 9cc.test.sh** with pure unit tests for a extracted function if you factor `pick_latest_tag` that takes a list:

```bash
# Test pick_latest_tag prefers 9cc-v over v*
list=$'v0.5.4\n9cc-v0.6.0\natlassian-v0.1.0\n9cc-v0.5.9'
# expected 9cc-v0.6.0
```

Implement `pick_latest_tag` as a function in test or in 9cc.sh and assert.

- [ ] **Step 5: Run** `bash 9cc/9cc.test.sh && bash 9cc/smoke.sh`  
  Expected: PASS

- [ ] **Step 6: Update README** pin examples:

```sh
CC9_VERSION=9cc-v0.5.4 bash install.sh
```

- [ ] **Step 7: Commit** — `git commit -m "feat(9cc): prefer 9cc-v* tags for install and update"`

---

### Task 5: Unified Jenkinsfile

**Files:**
- Modify: `jenkins/Jenkinsfile` (replace/extend; keep 9cc test intent)

**Interfaces:**
- Consumes: scripts from Tasks 1–3; credentials `github-token-userpass`
- Produces: PR CI without release; main auto-release

- [ ] **Step 1: Rewrite jenkins/Jenkinsfile**

```groovy
// investtal-toolchain CI + multi-tool auto-release (main only).
// GitHub Actions are not used. GitHub Releases = distribution only.

pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 45, unit: 'MINUTES')
        disableConcurrentBuilds()
    }

    environment {
        CC9_HOME = "${env.WORKSPACE}/.ci-home"
        CC9_BIN_DIR = "${env.WORKSPACE}/.ci-bin"
        IVT_HOOK_SKIP = '1'
    }

    stages {
        stage('9cc unit + smoke') {
            steps {
                sh '''
                    set -e
                    mkdir -p "$CC9_HOME" "$CC9_BIN_DIR"
                    bash -n 9cc/9cc.sh
                    bash -n 9cc/smoke.sh
                    bash 9cc/9cc.test.sh
                    bash 9cc/smoke.sh
                '''
            }
        }

        stage('Release scripts unit') {
            steps {
                sh 'bash scripts/release/tests/run.sh'
            }
        }

        stage('Atlassian unit + smoke') {
            steps {
                sh '''
                    set -e
                    # Prefer system zig; package script bootstraps on release path
                    if command -v zig >/dev/null 2>&1; then
                      (cd atlassian && zig build test)
                      (cd atlassian && zig build)
                      ./atlassian/scripts/smoke.sh ./atlassian/zig-out/bin/atlassian
                    else
                      echo "zig not on PATH — bootstrap 0.16 for tests"
                      VERSION=0.0.0 OUT_DIR="$WORKSPACE/.ci-atlassian-skip" \
                        bash -c 'source scripts/release/lib.sh; true'
                      # Install zig via package helper ensure path:
                      ZIG_VERSION=0.16.0
                      # call ensure by running a tiny build through package script partial — or:
                      bash scripts/release/package-atlassian.sh --help 2>/dev/null || true
                      # Simpler: use package-atlassian ensure by exporting PATH from a small script
                      bash -c '
                        set -euo pipefail
                        source scripts/release/lib.sh
                        # inline ensure_zig from package script: run package with VERSION for host-only if we add --host-only later
                      '
                    fi
                '''
            }
        }

        stage('Matrix: real macOS 9cc') {
            steps {
                script {
                    def macAgent = nodesByLabel label: 'macos'
                    if (macAgent) {
                        node('macos') {
                            sh '''
                                set -e
                                bash 9cc/9cc.test.sh
                                bash 9cc/smoke.sh
                            '''
                        }
                    } else {
                        echo 'no macos agent — skip native macOS 9cc'
                    }
                }
            }
        }

        stage('Auto release (main)') {
            when {
                allOf {
                    branch 'main'
                    not { changeRequest() }
                }
            }
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'github-token-userpass',
                    usernameVariable: 'GIT_USERNAME',
                    passwordVariable: 'GH_TOKEN'
                )]) {
                    sh '''
                        set -euo pipefail
                        export GITHUB_TOKEN="$GH_TOKEN"
                        export GH_TOKEN
                        export GIT_USERNAME
                        git fetch --tags --prune
                        # BASE_SHA: first parent of merge commit when available
                        if git rev-parse -q --verify HEAD^2 >/dev/null; then
                          export BASE_SHA="$(git rev-parse HEAD^1)"
                        else
                          export BASE_SHA="$(git rev-parse HEAD^)"
                        fi
                        bash scripts/release/run-auto-release.sh
                    '''
                }
            }
        }
    }

    post {
        always {
            sh 'rm -rf "$CC9_HOME" "$CC9_BIN_DIR" || true'
            archiveArtifacts artifacts: 'dist/**/*', allowEmptyArchive: true
            cleanWs()
        }
        unsuccessful {
            echo 'toolchain CI failed — check 9cc/atlassian tests or release scripts'
        }
    }
}
```

**Important implementer note:** Clean up the Atlassian stage — do not leave the half-stub in the final file. Final Atlassian stage must:

1. Ensure Zig 0.16 on PATH (extract `ensure_zig` to `scripts/release/ensure-zig.sh` if needed).
2. `cd atlassian && zig build test && zig build`
3. `./scripts/smoke.sh ./zig-out/bin/atlassian` from `atlassian/`

Recommended: extract `ensure_zig` from package script into `scripts/release/ensure-zig.sh` used by both CI and package.

- [ ] **Step 2: Extract ensure-zig.sh** and source it from package-atlassian.sh + Jenkins atlassian stage.

- [ ] **Step 3: Commit** — `git commit -m "ci: unified Jenkinsfile with multi-tool auto-release on main"`

---

### Task 6: Remove GitHub Actions + docs

**Files:**
- Delete: `.github/workflows/atlassian-release.yml`
- Delete empty dirs under `.github/` if unused
- Modify: `README.md` (root)
- Modify: `atlassian/README.md`
- Modify: `9cc/README.md` (if not fully done in Task 4)
- Modify: `proto/atlassian/plugin.toml` header comment
- Modify: `docs/specs/2026-07-17-atlassian-cli-design.md` section 11.2 note: CI is Jenkins (optional one-line pointer)

- [ ] **Step 1: Delete workflow**

```bash
git rm .github/workflows/atlassian-release.yml
# remove empty dirs if needed
```

- [ ] **Step 2: Root README — replace contributing release line**

Add a **Release** section:

```markdown
## Release (Jenkins only)

CI/CD runs on **Jenkins** (`jenkins/Jenkinsfile`). GitHub Actions are not used.

On every merge to `main`, if a registered tool under `scripts/release/tools.manifest` changed:

1. Bump that tool’s version from the PR title (Conventional Commits).
2. Tag `{tool}-vX.Y.Z` and push.
3. For binary tools (atlassian), cross-build and upload assets to a **GitHub Release** (distribution host only).

Manual tags for release are not required. Do not reintroduce `.github/workflows/*` for CI.
```

- [ ] **Step 3: atlassian README** — replace “Release workflow: `.github/workflows/...`” with Jenkins + `scripts/release/package-atlassian.sh` + tag `atlassian-v*`.

- [ ] **Step 4: proto/atlassian/plugin.toml** comment:

```toml
# Upstream release: investtal/investtal-toolchain tags atlassian-v* (created by Jenkins)
```

- [ ] **Step 5: Commit** — `git commit -m "ci: remove GitHub Actions release; document Jenkins-only releases"`

---

### Task 7: End-to-end verification checklist

**Files:** none (ops)

- [ ] **Step 1:** `bash scripts/release/tests/run.sh` → pass  
- [ ] **Step 2:** `bash 9cc/9cc.test.sh && bash 9cc/smoke.sh` → pass  
- [ ] **Step 3:** `cd atlassian && zig build test && zig build && ./scripts/smoke.sh ./zig-out/bin/atlassian` → pass  
- [ ] **Step 4:** Dry-run package one host target:

```bash
VERSION=0.1.0 OUT_DIR=/tmp/atl-dist bash scripts/release/package-atlassian.sh
# optional: full 6-target if time allows
ls /tmp/atl-dist
```

- [ ] **Step 5:** Confirm no workflow files:

```bash
test ! -f .github/workflows/atlassian-release.yml
```

- [ ] **Step 6:** Confirm Jenkins job for `investtal-toolchain` points at `jenkins/Jenkinsfile` (ops; document if job name differs). Credential `github-token-userpass` must have `contents:write` / release scope.

- [ ] **Step 7:** After merge to main with a real atlassian change, verify GitHub shows tag `atlassian-v*` and assets + checksums; proto install still works.

---

## Self-review (spec coverage)

| Spec requirement | Task |
|------------------|------|
| Auto on main | 5, 2 |
| Per-tool tags | 1–2 |
| 9cc → 9cc-v* | 4 |
| Conventional commit bump | 1, 2 |
| Unified Jenkinsfile + scripts | 1–5 |
| Zig cross ×6 + checksums | 3 |
| Delete GHA | 6 |
| Docs | 4, 6 |
| PR never releases | 5 `when` |
| Proto URL unchanged | 3 asset names |

No intentional placeholders left; Jenkins atlassian stage cleanup is explicit in Task 5.

---

## Execution notes

- Work on an `IVT-XXXX-…` branch per git-hooks.
- Prefer worktree isolation for long execution.
- First production atlassian release will install Zig on the agent and take longer (~minutes for 6 targets).
