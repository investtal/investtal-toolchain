#!/usr/bin/env bash
set -euo pipefail
# Jenkins main-only entry (also runnable locally).
# Env:
#   GH_TOKEN or GITHUB_TOKEN — required for PR title lookup + publish + push auth
#   BASE_SHA — git range start for change detection (default: HEAD^ / HEAD~1)
#   HEAD_SHA — git range end (default: HEAD)
#   GITHUB_REPOSITORY — optional (default investtal/investtal-toolchain)
#   BRANCH_NAME / GIT_BRANCH — Jenkins branch (create-tag-and-push requires main)
#   FORCE_RELEASE_TOOLS — comma-separated tool names to release even if paths unchanged
# Dependencies: bash, git, curl, gh (publish); PR title via gh | python3 | sed
# shellcheck source=/dev/null
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
cd "$REPO_ROOT"

# True if this tool has never been tagged as {tool}-v* (local after fetch --tags).
tool_never_tagged() {
  local tool="$1"
  # List local tags matching prefix; empty → never released under new scheme.
  if git tag -l "${tool}-v*" 2>/dev/null | grep -q .; then
    return 1
  fi
  return 0
}

# Append unique tool name to tools array (bash 3.2 — no associative arrays).
tools_append_unique() {
  local candidate="$1" t
  for t in "${tools[@]+"${tools[@]}"}"; do
    [[ "$t" == "$candidate" ]] && return 0
  done
  tools+=("$candidate")
}

# Package binary assets (if needed) and publish GitHub Release for tool@ver.
package_and_publish() {
  local tool="$1" ver="$2"
  load_tool "$tool"
  local tag="${tool}-v${ver}"
  local asset_dir=""
  if [[ "$KIND" == "binary" ]]; then
    asset_dir="$REPO_ROOT/dist/${tool}-${ver}"
    mkdir -p "$asset_dir"
    case "$tool" in
      atlassian)
        package_script="$RELEASE_ROOT/package-atlassian.sh"
        [[ -x "$package_script" || -f "$package_script" ]] \
          || die "package-atlassian.sh missing (Task 3) — cannot package binary tool"
        VERSION="$ver" OUT_DIR="$asset_dir" "$package_script"
        ;;
      *)
        die "no package script for $tool"
        ;;
    esac
  fi
  "$RELEASE_ROOT/publish-github-release.sh" "$tag" "${asset_dir:-}"
}

# Parse "chore(release): {tool} v{ver} ..." → sets _rel_tool _rel_ver
parse_release_subject() {
  local subject="$1"
  local rest tool_part ver_part
  rest="${subject#chore(release): }"
  # strip optional leading spaces (portable)
  rest="${rest#"${rest%%[![:space:]]*}"}"
  tool_part="${rest%% *}"
  ver_part="${rest#* }"
  ver_part="${ver_part%% *}"
  # strip optional leading v
  if [[ "$ver_part" == v* ]]; then
    ver_part="${ver_part#v}"
  fi
  [[ -n "$tool_part" && -n "$ver_part" ]] \
    || die "cannot parse release subject: $subject"
  # basic semver sanity
  case "$ver_part" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) die "invalid version in release subject: $subject" ;;
  esac
  _rel_tool="$tool_part"
  _rel_ver="$ver_part"
}

# Resolve associated PR title for a commit.
# Prefer: gh --jq → curl+python3 → curl+sed best-effort.
# Prints title or "none". Returns non-zero only when fetch/parse hard-fails.
resolve_pr_title() {
  local sha="$1" repo="$2" token="$3"
  local title="" pulls=""

  if command -v gh >/dev/null 2>&1; then
    # gh uses GH_TOKEN/GITHUB_TOKEN from env when set
    title="$(gh api "repos/${repo}/commits/${sha}/pulls" \
      --jq '.[0].title // "none"' 2>/dev/null || true)"
    if [[ -n "$title" ]]; then
      printf '%s\n' "$title"
      return 0
    fi
  fi

  if [[ -z "$token" ]]; then
    # No token and gh failed/missing → treat as no PR
    printf 'none\n'
    return 0
  fi

  pulls="$(curl -fsSL \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${repo}/commits/${sha}/pulls" 2>/dev/null || echo '')"

  if [[ -z "$pulls" ]]; then
    return 1
  fi

  if command -v python3 >/dev/null 2>&1; then
    title="$(printf '%s' "$pulls" | python3 -c '
import sys, json
try:
    a = json.load(sys.stdin)
    if not isinstance(a, list) or not a:
        print("none")
    else:
        print(a[0].get("title") or "none")
except Exception:
    sys.exit(1)
' 2>/dev/null)" || title=""
    if [[ -n "$title" ]]; then
      printf '%s\n' "$title"
      return 0
    fi
  fi

  # Pure bash/sed best-effort for first "title": "..."
  # Empty array → none; otherwise take first title field.
  if [[ "$pulls" == "[]" ]]; then
    printf 'none\n'
    return 0
  fi
  title="$(printf '%s' "$pulls" \
    | grep -o '"title"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n1 \
    | sed -E 's/.*"title"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)"
  if [[ -n "$title" ]]; then
    printf '%s\n' "$title"
    return 0
  fi

  # Response present but unparseable
  return 1
}

