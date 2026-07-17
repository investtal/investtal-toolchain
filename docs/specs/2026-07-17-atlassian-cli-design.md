# Atlassian CLI (Zig) — Design Spec

**Date:** 2026-07-17  
**Status:** Approved (architecture + scope)  
**Package:** `atlassian/` in `investtal/investtal-toolchain`  
**Zig:** 0.16.0 (existing scaffold)

---

## 1. Purpose

Ship a lightweight, single-binary Zig CLI (`atlassian`) for Atlassian Cloud operations:

- **Jira:** issues, projects, boards/sprints
- **Platform:** Goals (GraphQL), Teams (Public REST)
- **Confluence:** pages, spaces, comments
- **Auth/config:** file + env, Basic (API token) and OAuth 2.0 3LO interactive login
- **Distribution:** GitHub Releases + checksums + Investtal-owned `proto/atlassian` plugin

**Non-goals for architecture:** runtime product plugins, full OpenAPI codegen of every Atlassian endpoint.

---

## 2. Resolved requirements

| Item | Decision |
|------|----------|
| Approach | **A — Layered single binary** (cli → services → http/graphql → auth/config) |
| v0.1 surface | **Full command catalog skeleton**; real implementations for auth, config, issue CRUD/search, page CRUD, goals, teams, and `api request` |
| Deployment | **Cloud first**; `Site` / transport interfaces **Server/DC-ready** without changing command signatures |
| CLI shape | `atlassian <product> <resource> <verb>` |
| Output | **TOON default** (human + AI); `--markdown` / `--json` opt-in |
| Auth | **Basic + OAuth 3LO** (not deferred) |
| Goals | **Atlassian Goals GraphQL** (not Advanced Roadmaps) |
| Teams | **Teams Public REST v1** (not Tempo / undocumented internals) |
| HTTP | Retry **default 3** attempts; unified `ApiError` |
| Release | GitHub Releases + checksums + `proto/atlassian/plugin.toml` |

---

## 3. Architecture

### 3.1 Layer diagram

```text
┌─────────────────────────────────────────────────────────────┐
│  CLI (main)                                                  │
│  argv → router → global flags (--json, --config, -v)         │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  Commands (thin)                                             │
│  parse flags → call service → render (toon | markdown | json)│
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  Services (domain)                                           │
│  jira/* · platform/{goal,team} · confluence/* · api/raw      │
│  no argv / no stdout                                         │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  Transport                                                   │
│  HttpClient (retry) · GraphQL client · ApiError mapping      │
│  AuthProvider (basic | oauth+refresh) · Site URL builder     │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  Config + credential store                                   │
│  flags > env > config file > defaults                        │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Dependency rules (non-breaking growth)

| Layer | May depend on | Must not |
|-------|---------------|----------|
| `cli` / commands | services, config, render | raw HTTP URLs, product path hardcoding beyond flags |
| services | http/graphql client, domain types | argv, stdout, file paths for config |
| http / graphql | auth, config values, std | product business rules |
| auth | config, http (token refresh) | command routing |
| config | fs, env | network |

Adding a resource = new service file + command registration. No change to transport contracts.

### 3.3 Site / transport (Cloud-first, Server/DC-ready)

```text
Site {
  kind: cloud | server_dc
  base_url: []const u8          // https://acme.atlassian.net
  cloud_id: ?[]const u8         // OAuth accessible-resources id
  org_id: ?[]const u8           // Teams Public API
  auth: AuthProvider
}

resolve(product, path) → absolute URL
  cloud + basic:
    jira        → {base_url}/rest/api/3/{path}
    jira_soft   → {base_url}/rest/agile/1.0/{path}
    confluence  → {base_url}/wiki/api/v2/{path}
    gateway     → {base_url}/gateway/api/{path}
    graphql     → {base_url}/gateway/api/graphql
  cloud + oauth:
    jira        → https://api.atlassian.com/ex/jira/{cloud_id}/rest/api/3/{path}
    confluence  → https://api.atlassian.com/ex/confluence/{cloud_id}/wiki/api/v2/{path}
    gateway/graphql → documented OAuth-compatible host (same abstraction; verify at implement)
  server_dc: (future) path map only; command layer unchanged
