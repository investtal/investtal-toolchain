# Atlassian CLI (Zig) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `subagent-parallel-execution` (recommended) or inline execution via `finishing-execution` to implement task-by-task. Steps use `- [ ]` checkboxes.

**Goal:** Ship a Zig 0.16 single binary `atlassian` with layered architecture: full CLI catalog, real Jira issues / Confluence pages / Goals / Teams, Basic + OAuth auth, HTTP retry + ApiError, GitHub Releases + proto plugin.

**Architecture:** `cli` → domain services (`jira`, `platform`, `confluence`, `api`) → `http`/`graphql` → `auth` + `config`. Commands never call raw HTTP; services never write stdout. Cloud-first `Site` transport; Server/DC is a future path map only.

**Tech Stack:** Zig 0.16.0, std only (no third-party deps in v0.1), TOML config (hand-rolled minimal parser or key=value subset if full TOML is too large — see Task 2), GitHub Actions, proto TOML plugin.

**Spec:** `docs/specs/2026-07-17-atlassian-cli-design.md`

## Global Constraints

- Zig minimum: **0.16.0** (`build.zig.zon.minimum_zig_version`)
- Binary name: **`atlassian`**
- CLI shape: **`atlassian <product> <resource> <verb>`**
- Output: **human default**; **`--json`** opt-in (errors JSON on **stderr**, non-zero exit)
- Config precedence: **flags > env > file > defaults**
- Env keys: `ATLASSIAN_URL`, `ATLASSIAN_USERNAME`, `ATLASSIAN_API_TOKEN`, `ATLASSIAN_CLOUD`, `ATLASSIAN_ORG_ID`, `ATLASSIAN_CLOUD_ID`, `ATLASSIAN_AUTH`, `ATLASSIAN_OAUTH_CLIENT_ID`, `ATLASSIAN_OAUTH_CLIENT_SECRET`, `ATLASSIAN_HTTP_RETRIES`, `ATLASSIAN_CONFIG`
- HTTP retries: **default 3** attempts; retry on network, 429, 502, 503, 504; honor `Retry-After`
- Exit codes: 0 ok · 1 generic · 2 usage · 3 auth · 4 not found · 5 rate limit · 6 not_implemented · 7 network
- Goals: **Atlassian Goals GraphQL** (not Advanced Roadmaps)
- Teams: **Teams Public REST v1** under `/gateway/api/public/teams/v1/org/{orgId}/teams`
- Auth: **Basic + OAuth 2.0 3LO** (login/logout/status/refresh)
- Never log secrets; OAuth credential file mode **0600**
- Release tags: **`atlassian-vX.Y.Z`**
- Default `zig build test` must **not** require network
- Work only under `atlassian/`, `proto/atlassian/`, release workflow, and inventory docs listed in tasks
- Commits: conventional, small, per task

## File map (responsibility)

| Path | Responsibility |
|------|----------------|
| `atlassian/src/main.zig` | Process entry; wire Io/allocator; call `cli.run` |
| `atlassian/src/root.zig` | Library re-exports for tests |
| `atlassian/src/cli/exit_codes.zig` | Exit code constants |
| `atlassian/src/cli/flags.zig` | Global flag parse |
| `atlassian/src/cli/render.zig` | Human + JSON output / error print |
| `atlassian/src/cli/root.zig` | Router + subcommand dispatch |
| `atlassian/src/config/*` | Load/merge/save config |
| `atlassian/src/auth/*` | AuthProvider, basic, oauth, store, login |
| `atlassian/src/http/*` | Client, retry, ApiError, transport |
| `atlassian/src/graphql/client.zig` | GraphQL POST helper |
| `atlassian/src/jira/*` | Issue/project/board/sprint services |
| `atlassian/src/platform/*` | Goal + team services |
| `atlassian/src/confluence/*` | Page/space/comment services |
| `atlassian/src/api/raw.zig` | Escape-hatch request |
| `.github/workflows/atlassian-release.yml` | Cross-build release |
| `proto/atlassian/plugin.toml` | proto install definition |

---

### Task 1: CLI skeleton — exit codes, flags, render, router stubs

**Files:**
- Create: `atlassian/src/cli/exit_codes.zig`
- Create: `atlassian/src/cli/flags.zig`
- Create: `atlassian/src/cli/render.zig`
- Create: `atlassian/src/cli/root.zig`
- Modify: `atlassian/src/main.zig` (replace scaffold with `cli.run`)
- Modify: `atlassian/src/root.zig` (re-export cli modules for tests)
- Modify: `atlassian/build.zig` only if module paths need adjust (prefer single module root `src/root.zig` importing children)