# Resolve BASE_SHA from env or git parents (shallow-clone aware).
resolve_base_sha() {
  local sha=""
  if [[ -n "${BASE_SHA:-}" ]]; then
    printf '%s\n' "$BASE_SHA"
    return 0
  fi
  if sha="$(git rev-parse HEAD^ 2>/dev/null)"; then
    printf '%s\n' "$sha"
    return 0
  fi
  if sha="$(git rev-parse HEAD~1 2>/dev/null)"; then
    printf '%s\n' "$sha"
    return 0
  fi
  die "cannot resolve BASE_SHA (HEAD^/HEAD~1 failed). Shallow clone needs history: git fetch --unshallow || git fetch --deepen=50"
}

subject="$(git log -1 --pretty=%s)"

# Pure [skip ci]/[ci skip] that is NOT a release commit → do not release.
# chore(release): … [skip ci] is retriable (ensure push/package/publish only).
if [[ "$subject" != chore\(release\):* ]]; then
  if [[ "$subject" == *'[skip ci]'* || "$subject" == *'[ci skip]'* ]]; then
    echo "skip release: $subject"
    exit 0
  fi
fi

# Retriable path: HEAD is a release commit — no bump, ensure push + publish.
if [[ "$subject" == chore\(release\):* ]]; then
  echo "retriable publish for release commit: $subject"
  parse_release_subject "$subject"
  echo "=== ensuring publish $_rel_tool v$_rel_ver ==="
  "$RELEASE_ROOT/create-tag-and-push.sh" "$_rel_tool" "$_rel_ver"
  package_and_publish "$_rel_tool" "$_rel_ver"
  exit 0
fi

BASE_SHA="$(resolve_base_sha)"
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

# FORCE_RELEASE_TOOLS=atlassian,9cc — manual recovery / ops rebuild.
# Portable comma-split (no set -- / unquoted glob expansion).
if [[ -n "${FORCE_RELEASE_TOOLS:-}" ]]; then
  _rest_force="${FORCE_RELEASE_TOOLS}"
  while [[ -n "$_rest_force" ]]; do
    case "$_rest_force" in
      *,*)
        t="${_rest_force%%,*}"
        _rest_force="${_rest_force#*,}"
        ;;
      *)
        t="$_rest_force"
        _rest_force=""
        ;;
    esac
    t="$(echo "$t" | tr -d '[:space:]')"
    [[ -n "$t" ]] || continue
    load_tool "$t" >/dev/null
    tools_append_unique "$t"
    echo "force include tool: $t"
  done
fi

# First-time bootstrap: tools that never got a {tool}-v* tag (e.g. first main
# release failed at preflight before tagging). Ship current VERSION as-is.
_bootstrap=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^#|^$ ]] && continue
  IFS='|' read -r _name _rest <<<"$line"
  [[ -n "$_name" ]] || continue
  if tool_never_tagged "$_name"; then
    _bootstrap+=("$_name")
    tools_append_unique "$_name"
    echo "bootstrap initial release (no ${_name}-v* tags yet): $_name"
  fi
done <"$MANIFEST"

if [[ ${#tools[@]} -eq 0 ]]; then
  echo "no releasable tools changed (and none need bootstrap)"
  exit 0
fi

# Resolve PR title for HEAD via GitHub REST (associated pull requests)
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
sha="$(git rev-parse HEAD)"
repo="${GITHUB_REPOSITORY:-investtal/investtal-toolchain}"
title=""
if ! title="$(resolve_pr_title "$sha" "$repo" "$token")"; then
  die "cannot resolve associated PR title for ${sha} (need gh, or curl+python3, or parseable JSON). Tools changed: ${tools[*]}"
fi

level="$("$RELEASE_ROOT/detect-bump-level.sh" "$title")"
# Bootstrap-only (no path changes + no force): allow patch when there is no PR title.
# Path-based releases still require a real PR title level.
_only_bootstrap=1
for tool in "${tools[@]}"; do
  _is_boot=0
  for b in "${_bootstrap[@]+"${_bootstrap[@]}"}"; do
    [[ "$b" == "$tool" ]] && _is_boot=1 && break
  done
  if [[ "$_is_boot" -eq 0 ]]; then
    _only_bootstrap=0
    break
  fi
done
if [[ "$level" == "none" ]]; then
  if [[ "$_only_bootstrap" -eq 1 || -n "${FORCE_RELEASE_TOOLS:-}" ]]; then
    level="patch"
    echo "no PR title — using level=patch for bootstrap/force release"
  else
    echo "no PR / none bump — skip"
    exit 0
  fi
fi

for tool in "${tools[@]}"; do
  echo "=== releasing $tool (level=$level) ==="
  load_tool "$tool"
  cur="$(read_version "$REPO_ROOT/$VERSION_FILE" "$VERSION_KIND")"
  _is_boot=0
  for b in "${_bootstrap[@]+"${_bootstrap[@]}"}"; do
    [[ "$b" == "$tool" ]] && _is_boot=1 && break
  done

  if [[ "$_is_boot" -eq 1 ]]; then
    # First tag: ship version file as-is (e.g. atlassian-v0.1.0, 9cc-v0.5.4).
    new_ver="$cur"
    tag="${tool}-v${new_ver}"
    echo "initial tag $tag from current VERSION (no bump)"
  else
    # Compute target version without writing yet; if tag already exists, skip bump.
    new_ver="$(semver_bump "$cur" "$level")"
    tag="${tool}-v${new_ver}"
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
      echo "tag $tag already exists — skip bump; ensure push/package/publish"
    else
      new_ver="$("$RELEASE_ROOT/bump-version.sh" "$tool" "$level")"
      tag="${tool}-v${new_ver}"
    fi
  fi
  "$RELEASE_ROOT/create-tag-and-push.sh" "$tool" "$new_ver"
  package_and_publish "$tool" "$new_ver"
done
