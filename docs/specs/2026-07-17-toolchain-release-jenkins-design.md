# Toolchain release on Jenkins — Design Spec

**Date:** 2026-07-17  
**Status:** Approved  
**Repo:** `investtal/investtal-toolchain`  
**Replaces:** `.github/workflows/atlassian-release.yml` as CI/CD for releases

---

## 1. Purpose

Reorganize how tools in this monorepo are **versioned, tagged, and released** so that:

1. **CI/CD does not depend on GitHub Actions** — Jenkins is the only release orchestrator.
2. **Multiple tools** (9cc, atlassian, future CLIs) can ship independently with clear tags.
3. **GitHub remains distribution only** (git tags, Releases, raw URLs for proto/install) — not the pipeline host.

**Non-goals:** changing proto download URL scheme away from GitHub Releases; rewriting product deploy pipelines; historical rewrite of old `v0.5.x` 9cc tags.

---

## 2. Resolved decisions

| Item | Decision |
|------|----------|
| Release trigger | **Auto on main** (merge → detect tools → bump → tag → publish), same spirit as investtal-agent |
| Tag scheme | **Per-tool:** `{tool}-v{semver}` (e.g. `atlassian-v0.1.0`, `9cc-v0.6.0`) |
| 9cc migration | Move off bare `v*` / `releases/latest` to **`9cc-v*`** immediately (install + update) |
| Bump level | **Conventional Commits from associated PR title** (`feat`→minor, `!`/BREAKING→major, else patch; no PR→skip) |
| Pipeline layout | **One** `jenkins/Jenkinsfile` + portable `scripts/release/*` |
| Cross-compile | **Zig from one Linux agent** (all 6 targets); no macOS/Windows matrix agents |
| GitHub Actions | **Delete** `atlassian-release.yml`; no new Actions workflows |
| GitHub Releases | **Keep** as artifact host; created by Jenkins via `gh` + `github-token-userpass` |

---

## 3. Architecture

```text
                    PR / branch push
                           │
                           ▼
                 ┌─────────────────────┐
                 │  Jenkins (toolchain) │
                 │  Test stage(s)       │
                 │  9cc + atlassian     │
                 └─────────────────────┘

                    merge → main
                           │
                           ▼
                 ┌─────────────────────┐
                 │  Test (same as PR)  │
                 └──────────┬──────────┘
                            │ pass
                            ▼
                 ┌─────────────────────┐
                 │ Detect changed tools│  path globs from tools.manifest
                 │ Skip [skip ci]      │
                 └──────────┬──────────┘
                            │ for each changed tool
                            ▼
                 ┌─────────────────────┐
                 │ Bump from PR title  │  conventional commits
                 │ Update version file │
                 │ Commit + tag push   │  {tool}-vX.Y.Z  [skip ci]
                 └──────────┬──────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │ Package (if binary) │  atlassian: Zig × 6 targets
                 │ checksums           │  9cc: source-tag only
                 └──────────┬──────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │ gh release create   │  distribution only
                 │ (+ upload assets)   │
                 └─────────────────────┘
```

### 3.1 Dependency rules

| Layer | Owns | Must not |
|-------|------|----------|
| Jenkinsfile | Stages, credentials, when/branch guards | Hardcode tool packaging details |
| `scripts/release/*` | Detect, bump, tag, package, publish | Assume Jenkins env beyond documented vars |
| Tool VERSION / `build.zig.zon` | Canonical semver for that tool | Floating "latest monorepo version" |
| `proto/*/plugin.toml` | Download URL template for binaries | Trigger CI |

---

## 4. Components

### 4.1 Tool registry — `scripts/release/tools.manifest`

Machine-readable list (simple shell-friendly format, e.g. one line per tool or TOML/JSON):

