#!/usr/bin/env bash
# 9cc — launch Claude Code with a dynamic model over the 9Router gateway.
# Reads auth from ~/.claude/settings.json (read-only). Mac/Linux/WSL.
# Usage: 9cc list | 9cc run <alias-or-id> [claude args...] | 9cc help
set -euo pipefail

CC9_VERSION="${CC9_VERSION:-0.1.0-dev}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

# get_model <alias-or-id> -> echo "<9RouterID>|<window>"; exit 1 if unknown.
get_model() {
    case "$1" in
        fable|cc/fable-5)                       echo "cc/fable-5|200000" ;;
        opus|cc/claude-opus-4-8)                echo "cc/claude-opus-4-8|200000" ;;
        sonnet|cc/claude-sonnet-5)              echo "cc/claude-sonnet-5|200000" ;;
        haiku|cc/claude-haiku-4-5-20251001)     echo "cc/claude-haiku-4-5-20251001|200000" ;;
        gpt5|cx/gpt-5.5)                        echo "cx/gpt-5.5|128000" ;;
        glm5|glm/glm-5.2)                       echo "glm/glm-5.2|1000000" ;;
        glmturbo|glm/glm-5-turbo)               echo "glm/glm-5-turbo|1000000" ;;
        deepseek|ds/deepseek-v4-pro)            echo "ds/deepseek-v4-pro|1000000" ;;
        dsflash|ds/deepseek-v4-flash)           echo "ds/deepseek-v4-flash|1000000" ;;
        kimi|kimi/kimi-k2.7)                    echo "kimi/kimi-k2.7|1000000" ;;
        grok|gc/grok-build)                     echo "gc/grok-build|500000" ;;
        grokcomposer|gc/grok-composer-2.5-fast) echo "gc/grok-composer-2.5-fast|500000" ;;
        minimax|minimax/MiniMax-M3)             echo "minimax/MiniMax-M3|1000000" ;;
        *) return 1 ;;
    esac
}

# Tiered cascade chains (spec §8 OPUS_FALLBACK + §9 FREE_CASCADE). 9cc is the single
# source of model truth; the fleet healer asks `9cc next` to advance through these.
cascade_for() {
    case "$1" in
        opus) echo "cc/claude-opus-4-8 cx/gpt-5.5-high glm/glm-5.2-max" ;;
        free) echo "openrouter/poolside/laguna-xs-2.1:free openrouter/nvidia/nemotron-3-ultra-550b-a55b:free openrouter/nvidia/nemotron-3.5-content-safety:free openrouter/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free openrouter/google/gemma-4-26b-a4b-it:free openrouter/nvidia/nemotron-3-super-120b-a12b:free openrouter/qwen/qwen3-next-80b-a3b-instruct:free openrouter/openai/gpt-oss-120b:free openrouter/qwen/qwen3-coder:free openrouter/nousresearch/hermes-3-llama-3.1-405b:free" ;;
        *) return 1 ;;
    esac
}

# next_model <current> [--no-free] -> echo successor ID; exit 1 if none / unknown.
# Walks opus chain first, then the free cascade (unless --no-free). Unknown current -> exit 1.
# ponytail: cascade hardcoded flat; extract to models.json when >2 tiers
next_model() {
    local current="$1"; shift
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
  9cc run <alias|id> [args...]   Launch claude with that model (extra args forwarded)
  9cc next <id> [--no-free]      Print the next model in the cascade
  9cc version                    Print version
  9cc help                       Show this help
Shortcuts: fable opus sonnet haiku gpt5 glm5 glmturbo deepseek dsflash kimi grok grokcomposer minimax
In-session: type /model <id> (e.g. /model glm/glm-5.2) to switch without restarting.
EOF
}