**Interfaces:**
- Consumes: `std.process.Init` from Zig 0.16 main
- Produces:
  - `exit_codes.ok = 0`, `.usage = 2`, `.auth = 3`, `.not_found = 4`, `.rate_limit = 5`, `.not_implemented = 6`, `.network = 7`, `.generic = 1`
  - `flags.Global = struct { json: bool, config_path: ?[]const u8, verbose: bool, rest: []const []const u8 }`
  - `flags.parse(allocator, args: []const []const u8) !Global` — strips global flags; `rest` is remaining argv (without argv0)
  - `render.Context = struct { json: bool, out: *std.Io.Writer, err: *std.Io.Writer }`
  - `render.successText(ctx, text)` / `render.successJson(ctx, bytes)` / `render.fail(ctx, code, message)`
  - `cli.run(init: std.process.Init) u8` — returns exit code

- [ ] **Step 1: Write failing tests** in `atlassian/src/cli/flags.zig` and `exit_codes.zig` test blocks:

```zig
// flags.zig
test "parse extracts --json and --config" {
    const a = std.testing.allocator;
    const args = [_][]const u8{ "atlassian", "--json", "--config", "/tmp/c.toml", "config", "list" };
    const g = try parse(a, args[0..]);
    defer g.deinit(a);
    try std.testing.expect(g.json);
    try std.testing.expectEqualStrings("/tmp/c.toml", g.config_path.?);
    try std.testing.expectEqual(@as(usize, 2), g.rest.len);
    try std.testing.expectEqualStrings("config", g.rest[0]);
}

// exit_codes.zig
test "not_implemented is 6" {
    try std.testing.expectEqual(@as(u8, 6), not_implemented);
}
```

- [ ] **Step 2: Run tests, verify fail** — Run: `cd atlassian && zig build test 2>&1` Expected: FAIL (modules/files missing or parse undefined)

- [ ] **Step 3: Implement modules**

`exit_codes.zig`:
```zig
pub const ok: u8 = 0;
pub const generic: u8 = 1;
pub const usage: u8 = 2;
pub const auth: u8 = 3;
pub const not_found: u8 = 4;
pub const rate_limit: u8 = 5;
pub const not_implemented: u8 = 6;
pub const network: u8 = 7;
```

`flags.zig`: parse `--json`, `--config <path>`, `-v`/`--verbose`, stop at first non-flag or after `--`. Own copies of strings if needed; `deinit` frees.

`render.zig`: human messages to stdout; failures always stderr; if `json`, failure body:
```json
{"ok":false,"error":{"kind":"config","status":null,"code":null,"message":"...","details":null,"request_id":null,"retriable":false}}
```
(minimal until ApiError type exists — Task 3 will share `http/error.zig`).

`cli/root.zig`:
```zig
pub fn run(init: std.process.Init) u8 {
    // parse flags; switch on rest[0]:
    // config|auth|jira|platform|confluence|api|help|-h|--help
    // unknown → usage
    // implemented in Task 1: help text listing product tree; config/auth/jira/... return not_implemented with message
}
```

`main.zig`:
```zig
pub fn main(init: std.process.Init) void {
    const code = @import("cli/root.zig").run(init);
    std.process.exit(code);
}
```

Wire `root.zig` to `@import` cli modules so `zig build test` picks up tests.

- [ ] **Step 4: Run tests, verify pass** — Run: `cd atlassian && zig build test` Expected: PASS. Run: `zig build && zig-out/bin/atlassian --help` Expected: help text, exit 0. Run: `zig-out/bin/atlassian jira issue get` Expected: not implemented message, exit 6.

- [ ] **Step 5: Commit** — `git add atlassian && git commit -m "feat(atlassian): CLI skeleton with flags, render, router stubs"`

---

### Task 2: Config load, env merge, get/set/list/path

**Files:**
- Create: `atlassian/src/config/env.zig`
- Create: `atlassian/src/config/file.zig`
- Create: `atlassian/src/config/root.zig`
- Modify: `atlassian/src/cli/root.zig` — implement `config` subcommands

**Interfaces:**
- Consumes: `flags.Global.config_path`
- Produces:
  - `config.Config` struct fields: `url`, `username`, `api_token`, `cloud` (bool default true), `org_id`, `cloud_id`, `auth_mode` (`basic`|`oauth`), `oauth_client_id`, `oauth_client_secret`, `http_retries` (u8 default 3)
  - `config.load(allocator, override_path: ?[]const u8) !Config`
  - `config.save(allocator, cfg: Config, path: []const u8) !void`
  - `config.resolvedPath(allocator, override: ?[]const u8) ![]u8` — discovery order from spec
  - `config.get(cfg, key) ?[]const u8` / set by key name matching env semantic keys (camelCase file keys)

**File format (v0.1 — simple line parser, not full TOML library):**

