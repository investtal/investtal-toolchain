# investtal-toolchain

**Investtal-owned developer tools, supply-chain pins, and shared automation.**

This public monorepo is where we put the software engineers at Investtal actually run every day — CLIs we build, proto plugins we audit and vendor, git hooks that keep task IDs honest, and the CI that gates them. Private product repos (`investtal-portals`, `investtal-apis`, `devops-investtal`, …) **pin into this repo**; they do not pull toolchain definitions from random third-party GitHub accounts.

## Why this exists

| Problem | What we do here |
|---------|-----------------|
| Toolchain plugins installed from **uncontrolled third-party** proto repos (force-push / takeovers = poisoned binaries) | Vendor and audit plugins under [`proto/`](proto/) and pin by **commit SHA** |
| Agent + model routing needs a **fast, scriptable** launcher for Claude Code over our gateway | Ship [`9cc/`](9cc/) — model switcher + optional Docker sandbox |
| Atlassian Cloud ops should be a **single binary**, not a pile of one-off curl scripts | Ship [`atlassian/`](atlassian/) — Zig CLI for Jira / Confluence / Goals / Teams |
| Branches and commits without **IVT-XXXX** task IDs break tracking | Share [`git-hooks/`](git-hooks/) for every Landtal repo |
| Toolchain changes need a real gate | [`jenkins/`](jenkins/) pipelines for the tools that need CI |

**Rule of thumb:** if it installs on a laptop or CI agent and it is not product source code, it belongs here — owned, versioned, and documented.

## Tools at a glance

| Tool | What it is | Why we maintain it | Details |
|------|------------|--------------------|---------|
| **proto plugins** | Audited [proto](https://moonrepo.dev/proto) install definitions for gh, gitleaks, trivy, kubectl, openjdk, … | Single integrity surface; consumers pin raw URLs + commit SHA | [`proto/README.md`](proto/README.md) · [`INVENTORY.md`](INVENTORY.md) |
| **atlassian** | Zig CLI for Atlassian Cloud (Jira, Confluence, Goals, Teams) | One binary for day-to-day ops + scripts; OAuth/Basic; release + proto install | [`atlassian/README.md`](atlassian/README.md) |
| **9cc** | Claude Code model switcher over 9Router (+ Docker sandbox) | Agents and humans pick models without hand-editing Claude settings | [`9cc/README.md`](9cc/README.md) |
| **git-hooks** | Native hooks: IVT branch policy + commit subject task-id suffix | Same branch/commit contract across the monorepo family | [`git-hooks/README.md`](git-hooks/README.md) |
| **jenkins** | Jenkinsfiles for toolchain CI (e.g. 9cc tests/smoke) | Prove install/update paths before we trust them in production | [`jenkins/README.md`](jenkins/README.md) |

Deep design notes and implementation plans live under [`docs/`](docs/) (ideas, specs, plans). **How to install and use a tool is always in that tool’s `README.md`.**

## Layout

```text
investtal-toolchain/
├── proto/           # Vendored proto plugin definitions (per-tool dirs)
├── atlassian/       # Atlassian Cloud CLI (Zig)
├── 9cc/             # Claude Code model switcher + sandbox
├── git-hooks/       # Shared Landtal git hooks
├── jenkins/         # Toolchain CI
├── docs/            # Specs, plans, longer write-ups
├── INVENTORY.md     # Proto plugin audit table
└── README.md        # This hub
```

## How consumers pin us

**Proto plugins** — always commit-SHA-pinned (never a floating branch):

```toml
[plugins.tools]
gitleaks  = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/proto/gitleaks/plugin.toml"
atlassian = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/proto/atlassian/plugin.toml"
```

**9cc / atlassian / hooks** — follow the install section in each tool README.

Never re-point consumers at the original third-party proto plugin repos. That undoes the reason this repository exists.

## Contributing

1. Work on an `IVT-XXXX-…` branch (enforced by git-hooks).
2. Put tool-specific docs in that tool’s `README.md`, not only in the root.
3. For proto plugin changes: update inventory, verify checksum install, then bump SHAs in every consumer `.prototools`.
4. For CLIs: keep offline tests green; release artifacts go through GitHub Releases with checksums where applicable.

## License / ownership

Owned by **Investtal**. Public so private repos can pin over plain HTTPS without cloning private toolchain definitions.
