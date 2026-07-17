#!/usr/bin/env bash
set -euo pipefail

CC9_HOME="${CC9_HOME:-$HOME/.9cc}"
CC9_VERSION="${CC9_VERSION:-$(cat "$CC9_HOME/version" 2>/dev/null || echo 0.1.0-dev)}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

get_model() {
    case "$1" in
        fable|cc/claude-fable-5)                echo "cc/claude-fable-5|500000" ;;
        opus|cc/claude-opus-4-8)                echo "cc/claude-opus-4-8|500000" ;;
        sonnet|cc/claude-sonnet-5)              echo "cc/claude-sonnet-5|200000" ;;
        haiku|cc/claude-haiku-4-5-20251001)     echo "cc/claude-haiku-4-5-20251001|200000" ;;
        gpt5|cx/gpt-5.5)                        echo "cx/gpt-5.5|128000" ;;
        glm5|glm/glm-5.2)                       echo "glm/glm-5.2|500000" ;;
        glmturbo|glm/glm-5-turbo)               echo "glm/glm-5-turbo|500000" ;;
        deepseek|ds/deepseek-v4-pro)            echo "ds/deepseek-v4-pro|500000" ;;
        dsflash|ds/deepseek-v4-flash)           echo "ds/deepseek-v4-flash|500000" ;;
        kimi|kimi/kimi-k2.7)                    echo "kimi/kimi-k2.7|500000" ;;
        grok|xai/grok-4.5)                      echo "xai/grok-4.5|500000" ;;
        grokcomposer|xai/grok-composer-2.5-fast) echo "xai/grok-composer-2.5-fast|500000" ;;
        minimax|minimax/MiniMax-M3)             echo "minimax/MiniMax-M3|500000" ;;
        *) return 1 ;;
    esac
}

cascade_for() {
    case "$1" in
        opus) echo "cc/claude-opus-4-8 cx/gpt-5.5-high glm/glm-5.2-max" ;;
        free) echo "openrouter/poolside/laguna-xs-2.1:free openrouter/nvidia/nemotron-3-ultra-550b-a55b:free openrouter/nvidia/nemotron-3.5-content-safety:free openrouter/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free openrouter/google/gemma-4-26b-a4b-it:free openrouter/nvidia/nemotron-3-super-120b-a12b:free openrouter/qwen/qwen3-next-80b-a3b-instruct:free openrouter/openai/gpt-oss-120b:free openrouter/qwen/qwen3-coder:free openrouter/nousresearch/hermes-3-llama-3.1-405b:free" ;;
        *) return 1 ;;
    esac
}

# Pure: from newline-separated tag list, prefer highest 9cc-v*, else highest legacy v*
pick_latest_9cc_tag() {
    local list="${1:-}" ver=""
    ver="$(printf '%s\n' "$list" | grep -E '^9cc-v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sed 's/^9cc-v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1 || true)"
    if [ -n "$ver" ]; then
        printf '9cc-v%s' "$ver"
        return 0
    fi
    ver="$(printf '%s\n' "$list" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1 || true)"
    if [ -n "$ver" ]; then
        printf 'v%s' "$ver"
        return 0
    fi
    return 1
}