| Field | Example |
|-------|---------|
| `name` | `atlassian` |
| `path_globs` | `atlassian/**`, optionally `proto/atlassian/**` |
| `version_file` | `atlassian/build.zig.zon` (`.version`) or `9cc/VERSION` |
| `tag_prefix` | `atlassian-v` / `9cc-v` |
| `kind` | `binary` \| `source-tag` |
| `package_script` | `scripts/release/package-atlassian.sh` (binary only) |

Initial tools:

| Tool | kind | version source | notes |
|------|------|----------------|-------|
| **atlassian** | binary | `build.zig.zon` `.version` | 6-platform package + checksums; matches `proto/atlassian` |
| **9cc** | source-tag | new `9cc/VERSION` | GitHub Release notes only; install still pulls raw files at tag |

`git-hooks/` and `proto/*` (except tool-linked proto paths) are **not** auto-released tools unless later added to the manifest.

### 4.2 Scripts

| Script | Role |
|--------|------|
| `detect-changed-tools.sh` | Map `git diff` path list → tool names |
| `detect-bump-level.sh` | PR title → `major` \| `minor` \| `patch` \| `none` (mirror investtal-agent rules) |
| `bump-version.sh` | Apply semver bump to tool version file; print new version |
| `create-tag-and-push.sh` | Commit version + `chore(release): {tool} v{ver} [skip ci]`; tag; push |
| `package-atlassian.sh` | Install Zig 0.16 if missing; cross-build; archive; checksums |
| `publish-github-release.sh` | `gh release create` / upload assets; idempotent |

### 4.3 Jenkinsfile stages (target shape)

1. **Checkout**
2. **Unit / smoke** — always (PR + main): 9cc tests + atlassian `zig build test` + smoke (when Zig available)
3. **Auto release** — `when { branch 'main'; not { changeRequest() } }`:
   - Credentials: `github-token-userpass`
   - Orchestrate scripts above
4. **Post** — cleanWs; optional archive of release artifacts for debugging

Existing 9cc-only stages are **merged** into this unified file (keep macOS-strict base64 shim behavior).

### 4.4 Remove

- `.github/workflows/atlassian-release.yml`
- Empty `.github/` tree if nothing else remains

### 4.5 Docs updates

- Root `README.md` — release process = Jenkins, tag scheme
- `atlassian/README.md` — drop Actions link; document Jenkins + tag prefix
- `9cc/README.md` — `9cc-v*` pins; update examples
- `proto/atlassian/plugin.toml` comments — tags still `atlassian-v*`; producer is Jenkins
- Spec/plan cross-links; optional short note in design that GHA is retired

---

## 5. Versioning and tags

### 5.1 Format

```text
{tool}-v{MAJOR}.{MINOR}.{PATCH}
```

Parse: strip `{tool}-v` → semver.

### 5.2 Bump rules (PR title)

Same as investtal-agent `detect-bump-level` on **PR title**:

| Title pattern | Level |
|---------------|-------|
| `type!:` or `BREAKING CHANGE` / `BREAKING-CHANGE` | major |
| `feat` / `feat(scope)` | minor |
| other conventional types or unrecognized | patch |
| no associated PR for HEAD | **none** → skip release for that merge |

Subject/body of the merge commit with `[skip ci]` or `chore(release):` → **skip entire auto-release stage** (prevents loops).

### 5.3 Version files

- **atlassian:** keep single source in `build.zig.zon` `.version`; release commit updates it.
- **9cc:** add `9cc/VERSION` containing bare semver (`0.6.0`). Install stores full tag name `9cc-v0.6.0` in `~/.9cc/version` for display/update compare.

### 5.4 9cc install / update migration

- **Stop** using `GET /repos/.../releases/latest` as the 9cc version oracle (mixed tools break it).
- **Start** listing releases (or tags) and pick highest semver among tags matching `^9cc-v`.
- Accept `CC9_VERSION=9cc-vX.Y.Z` (and optionally bare `X.Y.Z` normalized to `9cc-v…`).
- Fallback pin in install script updates to last known good **`9cc-v*`** after first release under the new scheme (until then, temporary dual: prefer `9cc-v*`, fall back to legacy `v*` only if no `9cc-v*` exists — optional one-release bridge; prefer hard cut once first `9cc-v*` ships).

