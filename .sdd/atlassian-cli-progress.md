# Progress — Atlassian CLI (Zig)

Plan: `docs/plans/2026-07-17-atlassian-cli.md`
Branch: `IVT-1707-atlassian-cli`
Spec: `docs/specs/2026-07-17-atlassian-cli-design.md`
Base: `21d338a3c038c71ba8d40496548178ce8e15c2ab`

## Global Constraints
- Zig 0.16.0; binary `atlassian`
- CLI: `atlassian <product> <resource> <verb>`
- Human default; `--json` opt-in; errors JSON on stderr
- Config: flags > env > file > defaults
- HTTP retries default 3
- Exit: 0 ok, 1 generic, 2 usage, 3 auth, 4 not_found, 5 rate_limit, 6 not_implemented, 7 network
- Goals = GraphQL platform; Teams = Public REST v1
- Basic + OAuth 3LO; no secret logging
- Release tags atlassian-v*; default tests offline
- Scope: atlassian/, proto/atlassian/, release workflow, inventory docs

## Ledger
