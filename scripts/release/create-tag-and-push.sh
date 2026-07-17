#!/usr/bin/env bash
set -euo pipefail
# Usage: create-tag-and-push.sh <tool> <bare-version>
# Expects version file already bumped. Commits version file, creates annotated
# tag {tool}-v{ver}, and pushes HEAD:main + the tag.
# Env:
#   GH_TOKEN or GITHUB_TOKEN — if set, rewrites origin to HTTPS with token
#   GIT_USERNAME — optional (default x-access-token)
#   GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL — commit identity
# shellcheck source=/dev/null
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

tool="${1:?tool}"
ver="${2:?version}"
load_tool "$tool"
tag="${tool}-v${ver}"
cd "$REPO_ROOT"

git config user.name "${GIT_AUTHOR_NAME:-investtal-infra}"
git config user.email "${GIT_AUTHOR_EMAIL:-infra.dev@investtal.com}"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "tag $tag already exists — skip create"
  exit 0
fi

git add "$VERSION_FILE"
# include only version file for clean release commits
if git commit -m "chore(release): ${tool} v${ver} [skip ci]"; then
  :
else
  # nothing to commit (already at version)
  echo "no version commit needed"
fi

git tag -a "$tag" -m "Release ${tag}"

if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
  user="${GIT_USERNAME:-x-access-token}"
  token="${GH_TOKEN:-$GITHUB_TOKEN}"
  git remote set-url origin "https://${user}:${token}@github.com/investtal/investtal-toolchain.git"
fi

git push origin HEAD:main
git push origin "$tag"
echo "pushed $tag"
