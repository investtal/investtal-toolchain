#!/usr/bin/env bash
set -euo pipefail
# Usage: publish-github-release.sh <tag> [asset-dir]
# Creates GitHub Release for tag (idempotent) and optionally uploads assets.
# Requires: gh CLI; GH_TOKEN or GITHUB_TOKEN
# Env: GITHUB_REPOSITORY (default investtal/investtal-toolchain)
# shellcheck source=/dev/null
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

tag="${1:?tag}"
asset_dir="${2:-}"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN required"
REPO="${GITHUB_REPOSITORY:-investtal/investtal-toolchain}"

if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
  echo "release $tag exists"
else
  gh release create "$tag" --repo "$REPO" --title "$tag" --generate-notes
fi

if [[ -n "$asset_dir" && -d "$asset_dir" ]]; then
  # Collect files portably (bash 3.2: no mapfile; avoid empty $(find) arg)
  assets=()
  _assets_tmp="$(mktemp)"
  find "$asset_dir" -type f >"$_assets_tmp" || true
  while IFS= read -r f || [[ -n "$f" ]]; do
    [[ -n "$f" ]] && assets+=("$f")
  done <"$_assets_tmp"
  rm -f "$_assets_tmp"
  if [[ ${#assets[@]} -gt 0 ]]; then
    gh release upload "$tag" --repo "$REPO" --clobber "${assets[@]}"
  else
    echo "no assets under $asset_dir — skip upload"
  fi
fi

echo "published $tag"
