# Task 3 Report — package-atlassian.sh (Zig cross-build + checksums)

**Status:** DONE

## Summary

Implemented multi-arch packaging for atlassian via Zig cross-compile. Produces six platform archives plus a SHA-256 checksums file with names matching `proto/atlassian/plugin.toml`. Zig 0.16.0 is bootstrapped when missing/wrong via official ziglang.org tarballs. Extracted bootstrap into `ensure-zig.sh` for Task 5 reuse.

## Files created / updated

| Path | Purpose |
|------|---------|
| `scripts/release/package-atlassian.sh` | Cross-build 6 targets → archives + checksums |
| `scripts/release/ensure-zig.sh` | Bootstrap/pin Zig 0.16.0 (sourceable + direct exec) |
| `atlassian/scripts/package-release.sh` | Thin local wrapper → monorepo script |
| `scripts/release/tests/run.sh` | Include new scripts in `bash -n` suite |

All new `.sh` files are executable (`chmod +x`).

## Interfaces

### Env

| Var | Required | Notes |
|-----|----------|-------|
| `VERSION` | yes | Bare semver (`0.1.0`), no `v` prefix |
| `OUT_DIR` | yes | Destination dir (created if missing; resolved absolute) |
| `ZIG_VERSION` | no | Default `0.16.0` |

### Outputs in `OUT_DIR`

```
atlassian_{VERSION}_linux_amd64.tar.gz   # exe path: atlassian
atlassian_{VERSION}_linux_arm64.tar.gz
atlassian_{VERSION}_macos_amd64.tar.gz
atlassian_{VERSION}_macos_arm64.tar.gz
atlassian_{VERSION}_windows_amd64.zip    # exe path: atlassian.exe
atlassian_{VERSION}_windows_arm64.zip
atlassian_{VERSION}_checksums.txt        # sha256 of the six archives only
```

### Zig targets

| Zig `-Dtarget` | Asset |
|----------------|-------|
| `x86_64-linux-gnu` | linux/amd64 tar.gz |
| `aarch64-linux-gnu` | linux/arm64 tar.gz |
| `x86_64-macos` | macos/amd64 tar.gz |
| `aarch64-macos` | macos/arm64 tar.gz |
| `x86_64-windows` | windows/amd64 zip |
| `aarch64-windows` | windows/arm64 zip |

### Zig bootstrap (`ensure-zig.sh`)

- Prefer system `zig` if version is exact pin, `${ZIG_VERSION}.*`, or `0.16.*`
- Else download `https://ziglang.org/download/{ver}/zig-{arch}-{os}-{ver}.tar.xz`
  - Confirmed naming for 0.16.0: `zig-x86_64-linux-0.16.0.tar.xz`, `zig-aarch64-macos-0.16.0.tar.xz`, etc.
  - Host map: `darwin`→`macos`, `arm64`→`aarch64`
- Cache: `$REPO_ROOT/.cache/zig-sdk` (`--strip-components=1`), prepended to `PATH`
- Stale cache (wrong version) is wiped and re-fetched

## Commit

- **Message:** `feat(release): atlassian multi-arch package script IVT-1707`
- **Not pushed** (per constraints)

## Tests

```bash
bash -n scripts/release/package-atlassian.sh
bash -n scripts/release/ensure-zig.sh
bash scripts/release/tests/run.sh
VERSION=0.1.0 OUT_DIR=dist/atlassian-pkg-test ./scripts/release/package-atlassian.sh
```

| Check | Result |
|-------|--------|
| `bash -n` package + ensure-zig | OK |
| `scripts/release/tests/run.sh` | `passed=38 failed=0` |
| Full 6-target package (host: macOS arm64, zig 0.16.0) | OK (~2 min) |
| Asset names match plugin.toml | All 7 files present |
| tar contents | `atlassian` |
| zip contents | `atlassian.exe` |
| checksums lines | 6 (archives only) |

Dry-run artifacts left untracked under `dist/atlassian-pkg-test/` (not committed).

## Concerns / notes

1. **`zip` required** for Windows packages — present on macOS and typical Linux Jenkins agents; not installed by this script.
2. **Linux archives are larger** (~2.4 MiB) than macOS/Windows (~0.6–0.7 MiB) with current Zig/libc linking; expected with `link_libc` on gnu targets.
3. **`ensure_zig` accepts any `0.16.*`** on PATH — intentional patch tolerance; pin still downloads exact `ZIG_VERSION` when bootstrapping.
4. **No Jenkinsfile / 9cc install changes** (Tasks 4–5 out of scope).
5. **Task 5** can `source ensure-zig.sh` the same way as `package-atlassian.sh`.