```

`ATLASSIAN_CLOUD=true` (default) selects Cloud path prefixes.

---

## 4. Package layout

```text
atlassian/
  build.zig
  build.zig.zon
  src/
    main.zig                 # process entry, wire deps
    root.zig                 # library root re-exports
    cli/
      root.zig               # product → resource → verb router
      flags.zig
      render.zig             # human | json
      exit_codes.zig
    config/
      root.zig
      env.zig
      file.zig               # TOML config
    auth/
      root.zig               # AuthProvider interface
      basic.zig
      oauth.zig              # authorize, token, refresh
      store.zig              # credentials file mode 0600
      login.zig              # browser + loopback callback
    http/
      client.zig             # request + retry
      error.zig              # ApiError
      transport.zig          # Site URL builder
    graphql/
      client.zig             # POST GraphQL (Goals)
    jira/
      issue.zig
      project.zig
      board.zig
      sprint.zig
    platform/
      goal.zig               # Goals GraphQL
      team.zig               # Teams Public REST
    confluence/
      page.zig
      space.zig
      comment.zig
    api/
      raw.zig                # escape hatch
  # Release packaging: scripts/release/ + jenkins/Jenkinsfile (tags atlassian-v*)
proto/
  atlassian/
    plugin.toml
```

---

## 5. CLI surface

### 5.1 Global flags

| Flag | Meaning |
|------|---------|
| `--json` | Machine-readable success on stdout; errors as JSON on stderr |
| `--config PATH` | Config file override |
| `-v` / `--verbose` | Log request method/URL (never secrets) |

### 5.2 Command tree

```text
atlassian
  auth
    login [--scopes ...]
    logout
    status
    refresh
  config
    get [KEY]
    set KEY VALUE
    list
    path
  jira
    issue   get|create|update|delete|search|list
    project get|create|update|delete|list
    board   get|list|backlog
    sprint  get|list|create|start|complete
  platform
    goal    get|list|create|update|delete|watch|link-team
    team    get|list|create|update|delete|members|add-member|remove-member
  confluence
    page    get|create|update|delete|list
    space   get|create|update|delete|list
    comment get|create|update|delete|list
  api
    request METHOD PATH [--body FILE|-] [--product jira|confluence|gateway|graphql]
```

**Why `platform`:** Goals and Teams are org/platform APIs (GraphQL + Teams gateway REST), not Jira REST v3. Optional later: aliases `atlassian jira goal …` → same services.

### 5.3 v0.1 implementation depth

| Area | Depth |
|------|--------|
| `auth *` | **Real** — Basic via config; OAuth login/logout/status/refresh |
| `config *` | **Real** |
| `jira issue *` | **Real** — get/create/update/delete/search |
| `jira project` | **Real** list/get; create/update/delete → catalog stub (`not_implemented`) until filled |
| `jira board` / `sprint` | **Real** list/get; remaining verbs → catalog stub (`not_implemented`) |
| `platform goal *` | **Real** — GraphQL list/get/update (+ create/delete where mutations are stable) |
| `platform team *` | **Real** — Teams Public REST CRUD + members (requires `orgId`) |
| `confluence page *` | **Real** |
| `confluence space` / `comment` | Catalog wired; list/get preferred real, else stub |
| `api request` | **Real** |

Stubs: print help + exit code `6` (`not_implemented`), never silent no-op.

---

## 6. Config

### 6.1 Precedence

`CLI flags > environment > config file > defaults`

### 6.2 Keys

| Concept | Env | Config field |
|---------|-----|--------------|
| Site URL | `ATLASSIAN_URL` | `atlassianUrl` |
| Username (email) | `ATLASSIAN_USERNAME` | `atlassianUsername` |
| API token | `ATLASSIAN_API_TOKEN` | `atlassianApiToken` |
| Cloud mode | `ATLASSIAN_CLOUD` | `atlassianCloud` (bool, default `true`) |
| Org ID | `ATLASSIAN_ORG_ID` | `orgId` |
| Cloud ID | `ATLASSIAN_CLOUD_ID` | `cloudId` |
| Auth mode | `ATLASSIAN_AUTH` | `auth` = `basic` \| `oauth` |
| OAuth client id | `ATLASSIAN_OAUTH_CLIENT_ID` | `oauth.clientId` |
| OAuth client secret | `ATLASSIAN_OAUTH_CLIENT_SECRET` | `oauth.clientSecret` |
| HTTP retries | `ATLASSIAN_HTTP_RETRIES` | `http.retries` (default `3`) |
| Config path | `ATLASSIAN_CONFIG` | — |

### 6.3 Config file discovery

1. `--config`
2. `$ATLASSIAN_CONFIG`
3. `$XDG_CONFIG_HOME/atlassian/config.toml` or `~/.config/atlassian/config.toml`
4. `~/.atlassian/config.toml`

Format: TOML. Example:

```toml
atlassianUrl = "https://acme.atlassian.net"
atlassianUsername = "user@acme.com"
# atlassianApiToken preferred via env
atlassianCloud = true
auth = "basic"
orgId = "…"

