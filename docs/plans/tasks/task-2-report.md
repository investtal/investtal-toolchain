# Task 2 Report — Tag, push, and GitHub publish scripts

**Status:** DONE

## Summary

Implemented tag/push, GitHub Release publish, and main-branch auto-release orchestrator under `scripts/release/`. Added minimal `9cc/VERSION` (`0.5.4`) so source-tag bumps work before Task 4 install migration. All scripts are executable and portable for macOS bash 3.2. Unit/smoke suite green; **no live push or real GitHub release** was performed.

## Files created / updated

| Path | Purpose |
|------|---------|
| `scripts/release/create-tag-and-push.sh` | Commit version file, annotated tag `{tool}-v{ver}`, push `HEAD:main` + tag |
| `scripts/release/publish-github-release.sh` | Idempotent `gh release create` + optional asset upload |
| `scripts/release/run-auto-release.sh` | Jenkins/local orchestrator: skip, detect tools, PR title → bump → tag → package → publish |
| `9cc/VERSION` | Plain semver seed `0.5.4` (matches current install default pin family) |
| `scripts/release/tests/run.sh` | Extended with 9cc read_version, `bash -n`, skip-predicate smoke |

All new `.sh` files are executable (`chmod +x`).

## Interfaces

### `create-tag-and-push.sh <tool> <bare-version>`

- Loads tool via `lib.sh` / manifest
- Idempotent if tag already exists (exit 0, skip create)
- Commit message: `chore(release): {tool} v{ver} [skip ci]`
- If `GH_TOKEN`/`GITHUB_TOKEN` set: rewrites `origin` to HTTPS with `GIT_USERNAME` (default `x-access-token`)
- Pushes `origin HEAD:main` then `origin {tag}` (never force-push)

### `publish-github-release.sh <tag> [asset-dir]`

- Requires `GH_TOKEN` or `GITHUB_TOKEN`
- `GITHUB_REPOSITORY` optional (default `investtal/investtal-toolchain`)
- Skips create if release already exists; uploads files under `asset-dir` with `--clobber` when present

### `run-auto-release.sh`

- Skips when HEAD subject contains `[skip ci]` / `[ci skip]` or starts with `chore(release):`
- `BASE_SHA` default `HEAD^`; `HEAD_SHA` default `HEAD`
- PR title via GitHub REST `commits/{sha}/pulls` + **node** JSON parse (Jenkins agents have node)
- Bump level `none` → exit 0
- Binary tools: calls `package-atlassian.sh` for `atlassian` (Task 3 must land file; clear die if missing)
- Source-tag tools (9cc): tag + release notes only (empty asset dir)

## Commit

- **Message:** `feat(release): tag push and GitHub publish scripts IVT-1707`
- **Not pushed** (per constraints)

## Tests

```bash
bash scripts/release/tests/run.sh
```

**Result:** exit 0 — `passed=19 failed=0`

Coverage added beyond Task 1:

- `read_version` plain for `9cc/VERSION` → `0.5.4`
- `bash -n` on the three new scripts
- Skip-predicate true for release commits / false for normal `feat`
- Manual: `bump-version.sh 9cc patch` → `0.5.5` then restored

**Not run (by design):** live `git push`, live `gh release create`.

## Portability fixes vs plan sample code

1. **`mapfile`** in `run-auto-release.sh` — bash 4+ only. Replaced with `mktemp` + `while read` array build (same pattern as Task 1).
2. **`=~` skip regex** with brackets/parens — avoided; used substring `*` / glob `chore(release):*` matching for bash 3.2 safety.
3. **`$(find …)` asset upload** — empty find would pass zero paths to `gh`. Collect files into an array; skip upload when empty.
4. **Package script missing** — explicit `die` if `package-atlassian.sh` absent so binary path fails clearly until Task 3.

## Dependencies (document)

| Tool | Used by |
|------|---------|
| `bash`, `git` | all scripts |
| `curl` | PR title lookup in orchestrator |
| `node` | JSON parse of GitHub pulls response |
| `gh` | `publish-github-release.sh` |
| `GH_TOKEN` / `GITHUB_TOKEN` | push auth rewrite, API, `gh` |

## Concerns

- **`git push origin HEAD:main`** assumes Jenkins runs on main (per design). Running the orchestrator on a feature branch with a token would push that HEAD onto `main` — do not enable tokenized local runs off-main.
- **`package-atlassian.sh` not present yet** — releasing `atlassian` via orchestrator will die until Task 3. Source-tag path (9cc) does not need it.
- **Node required** for PR title parse; if node is unavailable on an agent, orchestrator fails after tools are detected. Acceptable per task note.
- **Tag-exists early exit** does not re-push or re-publish; re-run after partial failure may need manual recovery.
- **No dry-run flag** implemented (optional in plan); safety is “do not run with token off-main.”

## Out of scope (not done)

- `package-atlassian.sh` / Zig packaging (Task 3)
- Jenkinsfile wiring
- 9cc install/update migration to `9cc-v*` (Task 4)
- Deleting GitHub Actions workflows
