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

| Tool | Shape | Vendored as | Binary checksum verified? | Upstream forked from |
|------|-------|-------------|---------------------------|----------------------|
| gitleaks | TOML | `gitleaks/plugin.toml` | ✅ yes (`checksums.txt`) | `Phault/proto-toml-plugins` |
| migrate | TOML | `migrate/plugin.toml` | ✅ yes (`sha256sum.txt`) | `jamesukiyo/proto-plugins` |
| trivy | TOML | `trivy/plugin.toml` | ✅ yes (`checksums.txt`) | `ageha734/proto-plugins` |
| gh | TOML | `gh/plugin.toml` | ✅ **hardened** — added missing `checksum-url` | `appthrust/proto-toml-plugins` |
| gradle | TOML | `gradle/plugin.toml` | ✅ yes (`.sha256`) | `eplightning/openjdk-adoptium-proto-plugin` |
| yq | TOML | `yq/plugin.toml` | ❌ not possible — see note | `appthrust/proto-toml-plugins` |
| openjdk | **WASM** | `openjdk/openjdk_adoptium_tool.wasm` (+ `.sha256`) | n/a (binary vendored) | `eplightning/openjdk-adoptium-proto-plugin` |
| semgrep | **PyPI only** | `semgrep/requirements.txt` (hash-pinned) | ✅ pip `--require-hashes` | n/a (not a proto plugin) |
| shfmt | TOML | `shfmt/plugin.toml` | ❌ no checksum file (single-file binary) | `ageha734/proto-plugins` |
| shellcheck | TOML | `shellcheck/plugin.toml` | ❌ no aggregate checksum file | `ageha734/proto-plugins` |
| kubectl | TOML | `kubectl/plugin.toml` | ❌ per-binary `.sha256` exists but proto TOML cannot wire it | `ageha734/proto-plugins` |
| vault | TOML | `vault/plugin.toml` | ✅ yes (`SHA256SUMS`) | hand-authored from `releases.hashicorp.com` |

## Per-tool notes

### gh — hardened
The upstream `appthrust` plugin declared `checksum-file` but had **no
`checksum-url`**, so the downloaded binary was never verified. The gh release
ships a standard `<sha256>  <file>` `checksums.txt`; we added `checksum-url` so
integrity is now enforced. Verified working: install logs
`Verifying checksum against gh_<ver>_checksums.txt`.

### yq — no checksum possible
`mikefarah/yq` does **not** publish a standard checksums file. Its `checksums`
artifact is a non-standard multi-column, multi-algorithm table that proto's
parser cannot consume, so the plugin has no `checksum-url`. Integrity rests on
HTTPS transport, the pinned version, and this plugin being vendored. Revisit if
yq ever ships a parseable checksum file.

### openjdk — WASM plugin, vendored as a binary
This is a Rust→WASM plugin (not TOML); its Adoptium-API resolution logic can't
be expressed as a TOML plugin, so we vendor the compiled `.wasm` (release
`v0.2.0`).

**Integrity finding:** upstream's companion `openjdk_adoptium_tool.wasm.sha256`
states `4a1d7f99…`, which does **not** match the published artifact. GitHub's
server-side asset digest and a local recompute both confirm the real hash is:

```
4d16394d0205581112e79a302e57b6fffb7c762190f9d2c725d4d9a31b4a5120  openjdk_adoptium_tool.wasm
```

We record + trust **our** verified hash in `openjdk/openjdk_adoptium_tool.wasm.sha256`.
Re-verify any time:

```bash
cd openjdk && shasum -a 256 -c openjdk_adoptium_tool.wasm.sha256
```

### semgrep — not a proto plugin
semgrep ships no standalone GitHub-release binary (PyPI wheels/sdist only, needs
Python). It cannot be a proto CLI plugin. The controllable equivalent is the
hash-pinned `semgrep/requirements.txt`, installed with:

```bash
pip install --require-hashes -r semgrep/requirements.txt
```

`scripts/security-gate.sh` in each consumer invokes semgrep; install it this way
in `make bootstrap` so the SAST scanner is pinned like the rest.

### shfmt / shellcheck / kubectl — no wired checksum
- **shfmt** ships single-file release binaries (no archive, no checksum file), so
  there is no `checksum-url` to wire.
- **shellcheck** ships no aggregate checksum file for its release archives.
- **kubectl** publishes a per-binary `.sha256` at
  `https://dl.k8s.io/release/v{version}/bin/{platform}/{arch}/kubectl.sha256`,
  but proto TOML plugins cannot consume a per-binary checksum URL. Integrity
  rests on HTTPS transport, the pinned version, and this plugin being vendored.

### vault — checksum verified
HashiCorp ships a standard `<sha256>  <file>` `vault_{version}_SHA256SUMS`; the
plugin wires `checksum-url` so the downloaded archive is verified.

## Consuming the plugins

proto locators ([docs](https://moonrepo.dev/docs/proto/non-wasm-plugin)) — always
commit-SHA-pinned raw URLs against this public repo (immutable; a branch ref
would let anyone with push access silently change the download):

```toml
[plugins.tools]
gitleaks = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/gitleaks/plugin.toml"
openjdk  = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/openjdk/openjdk_adoptium_tool.wasm"
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