Support lines:
```
key = "value"
key = true
key = 3
[oauth]
clientId = "..."
[http]
retries = 3
```

Keys map:
- `atlassianUrl`, `atlassianUsername`, `atlassianApiToken`, `atlassianCloud`, `orgId`, `cloudId`, `auth`
- section `oauth`: `clientId`, `clientSecret`
- section `http`: `retries`

Env overlay after file:
| Field | Env |
|-------|-----|
| url | `ATLASSIAN_URL` |
| username | `ATLASSIAN_USERNAME` |
| api_token | `ATLASSIAN_API_TOKEN` |
| cloud | `ATLASSIAN_CLOUD` (`true`/`false`/`1`/`0`) |
| org_id | `ATLASSIAN_ORG_ID` |
| cloud_id | `ATLASSIAN_CLOUD_ID` |
| auth_mode | `ATLASSIAN_AUTH` |
| oauth_client_id | `ATLASSIAN_OAUTH_CLIENT_ID` |
| oauth_client_secret | `ATLASSIAN_OAUTH_CLIENT_SECRET` |
| http_retries | `ATLASSIAN_HTTP_RETRIES` |

- [ ] **Step 1: Write failing tests**

```zig
test "env overlays file values" {
    // write temp file with atlassianUrl = "https://file.example"
    // setenv ATLASSIAN_URL=https://env.example
    // load → url is env
}

test "parse retries default 3" {
    const cfg = Config{};
    try std.testing.expectEqual(@as(u8, 3), cfg.http_retries);
}
```

- [ ] **Step 2: Run test, verify fail** — `cd atlassian && zig build test` Expected: FAIL missing config module

- [ ] **Step 3: Implement config + CLI**

Commands:
- `atlassian config path` → print resolved path
- `atlassian config list` → print keys (mask token/secret as `***` unless empty)
- `atlassian config get KEY` → value or exit 4 if unset
- `atlassian config set KEY VALUE` → load, set, save (create parent dirs)

Never print raw tokens in list when length > 0 (show `***`).

- [ ] **Step 4: Run tests + manual** — `zig build test` PASS.  
  `zig-out/bin/atlassian config path` prints a path.  
  `zig-out/bin/atlassian config set atlassianUrl https://example.atlassian.net && zig-out/bin/atlassian config get atlassianUrl` prints URL.

- [ ] **Step 5: Commit** — `git commit -m "feat(atlassian): config file, env merge, config CLI"`

---

### Task 3: ApiError + HttpClient retry + transport URL builder

**Files:**
- Create: `atlassian/src/http/error.zig`
- Create: `atlassian/src/http/transport.zig`
- Create: `atlassian/src/http/client.zig`
- Modify: `atlassian/src/cli/render.zig` — `failApi(ctx, ApiError)` for structured errors

**Interfaces:**
- Produces:
```zig
pub const ApiError = struct {
    kind: enum { http, network, auth, decode, config, not_implemented },
    status: ?u16 = null,
    code: ?[]const u8 = null,
    message: []const u8,
    details: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    retriable: bool = false,

    pub fn exitCode(self: ApiError) u8 { ... } // map status 401/403→3, 404→4, 429→5, network→7, not_implemented→6, else 1
    pub fn deinit(self: *ApiError, allocator: Allocator) void { ... }
};

pub const Product = enum { jira, jira_software, confluence, gateway, graphql };

pub const Site = struct {
    kind: enum { cloud, server_dc } = .cloud,
    base_url: []const u8, // no trailing slash
    cloud_id: ?[]const u8 = null,
    auth_mode: enum { basic, oauth } = .basic,

    pub fn resolve(self: Site, allocator: Allocator, product: Product, path: []const u8) ![]u8
    // path has no leading slash preferred; normalize
};

pub const Request = struct {
    method: []const u8,
    url: []const u8,
    headers: []const std.http.Header, // or custom pairs
    body: ?[]const u8 = null,
};

pub const Response = struct {
    status: u16,
    body: []u8,
    request_id: ?[]const u8,
    pub fn deinit(self: *Response, a: Allocator) void,
};

pub const Client = struct {
    allocator: Allocator,
    // io handle as required by Zig 0.16 std.http
    retries: u8 = 3,
    verbose: bool = false,

    pub fn request(self: *Client, auth_header: []const u8, req: Request) !Response
    // on failure after retries: return error or ApiError — prefer `RequestError!Response` where RequestError includes ApiError payload via error union OR return `anyerror` and out-param; pick one style and stick to it:
    // Recommended: `pub fn request(...) ApiError!Response` with ApiError as error set is invalid in Zig —
    // Use: `pub fn request(...) !Response` and `pub fn requestApi(...) error{ApiFailed}!Response` with last_error field,
    // OR return `union(enum){ ok: Response, err: ApiError }`.
    // **Canonical for this project:** `pub const Result = union(enum) { ok: Response, err: ApiError }; pub fn request(...) !Result`
};
```

