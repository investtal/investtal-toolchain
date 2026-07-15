# Investtal git hooks

Enforces the **IVT-XXXX branch-naming policy** and **auto-suffixes commit messages**
with the task id, across every repo under `Landtal/`. Native git hooks only —
no husky, no vite-hooks, no third-party hook runner.

Two rules, applied on every repo:

1. **Branch naming** — every branch must be either an infra branch
   (`main`, `master`, `develop`, `dev`, `release/*`, `hotfix/*`) **or** contain a
   task id of the form `IVT-XXXX` (exactly 4 digits, delimited). Checkout to an
   invalid branch is **bounced back** to the previous branch with a clear error.
2. **Commit message** — when committing on an IVT branch, the task id is
   **appended** to the subject line automatically.
   `feat(api): add thing` on branch `IVT-0999` → `feat(api): add thing IVT-0999`.

## Quick reference

| Branch name                  | Allowed? | Why                                   |
|------------------------------|----------|---------------------------------------|
| `IVT-0999`                   | ✅       | clean 4-digit id                      |
| `feat/IVT-0999-broker-view`  | ✅       | id embedded in name                   |
| `IVT-0999-broker-view`       | ✅       | id embedded in name                   |
| `main`, `develop`, `master`  | ✅       | infra branch                          |
| `release/2.1.0`, `hotfix/x`  | ✅       | infra prefix                          |
| `feat/broker-view`           | ❌       | no task id                            |
| `chore/cleanup`              | ❌       | no task id                            |
| `IVT-999`                    | ❌       | only 3 digits                         |
| `IVT-99999`                  | ❌       | 5 digits — not a clean id             |
| `IVT-0999X`                  | ❌       | letter glued to digits                |
| `IVT-69696969`               | ❌       | 8 digits — not a clean id             |

## Architecture — native `.githooks/` per repo

Every repo gets a **tracked `.githooks/`** directory and `core.hooksPath` set to
it. This is the industry-standard "shared git hooks" pattern:

```
.githooks/
├── lib.sh          # shared ivt helpers (policy regex, chain logic)
├── commit-msg      # ivt task-id append (chains *.pre-ivt if present)
├── post-checkout   # ivt branch-policy switch-back (chains *.pre-ivt)
├── pre-commit      # repo-specific quality hook (lint) — where present
├── pre-push        # repo-specific quality hook (tests) — where present
├── post-commit     # graphify rebuild — where present
└── *.pre-ivt       # preserved originals (graphify post-checkout, etc.)
```

**Why tracked `.githooks/` + `core.hooksPath`:**
- Survives `git reset --hard` / `git checkout` — the dir is committed, so git
  never overwrites the hooks.
- One uniform model across all 13 repos — no husky, no vite-hooks, no per-repo
  `.git/hooks` copies.
- `make bootstrap` wires it up for every clone (developer + CI).
- Repo-specific quality hooks (lint, tests, graphify) live alongside the ivt
  hooks, all active at once.

**Chaining:** each ivt hook (`commit-msg`, `post-checkout`) chains a sibling
`<name>.pre-ivt` file if present — so a graphify post-checkout or an existing
commit-msg validator still runs. Quality hooks (`pre-commit`/`pre-push`/`post-commit`)
are standalone and run directly. A depth guard (`IVT_HOOK_CHAIN_DEPTH`, capped at
8) prevents infinite recursion.

## Setup — `make bootstrap`

Every repo has a Makefile with a `bootstrap` target. From inside any repo:

```bash
make bootstrap
```

This runs, in order (each step guarded by file-existence checks):

1. **`proto install`** — installs the pinned toolchain from `.prototools`
   (node, pnpm, bun, moon, etc.), only if `.prototools` exists.
2. **Git hooks setup** — `git config core.hooksPath .githooks` + `chmod +x .githooks/*`.
3. **`pnpm install`** — workspace dependencies, only if `package.json` exists.

Idempotent — re-run any time. Each repo's Makefile **inlines** the `bootstrap`
target directly (no external include) so it works on any clone without depending
on the Landtal folder layout. The `bootstrap.mk` file in this dir is a reference
copy of that inline target; it is NOT included by any repo.

For a fresh clone of any repo:

