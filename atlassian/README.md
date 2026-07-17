# atlassian — Atlassian Cloud CLI

Lightweight **Zig 0.16** CLI for day-to-day Atlassian Cloud work: Jira, Confluence, platform Goals/Teams, config, and auth.

## Why

- One binary instead of ad-hoc `curl` / Postman collections for common ops
- Same auth + retry + error contract for humans (`--help`) and scripts (`--json`)
- Installable via Investtal **proto** after release tags `atlassian-v*`

## Features

| Area | Capability |
|------|------------|
| **Jira** | issues, projects, boards, sprints |
| **Platform** | Goals (GraphQL), Teams (Public REST) |
| **Confluence** | pages, spaces (comments catalog stub) |
| **Auth** | Basic (email + API token), OAuth 2.0 3LO interactive login |
| **Config** | file + env; precedence `flags > env > file > defaults` |
| **HTTP** | retries (default 3), structured `ApiError` exit codes |

Command shape: `atlassian <product> <resource> <verb> …`

## Build

```bash
cd atlassian
zig build
./zig-out/bin/atlassian --help
zig build test
./scripts/smoke.sh ./zig-out/bin/atlassian
```

Requires [Zig 0.16](https://ziglang.org/).

## Config

```bash
atlassian config set atlassianUrl https://acme.atlassian.net
atlassian config set atlassianUsername you@acme.com
export ATLASSIAN_API_TOKEN=...   # prefer env for secrets
```

| Env | Config key |
|-----|------------|
| `ATLASSIAN_URL` | `atlassianUrl` |
| `ATLASSIAN_USERNAME` | `atlassianUsername` |
| `ATLASSIAN_API_TOKEN` | `atlassianApiToken` |
| `ATLASSIAN_CLOUD` | `atlassianCloud` |
| `ATLASSIAN_ORG_ID` | `orgId` |
| `ATLASSIAN_CLOUD_ID` | `cloudId` |
| `ATLASSIAN_AUTH` | `auth` (`basic` \| `oauth`) |
| `ATLASSIAN_OAUTH_CLIENT_ID` | `oauth.clientId` |
| `ATLASSIAN_OAUTH_CLIENT_SECRET` | `oauth.clientSecret` |
| `ATLASSIAN_HTTP_RETRIES` | `http.retries` |
| `ATLASSIAN_CONFIG` | path override |

Default file: `~/.config/atlassian/config.toml` (secrets prefer mode `0600` when written).

## OAuth

1. Create an OAuth 2.0 (3LO) app in the [Atlassian developer console](https://developer.atlassian.com/console/myapps/).
2. Callback: `http://127.0.0.1:8787/callback`
3. Set client id/secret (config or env)
4. `atlassian auth login`

## Examples

```bash
atlassian jira issue get PROJ-1
atlassian jira issue search --jql 'project = PROJ' --max 20
atlassian confluence page get 123456
atlassian platform team get TEAM_ID    # requires orgId
atlassian api request GET issue/PROJ-1 --product jira
atlassian --json jira issue get PROJ-1
```

## Install via proto

After a GitHub Release for tag `atlassian-vX.Y.Z` (checksums uploaded):

```toml
[plugins.tools]
atlassian = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/proto/atlassian/plugin.toml"
```

Plugin definition: [`../proto/atlassian/plugin.toml`](../proto/atlassian/plugin.toml).  
Release workflow: [`.github/workflows/atlassian-release.yml`](../.github/workflows/atlassian-release.yml) (Actions pinned by commit SHA).

## Design

- Spec: [`../docs/specs/2026-07-17-atlassian-cli-design.md`](../docs/specs/2026-07-17-atlassian-cli-design.md)
- Plan: [`../docs/plans/2026-07-17-atlassian-cli.md`](../docs/plans/2026-07-17-atlassian-cli.md)