**Retry policy:**
- attempts = `retries` (default 3)
- retry if: transport/network error, OR status in {429,502,503,504}
- sleep: if `Retry-After` header integer seconds, use it; else backoff_ms = 200 * (1 << attempt) + small jitter
- do not retry 401/403/404

**transport.resolve Cloud basic examples:**
- jira + `issue/PROJ-1` → `{base}/rest/api/3/issue/PROJ-1`
- jira_software + `board` → `{base}/rest/agile/1.0/board`
- confluence + `pages/123` → `{base}/wiki/api/v2/pages/123`
- gateway + `public/teams/v1/org/X/teams/Y` → `{base}/gateway/api/public/teams/v1/org/X/teams/Y`
- graphql + `` → `{base}/gateway/api/graphql`

**OAuth cloud:**
- jira → `https://api.atlassian.com/ex/jira/{cloud_id}/rest/api/3/{path}`
- confluence → `https://api.atlassian.com/ex/confluence/{cloud_id}/wiki/api/v2/{path}`
- gateway/graphql → `{base}/gateway/api/...` still on site host when using basic; for oauth use site base_url gateway if cloud_id only applies to ex/jira|confluence — document: OAuth gateway calls use `https://api.atlassian.com/ex/jira/{cloud_id}/gateway/api/...` only if Atlassian requires it; **v0.1 implement:** oauth jira/confluence via `api.atlassian.com/ex/...`; gateway + graphql use `base_url` with Bearer (same as browser session patterns). If live test fails, fix transport only.

**ApiError from HTTP body:**
- Parse JSON `errorMessages` array (Jira) → join message
- Parse `message` field
- GraphQL: `errors[0].message`
- Set `code` from `errorCode` / `errors` keys when present

- [ ] **Step 1: Write failing unit tests** (no network)

```zig
test "resolve jira basic cloud" {
    const site = Site{ .base_url = "https://acme.atlassian.net", .auth_mode = .basic };
    const u = try site.resolve(testing.allocator, .jira, "issue/A-1");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("https://acme.atlassian.net/rest/api/3/issue/A-1", u);
}

test "resolve jira oauth cloud" {
    const site = Site{ .base_url = "https://acme.atlassian.net", .cloud_id = "cid", .auth_mode = .oauth };
    const u = try site.resolve(testing.allocator, .jira, "issue/A-1");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("https://api.atlassian.com/ex/jira/cid/rest/api/3/issue/A-1", u);
}

test "exitCode maps 404 to not_found" {
    const e = ApiError{ .kind = .http, .status = 404, .message = "x" };
    try testing.expectEqual(@as(u8, 4), e.exitCode());
}

test "parse jira errorMessages" {
    const body = "{\"errorMessages\":[\"Issue does not exist\"],\"errors\":{}}";
    var e = try ApiError.fromHttp(testing.allocator, 404, body, null);
    defer e.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, e.message, "Issue does not exist") != null);
}
```

- [ ] **Step 2: Run tests, verify fail** — `zig build test` FAIL

- [ ] **Step 3: Implement error, transport, client**  
  For client unit tests without network: inject a `Transport` interface:

```zig
pub const RoundTrip = *const fn (ctx: *anyopaque, req: Request) anyerror!struct { status: u16, body: []const u8, headers_retry_after: ?[]const u8 };
```

  Default production uses `std.http`. Tests pass a fake that fails twice then 200 to assert retry count.

- [ ] **Step 4: Run tests** — `zig build test` PASS including retry fake test `retry three times on 503`

- [ ] **Step 5: Commit** — `git commit -m "feat(atlassian): HTTP client, retry, transport, ApiError"`

---

### Task 4: Auth Basic + Site from Config

**Files:**
- Create: `atlassian/src/auth/root.zig`
- Create: `atlassian/src/auth/basic.zig`
- Create: `atlassian/src/auth/store.zig` (empty token store API stubs for Task 9)
- Modify: `atlassian/src/config/root.zig` — helper `toSite(cfg) Site` + `authHeader`

**Interfaces:**
```zig
pub const AuthKind = enum { basic, oauth };

pub const AuthContext = struct {
    kind: AuthKind,
    // basic:
    username: ?[]const u8 = null,
    api_token: ?[]const u8 = null,
    // oauth filled Task 9:
    access_token: ?[]const u8 = null,

    pub fn authorizationHeader(self: AuthContext, allocator: Allocator) ![]u8
    // basic → "Basic " ++ base64(user:token)
    // oauth → "Bearer " ++ access_token
    // missing → error.MissingCredentials
};

pub fn fromConfig(cfg: config.Config, tokens: ?oauth_tokens) AuthContext
pub fn siteFromConfig(cfg: config.Config) Site
```