[oauth]
clientId = "…"
# clientSecret preferred via env

[http]
retries = 3
```

### 6.4 Credential store (OAuth)

Separate file (not the main config if possible):  
`~/.config/atlassian/credentials.json` (mode `0600`).

Contents: `access_token`, `refresh_token`, `expires_at`, `scope`, `cloud_id`. Never log or print token values in `auth status` (show expiry + mode only).

---

## 7. Authentication

### 7.1 Interface

```text
AuthProvider
  authorizationHeader(allocator) ![]const u8
  ensureValid(io) !void   // refresh oauth if near expiry
```

### 7.2 Basic

- Header: `Authorization: Basic base64(email:api_token)`
- Host: site base URL (`ATLASSIAN_URL`)
- Best for CI/scripts

### 7.3 OAuth 2.0 (3LO)

Per [Atlassian OAuth 2.0 3LO](https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/):

1. **`atlassian auth login`**
   - Bind loopback HTTP `http://127.0.0.1:<port>/callback` (port must match Developer Console callback URL; document default e.g. `8787`)
   - Open browser to  
     `https://auth.atlassian.com/authorize?audience=api.atlassian.com&client_id=…&scope=…&redirect_uri=…&state=…&response_type=code&prompt=consent`  
     Include `offline_access` for refresh tokens
   - Exchange code: `POST https://auth.atlassian.com/oauth/token` with `client_id`, `client_secret`, `code`, `redirect_uri`
   - Persist tokens; call `GET https://api.atlassian.com/oauth/token/accessible-resources` for `cloudId`
2. **API calls:** `Authorization: Bearer {access_token}` + OAuth URL form (`api.atlassian.com/ex/{product}/{cloudId}/…`)
3. **`auth refresh`:** rotating refresh token exchange; replace stored refresh token
4. **`auth logout`:** delete credential store
5. **`auth status`:** mode, site, cloud id, expiry (no secrets)

**OAuth app:** Investtal-owned 3LO app in Developer Console (shared client id) **or** user-supplied `clientId`/`clientSecret` in config. Design supports both; shipping default client id is an implementation choice documented in README.

**Scopes:** minimal set covering Jira work, Confluence content, and any scopes required for Teams/Goals as documented when wiring permissions. Exact scope list fixed in implementation plan from current API docs.

### 7.4 Mode selection

- `auth = basic` if API token present and mode not forced to oauth
- `auth = oauth` after successful login or explicit `ATLASSIAN_AUTH=oauth`
- Missing credentials → exit `3` with clear setup hint

---

## 8. Product APIs (concrete)

### 8.1 Jira Platform REST v3

- Base (basic): `{site}/rest/api/3`
- Docs: https://developer.atlassian.com/cloud/jira/platform/rest/v3/intro/
- Issues: get, create, update, delete, search (JQL)
- Projects: list, get, …

### 8.2 Jira Software REST (boards / sprints)

- Base: `{site}/rest/agile/1.0`
- Docs: https://developer.atlassian.com/cloud/jira/software/rest/

