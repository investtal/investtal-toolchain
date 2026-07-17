#!/usr/bin/env bash
# Ensure Zig compiler matching ZIG_VERSION is on PATH.
# Source after lib.sh (needs REPO_ROOT, die) then call ensure_zig.
# Official tarball naming (0.16.0): zig-{arch}-{os}-{version}.tar.xz
#   e.g. zig-x86_64-linux-0.16.0.tar.xz, zig-aarch64-macos-0.16.0.tar.xz
# shellcheck shell=bash

ensure_zig() {
  local want="${ZIG_VERSION:-0.16.0}"
  local v os arch tarball url cache

  if command -v zig >/dev/null 2>&1; then
    v="$(zig version 2>/dev/null || true)"
    # Accept exact pin or any 0.16.x (patch-compatible with build.zig.zon pin)
    if [[ "$v" == "$want" ]] || [[ "$v" == "$want".* ]] || [[ "$v" == "0.16."* ]]; then
      return 0
    fi
    echo "release: zig $v on PATH; need $want — bootstrapping" >&2
  fi

  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=x86_64 ;;
    arm64|aarch64) arch=aarch64 ;;
    *) die "unsupported host arch for zig bootstrap: $arch" ;;
  esac
  case "$os" in
    darwin) os=macos ;;
    linux) os=linux ;;
    *) die "unsupported host OS for zig bootstrap: $os" ;;
  esac

  # Official: https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
  tarball="zig-${arch}-${os}-${want}.tar.xz"
  url="https://ziglang.org/download/${want}/${tarball}"
  cache="${REPO_ROOT}/.cache/zig-sdk"
  mkdir -p "$cache"

  if [[ -x "$cache/zig" ]]; then
    v="$("$cache/zig" version 2>/dev/null || true)"
    if [[ "$v" == "$want" ]] || [[ "$v" == "$want".* ]] || [[ "$v" == "0.16."* ]]; then
      export PATH="$cache:$PATH"
      return 0
    fi
    # Stale cache — wipe and re-fetch
    rm -rf "$cache"
    mkdir -p "$cache"
  fi

  echo "release: downloading $url" >&2
  curl -fsSL "$url" -o "$cache/$tarball"
  tar -xJf "$cache/$tarball" -C "$cache" --strip-components=1
  rm -f "$cache/$tarball"
  [[ -x "$cache/zig" ]] || die "zig binary missing after extract into $cache"
  export PATH="$cache:$PATH"
  v="$(zig version)"
  echo "release: zig $v ready" >&2
}

# Allow direct execution for manual bootstrap
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
  ensure_zig
  zig version
fi