- [ ] **Step 1: Test**

```zig
test "basic header encoding" {
    const h = try AuthContext{ .kind = .basic, .username = "a@b.c", .api_token = "tok" }.authorizationHeader(testing.allocator);
    defer testing.allocator.free(h);
    try testing.expect(std.mem.startsWith(u8, h, "Basic "));
}
```

- [ ] **Step 2: FAIL then implement**

- [ ] **Step 3: `auth status` command** — if basic credentials present print `mode=basic url=...` (no token); if missing exit 3

- [ ] **Step 4: `zig build test` PASS; manual status**

- [ ] **Step 5: Commit** — `git commit -m "feat(atlassian): basic auth and Site from config"`

---

### Task 5: Jira issue service + commands (real)

**Files:**
- Create: `atlassian/src/jira/issue.zig`
- Create: `atlassian/src/jira/project.zig` (list/get real; other verbs not_implemented)
- Create: `atlassian/src/jira/board.zig` (list/get real or stub consistently)
- Create: `atlassian/src/jira/sprint.zig` (list/get)
- Modify: `atlassian/src/cli/root.zig` — wire `jira` product

**Interfaces:**
```zig
// issue.zig
pub fn get(client: *http.Client, site: Site, auth: []const u8, key: []const u8) !http.Result
pub fn create(client, site, auth, body_json: []const u8) !http.Result
pub fn update(client, site, auth, key, body_json) !http.Result
pub fn delete(client, site, auth, key) !http.Result
pub fn search(client, site, auth, jql: []const u8, max_results: u32) !http.Result
// Paths: GET/POST/PUT/DELETE rest/api/3/issue/{key}, POST rest/api/3/search (or /search/jql per current API)
```

Verify current Jira Cloud search path at implement time (`/rest/api/3/search` vs newer). Use documented v3 search endpoint.

**CLI:**
```
atlassian jira issue get KEY
atlassian jira issue create --body file.json|-
atlassian jira issue update KEY --body file.json
atlassian jira issue delete KEY
atlassian jira issue search --jql '...' [--max 50]
atlassian jira issue list  → alias search with jql=order by updated DESC, max 25
```

Human render: for get, print key, summary, status, assignee from JSON fields. JSON mode: raw body.

- [ ] **Step 1: Unit test** URL construction via transport for issue get path (no network)

- [ ] **Step 2: Implement service + CLI**

- [ ] **Step 3: Optional live test** only if env set:  
  `ATLASSIAN_URL=... ATLASSIAN_USERNAME=... ATLASSIAN_API_TOKEN=... zig-out/bin/atlassian jira issue get PROJ-1`  
  Not required for CI.

- [ ] **Step 4: `zig build test` PASS; `atlassian jira issue` without args → usage exit 2**

- [ ] **Step 5: Commit** — `git commit -m "feat(atlassian): jira issue CRUD and search"`

---

### Task 6: Confluence page service + commands (real)

**Files:**
- Create: `atlassian/src/confluence/page.zig`
- Create: `atlassian/src/confluence/space.zig` (list/get preferred; else stub)
- Create: `atlassian/src/confluence/comment.zig` (stub verbs with exit 6 if not real)
- Modify: `atlassian/src/cli/root.zig`

**Interfaces:**
```zig
pub fn get(client, site, auth, page_id: []const u8) !http.Result
// GET wiki/api/v2/pages/{id}?body-format=storage
pub fn create(client, site, auth, body_json) !http.Result
// POST wiki/api/v2/pages
pub fn update(client, site, auth, page_id, body_json) !http.Result
// PUT wiki/api/v2/pages/{id}
pub fn delete(client, site, auth, page_id) !http.Result
pub fn list(client, site, auth, space_key: ?[]const u8, limit: u32) !http.Result
```

**CLI:**
```
atlassian confluence page get ID
atlassian confluence page create --body file.json
atlassian confluence page update ID --body file.json
atlassian confluence page delete ID
atlassian confluence page list [--space KEY]
```

- [ ] **Step 1: Transport unit test for confluence path**

- [ ] **Step 2: Implement + wire CLI**

- [ ] **Step 3: `zig build test` PASS**

- [ ] **Step 4: Commit** — `git commit -m "feat(atlassian): confluence page CRUD"`

---

### Task 7: GraphQL client + platform goals

**Files:**
- Create: `atlassian/src/graphql/client.zig`
- Create: `atlassian/src/platform/goal.zig`
- Modify: `atlassian/src/cli/root.zig` — `platform goal *`

