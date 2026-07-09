# 9cc — Resolved Requirements Spec

**Source:** `0002-ManageClaudeCodeCLI.md` proposal + deep-interrogate session.
**Status:** Approved scope for v1. Auto-pilot deferred.

## Purpose

CLI launch Claude Code with dynamic model + compact-window over 9Router gateway. Solve 2 pains: (1) switch model without editing `settings.json` + restart, (2) fast per-model launch. Auto-pilot (overnight) deferred.

## Constraints

- **2 launchers only:** `9cc.sh` (mac/linux/wsl) + `9cc.ps1` (windows native). No binary, no runtime dep. (Installers + tests added for distribution; launchers remain 2.)
- **Auth:** `ANTHROPIC_API_KEY` (NOT `ANTHROPIC_AUTH_TOKEN` as draft proposed).
- **Secret reuse:** Read `ANTHROPIC_BASE_URL` + `ANTHROPIC_API_KEY` from existing `settings.json` `env` block (`https://ai.investtal.com/v1` + `sk-...`). No file write, no `9cc.env`, no `setup` command.
- **No config mutation:** Shell env export before `exec claude` overrides settings.json `env` block (shell env wins — confirmed via CC env precedence). Hooks/permissions/rtk/graphify/skipDangerous untouched.
- **Uniform model:** 1 alias sets `ANTHROPIC_MODEL` + all 3 `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`. In-session `/model <id>` switch works.
- **Per-model compact window:** `CLAUDE_CODE_AUTO_COMPACT_WINDOW` = model's window at launch.
- **Dual alias UX:** Accept short alias (`fable`, `glm5`) AND full 9Router ID (`glm/glm-5.2`).

## Model registry (13 models — shipped)

| Alias | 9Router ID | Window |
|-------|-----------|--------|
| fable | cc/claude-fable-5 | 1000000 |
| opus | cc/claude-opus-4-8 | 1000000 |
| sonnet | cc/claude-sonnet-5 | 200000 |
| haiku | cc/claude-haiku-4-5-20251001 | 200000 |
| gpt5 | cx/gpt-5.5 | 128000 |
| glm5 | glm/glm-5.2 | 1000000 |
| glmturbo | glm/glm-5-turbo | 1000000 |
| deepseek | ds/deepseek-v4-pro | 1000000 |
| dsflash | ds/deepseek-v4-flash | 1000000 |
| kimi | kimi/kimi-k2.7 | 1000000 |
| grok | xai/grok-4.5 | 500000 |
| grokcomposer | xai/grok-composer-2.5-fast | 500000 |
| minimax | minimax/MiniMax-M3 | 1000000 |

## Commands (shipped)

- `9cc list` / `9cc list --json` — table or machine-readable registry
- `9cc run <alias-or-id> [claude args...]` — export env, `exec claude`
- `9cc next <id|alias> [--no-free]` — cascade successor (fleet healer)
- `9cc update` — self-update to latest release
- `9cc uninstall` — remove home + PATH entry
- `9cc version` / `-v` / `--version`
- `9cc help` (or no args)

## Distribution (shipped)

- Launchers: `scripts/9cc.sh`, `scripts/9cc.ps1`
- Installers: `scripts/install.sh`, `scripts/install.ps1`
- Install (mac/linux): `gh api repos/investtal/investtal-toolchain/contents/scripts/install.sh --jq '.content' | base64 -d | bash`
- Install (windows): `gh api repos/investtal/investtal-toolchain/contents/scripts/install.ps1 --jq '.content' | base64 -d | powershell -c -`
- Pin: `?ref=<tag>` on contents path and/or `CC9_VERSION=<tag>`

## Success criteria (updated)

- `9cc run fable` → `cc/claude-fable-5`, window 1M, settings.json read-only
- `9cc list` / `list --json` cover all 13 models
- `9cc update` / `uninstall` / `version` work on both platforms
- Install/update prefer `gh` then raw fallback

## Decisions (trade-off → chosen → why)

- **Config strategy:** clobber settings.json → **pure ENV at launch** → zero risk to team's hooks/permissions/rtk/graphify.
- **Auth:** `ANTHROPIC_AUTH_TOKEN` → **`ANTHROPIC_API_KEY`** → matches real 9Router Investtal config.
- **In-session switch:** 3-tier mapping → **uniform model** → 1 alias = 1 model, `/model <id>` mid-session.
- **Distribution:** single bun/node → **2 files bash+ps1** → native, zero dep, copy-and-run.
- **Secret storage:** `9cc.env` file → **reuse settings.json env** → no new config surface.
- **Auto-pilot:** 2-phase fixed → **skip v1** → focus core tool, defer overnight as separate feature.
- **Compact window:** always max 1M → **per-model** → correct at launch (gotcha: mid-session switch to diff-window model stays launch value).
- **Alias UX:** short-only → **both short + full** → flexible.

## Open (deferred)

- **Auto-pilot overnight:** fable→minimax, `-p --dangerously-skip-permissions`, with docker/git sandbox. Separate feature, v2.
- **Alt+P/Option+P picker:** requires custom `~/.claude/keybindings.json`, not default. Not in v1; `/model` only.
