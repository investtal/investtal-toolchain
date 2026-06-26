# investtal-toolchain

Vendored, Investtal-owned [proto](https://moonrepo.dev/proto) toolchain plugins.

This **public** repo is the **single canonical source** for every Investtal proto
plugin. Private repos (e.g. `investtal-portals`, `devops-investtal`,
`investtal-apis`) pin proto plugins to immutable, Investtal-audited definitions
here over plain `https://` — instead of resolving them from uncontrolled
third-party repos. proto loads a plugin's definition at install time and has
**no checksum/lockfile for the plugin file itself**, so whoever controls the
source repo controls our binary download path. Vendoring + commit-SHA pinning is
the integrity control; each TOML plugin's `checksum-url` then verifies the
downloaded binary.

> Plugin definitions only point at public upstream release binaries — no secrets.
> This repo is the one place the plugins live; consumers reference it by
> commit-SHA-pinned raw URL.

## Inventory

| Tool | File | Kind | Binary checksum verified? |
|------|------|------|---------------------------|
| gitleaks | `gitleaks/plugin.toml` | TOML | ✅ `checksums.txt` |
| migrate | `migrate/plugin.toml` | TOML | ✅ `sha256sum.txt` |
| trivy | `trivy/plugin.toml` | TOML | ✅ `checksums.txt` |
| gh | `gh/plugin.toml` | TOML | ✅ hardened (added `checksum-url`) |
| gradle | `gradle/plugin.toml` | TOML | ✅ `.sha256` |
| yq | `yq/plugin.toml` | TOML | ❌ upstream ships no parseable checksum |
| openjdk | `openjdk/openjdk_adoptium_tool.wasm` (+ `.sha256`) | WASM | vendored binary, hash pinned |
| semgrep | `semgrep/requirements.txt` | PyPI | ✅ pip `--require-hashes` (fully locked) |
| shfmt | `shfmt/plugin.toml` | TOML | ❌ upstream ships no checksum file (single-file binary) |
| shellcheck | `shellcheck/plugin.toml` | TOML | ❌ upstream ships no aggregate checksum file |
| kubectl | `kubectl/plugin.toml` | TOML | ❌ per-binary `.sha256` exists but proto TOML cannot wire it |
| vault | `vault/plugin.toml` | TOML | ✅ `SHA256SUMS` |

See `INVENTORY.md` for audit dates and [`docs/proto-plugins.md`](docs/proto-plugins.md)
for full rationale, integrity findings, and per-tool notes.

## Usage

Pin to an immutable commit SHA (never a branch — a branch ref lets anyone with
push access silently change the download):

```toml
[plugins.tools]
gitleaks = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/gitleaks/plugin.toml"
openjdk  = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/openjdk/openjdk_adoptium_tool.wasm"
```

semgrep is not a proto plugin (PyPI-only); install its lockfile with:

```bash
pip install --require-hashes -r <path>/semgrep/requirements.txt
```

## Updating

1. Make the change here, verify with `proto install <tool>` against a `file://`
   locator (confirm the install log shows `Verifying checksum against …`).
2. Commit.
3. Bump the pinned commit SHA in every consumer `.prototools`.