**Interfaces:**
```zig
// graphql/client.zig
pub fn execute(client: *http.Client, site: Site, auth: []const u8, query: []const u8, variables_json: ?[]const u8) !http.Result
// POST site.resolve(.graphql, "") with body {"query":"...","variables":{...}}
// Content-Type application/json
// If body has errors array without data → ApiError.kind decode/http

// goal.zig — embed query strings constants
pub fn get(client, site, auth, goal_id: []const u8) !http.Result
pub fn list(client, site, auth, first: u32) !http.Result
pub fn update(client, site, auth, goal_id: []const u8, patch_vars_json: []const u8) !http.Result
// create/delete/watch/link-team: real mutations from Goals GraphQL docs when available; else exit 6 with message pointing to docs
```

Use queries from https://developer.atlassian.com/platform/goals/graphql/ — pin concrete query documents in source comments with doc URL.

**CLI:**
```
atlassian platform goal get ID
atlassian platform goal list [--first 20]
atlassian platform goal update ID --body vars.json
atlassian platform goal create|delete|watch|link-team ...
```

- [ ] **Step 1: Test GraphQL body builder** (string contains query + variables)

- [ ] **Step 2: Implement**

- [ ] **Step 3: `zig build test` PASS**

- [ ] **Step 4: Commit** — `git commit -m "feat(atlassian): GraphQL client and platform goals"`

---

### Task 8: Platform teams (Public REST v1)

**Files:**
- Create: `atlassian/src/platform/team.zig`
- Modify: `atlassian/src/cli/root.zig`

**Interfaces:**
```zig
// Requires cfg.org_id non-empty else ApiError.kind=config message "set orgId / ATLASSIAN_ORG_ID"

pub fn create(client, site, auth, org_id, body_json) !http.Result
// POST gateway public/teams/v1/org/{orgId}/teams/
pub fn get(client, site, auth, org_id, team_id) !http.Result
pub fn update(client, site, auth, org_id, team_id, body_json) !http.Result // PATCH
pub fn delete(client, site, auth, org_id, team_id) !http.Result
pub fn members(client, site, auth, org_id, team_id, body_json) !http.Result // POST .../members
pub fn addMembers(...) !http.Result
pub fn removeMembers(...) !http.Result
```

**CLI:**
```
atlassian platform team get TEAM_ID
atlassian platform team list  → if public list endpoint unavailable, document and exit 6 with hint to use gateway search; implement create/get/update/delete/members as per public docs
atlassian platform team create --body team.json
atlassian platform team update TEAM_ID --body patch.json
atlassian platform team delete TEAM_ID
atlassian platform team members TEAM_ID
atlassian platform team add-member TEAM_ID --account-id ID
atlassian platform team remove-member TEAM_ID --account-id ID
```

Note: Public docs emphasize get-by-id and members; **list** may require alternate search endpoint — if no public list, stub list with exit 6 and message (still catalog-complete).

- [ ] **Step 1: Unit test path contains `/gateway/api/public/teams/v1/org/`**

- [ ] **Step 2: Implement**

- [ ] **Step 3: `zig build test` PASS**

- [ ] **Step 4: Commit** — `git commit -m "feat(atlassian): platform teams Public REST"`

---

### Task 9: OAuth 3LO login, store, refresh, oauth transport

**Files:**
- Create: `atlassian/src/auth/oauth.zig`
- Create: `atlassian/src/auth/login.zig`
- Modify: `atlassian/src/auth/store.zig` — full read/write credentials
- Modify: `atlassian/src/auth/root.zig` — prefer oauth tokens when mode=oauth
- Modify: `atlassian/src/cli/root.zig` — `auth login|logout|refresh|status`

**Interfaces:**
```zig
pub const TokenSet = struct {
    access_token: []u8,
    refresh_token: ?[]u8,
    expires_at_unix: i64,
    scope: ?[]u8,
    cloud_id: ?[]u8,
};

pub fn credentialsPath(allocator) ![]u8
// $XDG_CONFIG_HOME/atlassian/credentials.json or ~/.config/atlassian/credentials.json

pub fn saveTokens(allocator, tokens: TokenSet) !void // mode 0o600
pub fn loadTokens(allocator) !?TokenSet
pub fn clearTokens() !void

// oauth.zig
pub fn exchangeCode(client, client_id, client_secret, code, redirect_uri) !TokenSet
pub fn refresh(client, client_id, client_secret, refresh_token) !TokenSet
pub fn accessibleResources(client, access_token) ![]Resource // id, url, name, scopes

// login.zig
pub fn interactiveLogin(allocator, io, cfg: Config, scopes: []const u8) !TokenSet
// 1. bind 127.0.0.1:8787 (constant DEFAULT_CALLBACK_PORT = 8787)
// 2. redirect_uri = http://127.0.0.1:8787/callback
// 3. state = random 32 bytes hex
// 4. open URL via `open` (mac) / `xdg-open` (linux) / cmd start (windows)
// 5. wait for GET /callback?code&state; validate state
// 6. exchangeCode; accessibleResources; pick resource matching cfg.url or first
// 7. saveTokens; set cloud_id on tokens
```

