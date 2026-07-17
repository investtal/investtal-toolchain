#!/usr/bin/env bash
set -euo pipefail
# Usage: create-tag-and-push.sh <tool> <bare-version>
# Expects version file already bumped. Commits version file, creates annotated
# tag {tool}-v{ver}, and pushes HEAD:main + the tag.
# Env:
#   GH_TOKEN or GITHUB_TOKEN — if set, push via one-shot HTTPS URL (token not
#     written into origin remote config)
#   GIT_USERNAME — optional (default x-access-token)
#   GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL — commit identity
#   BRANCH_NAME / GIT_BRANCH — Jenkins branch indicators (must be main for push)
# shellcheck source=/dev/null
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

tool="${1:?tool}"
ver="${2:?version}"
load_tool "$tool"
tag="${tool}-v${ver}"
cd "$REPO_ROOT"

git config user.name "${GIT_AUTHOR_NAME:-investtal-infra}"
git config user.email "${GIT_AUTHOR_EMAIL:-infra.dev@investtal.com}"

# Refuse HEAD:main push unless on main (local branch or Jenkins env).
# Detached HEAD on Jenkins still has BRANCH_NAME/GIT_BRANCH=main.
require_main_for_push() {
  local current_branch env_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  env_branch="${BRANCH_NAME:-${GIT_BRANCH:-}}"
  # origin/main or refs/heads/main → main
  env_branch="${env_branch##*/}"
  if [[ "$current_branch" == "main" || "$env_branch" == "main" ]]; then
    return 0
  fi
  die "refusing git push origin HEAD:main: not on main (branch='${current_branch:-?}' BRANCH_NAME/GIT_BRANCH='${BRANCH_NAME:-${GIT_BRANCH:-}}')"
}

tag_exists=0
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  tag_exists=1
  echo "tag $tag already exists — skip create"
fi

if [[ "$tag_exists" -eq 0 ]]; then
  git add "$VERSION_FILE"
  # Companion CLI VERSION const (atlassian/src/cli/root.zig) kept in sync by write_version
  if [[ "${VERSION_KIND:-}" == "zig.zon" ]]; then
    _cli_root="$(dirname "$VERSION_FILE")/src/cli/root.zig"
    [[ -f "$_cli_root" ]] && git add "$_cli_root"
  fi
  # include only version file(s) for clean release commits
  if git commit -m "chore(release): ${tool} v${ver} [skip ci]"; then
    :
  else
    # nothing to commit (already at version)
    echo "no version commit needed"
  fi
  git tag -a "$tag" -m "Release ${tag}"
fi

# Always ensure tag (+ commit) are pushed when we reach here — including
# the tag-already-exists path so a re-run can finish publish after partial failure.
# Push via URL once — do NOT rewrite origin (avoids persisting token in remote config).
require_main_for_push
if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
  user="${GIT_USERNAME:-x-access-token}"
  token="${GH_TOKEN:-$GITHUB_TOKEN}"
  push_url="https://${user}:${token}@github.com/investtal/investtal-toolchain.git"
  git push "$push_url" HEAD:main
  git push "$push_url" "refs/tags/${tag}"
else
  git push origin HEAD:main
  git push origin "refs/tags/${tag}"
fi
echo "pushed $tag"
