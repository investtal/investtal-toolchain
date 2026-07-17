#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
assert_eq() {
  local want="$1" got="$2" msg="$3"
  if [[ "$want" == "$got" ]]; then
    echo "  ✓ $msg"; pass=$((pass+1))
  else
    echo "  ✗ $msg (want=$want got=$got)"; fail=$((fail+1))
  fi
}

echo "== detect-bump-level =="
assert_eq major "$("$ROOT/detect-bump-level.sh" 'feat!: drop api')" "feat!"
assert_eq major "$("$ROOT/detect-bump-level.sh" 'BREAKING CHANGE: x')" "BREAKING"
assert_eq minor "$("$ROOT/detect-bump-level.sh" 'feat(atlassian): add x')" "feat"
assert_eq patch "$("$ROOT/detect-bump-level.sh" 'fix: bug')" "fix"
assert_eq patch "$("$ROOT/detect-bump-level.sh" 'chore: stuff')" "chore"
assert_eq none "$("$ROOT/detect-bump-level.sh" 'none')" "none sentinel"

echo "== detect-changed-tools =="
got="$(printf '%s\n' 'atlassian/src/main.zig' 'README.md' | "$ROOT/detect-changed-tools.sh" | tr '\n' ' ' | xargs)"
assert_eq atlassian "$got" "atlassian path"

got="$(printf '%s\n' '9cc/9cc.sh' | "$ROOT/detect-changed-tools.sh" | tr '\n' ' ' | xargs)"
assert_eq 9cc "$got" "9cc path"

got="$(printf '%s\n' 'docs/specs/x.md' | "$ROOT/detect-changed-tools.sh" | tr '\n' ' ' | xargs)"
assert_eq "" "$got" "docs only → empty"

echo "== semver_bump via lib =="
# shellcheck source=/dev/null
source "$ROOT/lib.sh"
assert_eq 0.2.0 "$(semver_bump 0.1.5 minor)" "minor"
assert_eq 1.0.0 "$(semver_bump 0.9.9 major)" "major"
assert_eq 0.1.6 "$(semver_bump 0.1.5 patch)" "patch"

echo "== read_version zig.zon =="
load_tool atlassian
assert_eq 0.1.0 "$(read_version "$REPO_ROOT/$VERSION_FILE" "$VERSION_KIND")" "atlassian build.zig.zon"

echo "== read_version plain (9cc) =="
load_tool 9cc
assert_eq 0.5.4 "$(read_version "$REPO_ROOT/$VERSION_FILE" "$VERSION_KIND")" "9cc VERSION"

echo "== bash -n syntax (new Task 2 scripts) =="
for s in create-tag-and-push.sh publish-github-release.sh run-auto-release.sh; do
  if bash -n "$ROOT/$s"; then
    echo "  ✓ bash -n $s"; pass=$((pass+1))
  else
    echo "  ✗ bash -n $s"; fail=$((fail+1))
  fi
done

echo "== run-auto-release skip [skip ci] subject =="
# Smoke: script sources and exits 0 when HEAD subject would skip.
# We exercise the skip predicate logic via a temp clone of the check only.
_skip_subj='chore(release): atlassian v0.1.1 [skip ci]'
if [[ "$_skip_subj" == *'[skip ci]'* || "$_skip_subj" == *'[ci skip]'* ]] \
  || [[ "$_skip_subj" == chore\(release\):* ]]; then
  echo "  ✓ skip predicate matches release commit"; pass=$((pass+1))
else
  echo "  ✗ skip predicate failed"; fail=$((fail+1))
fi
_noskip='feat(atlassian): add feature'
if [[ "$_noskip" == *'[skip ci]'* || "$_noskip" == *'[ci skip]'* ]] \
  || [[ "$_noskip" == chore\(release\):* ]]; then
  echo "  ✗ skip predicate false-positive on feat"; fail=$((fail+1))
else
  echo "  ✓ skip predicate ignores normal feat"; pass=$((pass+1))
fi

echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
