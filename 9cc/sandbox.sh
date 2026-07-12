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

# Resolve symlinks portably (macOS lacks readlink -f).
_resolve_path() {
    local p="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$p" 2>/dev/null && return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null && return 0
    fi
    # Best-effort manual follow for simple absolute/relative symlinks.
    local target
    while [ -L "$p" ]; do
        target="$(readlink "$p")" || break
        case "$target" in
            /*) p="$target" ;;
            *)  p="$(dirname "$p")/$target" ;;
        esac
    done
    printf '%s' "$p"
}

# True if file is a Linux ELF binary (runs inside node:*-slim containers).
_is_linux_elf() {
    local f="$1"
    [ -f "$f" ] || return 1
    local magic
    magic="$(dd if="$f" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ "$magic" = "7f454c46" ]
}

# True if file can be copied into the Linux image as the claude CLI:
# Linux ELF, or a shebang script (typical npm / migrate-installer wrapper).
_is_container_runnable_claude() {
    local f="$1"
    [ -f "$f" ] || return 1
    _is_linux_elf "$f" && return 0
    local head2
    head2="$(dd if="$f" bs=2 count=1 2>/dev/null || true)"
    [ "$head2" = "#!" ]
}

# Locate host Claude install. Team members use different layouts:
#   1) CC9_CLAUDE_LOCAL  — explicit directory (copied as image /.claude/local)
#   2) CC9_CLAUDE_BIN    — explicit binary path
#   3) ~/.claude/local   — classic migrate-installer / local install
#   4) `claude` on PATH  — native installer (~/.local/bin/claude → versions/N)
# Prints:  dir|<path>  |  bin|<path>  |  npm|
# npm  = no host-copyable Linux-runnable install; Dockerfile installs via npm.
find_claude_source() {
    local dir bin resolved candidate

    if [ -n "${CC9_CLAUDE_LOCAL:-}" ]; then
        dir="$CC9_CLAUDE_LOCAL"
        [ -d "$dir" ] || { echo "9cc sandbox: CC9_CLAUDE_LOCAL=$dir is not a directory" >&2; return 1; }
        printf 'dir|%s\n' "$dir"
        return 0
    fi

    if [ -n "${CC9_CLAUDE_BIN:-}" ]; then
        bin="$CC9_CLAUDE_BIN"
        [ -f "$bin" ] || { echo "9cc sandbox: CC9_CLAUDE_BIN=$bin not found" >&2; return 1; }
        resolved="$(_resolve_path "$bin")"
        if _is_container_runnable_claude "$resolved"; then
            printf 'bin|%s\n' "$resolved"
        else
            echo "9cc sandbox: CC9_CLAUDE_BIN=$resolved is not Linux-runnable; falling back to npm install in image" >&2
            printf 'npm|\n'
        fi
        return 0
    fi

    # Classic local install directory.
    if [ -d "$HOME/.claude/local" ]; then
        candidate=""
        if [ -f "$HOME/.claude/local/bin/claude" ]; then
            candidate="$HOME/.claude/local/bin/claude"
        elif [ -f "$HOME/.claude/local/claude" ]; then
            candidate="$HOME/.claude/local/claude"
        fi
        if [ -n "$candidate" ] && _is_container_runnable_claude "$(_resolve_path "$candidate")"; then
            printf 'dir|%s\n' "$HOME/.claude/local"
            return 0
        fi
        if [ -n "$candidate" ]; then
            echo "9cc sandbox: $HOME/.claude/local has a non-Linux claude binary; trying PATH / npm" >&2
        fi
    fi

    # PATH resolution (native installer: ~/.local/bin/claude → share/claude/versions/*).
    if command -v claude >/dev/null 2>&1; then
        bin="$(command -v claude)"
        resolved="$(_resolve_path "$bin")"
        if _is_container_runnable_claude "$resolved"; then
            printf 'bin|%s\n' "$resolved"
            return 0
        fi
        echo "9cc sandbox: host claude at $resolved is not Linux-runnable (e.g. macOS Mach-O); installing Claude Code via npm in the image" >&2
        printf 'npm|\n'
        return 0
    fi

    # Common native-installer locations when PATH is incomplete (e.g. non-login shell).
    for candidate in \
        "$HOME/.local/bin/claude" \
        "$HOME/.local/share/claude/versions"/*
    do
        [ -e "$candidate" ] || continue
        [ -f "$candidate" ] || continue
        resolved="$(_resolve_path "$candidate")"
        if _is_container_runnable_claude "$resolved"; then
            printf 'bin|%s\n' "$resolved"
            return 0
        fi
    done

    echo "9cc sandbox: no host Claude install found; installing Claude Code via npm in the image" >&2
    printf 'npm|\n'
}

# Stage claude-local/ + claude-source.mode into the Docker build context.
# Image always expects /home/9cc/.claude/local/bin on PATH (see sandbox-entrypoint.sh).
stage_claude_local() {
    local ctx="$1"
    local src kind path
    src="$(find_claude_source)" || return 1
    kind="${src%%|*}"
    path="${src#*|}"

    case "$kind" in
        dir)
            # Replace dest contents (cp into an existing dir would nest basename).
            rm -rf "$ctx/claude-local"
            cp -a "$path" "$ctx/claude-local"
            # Normalize so entrypoint PATH works even if host used flat layout.
            if [ ! -e "$ctx/claude-local/bin/claude" ] && [ -f "$ctx/claude-local/claude" ]; then
                mkdir -p "$ctx/claude-local/bin"
                cp -a "$ctx/claude-local/claude" "$ctx/claude-local/bin/claude"
            fi
            printf 'host\n' > "$ctx/claude-source.mode"
            echo "9cc sandbox: using host Claude dir $path" >&2
            ;;
        bin)
            mkdir -p "$ctx/claude-local/bin"
            cp -a "$path" "$ctx/claude-local/bin/claude"
            chmod +x "$ctx/claude-local/bin/claude" 2>/dev/null || true
            printf 'host\n' > "$ctx/claude-source.mode"
            echo "9cc sandbox: using host Claude binary $path" >&2
            ;;
        npm)
            # Placeholder so COPY claude-local always has content; Dockerfile npm-installs.
            mkdir -p "$ctx/claude-local"
            printf '# npm install inside image\n' > "$ctx/claude-local/.npm-install"
            printf 'npm\n' > "$ctx/claude-source.mode"
            ;;
        *)
            echo "9cc sandbox: internal error: unknown claude source kind '$kind'" >&2
            return 1
            ;;
    esac
}

build_image() {
    command -v docker >/dev/null 2>&1 || { echo "9cc sandbox: docker not found" >&2; return 1; }

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
    stage_claude_local "$ctx" || return 1
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
