# Final branch review — IVT-1707-toolchain-jenkins-release

See parent session for full body. Verdicts:

- SPEC_COMPLIANCE: PASS
- CODE_QUALITY: PASS
- SHIP_READY: YES

Important (pre-fix):
1. atlassian CLI VERSION hardcoded vs build.zig.zon
2. node required for PR title parse
3. shallow clone breaks BASE_SHA
4. agent deps not preflighted
5. 9cc releases per_page=100 only
6. token embedded in git remote URL

---

## Fixes applied (post-review)

Commit message: `fix(release): address final review important items IVT-1707`

### 1. Sync atlassian CLI VERSION with build.zig.zon
- `scripts/release/lib.sh` `write_version` for `zig.zon` now also calls `sync_cli_version_const`, which sed-updates `pub const VERSION` in `<pkg>/src/cli/root.zig` when present.
- `atlassian/src/cli/root.zig` help banner uses compile-time `VERSION` concat (single source of truth in the Zig file).
- `create-tag-and-push.sh` stages the companion `src/cli/root.zig` on zig.zon tools so the release commit includes both.
- Unit test: temp copy of zon + root.zig asserts both land on `9.8.7` after `write_version`.

### 2. PR title without hard node requirement
- `run-auto-release.sh` `resolve_pr_title`: prefer `gh api … --jq '.[0].title // "none"'`, then curl+python3, then curl+sed/grep best-effort for `"title": "…"`.
- Dies with a clear message only when tools changed and all resolve paths fail.

### 3. Shallow clone / BASE_SHA
- Jenkins Auto release stage: `git fetch --unshallow || git fetch --deepen=50 || true` before BASE_SHA resolution; tries `HEAD^` then `HEAD~1`, fails clearly if neither works.
- `run-auto-release.sh` `resolve_base_sha`: same `HEAD^` → `HEAD~1` fallback with an explicit unshallow/deepen error if history is missing.

### 4. Agent preflight in Jenkinsfile Auto release stage
- Requires `gh`, `curl`, `git`, and `zip` before running the orchestrator.
- `package-atlassian.sh` dies early with a clear message if `zip` or `tar` is missing.

### 5. 9cc tag discovery pagination
- `9cc/9cc.sh` `get_latest_tag` and `9cc/install.sh` `resolve_latest_9cc_tag`:
  - `gh api --paginate '…/releases?per_page=100'`
  - curl path: pages 1 and 2 (`&page=N`)

### 6. Don't persist token in origin remote
- `create-tag-and-push.sh` pushes via one-shot URL  
  `git push "https://${user}:${token}@github.com/…/investtal-toolchain.git" HEAD:main`  
  and `refs/tags/$tag` — no `git remote set-url origin`.

## Test summary (local)

| Check | Result |
|-------|--------|
| `bash -n` on changed release + 9cc scripts | pass |
| `bash scripts/release/tests/run.sh` | passed=40 failed=0 |
| `bash 9cc/9cc.test.sh` | PASS=136 FAIL=0 |
| `bash 9cc/smoke.sh` | SMOKE PASS=4 FAIL=0 |
| `atlassian` build + `atlassian version` | 0.1.0 |
