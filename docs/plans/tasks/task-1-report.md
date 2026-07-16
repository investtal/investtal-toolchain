# Task 1 Report — CLI skeleton (exit codes, flags, render, router stubs)

**Status:** DONE  
**Branch:** `IVT-1707-atlassian-cli`  
**Commit:** `4b85d3967fc5b2e646405c04b10021b1db4aa8b3`  
**Message:** `feat(atlassian): CLI skeleton with flags, render, router stubs IVT-1707`  
(prepare-commit-msg hook appended ticket id)

## Deliverables

| Path | Action |
|------|--------|
| `atlassian/src/cli/exit_codes.zig` | Created — exit code constants 0–7 |
| `atlassian/src/cli/flags.zig` | Created — `Global` + `parse` / `deinit` |
| `atlassian/src/cli/render.zig` | Created — human/JSON success + fail |
| `atlassian/src/cli/root.zig` | Created — `run(init)` router + help + stubs |
| `atlassian/src/main.zig` | Replaced scaffold with `cli.run` + `process.exit` |
| `atlassian/src/root.zig` | Re-exports cli modules; `refAllDecls` for tests |
| `atlassian/.gitignore` | Ignores `.zig-cache/`, `zig-cache/`, `zig-out/` |
| `atlassian/build.zig` | Unchanged layout (single module root) |

## Behavior

- Global flags: `--json`, `--config PATH` / `--config=PATH`, `-v` / `--verbose`; stop at first non-flag or after `--`
- `atlassian` / `atlassian --help` / `-h` / `help` → product tree help, exit **0**
- Known products `config|auth|jira|platform|confluence|api` → clear not-implemented message, exit **6**
- Unknown top-level → usage message, exit **2**
- Failures always on stderr; with `--json`, minimal ApiError-shaped envelope (`kind:"config"` placeholder until Task 3)

## Interfaces (as specified)

- `exit_codes.{ok,generic,usage,auth,not_found,rate_limit,not_implemented,network}`
- `flags.Global = { json, config_path, verbose, rest }` + `parse` / `deinit`
- `render.Context = { json, out, err }` + `successText` / `successJson` / `fail`
- `cli.run(init: std.process.Init) u8`

## Verification

```
cd atlassian && zig build test   # PASS (offline)
zig build
./zig-out/bin/atlassian --help           # exit 0
./zig-out/bin/atlassian jira issue get   # exit 6
./zig-out/bin/atlassian foobar           # exit 2
```

## Tests included

- `exit_codes`: `not_implemented is 6`
- `flags`: parse extracts `--json` and `--config`
- `render`: human fail to stderr; JSON fail envelope
- `cli/root`: known product recognition

## Notes / non-scope

- No config load, HTTP, or product services (Tasks 2+)
- Untracked on disk (not in this commit): `atlassian/src/http/*` (appeared during work; left out of Task 1 commit)
- Docs/plans remain untracked as requested (work under `atlassian/` + commit only)

## Concerns

None for Task 1 acceptance criteria.
