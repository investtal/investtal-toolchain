# investtal-toolchain — inventory

Vendored, Investtal-owned proto toolchain plugins. Full rationale, integrity
findings, and consumer instructions: [`docs/proto-plugins.md`](docs/proto-plugins.md).

| Tool | File | Kind | Binary checksum | Audited |
|------|------|------|-----------------|---------|
| gitleaks | `proto/gitleaks/plugin.toml` | TOML | ✅ `checksums.txt` | 2026-06-23 |
| migrate | `proto/migrate/plugin.toml` | TOML | ✅ `sha256sum.txt` | 2026-06-23 |
| trivy | `proto/trivy/plugin.toml` | TOML | ✅ `checksums.txt` | 2026-06-23 |
| gh | `proto/gh/plugin.toml` | TOML | ✅ hardened (added `checksum-url`) | 2026-06-23 |
| gradle | `proto/gradle/plugin.toml` | TOML | ✅ `.sha256` | 2026-06-23 |
| yq | `proto/yq/plugin.toml` | TOML | ❌ upstream ships no parseable checksum | 2026-06-23 |
| openjdk | `proto/openjdk/openjdk_adoptium_tool.wasm` | WASM | vendored binary, `.sha256` pinned | 2026-06-23 |
| semgrep | `proto/semgrep/requirements.txt` | PyPI | ✅ pip `--require-hashes` | 2026-06-23 |
| shfmt | `proto/shfmt/plugin.toml` | TOML | ❌ upstream ships no checksum file (single-file binary) | 2026-06-23 |
| shellcheck | `proto/shellcheck/plugin.toml` | TOML | ❌ upstream ships no aggregate checksum file | 2026-06-23 |
| kubectl | `proto/kubectl/plugin.toml` | TOML | ❌ per-binary `.sha256` exists but proto TOML cannot wire it | 2026-06-23 |
| vault | `proto/vault/plugin.toml` | TOML | ✅ `SHA256SUMS` | 2026-06-23 |
| netbird | `proto/netbird/plugin.toml` | TOML | n/a (vendored CLI plugin definition) | 2026-07-08 |
| atlassian | `proto/atlassian/plugin.toml` | TOML | ✅ release checksums | 2026-07-17 |

All verified end-to-end with `proto 0.56.4`: each TOML plugin resolves versions,
downloads, and (where supported) verifies the binary checksum; the openjdk WASM
plugin loads and lists Adoptium versions.

Docs: [`proto/README.md`](proto/README.md) · longer notes: [`docs/ideas/proto-plugins.md`](docs/ideas/proto-plugins.md).