**Authorize URL:**
```
https://auth.atlassian.com/authorize?audience=api.atlassian.com&client_id={id}&scope={urlencode scopes}&redirect_uri={uri}&state={state}&response_type=code&prompt=consent
```

Default scopes string (space-separated, include offline_access):
```
read:jira-work write:jira-work read:jira-user offline_access read:confluence-content.all write:confluence-content manage:confluence-content read:me
```
Adjust if Developer Console rejects; document final list in `atlassian/README.md`.

**Token endpoint:** `POST https://auth.atlassian.com/oauth/token` JSON body grant_type authorization_code | refresh_token.

**CLI:**
```
atlassian auth login
atlassian auth logout
atlassian auth refresh
atlassian auth status   # mode, url, cloud_id, expires_at — never tokens
```

When `auth=oauth` or tokens present and mode oauth: `authorizationHeader` = Bearer; `Site.auth_mode=.oauth` and `cloud_id` from tokens/config.

- [ ] **Step 1: Unit tests** for authorize URL builder, state validation reject, token JSON parse

- [ ] **Step 2: Implement store + oauth + login**

- [ ] **Step 3: `zig build test` PASS (no live OAuth in CI)**

- [ ] **Step 4: Commit** — `git commit -m "feat(atlassian): OAuth 3LO login, refresh, credential store"`

---

### Task 10: Catalog completion — remaining stubs + board/sprint list/get

**Files:**
- Modify: `atlassian/src/jira/board.zig`, `sprint.zig`, `project.zig`
- Modify: `atlassian/src/confluence/space.zig`, `comment.zig`
- Modify: `atlassian/src/cli/root.zig` — ensure **every** catalog verb routes to real handler or `not_implemented`

**Rule:** Every path in spec §5.2 returns either real result or exit **6** with `Error: not implemented: <product> <resource> <verb>` — never fall through to usage for known verbs.

**Real where specified:**
- project list/get → GET `/rest/api/3/project`, GET `/rest/api/3/project/{idOrKey}`
- board list/get → GET `/rest/agile/1.0/board`, GET `/rest/agile/1.0/board/{id}`
- sprint list/get → GET `/rest/agile/1.0/board/{boardId}/sprint`, GET `/rest/agile/1.0/sprint/{id}`
- space list/get if v2 paths clear; else stub

- [ ] **Step 1: Test router table** — optional table-driven test that known commands don't return exit 2

- [ ] **Step 2: Implement**

- [ ] **Step 3: Manual** `atlassian jira board create` → exit 6

- [ ] **Step 4: Commit** — `git commit -m "feat(atlassian): complete command catalog stubs and board/sprint get"`

---

### Task 11: `api request` escape hatch

**Files:**
- Create: `atlassian/src/api/raw.zig`
- Modify: `atlassian/src/cli/root.zig`

**Interfaces:**
```zig
pub fn rawRequest(
    client: *http.Client,
    site: Site,
    auth: []const u8,
    method: []const u8,
    product: http.Product,
    path: []const u8,
    body: ?[]const u8,
) !http.Result
```

**CLI:**
```
atlassian api request GET issue/PROJ-1 --product jira
atlassian api request POST search --product jira --body body.json
atlassian api request GET pages/1 --product confluence
```

- [ ] **Step 1: Test** product flag parsing

- [ ] **Step 2: Implement**

- [ ] **Step 3: Commit** — `git commit -m "feat(atlassian): api request escape hatch"`

---

### Task 12: Cross-platform release workflow

**Files:**
- Create: `.github/workflows/atlassian-release.yml`
- Modify: `atlassian/build.zig` — ensure `zig build -Doptimize=ReleaseSafe` produces `atlassian` binary; add optional `-Dtarget=`
- Create: `atlassian/scripts/package-release.sh` — optional helper for local packaging

**Workflow behavior:**
- Trigger: `push` tags matching `atlassian-v*`
- Matrix:
  - `x86_64-linux`, `aarch64-linux`
  - `x86_64-macos`, `aarch64-macos`
  - `x86_64-windows`, `aarch64-windows`
- Build: `cd atlassian && zig build -Doptimize=ReleaseSafe -Dtarget=<triple>`
- Package:
  - Unix: `tar czf atlassian_${VER}_${os}_${arch}.tar.gz atlassian` (binary renamed from zig-out)
  - Windows: zip `atlassian.exe`
