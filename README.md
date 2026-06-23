# proto-plugins

Vendored, Investtal-owned [proto](https://moonrepo.dev/proto) toolchain plugins.

This **public** repo exists so private repos (e.g. `investtal-portals`,
`devops-investtal`) can pin proto plugins to immutable, Investtal-audited
definitions over plain `https://` — instead of resolving them from uncontrolled
third-party repos. proto loads a plugin's definition at install time and has
**no checksum/lockfile for the plugin file itself**, so whoever controls the
source repo controls our binary download path. Vendoring + commit-SHA pinning is
the integrity control; each TOML plugin's `checksum-url` then verifies the
downloaded binary.

> Plugin definitions only point at public upstream release binaries — no secrets.
> The canonical source is `investtal-portals/packages/proto-plugins`; this repo
> is the public mirror used for `https://` locators.

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

See `INVENTORY.md` for audit dates and per-tool notes.

## Usage

Pin to an immutable commit SHA (never a branch — a branch ref lets anyone with
push access silently change the download):

```toml
[plugins.tools]
gitleaks = "https://raw.githubusercontent.com/investtal/proto-plugins/<COMMIT_SHA>/gitleaks/plugin.toml"
openjdk  = "https://raw.githubusercontent.com/investtal/proto-plugins/<COMMIT_SHA>/openjdk/openjdk_adoptium_tool.wasm"
```

semgrep is not a proto plugin (PyPI-only); install its lockfile with:

```bash
pip install --require-hashes -r <path>/semgrep/requirements.txt
```

## Updating

1. Make the change in `investtal-portals/packages/proto-plugins`, verify with
   `proto install <tool>` against a `file://` locator.
2. Mirror the changed files here, commit.
3. Bump the pinned commit SHA in every consumer `.prototools`.
