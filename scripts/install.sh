#!/usr/bin/env bash
# 9cc installer — curl -fsSL <raw url>/install.sh | bash
# Downloads 9cc.sh into ~/.9cc and symlinks `9cc` into a writable PATH dir.
set -euo pipefail

CC9_HOME="${CC9_HOME:-$HOME/.9cc}"
CC9_VERSION="${CC9_VERSION:-v0.3.1}"
CC9_SOURCE="${CC9_SOURCE:-https://raw.githubusercontent.com/investtal/investtal-toolchain/$CC9_VERSION/scripts/9cc.sh}"
# prefer explicit CC9_BIN_DIR, else first writable candidate
if [ -z "${CC9_BIN_DIR:-}" ]; then
    for c in /usr/local/bin "$HOME/.local/bin"; do
        if mkdir -p "$c" 2>/dev/null && [ -w "$c" ]; then CC9_BIN_DIR="$c"; break; fi
    done
fi
if [ -z "${CC9_BIN_DIR:-}" ]; then echo "install: no writable bin dir found (set CC9_BIN_DIR)" >&2; exit 1; fi

mkdir -p "$CC9_HOME" "$CC9_BIN_DIR"

if [ -f "$CC9_SOURCE" ]; then cp "$CC9_SOURCE" "$CC9_HOME/9cc.sh";     # local fixture / file:// (tests)
else curl -fsSL "$CC9_SOURCE" -o "$CC9_HOME/9cc.sh"; fi
chmod +x "$CC9_HOME/9cc.sh"

ln -sfn "$CC9_HOME/9cc.sh" "$CC9_BIN_DIR/9cc"

echo "9cc installed: $CC9_HOME/9cc.sh"
echo "symlink:       $CC9_BIN_DIR/9cc  (ensure it's on your PATH)"
