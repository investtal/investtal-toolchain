# investtal-toolchain — proto plugins

Vendored, Investtal-owned [proto](https://moonrepo.dev/proto) toolchain plugins.

This is the **single canonical source** for every Investtal proto plugin. It is a
**public** repo so private consumers (`investtal-portals`, `devops-investtal`,
`investtal-apis`, …) can pin plugins over plain `https://` instead of resolving
them from uncontrolled third-party repos.

## Why this exists

Our `.prototools` files previously resolved every non-builtin tool from an
**uncontrolled third-party GitHub repo** (`ageha734`, `Phault`, `appthrust`,
`jamesukiyo`, `eplightning`). proto loads a plugin's definition at install time,
so whoever controls those repos controls what URL our CI/dev machines download a
binary from. They can be force-pushed, deleted, transferred, or poisoned — and
**proto has no checksum/lockfile for the plugin file itself**. That is a live
supply-chain risk on a security-tooling install path.

This repo forks each plugin into infrastructure we own and have audited so the
toolchain only ever resolves plugins we control. Vendoring + commit-SHA pinning
**is** the integrity control for the plugin definition; the per-tool
`checksum-url` (below) then verifies the downloaded binary.

## Inventory

All plugins live under `proto/`. Per-tool shape, checksum status, and upstream
provenance are tracked in [`INVENTORY.md`](INVENTORY.md); full integrity findings
and per-tool notes are in [`docs/proto-plugins.md`](docs/proto-plugins.md).

| Tool | File | Kind | Binary checksum | Upstream forked from |
|------|------|------|-----------------|----------------------|
| gitleaks | `proto/gitleaks/plugin.toml` | TOML | ✅ `checksums.txt` | `Phault/proto-toml-plugins` |
| migrate | `proto/migrate/plugin.toml` | TOML | ✅ `sha256sum.txt` | `jamesukiyo/proto-plugins` |
| trivy | `proto/trivy/plugin.toml` | TOML | ✅ `checksums.txt` | `ageha734/proto-plugins` |
| gh | `proto/gh/plugin.toml` | TOML | ✅ hardened (added `checksum-url`) | `appthrust/proto-toml-plugins` |
| gradle | `proto/gradle/plugin.toml` | TOML | ✅ `.sha256` | `eplightning/openjdk-adoptium-proto-plugin` |
| yq | `proto/yq/plugin.toml` | TOML | ❌ upstream ships no parseable checksum | `appthrust/proto-toml-plugins` |
| openjdk | `proto/openjdk/openjdk_adoptium_tool.wasm` (+ `.sha256`) | WASM | vendored binary, hash pinned | `eplightning/openjdk-adoptium-proto-plugin` |
| semgrep | `proto/semgrep/requirements.txt` | PyPI | ✅ `--require-hashes` | n/a (not a proto plugin) |
| shfmt | `proto/shfmt/plugin.toml` | TOML | ❌ single-file binary, no checksum file | `ageha734/proto-plugins` |
| shellcheck | `proto/shellcheck/plugin.toml` | TOML | ❌ no aggregate checksum file | `ageha734/proto-plugins` |
| kubectl | `proto/kubectl/plugin.toml` | TOML | ❌ per-binary `.sha256` unwirable in TOML | `ageha734/proto-plugins` |
| vault | `proto/vault/plugin.toml` | TOML | ✅ `SHA256SUMS` | hand-authored from `releases.hashicorp.com` |
| netbird | `proto/netbird/plugin.toml` | TOML | n/a vendored CLI plugin definition | `netbirdio/netbird` |

## Consuming the plugins

proto locators ([docs](https://moonrepo.dev/docs/proto/non-wasm-plugin)) — always
commit-SHA-pinned raw URLs against this public repo (immutable; a branch ref
would let anyone with push access silently change the download):

```toml
[plugins.tools]
gitleaks = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/proto/gitleaks/plugin.toml"
openjdk  = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/proto/openjdk/openjdk_adoptium_tool.wasm"
```

> Never reference the original third-party repos again. Never use an unpinned
> `github://` or branch URL for these — that re-introduces the risk this repo
> removes.

## Updating a plugin

1. Diff the upstream plugin against ours; copy only intended changes.
2. Confirm release asset + checksum filenames still match (GitHub API
   `/releases/latest`).
3. `proto install <tool>` in a scratch dir against a `file://` locator;
   confirm the install log shows `Verifying checksum against …`.
4. For openjdk: re-download the `.wasm`, recompute `.sha256`, confirm it equals
   GitHub's server-side asset digest.
5. For semgrep: bump version, re-resolve hashes from PyPI.
6. Commit, then bump the pinned commit SHA in every consumer `.prototools`.

## 9cc — Claude Code model switcher

Launch Claude Code with a dynamic model over the 9Router gateway. Reads auth from
`~/.claude/settings.json` (read-only — never mutates it).

**Install (mac/linux/wsl):**
```sh
gh api repos/investtal/investtal-toolchain/contents/scripts/install.sh --jq '.content' | base64 -d | bash
```
**Install (windows, PowerShell):**
```powershell
gh api repos/investtal/investtal-toolchain/contents/scripts/install.ps1 --jq '.content' | base64 -d | powershell -c -  
```
Pin a specific version or commit SHA via `CC9_VERSION` or by adding `?ref=<tag>` to the API path:
```sh
gh api "repos/investtal/investtal-toolchain/contents/scripts/install.sh?ref=v0.3.5" --jq '.content' | base64 -d | bash
gh api repos/investtal/investtal-toolchain/contents/scripts/install.sh --jq '.content' | base64 -d | CC9_VERSION=v0.3.5 bash
gh api repos/investtal/investtal-toolchain/contents/scripts/install.sh --jq '.content' | base64 -d | CC9_VERSION=<full-commit-sha> bash
```
Check installed version: `9cc version`.

**Update:**
```sh
9cc update  # update to the latest release
```

**Use:**
```sh
9cc list                 # list models
9cc list --json          # machine-readable registry (alias -> full id); consumed by fleet routing
9cc update               # update 9cc to the latest release
9cc uninstall            # remove 9cc (home directory and PATH copy/symlink)
9cc run fable            # launch with cc/claude-fable-5
9cc run glm/glm-5.2      # full 9Router ID also works
9cc run minimax --resume # extra args forwarded to claude
9cc next minimax         # print cascade successor for a model (fleet healer advances on rate-limit)
9cc next minimax --no-free # successor excluding the free pool
9cc version              # print version
```
In a live session, switch without restart: `/model <id>` (e.g. `/model glm/glm-5.2`).

Full design: [`docs/ideas/0002-ManageClaudeCodeCLI.spec.md`](docs/ideas/0002-ManageClaudeCodeCLI.spec.md).
Implementation plan: [`docs/plans/2026-07-08-9cc-model-switcher.md`](docs/plans/2026-07-08-9cc-model-switcher.md).
Overnight auto-pilot is deferred to a follow-up.
