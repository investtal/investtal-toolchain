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

tool_never_tagged() {
  local tool="$1"
  if git tag -l "${tool}-v*" 2>/dev/null | grep -q .; then
    return 1
  fi
  return 0
}

tools_append_unique() {
  local candidate="$1" t
  for t in "${tools[@]+"${tools[@]}"}"; do
    [[ "$t" == "$candidate" ]] && return 0
  done
  tools+=("$candidate")
}

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

# Sets _rel_tool and _rel_ver from "chore(release): {tool} v{ver} ..."
parse_release_subject() {
  local subject="$1"
  local rest tool_part ver_part
  rest="${subject#chore(release): }"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  tool_part="${rest%% *}"
  ver_part="${rest#* }"
  ver_part="${ver_part%% *}"
  if [[ "$ver_part" == v* ]]; then
    ver_part="${ver_part#v}"
  fi
  [[ -n "$tool_part" && -n "$ver_part" ]] \
    || die "cannot parse release subject: $subject"
  case "$ver_part" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) die "invalid version in release subject: $subject" ;;
  esac
  _rel_tool="$tool_part"
  _rel_ver="$ver_part"
}

# Prints PR title for commit, or "none". Non-zero only on hard fetch/parse failure.
resolve_pr_title() {
  local sha="$1" repo="$2" token="$3"
  local title="" pulls=""

  if command -v gh >/dev/null 2>&1; then
    title="$(gh api "repos/${repo}/commits/${sha}/pulls" \
      --jq '.[0].title // "none"' 2>/dev/null || true)"
    if [[ -n "$title" ]]; then
      printf '%s\n' "$title"
      return 0
    fi
  fi

  if [[ -z "$token" ]]; then
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

  return 1
}

# PR base covers full rebase/squash ranges; HEAD^ only sees the tip commit.
resolve_pr_base_sha() {
  local sha="$1" repo="$2" token="$3"
  local base="" pulls=""

  if command -v gh >/dev/null 2>&1; then
    base="$(gh api "repos/${repo}/commits/${sha}/pulls" \
      --jq '.[0].base.sha // empty' 2>/dev/null || true)"
    if [[ -n "$base" ]]; then
      printf '%s\n' "$base"
      return 0
    fi
  fi

  if [[ -z "$token" ]]; then
    return 0
  fi

  pulls="$(curl -fsSL \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${repo}/commits/${sha}/pulls" 2>/dev/null || echo '')"
  [[ -n "$pulls" && "$pulls" != "[]" ]] || return 0

  if command -v python3 >/dev/null 2>&1; then
    base="$(printf '%s' "$pulls" | python3 -c '
import sys, json
try:
    a = json.load(sys.stdin)
    if isinstance(a, list) and a:
        b = (a[0].get("base") or {}).get("sha") or ""
        print(b)
except Exception:
    pass
' 2>/dev/null || true)"
    if [[ -n "$base" ]]; then
      printf '%s\n' "$base"
      return 0
    fi
  fi

  base="$(printf '%s' "$pulls" \
    | tr '\n' ' ' \
    | sed -E 's/.*"base"[[:space:]]*:[[:space:]]*\{[^}]*"sha"[[:space:]]*:[[:space:]]*"([0-9a-f]{7,40})".*/\1/' \
    || true)"
  if [[ "$base" =~ ^[0-9a-f]{7,40}$ ]]; then
    printf '%s\n' "$base"
  fi
}

# BASE_SHA: env override → merge first-parent → PR base → HEAD^
resolve_base_sha() {
  local sha="" head_sha repo token pr_base
  if [[ -n "${BASE_SHA:-}" ]]; then
    printf '%s\n' "$BASE_SHA"
    return 0
  fi

  if git rev-parse -q --verify HEAD^2 >/dev/null; then
    git rev-parse HEAD^1
    return 0
  fi

  head_sha="$(git rev-parse HEAD)"
  repo="${GITHUB_REPOSITORY:-investtal/investtal-toolchain}"
  token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  pr_base="$(resolve_pr_base_sha "$head_sha" "$repo" "$token" || true)"
  if [[ -n "$pr_base" ]]; then
    if ! git rev-parse -q --verify "${pr_base}^{commit}" >/dev/null 2>&1; then
      git fetch --depth=1 origin "$pr_base" 2>/dev/null || true
      git fetch --deepen=50 2>/dev/null || true
    fi
    if git rev-parse -q --verify "${pr_base}^{commit}" >/dev/null 2>&1; then
      if git merge-base --is-ancestor "$pr_base" HEAD 2>/dev/null; then
        echo "release: BASE_SHA from associated PR base ($pr_base)" >&2
        printf '%s\n' "$pr_base"
        return 0
      fi
      echo "release: ignoring PR base $pr_base (not ancestor of HEAD)" >&2
    else
      echo "release: PR base $pr_base not in local history; falling back to HEAD^" >&2
    fi
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

# [skip ci] skips release unless this is a retriable chore(release): commit.
if [[ "$subject" != chore\(release\):* ]]; then
  if [[ "$subject" == *'[skip ci]'* || "$subject" == *'[ci skip]'* ]]; then
    echo "skip release: $subject"
    exit 0
  fi
fi

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

tools=()
_tools_tmp="$(mktemp)"
"$RELEASE_ROOT/detect-changed-tools.sh" >"$_tools_tmp" || true
while IFS= read -r t || [[ -n "$t" ]]; do
  [[ -n "$t" ]] && tools+=("$t")
done <"$_tools_tmp"
rm -f "$_tools_tmp"

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

# Bootstrap tools that never got a {tool}-v* tag (ship current VERSION as-is).
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

token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
sha="$(git rev-parse HEAD)"
repo="${GITHUB_REPOSITORY:-investtal/investtal-toolchain}"
title=""
if ! title="$(resolve_pr_title "$sha" "$repo" "$token")"; then
  die "cannot resolve associated PR title for ${sha} (need gh, or curl+python3, or parseable JSON). Tools changed: ${tools[*]}"
fi

level="$("$RELEASE_ROOT/detect-bump-level.sh" "$title")"
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
    new_ver="$cur"
    tag="${tool}-v${new_ver}"
    echo "initial tag $tag from current VERSION (no bump)"
  else
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