### 8.3 Goals — Atlassian platform GraphQL

- **Not** Advanced Roadmaps (no public Cloud CRUD for AR “goals”)
- Docs: https://developer.atlassian.com/platform/goals/goals-graphql-api/introduction/
- Transport: GraphQL POST via `graphql/client.zig` (site gateway `/gateway/api/graphql` under basic; OAuth path via transport abstraction)
- Operations: retrieve/list, edit name/description/due date, metrics, watch, link team, updates (as schema allows)

### 8.4 Teams — Public REST v1

- Docs: https://developer.atlassian.com/platform/teams/components/team-public-rest-api/
- Base: `{site}/gateway/api/public/teams/v1/org/{orgId}/teams`
- Operations:
  - `POST …/teams/` create
  - `GET …/teams/{teamId}` get
  - `PATCH …/teams/{teamId}` modify
  - `DELETE …/teams/{teamId}` delete
  - members fetch/add/remove
- Requires configured `orgId`

### 8.5 Confluence REST v2

- Base (basic): `{site}/wiki/api/v2`
- Docs: https://developer.atlassian.com/cloud/confluence/rest/v2/intro
- Pages CRUD; spaces/comments per v0.1 depth table

### 8.6 Escape hatch

`atlassian api request METHOD PATH` uses the same auth + transport + retry stack for endpoints not yet wrapped.

---

## 9. HTTP client, retry, errors

### 9.1 Retry

| Setting | Default |
|---------|---------|
| Attempts | **3** (1 initial + 2 retries) |
| Retry on | network failure, **429**, **502**, **503**, **504** |
| Backoff | exponential + jitter; honor `Retry-After` when present |
| No retry | 401, 403, 404, other 4xx (except 429), successful responses |

### 9.2 ApiError

```text
ApiError {
  kind: http | network | auth | decode | config | not_implemented
  status: ?u16
  code: ?[]const u8          // Atlassian error key / GraphQL code
  message: []const u8
  details: ?[]const u8       // body snippet or GraphQL errors
  request_id: ?[]const u8
  retriable: bool
}
```

### 9.3 Human error (stderr)

```text
Error: Jira issue not found (404)
  code: ISSUE_NOT_FOUND
  message: Issue does not exist or you do not have permission to see it.
  request_id: …
hint: check key and browse permission
```

### 9.4 JSON error (`--json`, stderr, non-zero exit)

```json
{
  "ok": false,
  "error": {
    "kind": "http",
    "status": 404,
    "code": "ISSUE_NOT_FOUND",
    "message": "…",
    "details": null,
    "request_id": "…",
    "retriable": false
  }
}
```

Success with `--json`: pretty or compact JSON object/array on **stdout** only (`ok` wrapper optional; prefer raw resource payload for scripting, document clearly).

### 9.5 Exit codes

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | generic failure |
| 2 | usage / invalid args |
| 3 | auth |
| 4 | not found |
| 5 | rate limit |
| 6 | not implemented (catalog stub) |
| 7 | network |

GraphQL errors map into the same `ApiError` / exit mapping.

---

## 10. Output rendering

