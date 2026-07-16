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

