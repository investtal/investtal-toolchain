# atlassian — Investtal Atlassian CLI

Lightweight Zig 0.16 CLI for Atlassian Cloud:

- **Jira** issues, projects, boards, sprints
- **Platform** Goals (GraphQL) and Teams (Public REST)
- **Confluence** pages, spaces (comments catalog stub)
- **Auth** Basic (email + API token) and OAuth 2.0 3LO interactive login
- **Config** file + env with `flags > env > file > defaults`
- **HTTP** retries (default 3) and structured `ApiError`

## Build

```bash
cd atlassian
zig build
./zig-out/bin/atlassian --help
zig build test   # offline unit tests
```

## Config

```bash
atlassian config set atlassianUrl https://acme.atlassian.net
atlassian config set atlassianUsername you@acme.com
# prefer env for secrets:
export ATLASSIAN_API_TOKEN=...
```

Env keys: `ATLASSIAN_URL`, `ATLASSIAN_USERNAME`, `ATLASSIAN_API_TOKEN`, `ATLASSIAN_CLOUD`,
`ATLASSIAN_ORG_ID`, `ATLASSIAN_CLOUD_ID`, `ATLASSIAN_AUTH`, `ATLASSIAN_OAUTH_CLIENT_ID`,
`ATLASSIAN_OAUTH_CLIENT_SECRET`, `ATLASSIAN_HTTP_RETRIES`, `ATLASSIAN_CONFIG`.

Config file (TOML-ish): `~/.config/atlassian/config.toml`.

## OAuth

1. Create an OAuth 2.0 (3LO) app in the [Atlassian developer console](https://developer.atlassian.com/console/myapps/).
2. Callback URL: `http://127.0.0.1:8787/callback`
3. Set `oauth.clientId` / `oauth.clientSecret` (or env).
4. `atlassian auth login`

## Examples

```bash
atlassian jira issue get PROJ-1
atlassian jira issue search --jql 'project = PROJ' --max 20
atlassian confluence page get 123456
atlassian platform team get TEAM_ID   # requires orgId
atlassian api request GET issue/PROJ-1 --product jira
atlassian --json jira issue get PROJ-1
```

## Install via proto

After a release tag `atlassian-vX.Y.Z`:

```toml
[plugins.tools]
atlassian = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/proto/atlassian/plugin.toml"
```

## Design / plan

- Spec: `docs/specs/2026-07-17-atlassian-cli-design.md`
- Plan: `docs/plans/2026-07-17-atlassian-cli.md`
