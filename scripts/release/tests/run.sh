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

echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