list_models() {
    if [ "${1:-}" = "--json" ]; then
        # Machine-readable registry (fleet consumes this). node emits JSON; avoids
        # hand-rolling array/quote escaping. 9cc requires node anyway (read_setting).
        local entries="" a id win rest
        for row in \
            "fable|cc/fable-5|200000" "opus|cc/claude-opus-4-8|200000" "sonnet|cc/claude-sonnet-5|200000" \
            "haiku|cc/claude-haiku-4-5-20251001|200000" "gpt5|cx/gpt-5.5|128000" "glm5|glm/glm-5.2|1000000" \
            "glmturbo|glm/glm-5-turbo|1000000" "deepseek|ds/deepseek-v4-pro|1000000" "dsflash|ds/deepseek-v4-flash|1000000" \
            "kimi|kimi/kimi-k2.7|1000000" "grok|gc/grok-build|500000" "grokcomposer|gc/grok-composer-2.5-fast|500000" \
            "minimax|minimax/MiniMax-M3|1000000"; do
            a="${row%%|*}"; rest="${row#*|}"; id="${rest%%|*}"; win="${rest##*|}"
            entries="${entries}{\"alias\":\"$a\",\"id\":\"$id\",\"window\":$win},"
        done
        printf '[%s]\n' "${entries%,}"
        return
    fi
    printf '%-14s %-32s %s\n' "ALIAS" "9ROUTER_ID" "WINDOW"
    local a id win rest
    for row in \
        "fable|cc/fable-5|200000" "opus|cc/claude-opus-4-8|200000" "sonnet|cc/claude-sonnet-5|200000" \
        "haiku|cc/claude-haiku-4-5-20251001|200000" "gpt5|cx/gpt-5.5|128000" "glm5|glm/glm-5.2|1000000" \
        "glmturbo|glm/glm-5-turbo|1000000" "deepseek|ds/deepseek-v4-pro|1000000" "dsflash|ds/deepseek-v4-flash|1000000" \
        "kimi|kimi/kimi-k2.7|1000000" "grok|gc/grok-build|500000" "grokcomposer|gc/grok-composer-2.5-fast|500000" \
        "minimax|minimax/MiniMax-M3|1000000"; do
        a="${row%%|*}"; rest="${row#*|}"; id="${rest%%|*}"; win="${rest##*|}"
        printf '%-14s %-32s %s\n' "$a" "$id" "$win"
    done
}

read_setting() {
    command -v node >/dev/null 2>&1 || { echo "9cc: node not found (required to read settings.json)" >&2; return 1; }
    local v; v="$(CLAUDE_SETTINGS="$CLAUDE_SETTINGS" node -e '
        const fs=require("fs"); let s={};
        try{ s=JSON.parse(fs.readFileSync(process.env.CLAUDE_SETTINGS,"utf8")); }catch(e){ process.exit(1); }
        const v=(s.env||{})[process.argv[1]];
        if(!v) process.exit(1);
        process.stdout.write(v);
    ' "$1")" || { echo "9cc: '$1' not found in $CLAUDE_SETTINGS env" >&2; return 1; }
    printf '%s' "$v"
}

run_session() {
    command -v claude >/dev/null 2>&1 || { echo "9cc: claude command not found. Please install Claude Code first." >&2; return 1; }
    local key="$1"; shift || true
    local props; props="$(get_model "$key")" || { echo "9cc: unknown model '$key'. Run '9cc list'." >&2; return 1; }
    local id="${props%%|*}"; local win="${props##*|}"
    local base token
    base="$(read_setting ANTHROPIC_BASE_URL)" || return 1
    token="$(read_setting ANTHROPIC_API_KEY)" || return 1
    export ANTHROPIC_BASE_URL="$base"
    export ANTHROPIC_API_KEY="$token"
    export ANTHROPIC_MODEL="$id"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$id"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$id"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$id"
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$win"
    echo "9cc -> $id (window $win)" >&2
    exec claude "$@"
}

main() {
    case "${1:-help}" in
        list) shift || true; list_models "$@" ;;
        run)  shift || true; [ "${1:-}" ] || { echo "9cc: missing model. Usage: 9cc run <alias|id>" >&2; return 1; }; run_session "$@" ;;
        next) shift || true; [ "${1:-}" ] || { echo "9cc: missing current model. Usage: 9cc next <id> [--no-free]" >&2; return 1; }; local s; s="$(next_model "$@")" || { echo "9cc: no successor for '$1'" >&2; return 1; }; printf '%s\n' "$s" ;;
        version|-v|--version) echo "9cc $CC9_VERSION" ;;
        help|-h|--help) show_help ;;
        *) echo "9cc: unknown command '$1'. Run '9cc help'." >&2; return 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then main "$@"; fi
