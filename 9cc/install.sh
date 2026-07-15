#!/usr/bin/env bash
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
    [ -n "$CC9_VERSION" ] || CC9_VERSION="v0.5.4"
fi
CC9_SOURCE="${CC9_SOURCE:-}"
if [ -z "${CC9_BIN_DIR:-}" ]; then
    for c in /usr/local/bin "$HOME/.local/bin"; do
        if mkdir -p "$c" 2>/dev/null && [ -w "$c" ]; then CC9_BIN_DIR="$c"; break; fi
    done
fi
if [ -z "${CC9_BIN_DIR:-}" ]; then echo "install: no writable bin dir found (set CC9_BIN_DIR)" >&2; exit 1; fi

mkdir -p "$CC9_HOME" "$CC9_BIN_DIR"

atomic_install() {
    local dest="$1"
    local dir tmp
    dir="$(dirname "$dest")"
    mkdir -p "$dir"
    tmp="$(mktemp "${dir}/.9cc-install.XXXXXX")" || return 1
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dest"
}

if [ -n "$CC9_SOURCE" ] && [ -f "$CC9_SOURCE" ]; then
    atomic_install "$CC9_HOME/9cc.sh" < "$CC9_SOURCE"
elif [ -n "$CC9_SOURCE" ]; then
    tmp="$(mktemp "${CC9_HOME}/.9cc-install.XXXXXX")"
    curl -fsSL "$CC9_SOURCE" -o "$tmp"
    mv -f "$tmp" "$CC9_HOME/9cc.sh"
else
    fetched=0
    if command -v gh >/dev/null 2>&1; then
        if content="$(gh api "repos/investtal/investtal-toolchain/contents/9cc/9cc.sh?ref=$CC9_VERSION" --jq '.content' 2>/dev/null)"; then
            if [ -n "$content" ]; then
                tmp="$(mktemp "${CC9_HOME}/.9cc-install.XXXXXX")"
                if printf '%s' "$content" | tr -d '[:space:]' | base64 -d > "$tmp" 2>/dev/null; then
                    mv -f "$tmp" "$CC9_HOME/9cc.sh"
                    fetched=1
                else
                    rm -f "$tmp"
                fi
            fi
        fi
    fi
    if [ "$fetched" != "1" ]; then
        raw="https://raw.githubusercontent.com/investtal/investtal-toolchain/$CC9_VERSION/9cc/9cc.sh"
        tmp="$(mktemp "${CC9_HOME}/.9cc-install.XXXXXX")"
        curl -fsSL "$raw" -o "$tmp"
        mv -f "$tmp" "$CC9_HOME/9cc.sh"
    fi
fi
chmod +x "$CC9_HOME/9cc.sh"
printf '%s\n' "$CC9_VERSION" > "$CC9_HOME/version"

install_asset() {
    local name="$1" src tmp
    if [ -n "${CC9_SOURCE:-}" ] && [ -f "$CC9_SOURCE" ]; then
        src="$(dirname "$CC9_SOURCE")/$name"
        if [ -f "$src" ]; then
            atomic_install "$CC9_HOME/$name" < "$src"
        fi
        return 0
    fi
    src="https://raw.githubusercontent.com/investtal/investtal-toolchain/$CC9_VERSION/9cc/$name"
    tmp="$(mktemp "${CC9_HOME}/.9cc-install.XXXXXX")"
    if curl -fsSL "$src" -o "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$CC9_HOME/$name"
    else
        rm -f "$tmp"
        echo "install: warning: could not fetch $name from $src" >&2
    fi
}
for f in Dockerfile agent-proxy.mjs sandbox-entrypoint.sh sandbox.sh; do
    install_asset "$f"
done

ln -sfn "$CC9_HOME/9cc.sh" "$CC9_BIN_DIR/9cc"

echo "9cc installed: $CC9_HOME/9cc.sh"
echo "symlink:       $CC9_BIN_DIR/9cc  (ensure it's on your PATH)"
