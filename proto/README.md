# proto — Investtal-owned toolchain plugins

Vendored [proto](https://moonrepo.dev/proto) (and related) install definitions for tools Investtal runs in CI and on laptops.

## Why

`.prototools` used to resolve plugins from **uncontrolled third-party GitHub repos**. Whoever owns those repos owns the URL every agent downloads a binary from. Plugins can be force-pushed or transferred; proto does **not** lock the plugin file itself.

This directory is the **single canonical, audited** source. Consumers pin **raw HTTPS URLs + commit SHA**. Binary integrity (where possible) uses each plugin’s `checksum-url`.

## Inventory

Full audit table (checksum status, dates): [`../INVENTORY.md`](../INVENTORY.md)  
Integrity findings and per-tool notes: [`../docs/ideas/proto-plugins.md`](../docs/ideas/proto-plugins.md)

| Tool | Path | Kind |
|------|------|------|
| gitleaks | `gitleaks/plugin.toml` | TOML CLI |
| migrate | `migrate/plugin.toml` | TOML CLI |
| trivy | `trivy/plugin.toml` | TOML CLI |
| gh | `gh/plugin.toml` | TOML CLI |
| gradle | `gradle/plugin.toml` | TOML CLI |
| yq | `yq/plugin.toml` | TOML CLI |
| openjdk | `openjdk/*.wasm` | WASM plugin |
| semgrep | `semgrep/requirements.txt` | PyPI hashes (not a proto CLI plugin) |
| shfmt | `shfmt/plugin.toml` | TOML CLI |
| shellcheck | `shellcheck/plugin.toml` | TOML CLI |
| kubectl | `kubectl/plugin.toml` | TOML CLI |
| vault | `vault/plugin.toml` | TOML CLI |
| netbird | `netbird/plugin.toml` | TOML CLI |
| atlassian | `atlassian/plugin.toml` | TOML CLI (Investtal-built) |

## Consume (pin by commit)

```toml
[plugins.tools]
gitleaks  = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/proto/gitleaks/plugin.toml"
openjdk   = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/proto/openjdk/openjdk_adoptium_tool.wasm"
atlassian = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/proto/atlassian/plugin.toml"
```

Do **not** use unpinned `github://` or branch refs for these plugins.

## Update a plugin

1. Diff upstream (if any); take only intended changes.
2. Confirm release asset + checksum filenames still match.
3. `proto install <tool>` against a `file://` locator; confirm checksum verification in logs.
4. For openjdk: re-verify `.wasm` hash against GitHub asset digest.
5. For semgrep: bump version and re-resolve pip hashes.
6. Commit, then bump the pinned SHA in every consumer `.prototools`.

## atlassian binary

The `atlassian` plugin installs Investtal’s Zig CLI from this repo’s GitHub Releases (`atlassian-v*` tags). Build and CLI docs: [`../atlassian/README.md`](../atlassian/README.md).
