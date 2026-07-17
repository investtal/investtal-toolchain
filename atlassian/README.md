# atlassian — Atlassian Cloud CLI

Lightweight **Zig 0.16** CLI for day-to-day Atlassian Cloud work: Jira, Confluence, platform Goals/Teams, config, and auth.

## Why

- One binary instead of ad-hoc `curl` / Postman collections for common ops
- Same auth + retry + error contract for humans (TOON/Markdown) and scripts (`--json`)
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
| **Output** | **TOON** default ([spec](https://github.com/toon-format/toon)); `--markdown` / `--json` opt-in |

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

## Output formats

API success bodies support three modes (last flag wins):

| Flag | Mode | Use for |
|------|------|---------|
| _(default)_ / `--toon` | [TOON](https://github.com/toon-format/toon) | Humans + AI (compact, structured) |
| `--markdown` / `--md` | Markdown | Aligned tables / cards |
| `--json` | JSON | Scripts |

For **Jira issue get / search**, all three modes use the same **main-field** curation
(status, assignee, sprint, description, … — not the full REST expand blob).  
Need the full raw issue? Use `atlassian --json api request GET 'issue/KEY' --product jira`.

```bash
atlassian jira issue get PROJ-1                 # TOON, main fields
atlassian --markdown jira issue get PROJ-1      # aligned Markdown table
atlassian --json jira issue get PROJ-1          # compact JSON, main fields
atlassian --format=markdown jira issue search --jql 'project = PROJ'
```

Errors: human text on stderr by default; JSON `ApiError` on stderr when `--json`.

## Examples

```bash
atlassian jira issue get PROJ-1
atlassian jira issue search --jql 'project = PROJ' --max 20
atlassian jira issue search --assignee me --jql 'project = PROJ'

# Board backlog + assignee filter
# Preferred (needs Jira Software OAuth scopes):
atlassian --markdown jira board backlog --board 1 --assignee me
# Works with platform scopes only (no Agile):
atlassian --markdown jira board backlog --project IVT --assignee me
atlassian --markdown jira board backlog --board 1 --project IVT --assignee me  # Agile, auto JQL fallback on 401

# Active sprint
atlassian --markdown jira sprint current --assignee me
atlassian --markdown jira sprint current --board 1 --assignee me
atlassian --markdown jira sprint issues 7 --assignee unassigned

atlassian confluence page get 123456
atlassian platform team get TEAM_ID    # requires orgId
atlassian api request GET issue/PROJ-1 --product jira
atlassian --json jira issue get PROJ-1
```

### Assignee filter (`--assignee`)

Works on `issue search`, `board backlog`, `sprint issues`, `sprint current`:

| Value | JQL |
|-------|-----|
| `me` | `assignee = currentUser()` |
| `unassigned` / `none` | `assignee is EMPTY` |
| email / display name / accountId | `assignee = "…"` |

Combine with extra JQL: `--assignee me --jql 'priority = High'`.

### OAuth: why `board backlog --board` can 401 while `issue search` works

| Command | API | Scopes |
|---------|-----|--------|
| `issue search` / `issue get` | Platform `/rest/api/3` | classic `read:jira-work` |
| `board backlog --board` / `board list` | Agile `/rest/agile/1.0` | granular `read:board-scope:jira-software` + `read:issue-details:jira` |

**Selecting all permissions under classic “Jira API” is not enough.**  
In the [Developer Console](https://developer.atlassian.com/console/myapps/) you must also add **Jira Software API** permissions.

Then:

```bash
# Revoke old grant (otherwise consent may not re-prompt fully)
# https://id.atlassian.com/manage-profile/apps
atlassian auth login
atlassian auth status   # agile_board_scope=ok
```

`auth refresh` never adds new scopes. If login still omits Software scopes, the app does not have them enabled.

**Works without Agile scopes:**

```bash
atlassian --markdown jira board backlog --project IVT --assignee me
atlassian --markdown jira sprint current --assignee me
atlassian --markdown jira issue search --assignee me --jql 'project = IVT'
```

### OAuth: why `confluence space list` can 401 with “scope does not match”

Confluence REST **v2** (what this CLI uses) needs **granular** scopes. Classic content scopes alone fail:

| Command | API | Scopes |
|---------|-----|--------|
| `confluence space list` / `get` | `/wiki/api/v2/spaces` | `read:space:confluence` |
| `confluence page list` / `get` | `/wiki/api/v2/pages` | `read:page:confluence` |
| `confluence page create` / `update` | POST/PUT pages | `write:page:confluence` |
| `confluence page delete` | DELETE pages | `delete:page:confluence` |

Classic `read:confluence-content.all` / `write:confluence-content` are requested too, but **do not replace** the granular space/page scopes for v2.

**Selecting all classic Confluence scopes is not enough** if granular space/page scopes are missing from either:

1. the OAuth app permissions, or  
2. the scopes string the CLI requests at `auth login` (see `DEFAULT_SCOPES` in `src/auth/oauth.zig`)

```bash
# 1) Enable granular Confluence scopes on the OAuth app
# 2) Revoke old grant — no full reinstall of the CLI required
#    https://id.atlassian.com/manage-profile/apps
atlassian auth login
atlassian auth status   # confluence_scope=ok
atlassian confluence space list
```

`auth refresh` never adds new scopes. Rebuild/update the binary if your installed CLI predates the Confluence granular scope list, then re-login.

## Install via proto

After a GitHub Release for tag `atlassian-vX.Y.Z` (checksums uploaded):

```toml
[plugins.tools]
atlassian = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/proto/atlassian/plugin.toml"
```

Plugin definition: [`../proto/atlassian/plugin.toml`](../proto/atlassian/plugin.toml).

## Release

Releases are **Jenkins-only** (`../jenkins/Jenkinsfile`). On merge to `main`, when `atlassian/` changes, CI bumps the version, tags **`atlassian-vX.Y.Z`**, packages multi-arch binaries via [`../scripts/release/package-atlassian.sh`](../scripts/release/package-atlassian.sh), and uploads assets + checksums to a GitHub Release (distribution host only). Manual tags are not required.

## Design

- Spec: [`../docs/specs/2026-07-17-atlassian-cli-design.md`](../docs/specs/2026-07-17-atlassian-cli-design.md)
- Plan: [`../docs/plans/2026-07-17-atlassian-cli.md`](../docs/plans/2026-07-17-atlassian-cli.md)
