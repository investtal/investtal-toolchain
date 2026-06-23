# proto-plugins — inventory

Vendored, Investtal-owned proto toolchain plugins. Full rationale, integrity
findings, and consumer instructions: [`docs/proto-plugins.md`](../../docs/proto-plugins.md).

| Tool | File | Kind | Binary checksum | Audited |
|------|------|------|-----------------|---------|
| gitleaks | `gitleaks/plugin.toml` | TOML | ✅ `checksums.txt` | 2026-06-23 |
| migrate | `migrate/plugin.toml` | TOML | ✅ `sha256sum.txt` | 2026-06-23 |
| trivy | `trivy/plugin.toml` | TOML | ✅ `checksums.txt` | 2026-06-23 |
| gh | `gh/plugin.toml` | TOML | ✅ hardened (added `checksum-url`) | 2026-06-23 |
| gradle | `gradle/plugin.toml` | TOML | ✅ `.sha256` | 2026-06-23 |
| yq | `yq/plugin.toml` | TOML | ❌ upstream ships no parseable checksum | 2026-06-23 |
| openjdk | `openjdk/openjdk_adoptium_tool.wasm` | WASM | vendored binary, `.sha256` pinned | 2026-06-23 |
| semgrep | `semgrep/requirements.txt` | PyPI | ✅ pip `--require-hashes` | 2026-06-23 |

All verified end-to-end with `proto 0.56.4`: each TOML plugin resolves versions,
downloads, and (where supported) verifies the binary checksum; the openjdk WASM
plugin loads and lists Adoptium versions.
