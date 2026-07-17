# Task 2 Report — Tag, push, and GitHub publish scripts

**Status:** DONE (review findings fixed)

## Summary

Implemented tag/push, GitHub Release publish, and main-branch auto-release orchestrator under `scripts/release/`. Added minimal `9cc/VERSION` (`0.5.4`) so source-tag bumps work before Task 4 install migration. All scripts are executable and portable for macOS bash 3.2. Unit/smoke suite green; **no live push or real GitHub release** was performed.

## Files created / updated

| Path | Purpose |
|------|---------|
| `scripts/release/create-tag-and-push.sh` | Commit version file, annotated tag `{tool}-v{ver}`, push `HEAD:main` + tag |
| `scripts/release/publish-github-release.sh` | Idempotent `gh release create` + optional asset upload |
| `scripts/release/run-auto-release.sh` | Jenkins/local orchestrator: skip, detect tools, PR title → bump → tag → package → publish |
| `9cc/VERSION` | Plain semver seed `0.5.4` (matches current install default pin family) |
| `scripts/release/tests/run.sh` | Extended with 9cc read_version, `bash -n`, skip/retriable predicates, parse, main guard |

All new `.sh` files are executable (`chmod +x`).

## Interfaces

### `create-tag-and-push.sh <tool> <bare-version>`

- Loads tool via `lib.sh` / manifest
- If tag already exists: skip create/commit, **still** push `HEAD:main` + tag (retriable)
- Commit message: `chore(release): {tool} v{ver} [skip ci]`
- If `GH_TOKEN`/`GITHUB_TOKEN` set: rewrites `origin` to HTTPS with `GIT_USERNAME` (default `x-access-token`)
- **Main-only push:** refuses `git push origin HEAD:main` unless local branch is `main` **or** `BRANCH_NAME`/`GIT_BRANCH` (basename) is `main` (Jenkins detached HEAD). Clear `die` otherwise.
- Pushes `origin HEAD:main` then `origin {tag}` (never force-push)

### `publish-github-release.sh <tag> [asset-dir]`

- Requires `GH_TOKEN` or `GITHUB_TOKEN`
- `GITHUB_REPOSITORY` optional (default `investtal/investtal-toolchain`)
- Skips create if release already exists; uploads files under `asset-dir` with `--clobber` when present

### `run-auto-release.sh`

- **Full skip** only for pure `[skip ci]` / `[ci skip]` subjects that are **not** `chore(release):…`
- **Retriable path:** `chore(release): {tool} v{ver} …` → parse tool+ver → `create-tag-and-push` + package + `publish-github-release` only (no bump, no new version commit)
- Normal merges: detect tools → PR title → bump level
- **Before bump:** compute `{tool}-v{current+level}`; if that tag already exists, skip `bump-version.sh` and only ensure push/package/publish
- `BASE_SHA` default `HEAD^`; `HEAD_SHA` default `HEAD`
- PR title via GitHub REST `commits/{sha}/pulls` + **node** JSON parse (Jenkins agents have node)
- Bump level `none` → exit 0
- Binary tools: calls `package-atlassian.sh` for `atlassian` (Task 3 must land file; clear die if missing)
- Source-tag tools (9cc): tag + release notes only (empty asset dir)

## Commits

- **Initial:** `feat(release): tag push and GitHub publish scripts IVT-1707`
- **Review fix:** `fix(release): main-only push and retriable publish IVT-1707`
- **Not pushed** (per constraints)

## Review fix notes (Important findings)

1. **Main-only `HEAD:main` push** — `create-tag-and-push.sh` now calls `require_main_for_push` before any push. Accepts local `main` or Jenkins `BRANCH_NAME`/`GIT_BRANCH` resolving to `main` (including `origin/main`).
2. **Tag-exists is not a no-op** — existing local tag skips create/commit but still rewrites remote (if token) and pushes commit + tag so publish can proceed on re-run.
3. **Retriable publish after release commit** — orchestrator no longer exits 0 on `chore(release): … [skip ci]`. Those commits re-enter ensure-push + package + publish only. Pure `[skip ci]` / `[ci skip]` (non-release) still full-skip.
4. **Skip bump when target tag exists** — normal path computes next version from current+level; if `{tool}-v{new}` exists, skips write/bump and continues with push/package/publish.

## Tests

```bash
bash scripts/release/tests/run.sh
```

**Result:** exit 0 — `passed=36 failed=0`

Coverage:

- `read_version` plain for `9cc/VERSION` → `0.5.4`
- `bash -n` on all release scripts
- Full-skip vs retriable (`chore(release)`) subject predicates
- Parse `chore(release): {tool} v{ver}` subjects
- Main-only push decision matrix (local / detached / env)
- Target tag naming from current+level (skip-bump contract)
- Manual: `bump-version.sh 9cc patch` → `0.5.5` then restored (earlier)

**Not run (by design):** live `git push`, live `gh release create`.

## Portability fixes vs plan sample code

1. **`mapfile`** in `run-auto-release.sh` — bash 4+ only. Replaced with `mktemp` + `while read` array build (same pattern as Task 1).
2. **`=~` skip regex** with brackets/parens — avoided; used substring `*` / glob `chore(release):*` matching for bash 3.2 safety.
3. **`$(find …)` asset upload** — empty find would pass zero paths to `gh`. Collect files into an array; skip upload when empty.
4. **Package script missing** — explicit `die` if `package-atlassian.sh` absent so binary path fails clearly until Task 3.
5. **Release-subject parse** — pure parameter expansion (no `BASH_REMATCH` dependency) for bash 3.2.

## Dependencies (document)

| Tool | Used by |
|------|---------|
| `bash`, `git` | all scripts |
| `curl` | PR title lookup in orchestrator |
| `node` | JSON parse of GitHub pulls response |
| `gh` | `publish-github-release.sh` |
| `GH_TOKEN` / `GITHUB_TOKEN` | push auth rewrite, API, `gh` |

## Concerns

- **`package-atlassian.sh` not present yet** — releasing `atlassian` via orchestrator will die until Task 3. Source-tag path (9cc) does not need it.
- **Node required** for PR title parse; if node is unavailable on an agent, orchestrator fails after tools are detected. Acceptable per task note.
- **No dry-run flag** implemented (optional in plan); safety is main-only push guard + “do not run with token off-main.”
- Jenkins must set `BRANCH_NAME` or `GIT_BRANCH` when checkout is detached HEAD.

## Out of scope (not done)

- `package-atlassian.sh` / Zig packaging (Task 3)
- Jenkinsfile wiring
- 9cc install/update migration to `9cc-v*` (Task 4)
- Deleting GitHub Actions workflows
