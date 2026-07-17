#!/usr/bin/env bash
set -euo pipefail
# Jenkins main-only entry (also runnable locally).
# Env:
#   GH_TOKEN or GITHUB_TOKEN — required for PR title lookup + publish + push auth
#   BASE_SHA — git range start for change detection (default: HEAD^)
#   HEAD_SHA — git range end (default: HEAD)
#   GITHUB_REPOSITORY — optional (default investtal/investtal-toolchain)
# Dependencies: bash, git, curl, gh (publish), node (PR title JSON parse)
# shellcheck source=/dev/null
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
cd "$REPO_ROOT"

subject="$(git log -1 --pretty=%s)"
# Skip release-loop commits and explicit CI skip markers
if [[ "$subject" == *'[skip ci]'* || "$subject" == *'[ci skip]'* ]] \
  || [[ "$subject" == chore\(release\):* ]]; then
  echo "skip release: $subject"
  exit 0
fi

BASE_SHA="${BASE_SHA:-$(git rev-parse HEAD^)}"
export BASE_SHA
export HEAD_SHA="${HEAD_SHA:-HEAD}"

# Portable: no mapfile (bash 3.2)
tools=()
_tools_tmp="$(mktemp)"
# detect-changed-tools exits 0 with empty stdout when nothing matched
"$RELEASE_ROOT/detect-changed-tools.sh" >"$_tools_tmp" || true
while IFS= read -r t || [[ -n "$t" ]]; do
  [[ -n "$t" ]] && tools+=("$t")
done <"$_tools_tmp"
rm -f "$_tools_tmp"

if [[ ${#tools[@]} -eq 0 ]]; then
  echo "no releasable tools changed"
  exit 0
fi

# Resolve PR title for HEAD via GitHub REST (associated pull requests)
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
sha="$(git rev-parse HEAD)"
title=""
repo="${GITHUB_REPOSITORY:-investtal/investtal-toolchain}"
if [[ -n "$token" ]]; then
  pulls="$(curl -fsSL \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${repo}/commits/${sha}/pulls" || echo '[]')"
  # Requires node on Jenkins agents / local for JSON parse
  title="$(printf '%s' "$pulls" | node -e '
    let d=""; process.stdin.on("data",c=>d+=c); process.stdin.on("end",()=>{
      try {
        const a=JSON.parse(d);
        if(!Array.isArray(a) || !a.length){ console.log("none"); process.exit(0); }
        console.log(a[0].title||"none");
      } catch(e) { console.log("none"); }
    });
  ')"
else
  title="none"
fi

level="$("$RELEASE_ROOT/detect-bump-level.sh" "$title")"
if [[ "$level" == "none" ]]; then
  echo "no PR / none bump — skip"
  exit 0
fi

for tool in "${tools[@]}"; do
  echo "=== releasing $tool (level=$level) ==="
  load_tool "$tool"
  new_ver="$("$RELEASE_ROOT/bump-version.sh" "$tool" "$level")"
  tag="${tool}-v${new_ver}"
  "$RELEASE_ROOT/create-tag-and-push.sh" "$tool" "$new_ver"

  asset_dir=""
  if [[ "$KIND" == "binary" ]]; then
    asset_dir="$REPO_ROOT/dist/${tool}-${new_ver}"
    mkdir -p "$asset_dir"
    case "$tool" in
      atlassian)
        package_script="$RELEASE_ROOT/package-atlassian.sh"
        [[ -x "$package_script" || -f "$package_script" ]] \
          || die "package-atlassian.sh missing (Task 3) — cannot package binary tool"
        VERSION="$new_ver" OUT_DIR="$asset_dir" "$package_script"
        ;;
      *)
        die "no package script for $tool"
        ;;
    esac
  fi
  "$RELEASE_ROOT/publish-github-release.sh" "$tag" "${asset_dir:-}"
done