get_latest_tag() {
    local tags="" resp=""
    if [ -n "${CC9_LATEST_API_FIXTURE:-}" ]; then
        if [ ! -f "$CC9_LATEST_API_FIXTURE" ]; then return 1; fi
        resp="$(cat "$CC9_LATEST_API_FIXTURE")" || return 1
        tags="$(printf '%s' "$resp" \
            | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | sed -E 's/.*"([^"]+)".*/\1/')" || true
        [ -n "$tags" ] || return 1
        pick_latest_9cc_tag "$tags"
        return $?
    fi
    if command -v gh >/dev/null 2>&1; then
        tags="$(gh api "repos/investtal/investtal-toolchain/releases?per_page=100" --jq '.[].tag_name' 2>/dev/null)" || return 1
    else
        command -v curl >/dev/null 2>&1 || { echo "9cc update: curl not found" >&2; return 1; }
        tags="$(curl -fsSL --max-time 30 \
            'https://api.github.com/repos/investtal/investtal-toolchain/releases?per_page=100' 2>/dev/null \
            | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | sed -E 's/.*"([^"]+)".*/\1/')" || return 1
    fi
    [ -n "$tags" ] || return 1
    pick_latest_9cc_tag "$tags"
}

do_update() {
    local latest
    latest="$(get_latest_tag)" || { echo "9cc update: failed to reach GitHub" >&2; return 1; }
    if [ "$latest" = "$CC9_VERSION" ]; then
        echo "9cc is up to date ($CC9_VERSION)"
        return 0
    fi
    echo "9cc update: $CC9_VERSION -> $latest" >&2
    local install_src="https://raw.githubusercontent.com/investtal/investtal-toolchain/$latest/9cc/install.sh"
    if [ -n "${CC9_INSTALL_SOURCE:-}" ]; then
        install_src="$CC9_INSTALL_SOURCE"
        if [ -f "$install_src" ]; then
            CC9_VERSION="$latest" bash "$install_src" || return 1
        else
            echo "9cc update: installer source not found" >&2
            return 1
        fi
    else
        local script=""
        if command -v gh >/dev/null 2>&1; then
            local b64
            b64="$(gh api "repos/investtal/investtal-toolchain/contents/9cc/install.sh?ref=$latest" --jq '.content' 2>/dev/null)" || b64=""
            if [ -n "$b64" ]; then
                script="$(printf '%s' "$b64" | tr -d '[:space:]' | base64 -d 2>/dev/null)" || script=""
            fi
        fi
        if [ -z "$script" ]; then
            script="$(curl -fsSL --max-time 120 "$install_src" 2>/dev/null)" || script=""
        fi
        [ -n "$script" ] || { echo "9cc update: failed to fetch installer" >&2; return 1; }
        printf '%s\n' "$script" | CC9_VERSION="$latest" bash || return 1
    fi
    echo "9cc updated to $latest" >&2
    echo "9cc $latest"
    # bash 3.2 (macOS) re-parses the replaced script after self-update → syntax error.
    exit 0
}
do_uninstall() {
    local home="${CC9_HOME:-$HOME/.9cc}"
    local bin
    bin="$(command -v 9cc 2>/dev/null || true)"
    if [ -n "$bin" ] && [ -L "$bin" ]; then
        local target
        target="$(readlink "$bin" 2>/dev/null || true)"
        if [ "$target" = "$home/9cc.sh" ]; then
            rm -f "$bin"
            echo "removed: $bin"
        else
            echo "9cc uninstall: $bin does not point to $home/9cc.sh; leaving symlink" &&2
        fi
    fi
    if [ -d "$home" ]; then
        rm -rf "$home"
        echo "removed: $home"
    fi
    echo "9cc uninstalled"
}

# ponytail: cascade hardcoded flat; extract to models.json when >2 tiers
next_model() {
    local current="$1"; shift
    local props; if props="$(get_model "$current")"; then current="${props%%|*}"; fi
    local allow_free=1
    [ "${1:-}" = "--no-free" ] && allow_free=0
    local chain; chain="$(cascade_for opus)"
    [ "$allow_free" = "1" ] && chain="$chain $(cascade_for free)"
    local found=0 succ=""
    local m
    for m in $chain; do
        if [ "$found" = "1" ]; then succ="$m"; break; fi
        [ "$m" = "$current" ] && found=1
    done
    [ -n "$succ" ] || return 1
    printf '%s' "$succ"
}

show_help() {
    cat <<'EOF'
9cc — Claude Code model switcher over 9Router
Usage:
  9cc list                       List supported models
  9cc run <alias|id> [--sandbox] Launch claude with that model (extra args forwarded)
  9cc sandbox build              Build the sandbox Docker image
  9cc next <id> [--no-free]      Print the next model in the cascade
  9cc update                     Update 9cc to the latest release
  9cc uninstall                  Remove 9cc (home directory and PATH symlink)
  9cc version                    Print version
  9cc help                       Show this help
Shortcuts: fable opus sonnet haiku gpt5 glm5 glmturbo deepseek dsflash kimi grok grokcomposer minimax
In-session: type /model <id> (e.g. /model glm/glm-5.2) to switch without restarting.
EOF
}

list_models() {
    if [ "${1:-}" = "--json" ]; then
        local entries="" a id win rest
        for row in \
            "fable|cc/claude-fable-5|500000" "opus|cc/claude-opus-4-8|500000" "sonnet|cc/claude-sonnet-5|200000" \
            "haiku|cc/claude-haiku-4-5-20251001|200000" "gpt5|cx/gpt-5.5|128000" "glm5|glm/glm-5.2|500000" \
            "glmturbo|glm/glm-5-turbo|500000" "deepseek|ds/deepseek-v4-pro|500000" "dsflash|ds/deepseek-v4-flash|500000" \
            "kimi|kimi/kimi-k2.7|500000" "grok|xai/grok-4.5|500000" "grokcomposer|xai/grok-composer-2.5-fast|500000" \
            "minimax|minimax/MiniMax-M3|500000"; do
            a="${row%%|*}"; rest="${row#*|}"; id="${rest%%|*}"; win="${rest##*|}"
            entries="${entries}{\"alias\":\"$a\",\"id\":\"$id\",\"window\":$win},"
        done
        printf '[%s]\n' "${entries%,}"
        return
    fi
    printf '%-14s %-32s %s\n' "ALIAS" "9ROUTER_ID" "WINDOW"
    local a id win rest
    for row in \
        "fable|cc/claude-fable-5|500000" "opus|cc/claude-opus-4-8|500000" "sonnet|cc/claude-sonnet-5|200000" \
        "haiku|cc/claude-haiku-4-5-20251001|200000" "gpt5|cx/gpt-5.5|128000" "glm5|glm/glm-5.2|500000" \
        "glmturbo|glm/glm-5-turbo|500000" "deepseek|ds/deepseek-v4-pro|500000" "dsflash|ds/deepseek-v4-flash|500000" \
        "kimi|kimi/kimi-k2.7|500000" "grok|xai/grok-4.5|500000" "grokcomposer|xai/grok-composer-2.5-fast|500000" \
        "minimax|minimax/MiniMax-M3|500000"; do
        a="${row%%|*}"; rest="${row#*|}"; id="${rest%%|*}"; win="${rest##*|}"
        printf '%-14s %-32s %s\n' "$a" "$id" "$win"
    done
}

read_setting() {
    [ -f "$CLAUDE_SETTINGS" ] || { echo "9cc: settings not found at $CLAUDE_SETTINGS" >&2; return 1; }
    local key="$1" v=""
    if command -v node >/dev/null 2>&1; then
        v="$(CLAUDE_SETTINGS="$CLAUDE_SETTINGS" node -e '
            const fs=require("fs"); let s={};
            try{ s=JSON.parse(fs.readFileSync(process.env.CLAUDE_SETTINGS,"utf8")); }catch(e){ process.exit(1); }
            const v=(s.env||{})[process.argv[1]];
            if(!v) process.exit(1);
            process.stdout.write(v);
        ' "$key" 2>/dev/null)" || v=""
    fi
    if [ -z "$v" ]; then
        v="$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CLAUDE_SETTINGS" \
            | sed -E 's/.*:[[:space:]]*"(.*)"$/\1/' | head -n1)"
        v="${v//\\\"/\"}"; v="${v//\\\\/\\}"; v="${v//\\n/$'\n'}"; v="${v//\\t/$'\t'}"
    fi
    [ -n "$v" ] || { echo "9cc: '$key' not found in $CLAUDE_SETTINGS env" >&2; return 1; }
    printf '%s' "$v"
}

tier_defaults() {
    local id="$1"
    case "$id" in
        cc/claude-fable-5|cc/claude-opus-4-8|cc/claude-sonnet-5|cc/claude-haiku-4-5-20251001)
            if [ "$id" = "cc/claude-fable-5" ]; then
                printf '%s' "cc/claude-fable-5|cc/claude-sonnet-5|cc/claude-haiku-4-5-20251001"
            else
                printf '%s' "cc/claude-opus-4-8|cc/claude-sonnet-5|cc/claude-haiku-4-5-20251001"
            fi
            ;;
        xai/grok-4.5|xai/grok-composer-2.5-fast)
            printf '%s' "xai/grok-4.5|xai/grok-4.5|xai/grok-composer-2.5-fast"
            ;;
        *)
            printf '%s' "$id|$id|$id"
            ;;
    esac
}