- Checksums: `sha256sum atlassian_${VER}_* > atlassian_${VER}_checksums.txt` (format: `hash  filename`)
- Upload to GitHub Release for the tag via `softprops/action-gh-release` or `gh release create`

Version parse: tag `atlassian-v0.1.0` → `0.1.0`

- [ ] **Step 1: Write workflow YAML** (no need for failing test; validate with `actionlint` if available)

- [ ] **Step 2: Local dry-run** `cd atlassian && zig build -Doptimize=ReleaseSafe` succeeds on dev machine

- [ ] **Step 3: Commit** — `git commit -m "ci(atlassian): cross-platform release workflow"`

---

### Task 13: Proto plugin + inventory + README

**Files:**
- Create: `proto/atlassian/plugin.toml`
- Create: `atlassian/README.md` — install, config, auth, examples
- Modify: `INVENTORY.md` — add atlassian row
- Modify: `docs/ideas/proto-plugins.md` and/or root `README.md` inventory table

**plugin.toml** (align names with release assets from Task 12):

```toml
# @investtal/proto-plugins — atlassian (Investtal Atlassian CLI)
name = "Atlassian CLI"
type = "cli"

[resolve]
git-url = "https://github.com/investtal/investtal-toolchain"

[platform.linux]
exe-path = "atlassian"
download-file = "atlassian_{version}_linux_{arch}.tar.gz"
checksum-file = "atlassian_{version}_checksums.txt"

[platform.macos]
exe-path = "atlassian"
download-file = "atlassian_{version}_macos_{arch}.tar.gz"
checksum-file = "atlassian_{version}_checksums.txt"

[platform.windows]
exe-path = "atlassian.exe"
download-file = "atlassian_{version}_windows_{arch}.zip"
checksum-file = "atlassian_{version}_checksums.txt"

[install]
download-url = "https://github.com/investtal/investtal-toolchain/releases/download/atlassian-v{version}/{download_file}"
checksum-url = "https://github.com/investtal/investtal-toolchain/releases/download/atlassian-v{version}/{checksum_file}"

[install.arch]
aarch64 = "arm64"
x86_64 = "amd64"
```

If archive layout nests binary, set `exe-path` accordingly (match packaging script).

- [ ] **Step 1: Add files**

- [ ] **Step 2: Self-check** asset name consistency between workflow and plugin.toml

- [ ] **Step 3: Commit** — `git commit -m "feat(proto): atlassian CLI plugin and docs"`

---

### Task 14: Integration polish + version bump

**Files:**
- Modify: `atlassian/build.zig.zon` version `0.1.0`
- Modify: `atlassian/src/cli/root.zig` — `atlassian version` prints `0.1.0`
- Create: `atlassian/CHANGELOG.md` — 0.1.0 notes

- [ ] **Step 1: `zig build test` full PASS**

- [ ] **Step 2: Smoke script** `atlassian/scripts/smoke.sh`:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  BIN="${1:-zig-out/bin/atlassian}"
  "$BIN" --help >/dev/null
  "$BIN" config path >/dev/null
  "$BIN" jira board create >/dev/null && exit 1 || test $? -eq 6
  echo smoke ok
  ```

- [ ] **Step 3: Commit** — `git commit -m "chore(atlassian): v0.1.0 polish and smoke script"`

---

## Spec coverage checklist

| Spec requirement | Task(s) |
|------------------|---------|
| Layered architecture | 1–11 file map |
| Full catalog skeleton | 1, 10 |
| config get/set + env | 2 |
| Basic auth | 4 |
| OAuth 3LO interactive | 9 |
| HTTP retry default 3 | 3 |
| ApiError + exit codes | 1, 3 |
| Jira issue real | 5 |
| Boards/sprints | 5, 10 |
| Goals GraphQL | 7 |
| Teams Public REST | 8 |
| Confluence pages | 6 |
| api request | 11 |
| Cloud-first transport Server/DC-ready | 3 |
| Human + --json | 1, 3 |
| GitHub Releases cross-platform | 12 |
| proto plugin | 13 |

## Self-review notes

- No TBD in task steps; open API path variants (Jira search URL, Goals exact GraphQL documents) resolved at implement by reading current Atlassian docs once and locking strings in source.
- Types: `http.Result`, `Site`, `ApiError`, `Config`, `AuthContext` used consistently across tasks.
- Not data-bearing (no DB schema); data-first N/A.
- OAuth + Goals + Teams not deferred (Tasks 7–9).

---

## Execution notes

- Implement inside `atlassian/` working tree; prefer isolated git worktree for long runs (`git-worktree` skill).
- After plan approval: subagent-per-task recommended.
- Do not tag `atlassian-v0.1.0` until Task 14 smoke passes on main branch.