```bash
git clone <repo> && cd <repo>
make bootstrap
```

## Managing the shared hooks

The single source of truth is `Landtal/scripts/git-hooks/` (`lib.sh`,
`commit-msg`, `post-checkout`). Each repo's `.githooks/` is a **committed copy**
(portable, no dependency on the Landtal folder layout). To refresh every repo's
copy after editing the shared sources:

```bash
# from Landtal/
bash scripts/git-hooks/install.sh            # install/sync all repos
bash scripts/git-hooks/install.sh <repo>...  # only the named repos
bash scripts/git-hooks/install.sh --sync     # explicit refresh verb
bash scripts/git-hooks/install.sh --status   # audit state across repos
bash scripts/git-hooks/install.sh --uninstall [--all | <repo>...]
```

After syncing, **commit the refreshed `.githooks/` copies** in each repo so the
change reaches the team:

```bash
cd <repo>
git add .githooks/
git commit -m "IVT-XXXX chore: refresh ivt git hooks"
```

The installer copies `lib.sh` + `commit-msg` + `post-checkout` only; it never
touches repo-specific quality hooks (`pre-commit`/`pre-push`/`post-commit`) or
`.pre-ivt` chain files.

## Bypassing

For a single checkout that you know should be allowed despite the policy:

```bash
IVT_HOOK_SKIP=1 git checkout some-branch
```

For commits, the standard `--no-verify` skips the commit-msg hook (but also
skips any chained hook like a validator — use `IVT_HOOK_SKIP=1` instead to skip
only the IVT append while keeping other validators):

```bash
IVT_HOOK_SKIP=1 git commit -m "..."   # skip ivt append, keep validators/lint
git commit --no-verify -m "..."        # skip ALL hooks
```

`IVT_HOOK_SKIP=1` only disables the IVT-specific logic. Any `.pre-ivt` chain
target still runs. Set it globally in CI to bypass branch-name enforcement when
checking out arbitrary refs.

## Files

```
Landtal/scripts/git-hooks/
├── README.md        this file
├── lib.sh           shared helpers (regex policy, chain logic, debug)
├── post-checkout    branch-name enforcement + switch-back
├── commit-msg       task-id append + chains previous hook
├── install.sh       install / sync / uninstall / status across repos
└── bootstrap.mk     reference copy of the inline bootstrap target (not included)
```

## Cross-platform

Tested on macOS (bash 3.2, BSD readlink) and Linux (bash 5+, GNU readlink). The
symlink resolver probes `readlink -f` (Linux, macOS 12.3+), falls back to
`greadlink` (coreutils), then to a manual chase loop. No bash 4+ features used.

## Migration notes (husky / vite-hooks → native)

The 4 husky repos (investtal-apis, investtal-portals, investtal-webs,
investtal-mobile-apps) and 2 vite-hooks repos (investtal-design-system,
investtal-operations) were migrated:

- `.husky/` / `.vite-hooks/` removed; quality hooks (`pre-commit`, `pre-push`,
  `post-commit`) and graphify (`post-checkout.pre-ivt`) copied into `.githooks/`.
- `prepare: "husky"` / `postinstall: "husky"` / `prepare: "vp config"` scripts
  removed from `package.json` (replaced by `make bootstrap`).
- `husky` devDependency removed from husky repos. **`vite-plus` kept** in the
  two vite-hooks repos — it powers `vp check` / `vp test` / `vp lint`, not just
  hooks.
- `pnpm-lock.yaml` will update on the next `pnpm install` to drop the husky
  package; run `make bootstrap` (or `pnpm install`) to refresh it.

## Troubleshooting

**Hook doesn't fire** — run `git config core.hooksPath`; it must show `.githooks`.
If not, run `make bootstrap` (or `git config core.hooksPath .githooks`).

**`make: *** No rule to make target 'bootstrap'`** — you're in a repo without a
Makefile, or not at the repo root. The 3 docs-only repos
(investtal-business, investtal-data-platform, investtal-releases) have a minimal
Makefile that wires up hooks only.

**Debug trace** — `IVT_HOOK_DEBUG=1 git checkout -b feat/test` logs decisions.

**Committed to the wrong branch name** — `git branch -m IVT-XXXX-short-description`.