| Mode | Success (stdout) | Failure (stderr) |
|------|------------------|------------------|
| **Default / `--toon`** | JSON body encoded as [TOON](https://github.com/toon-format/toon) (token-efficient, structured) | Human error |
| `--markdown` / `--md` | Curated Markdown (Jira issue cards, search tables; generic KV otherwise) | Human error |
| `--json` | Raw JSON resource | JSON `ApiError` |
| `--format toon\|markdown\|json` | Same as dedicated flags; **last flag wins** | per mode |

No mixing of progress noise on stdout in JSON mode. Empty success bodies print `ok` (toon/markdown) or a blank line (json).

---

## 11. Release and proto

### 11.1 Versioning

- Semver for the CLI package (`build.zig.zon` / release notes)
- Git tags: **`atlassian-vX.Y.Z`** (prefix avoids colliding with other monorepo tags)

### 11.2 CI (Jenkins)

> **Note (2026-07-17):** CI/CD moved off GitHub Actions to **Jenkins** (`jenkins/Jenkinsfile`). Tags `atlassian-v*` are created by Jenkins auto-release; GitHub Releases remain the distribution host only. See [`2026-07-17-toolchain-release-jenkins-design.md`](./2026-07-17-toolchain-release-jenkins-design.md).

On tag `atlassian-v*`:

1. Cross-build with Zig for:

   | OS | Arch |
   |----|------|
   | linux | x86_64, aarch64 |
   | macos | x86_64, aarch64 |
   | windows | x86_64, aarch64 |

2. Package archives:  
   `atlassian_{version}_{os}_{arch}.tar.gz` (Windows: `.zip`)
3. Generate `atlassian_{version}_checksums.txt` (`sha256  filename` lines)
4. Upload all assets to the GitHub Release for that tag

### 11.3 Proto plugin

Path: `proto/atlassian/plugin.toml`

Pattern (aligned with `proto/gh/plugin.toml`):

- `type = "cli"`
- `download-url` →  
  `https://github.com/investtal/investtal-toolchain/releases/download/atlassian-v{version}/{download_file}`
- `checksum-url` → matching checksums file
- Platform `exe-path` / `download-file` with `{version}`, `{arch}`
- Arch map: `aarch64 = "arm64"`, `x86_64 = "amd64"`

Consumers pin:

```toml
[plugins.tools]
atlassian = "https://raw.githubusercontent.com/investtal/investtal-toolchain/<COMMIT_SHA>/proto/atlassian/plugin.toml"
```

### 11.4 Inventory docs

Update `INVENTORY.md` and proto plugin docs when the plugin is added.

---

## 12. Testing strategy

| Layer | Approach |
|-------|----------|
| config merge / precedence | unit tests |
| URL transport (basic vs oauth, cloud paths) | unit tests |
| ApiError parsing (sample Jira/Confluence/GraphQL bodies) | unit tests |
| retry policy | unit tests with fake transport |
| CLI router / stubs exit codes | unit or integration |
| live API | optional manual / gated integration (`ATLASSIAN_*` present); not required in default CI |

No network in default `zig build test`.

---

## 13. Security notes

- Never print API tokens, OAuth secrets, or access/refresh tokens
- Credential file `0600`; prefer env for secrets in CI
- Verbose mode redacts `Authorization` header
- OAuth `state` parameter required and validated on callback
- Loopback callback only binds `127.0.0.1`

---

## 14. Implementation sequencing (for writing-plan)

1. Project skeleton: modules, CLI router, exit codes, render
2. Config load/save + env
3. HttpClient + retry + ApiError
4. Auth basic + transport Site
5. `jira issue` real commands
6. `confluence page` real commands
7. GraphQL client + `platform goal`
8. `platform team` + orgId
9. OAuth login/refresh/store + oauth transport paths
10. Remaining catalog stubs (project/board/sprint/space/comment verbs)
11. `api request` escape hatch
12. Cross-compile release workflow + checksums
13. `proto/atlassian/plugin.toml` + inventory

---

## 15. Open items (implementation detail, not design blockers)

- Exact default OAuth callback port and Investtal vs user-owned client id defaults
- Exact OAuth scope list for Goals + Teams on current Developer Console APIs
- Confirm GraphQL endpoint under OAuth bearer (gateway vs `api.atlassian.com`) during implement
- Whether success JSON wraps `{ "ok": true, "data": … }` or raw payload — **prefer raw payload** for scripting unless user feedback says otherwise

---

## 16. Approval record

| Section | Status |
|---------|--------|
| Approach A (layered binary) | Approved |
| Full catalog skeleton | Approved |
| Cloud-first, Server/DC-ready transport | Approved |
| TOON default; `--markdown` / `--json` opt-in | Approved (updated 2026-07-17) |
| `atlassian <product> <resource> <verb>` | Approved |
| Goals = platform GraphQL; Teams = Public REST | Approved |
| OAuth 3LO + Basic both in scope | Approved |
| Releases + proto plugin | Approved |
| Design sections 1–4 (prior chat) | Approved 2026-07-17 |
