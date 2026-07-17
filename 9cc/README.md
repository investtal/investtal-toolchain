# 9cc — Claude Code model switcher

Launch [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with a **chosen model** over Investtal’s **9Router** gateway. Reads auth from `~/.claude/settings.json` (**read-only** — never mutates it).

## Why 9cc

- Humans and agent fleets need a **one-command** way to pick a model (alias or full 9Router id).
- Settings stay owned by Claude; 9cc only **launches** with the right model id.
- Optional **Docker sandbox** isolates the project workspace and logs egress for safer agent runs.

## Install

**macOS / Linux / WSL:**

```sh
gh api repos/investtal/investtal-toolchain/contents/9cc/install.sh --jq '.content' | base64 -d | bash
```

**Windows (PowerShell):**

```powershell
gh api repos/investtal/investtal-toolchain/contents/9cc/install.ps1 --jq '.content' | base64 -d | powershell -c -
```

Pin a release or commit:

```sh
gh api "repos/investtal/investtal-toolchain/contents/9cc/install.sh?ref=9cc-v0.5.4" --jq '.content' | base64 -d | bash
gh api repos/investtal/investtal-toolchain/contents/9cc/install.sh --jq '.content' | base64 -d | CC9_VERSION=9cc-v0.5.4 bash
```

Check: `9cc version`. Update: `9cc update`.

## Usage

```sh
9cc list                 # list models
9cc list --json          # machine-readable registry (alias → full id)
9cc run fable            # launch with alias
9cc run glm/glm-5.2      # full 9Router ID also works
9cc run minimax --resume # extra args forwarded to claude
9cc next minimax         # cascade successor (fleet healer on rate-limit)
9cc next minimax --no-free
9cc sandbox build        # build sandbox Docker image
9cc run fable --sandbox  # launch inside sandbox
9cc uninstall
9cc version
```

In a live session: `/model <id>` (e.g. `/model glm/glm-5.2`).

## Sandbox mode

`9cc run <model> --sandbox` runs Claude Code in Docker:

- mounts only the current project directory as the workspace
- hides host `~`, `~/.ssh`, `~/.aws`, and most host environment
- copies tooling homes into the image at build time; mounts Claude settings read-only for auth
- refuses to run from `~` or `/`
- routes outbound traffic through an in-container agent-proxy (logs under `~/.9cc/egress/`)

**Claude binary resolution** (host → image):

1. `CC9_CLAUDE_LOCAL` — directory staged as image `~/.claude/local`
2. `CC9_CLAUDE_BIN` — single binary
3. `~/.claude/local` — classic migrate-installer layout
4. `claude` on `PATH`
5. If the host binary is not Linux-runnable (e.g. macOS Mach-O), the image npm-installs `@anthropic-ai/claude-code`

## Development & CI

```sh
bash 9cc/9cc.test.sh && bash 9cc/smoke.sh
```

Jenkins: [`../jenkins/Jenkinsfile`](../jenkins/Jenkinsfile) — unit tests, update smoke, optional macOS agent.

## Design notes

- Spec: [`../docs/ideas/0002-ManageClaudeCodeCLI.spec.md`](../docs/ideas/0002-ManageClaudeCodeCLI.spec.md)
- Plan: [`../docs/plans/2026-07-08-9cc-model-switcher.md`](../docs/plans/2026-07-08-9cc-model-switcher.md)
