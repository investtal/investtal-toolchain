# Task 1 Report — Release core scripts + unit tests

**Status:** DONE

## Summary

Implemented core release scripts under `scripts/release/`: tools manifest, shared lib helpers, detect-changed-tools, detect-bump-level, bump-version, and unit tests. All scripts are portable for macOS bash 3.2 and Linux bash. Tests pass with exit 0.

## Files created

| Path | Purpose |
|------|---------|
| `scripts/release/tools.manifest` | Tool registry: atlassian (binary/zig.zon), 9cc (source-tag/plain) |
| `scripts/release/lib.sh` | Shared helpers: `die`, `load_tool`, `semver_bump`, `read_version`, `write_version` |
| `scripts/release/detect-changed-tools.sh` | Maps changed paths (stdin or `BASE_SHA`/`HEAD_SHA` git diff) → tool names |
| `scripts/release/detect-bump-level.sh` | PR title → `major` \| `minor` \| `patch` \| `none` |
| `scripts/release/bump-version.sh` | Bump tool version file; print new bare semver |
| `scripts/release/tests/run.sh` | Unit tests for bump level, path matching, semver |

All `.sh` files are executable (`chmod +x`).

Note: `scripts/release/tests/fixtures/` was not needed; fixtures are exercised inline in `run.sh`.

## Commit

- **SHA:** `0472d23f7af1e41ca6d49aa30b91f40c185296af` (short: `0472d23`)
- **Message:** `feat(release): core detect/bump scripts for multi-tool releases IVT-1707`
- **Not pushed** (per constraints)

## Tests

```bash
bash scripts/release/tests/run.sh
```

**Result:** exit 0 — `passed=12 failed=0`

Coverage:

- detect-bump-level: `feat!`→major, `BREAKING CHANGE`→major, `feat(scope):`→minor, `fix`/`chore`→patch, `none`→none
- detect-changed-tools: atlassian path, 9cc path, docs-only empty
- semver_bump: minor / major / patch arithmetic

## Portability fixes vs plan sample code

Sample code used constructs that fail on macOS bash 3.2:

1. **`declare -A`** in `detect-changed-tools.sh` — associative arrays unavailable. Replaced with a newline-separated string set + `grep -Fxq` uniqueness.
2. **`=~` with inline parentheses** in `detect-bump-level.sh` — bash 3.2 parser errors (`unexpected token )`). Regex patterns stored in variables and split into simpler patterns (`type!:` vs `type(scope)!:`).
3. **Process substitution** for git diff path collection — replaced with `mktemp` + file redirect for broader portability.
4. **Comma-split globs** — explicit loop instead of `read -ra` + associative map iteration over `${!seen[@]}`.

## Concerns

None blocking. Minor notes for later tasks:

- `detect-changed-tools.sh` only implements trailing `/**` prefix matching (per plan); full fnmatch is not required by current manifest.
- `bump-version.sh` is implemented but not unit-tested against real `build.zig.zon` / `VERSION` files in `run.sh` (out of plan’s test sample); worth adding in a later task if packaging depends on it.
- Empty `paths` + stdin-only mode is covered; git `BASE_SHA` mode not covered by unit tests (needs a real repo range; intentional for unit suite).

## Out of scope (not done)

- Packaging / Zig cross-compile
- Jenkinsfile
- 9cc install/update changes
- Deleting GitHub Actions workflows

## Follow-up fix (review)

**Portability — `[[:space:]]` instead of `\s` (IVT-1707)**

- **Finding:** `read_version` / `write_version` zig.zon paths used `grep -E` / `sed -E` with `\s`, which is not portable on macOS BSD grep/sed.
- **Fix:** Replaced `\s` with `[[:space:]]` in both patterns in `scripts/release/lib.sh`.
- **Also:** Trap cleanup for `_diff_tmp` in `detect-changed-tools.sh`; unit test for `read_version` against `atlassian/build.zig.zon`.
- **Verify:** `bash scripts/release/tests/run.sh` → `passed=13 failed=0`; manual `load_tool atlassian; read_version ...` → `0.1.0`.
- **Commit:** `fix(release): portable whitespace class for zig.zon version IVT-1707`
