#!/usr/bin/env bash
# 9cc sandbox helpers — isolate Claude Code in Docker.
set -euo pipefail

: "${CC9_HOME:=${HOME}/.9cc}"
: "${CLAUDE_SETTINGS:=${HOME}/.claude/settings.json}"
: "${CC9_SANDBOX_IMAGE:=9cc-sandbox:latest}"
: "${CC9_SANDBOX_CONTEXT:=${CC9_HOME}/sandbox-context}"

is_guarded_dir() {
    local cwd; cwd="$(cd "$1" && pwd -P)"
    local home; home="$(cd "$HOME" && pwd -P)"
    if [ "$cwd" = "$home" ] || [ "$cwd" = "/" ]; then
        echo "9cc sandbox: refusing to run in $cwd (mount would expose home or root)" >&2
        return 1
    fi
}

_copy_if_exists() {
    local src="$1" dst="$2"
    if [ -e "$src" ]; then cp -a "$src" "$dst"; fi
}

_copy_dir_if_exists() {
    local src="$1" dst="$2"
    if [ -d "$src" ]; then cp -a "$src" "$dst"; fi
}

build_image() {
    command -v docker >/dev/null 2>&1 || { echo "9cc sandbox: docker not found" >&2; return 1; }
    local claude_local="$HOME/.claude/local"
    [ -d "$claude_local" ] || { echo "9cc sandbox: $claude_local not found; install Claude Code first" >&2; return 1; }

    local ctx="$CC9_SANDBOX_CONTEXT"
    # Guard: only wipe our own managed context dir to avoid data loss if user overrides CC9_SANDBOX_CONTEXT.
    case "$ctx/" in
        "${CC9_HOME}/"*) : ;;           # default location
        /tmp/*|/var/tmp/*) : ;;         # explicit scratch
        *) echo "9cc sandbox: refusing to wipe CC9_SANDBOX_CONTEXT=$ctx (must be under \$CC9_HOME or /tmp)" >&2; return 1 ;;
    esac
    rm -rf "$ctx"
    mkdir -p "$ctx"

    mkdir -p "$ctx/claude"
    _copy_dir_if_exists "$claude_local" "$ctx/claude-local"
    _copy_dir_if_exists "$HOME/.claude" "$ctx/claude"
    # Never bake secrets or the host binary into image layers; both are supplied at runtime.
    rm -rf "$ctx/claude/settings.json" "$ctx/claude/local"
    mkdir -p "$ctx/investtal" "$ctx/proto"
    _copy_dir_if_exists "$HOME/.investtal" "$ctx/investtal"
    _copy_dir_if_exists "$HOME/.proto" "$ctx/proto"
    _copy_if_exists "$HOME/.prototools" "$ctx/prototools"
    _copy_if_exists "$HOME/.zshrc" "$ctx/zshrc"
    _copy_if_exists "$HOME/.zshenv" "$ctx/zshenv"
    [ -f "$ctx/zshrc" ] || touch "$ctx/zshrc"
    [ -f "$ctx/zshenv" ] || touch "$ctx/zshenv"

    local this_dir; this_dir="${CC9_SANDBOX_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    cp "$this_dir/agent-proxy.mjs" "$ctx/agent-proxy.mjs"
    cp "$this_dir/sandbox-entrypoint.sh" "$ctx/sandbox-entrypoint.sh"

    local df; df="$this_dir/Dockerfile"
    [ -f "$df" ] || { echo "9cc sandbox: Dockerfile not found at $df" >&2; return 1; }

    docker build \
        -t "$CC9_SANDBOX_IMAGE" \
        -f "$df" \
        "$ctx"
}

egress_dir() {
    local dir; dir="${CC9_HOME}/egress"
    mkdir -p "$dir"
    printf '%s' "$dir"
}

run_sandboxed() {
    command -v docker >/dev/null 2>&1 || { echo "9cc sandbox: docker not found" >&2; return 1; }
    local cwd; cwd="$(pwd -P)"
    is_guarded_dir "$cwd" || return 1

    if [ "${CC9_SANDBOX_NO_BUILD:-}" != "1" ]; then
        docker image inspect "$CC9_SANDBOX_IMAGE" >/dev/null 2>&1 || build_image || return 1
    fi

    [ -f "$CLAUDE_SETTINGS" ] || { echo "9cc sandbox: $CLAUDE_SETTINGS not found" >&2; return 1; }

    local egress; egress="$(egress_dir)"
    echo "9cc sandbox: egress logs -> $egress" >&2

    docker run --rm -it \
        --user "$(id -u):$(id -g)" \
        --workdir /workspace \
        -v "$cwd:/workspace" \
        -v "$CLAUDE_SETTINGS:/home/9cc/.claude/settings.json:ro" \
        -v "$egress:/tmp/9cc-egress" \
        -e HOME=/home/9cc \
        -e USER="$(id -un)" \
        -e TERM="${TERM:-xterm-256color}" \
        -e "ANTHROPIC_MODEL=${ANTHROPIC_MODEL}" \
        -e "ANTHROPIC_DEFAULT_OPUS_MODEL=${ANTHROPIC_DEFAULT_OPUS_MODEL}" \
        -e "ANTHROPIC_DEFAULT_SONNET_MODEL=${ANTHROPIC_DEFAULT_SONNET_MODEL}" \
        -e "ANTHROPIC_DEFAULT_HAIKU_MODEL=${ANTHROPIC_DEFAULT_HAIKU_MODEL}" \
        -e "CLAUDE_CODE_AUTO_COMPACT_WINDOW=${CLAUDE_CODE_AUTO_COMPACT_WINDOW}" \
        -e "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}" \
        -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" \
        "$CC9_SANDBOX_IMAGE" \
        claude "$@"
}