**Decision for implementer:** implement **prefer `9cc-v*`**, if none exist fall back to highest legacy `v*` so existing users still update until the first new-style release lands.

---

## 6. Atlassian packaging (parity with former GHA)

Targets (Zig triples → asset names):

| Triple | asset_os | asset_arch | archive |
|--------|----------|------------|---------|
| `x86_64-linux-gnu` | linux | amd64 | `.tar.gz` |
| `aarch64-linux-gnu` | linux | arm64 | `.tar.gz` |
| `x86_64-macos` | macos | amd64 | `.tar.gz` |
| `aarch64-macos` | macos | arm64 | `.tar.gz` |
| `x86_64-windows` | windows | amd64 | `.zip` |
| `aarch64-windows` | windows | arm64 | `.zip` |

Naming:

```text
atlassian_{version}_{os}_{arch}.tar.gz   # or .zip
atlassian_{version}_checksums.txt        # sha256  filename
```

Build:

```bash
cd atlassian
zig build -Doptimize=ReleaseSafe -Dtarget=<triple>
```

Must match `proto/atlassian/plugin.toml` download templates:

```text
…/releases/download/atlassian-v{version}/{download_file}
```

---

## 7. Error handling and idempotency

| Situation | Behavior |
|-----------|----------|
| Tests fail | No release |
| No tools changed | Success, no tags |
| Bump level `none` | Skip release |
| Version commit/tag push fails | Fail build |
| Tag already exists for computed version | Skip bump; may re-upload release assets |
| Release exists, assets missing | `gh release upload --clobber` |
| Zig missing on agent | Package script installs official 0.16.0 tarball into workspace tool cache |
| Partial multi-tool failure | Fail after first tool error; do not hide partial tags (log tool + tag clearly for re-run) |

Credentials: never echo tokens. Use `GH_TOKEN` for `gh` and authenticated `git push`.

---

## 8. Testing strategy

| Layer | Approach |
|-------|----------|
| Bump detection | Pure function tests (shell or small node) for title → level matrix |
| Changed tools | Fixture path lists |
| Atlassian package | Local dry-run on host triple in CI; full cross-build on main release path |
| 9cc install/update | Unit tests for tag filter (`9cc-v*` prefer, legacy `v*` fallback) |
| End-to-end | First production cut via merge to main after pipeline lands |

Default PR CI: **no** GitHub release creation.

---

## 9. Security notes

- Use existing Jenkins credential `github-token-userpass` (scoped PAT for contents/releases).
- No long-lived tokens in repo.
- Release commit messages include `[skip ci]` so hooks/pipelines that honor it do not loop.
- Checksums published with binary assets; proto continues to verify.

---

## 10. Migration sequence (implementation order)

1. Add `scripts/release/*` + `tools.manifest` + `9cc/VERSION`.
2. Update 9cc install/update + tests for `9cc-v*`.
3. Expand `jenkins/Jenkinsfile` (tests + auto-release).
4. Delete `.github/workflows/atlassian-release.yml`.
5. Update READMEs / proto comments / inventory notes.
6. First atlassian release only after green main + package smoke; first `9cc-v*` when 9cc next changes on main.

---

## 11. Open items (non-blocking)

- Whether Jenkins job must be (re)registered as multibranch for this repo if not already.
- Exact Zig install path/cache on agents (script-local is fine).
- Whether `proto/atlassian/**` alone should bump atlassian (yes if listed in path_globs — keep yes so plugin-only fixes can release).

---

## 12. Success criteria

- [ ] No GitHub Actions workflows remain for toolchain release.
- [ ] Merge to main that touches `atlassian/` can produce tag `atlassian-v*` + Release + assets without human tagging.
- [ ] 9cc update/install resolve `9cc-v*` tags.
- [ ] Proto install URL contract for atlassian unchanged.
- [ ] PR builds never create releases.