run_session() {
    command -v claude >/dev/null 2>&1 || { echo "9cc: claude command not found. Please install Claude Code first." >&2; return 1; }
    local key="$1"; shift || true
    local props; props="$(get_model "$key")" || { echo "9cc: unknown model '$key'. Run '9cc list'." >&2; return 1; }
    local id="${props%%|*}"; local win="${props##*|}"
    local base token
    base="$(read_setting ANTHROPIC_BASE_URL)" || return 1
    token="$(read_setting ANTHROPIC_API_KEY)" || return 1
    local tiers opus sonnet haiku rest
    tiers="$(tier_defaults "$id")"
    opus="${tiers%%|*}"; rest="${tiers#*|}"; sonnet="${rest%%|*}"; haiku="${rest##*|}"
    export ANTHROPIC_BASE_URL="$base"
    export ANTHROPIC_API_KEY="$token"
    export ANTHROPIC_MODEL="$id"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$opus"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$sonnet"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$haiku"
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$win"
    echo "9cc -> $id (window $win)" >&2
    exec claude "$@"
}

main() {
    case "${1:-help}" in
        list) shift || true; list_models "$@" ;;
        run)  shift || true
         local use_sandbox=0
         if [ "${1:-}" = "--sandbox" ]; then use_sandbox=1; shift; fi
         if [ "${2:-}" = "--sandbox" ]; then use_sandbox=1; local m="$1"; shift 2; set -- "$m" "$@"; fi
         [ "${1:-}" ] || { echo "9cc: missing model. Usage: 9cc run <alias|id> [--sandbox]" >&2; return 1; }
         if [ "$use_sandbox" = "1" ]; then
             local props id win tiers base token opus sonnet haiku rest
             props="$(get_model "$1")" || { echo "9cc: unknown model '$1'. Run '9cc list'." >&2; return 1; }
             id="${props%%|*}"; win="${props##*|}"
             tiers="$(tier_defaults "$id")"
             opus="${tiers%%|*}"; rest="${tiers#*|}"; sonnet="${rest%%|*}"; haiku="${rest##*|}"
             base="$(read_setting ANTHROPIC_BASE_URL)" || return 1
             token="$(read_setting ANTHROPIC_API_KEY)" || return 1
             export ANTHROPIC_MODEL="$id"
             export ANTHROPIC_DEFAULT_OPUS_MODEL="$opus"
             export ANTHROPIC_DEFAULT_SONNET_MODEL="$sonnet"
             export ANTHROPIC_DEFAULT_HAIKU_MODEL="$haiku"
             export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$win"
             export ANTHROPIC_BASE_URL="$base"
             export ANTHROPIC_API_KEY="$token"
             local sandbox_script="$CC9_HOME/sandbox.sh"
             [ -f "$sandbox_script" ] || sandbox_script="$DIR/sandbox.sh"
             export CC9_SANDBOX_DIR="$DIR"
             source "$sandbox_script"
             run_sandboxed "$@"
         else
             run_session "$@"
         fi
         ;;
    sandbox) shift || true
        local sandbox_script="$CC9_HOME/sandbox.sh"
        [ -f "$sandbox_script" ] || sandbox_script="$DIR/sandbox.sh"
        export CC9_SANDBOX_DIR="$DIR"
        source "$sandbox_script"
        case "${1:-}" in
            build) shift || true; build_image ;;
            *)     echo "9cc sandbox: usage: 9cc sandbox build" >&2; return 1 ;;
        esac
        ;;
        next) shift || true; [ "${1:-}" ] || { echo "9cc: missing current model. Usage: 9cc next <id> [--no-free]" >&2; return 1; }; local s; s="$(next_model "$@")" || { echo "9cc: no successor for '$1'" >&2; return 1; }; printf '%s\n' "$s" ;;
        update) do_update ;;
        uninstall) do_uninstall ;;
        version|-v|--version) echo "9cc $CC9_VERSION" ;;
        help|-h|--help) show_help ;;
        *) echo "9cc: unknown command '$1'. Run '9cc help'." >&2; return 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then main "$@"; fi
