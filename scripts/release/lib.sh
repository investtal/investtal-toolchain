#!/usr/bin/env bash
# Shared helpers for scripts/release/*
set -euo pipefail

RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$RELEASE_ROOT/../.." && pwd)"
MANIFEST="${RELEASE_ROOT}/tools.manifest"

die() { echo "release: $*" >&2; exit 1; }

# Read manifest line for tool → sets NAME KIND VERSION_FILE VERSION_KIND PATH_GLOBS
load_tool() {
  local tool="$1" line
  line="$(grep -E "^${tool}\\|" "$MANIFEST" | head -n1 || true)"
  [[ -n "$line" ]] || die "unknown tool: $tool"
  IFS='|' read -r NAME KIND VERSION_FILE VERSION_KIND PATH_GLOBS <<<"$line"
}

semver_bump() {
  local ver="$1" level="$2"
  local major minor patch
  IFS='.' read -r major minor patch <<<"$ver"
  major=${major//[^0-9]/}
  minor=${minor//[^0-9]/}
  patch=${patch//[^0-9]/}
  [[ -n "$major" && -n "$minor" && -n "$patch" ]] || die "invalid semver: $ver"
  case "$level" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) die "invalid bump level: $level" ;;
  esac
  printf '%s.%s.%s' "$major" "$minor" "$patch"
}

read_version() {
  local file="$1" kind="$2"
  case "$kind" in
    plain)
      tr -d '[:space:]' <"$file"
      ;;
    zig.zon)
      # .version = "0.1.0",
      # Use [[:space:]] not \s — BSD grep (macOS) does not support \s
      grep -E '^[[:space:]]*\.version[[:space:]]*=' "$file" | head -n1 \
        | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/'
      ;;
    *) die "unknown version_kind: $kind" ;;
  esac
}

# Sync atlassian CLI `pub const VERSION` with build.zig.zon when present.
# Companion path: <pkg>/build.zig.zon → <pkg>/src/cli/root.zig
sync_cli_version_const() {
  local zon_file="$1" ver="$2"
  local cli_root tmp
  cli_root="$(dirname "$zon_file")/src/cli/root.zig"
  [[ -f "$cli_root" ]] || return 0
  tmp="$(mktemp)"
  # pub const VERSION = "0.1.0";
  sed -E "s/^(pub const VERSION = \")[0-9]+\\.[0-9]+\\.[0-9]+(\";.*)/\\1${ver}\\2/" \
    "$cli_root" >"$tmp"
  mv "$tmp" "$cli_root"
}

write_version() {
  local file="$1" kind="$2" ver="$3"
  case "$kind" in
    plain)
      printf '%s\n' "$ver" >"$file"
      ;;
    zig.zon)
      # portable: rewrite .version line only
      # Use [[:space:]] not \s — BSD sed/grep (macOS) do not support \s
      local tmp
      tmp="$(mktemp)"
      sed -E "s/^([[:space:]]*\\.version[[:space:]]*=[[:space:]]*\")[0-9]+\\.[0-9]+\\.[0-9]+(\".*)/\\1${ver}\\2/" \
        "$file" >"$tmp"
      mv "$tmp" "$file"
      # Keep CLI VERSION const in lockstep (single bump path)
      sync_cli_version_const "$file" "$ver"
      ;;
    *) die "unknown version_kind: $kind" ;;
  esac
}
