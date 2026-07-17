#!/usr/bin/env bash
set -euo pipefail
# Usage: bump-version.sh <tool> <major|minor|patch>
# Prints new bare semver on stdout
# shellcheck source=/dev/null
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
tool="${1:?tool}"; level="${2:?level}"
load_tool "$tool"
file="$REPO_ROOT/$VERSION_FILE"
[[ -f "$file" ]] || die "missing version file: $file"
cur="$(read_version "$file" "$VERSION_KIND")"
new="$(semver_bump "$cur" "$level")"
write_version "$file" "$VERSION_KIND" "$new"
printf '%s\n' "$new"
