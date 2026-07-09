#!/usr/bin/env bash
# 9cc installer — prefer: gh api contents | base64 -d | bash
# Downloads 9cc.sh into ~/.9cc and symlinks `9cc` into a writable PATH dir.
set -euo pipefail

CC9_HOME="${CC9_HOME:-$HOME/.9cc}"
CC9_VERSION="${CC9_VERSION:-}"
if [ -z "$CC9_VERSION" ]; then
    if command -v gh >/dev/null 2>&1; then
        CC9_VERSION="$(gh api repos/investtal/investtal-toolchain/releases/latest --jq '.tag_name' 2>/dev/null || true)"
    else
        CC9_VERSION="$(curl -fsSL --max-time 10 'https://api.github.com/repos/investtal/investtal-toolchain/releases/latest' 2>/dev/null \
            | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | sed -E 's/.*"([^"]+)".*/\1/' \
            | head -n1)"
    fi
    [ -n "$CC9_VERSION" ] || CC9_VERSION="v0.3.5"
fi
CC9_SOURCE="${CC9_SOURCE:-}"
# prefer explicit CC9_BIN_DIR, else first writable candidate
if [ -z "${CC9_BIN_DIR:-}" ]; then
    for c in /usr/local/bin "$HOME/.local/bin"; do
        if mkdir -p "$c" 2>/dev/null && [ -w "$c" ]; then CC9_BIN_DIR="$c"; break; fi
    done
fi
if [ -z "${CC9_BIN_DIR:-}" ]; then echo "install: no writable bin dir found (set CC9_BIN_DIR)" >&2; exit 1; fi

mkdir -p "$CC9_HOME" "$CC9_BIN_DIR"

if [ -n "$CC9_SOURCE" ] && [ -f "$CC9_SOURCE" ]; then
    cp "$CC9_SOURCE" "$CC9_HOME/9cc.sh"     # local fixture / tests
elif [ -n "$CC9_SOURCE" ]; then
    curl -fsSL "$CC9_SOURCE" -o "$CC9_HOME/9cc.sh"
else
    fetched=0
    if command -v gh >/dev/null 2>&1; then
        if content="$(gh api "repos/investtal/investtal-toolchain/contents/9cc/9cc.sh?ref=$CC9_VERSION" --jq '.content' 2>/dev/null)"; then
            if [ -n "$content" ] && printf '%s' "$content" | base64 -d > "$CC9_HOME/9cc.sh" 2>/dev/null; then
                fetched=1
            fi
        fi
    fi
    if [ "$fetched" != "1" ]; then
        raw="https://raw.githubusercontent.com/investtal/investtal-toolchain/$CC9_VERSION/9cc/9cc.sh"
        curl -fsSL "$raw" -o "$CC9_HOME/9cc.sh"
    fi
fi
chmod +x "$CC9_HOME/9cc.sh"
printf '%s\n' "$CC9_VERSION" > "$CC9_HOME/version"

ln -sfn "$CC9_HOME/9cc.sh" "$CC9_BIN_DIR/9cc"

echo "9cc installed: $CC9_HOME/9cc.sh"
echo "symlink:       $CC9_BIN_DIR/9cc  (ensure it's on your PATH)"
