#!/usr/bin/env bash
# 9cc — launch Claude Code with a dynamic model over the 9Router gateway.
# Reads auth from ~/.claude/settings.json (read-only). Mac/Linux/WSL.
# Usage: 9cc list | 9cc run <alias-or-id> [claude args...] | 9cc help
set -euo pipefail

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

show_help() {
    cat <<'EOF'
9cc — Claude Code model switcher over 9Router
Usage:
  9cc list                       List supported models
  9cc run <alias|id> [args...]   Launch claude with that model (extra args forwarded)
  9cc help                       Show this help
Shortcuts: fable opus sonnet haiku gpt5 glm5 glmturbo deepseek dsflash kimi grok grokcomposer minimax
In-session: type /model <id> (e.g. /model glm/glm-5.2) to switch without restarting.
EOF
}

list_models() {
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
        list) list_models ;;
        run)  shift || true; [ "${1:-}" ] || { echo "9cc: missing model. Usage: 9cc run <alias|id>" >&2; return 1; }; run_session "$@" ;;
        help|-h|--help) show_help ;;
        *) echo "9cc: unknown command '$1'. Run '9cc help'." >&2; return 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then main "$@"; fi
