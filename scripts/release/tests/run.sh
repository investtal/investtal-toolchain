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
assert_true() {
  local msg="$1"
  echo "  ✓ $msg"; pass=$((pass+1))
}
assert_fail_msg() {
  local msg="$1"
  echo "  ✗ $msg"; fail=$((fail+1))
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
# Fixture only — do not pin live package versions (they bump on every release).
_tmpd="$(mktemp -d)"
cat > "$_tmpd/build.zig.zon" <<'ZON'
.{
    .name = .atlassian,
    .version = "3.2.1",
    .paths = .{""},
}
ZON
assert_eq 3.2.1 "$(read_version "$_tmpd/build.zig.zon" zig.zon)" "read_version zig.zon fixture"
rm -rf "$_tmpd"

echo "== write_version zig.zon syncs CLI VERSION const =="
# Isolated package tree so write_version + sync_cli_version_const never touch the repo.
_tmpd="$(mktemp -d)"
cp "$REPO_ROOT/atlassian/build.zig.zon" "$_tmpd/build.zig.zon"
mkdir -p "$_tmpd/src/cli"
cp "$REPO_ROOT/atlassian/src/cli/root.zig" "$_tmpd/src/cli/root.zig"
write_version "$_tmpd/build.zig.zon" zig.zon "9.8.7"
assert_eq 9.8.7 "$(read_version "$_tmpd/build.zig.zon" zig.zon)" "temp zon bumped"
_cli_ver="$(grep -E '^pub const VERSION = "' "$_tmpd/src/cli/root.zig" | head -n1 | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')"
assert_eq 9.8.7 "$_cli_ver" "CLI root.zig VERSION stays in sync"
rm -rf "$_tmpd"

echo "== read_version plain (9cc) =="
_tmpd="$(mktemp -d)"
printf '%s\n' '7.6.5' > "$_tmpd/VERSION"
assert_eq 7.6.5 "$(read_version "$_tmpd/VERSION" plain)" "read_version plain fixture"
rm -rf "$_tmpd"

echo "== bash -n syntax (release scripts) =="
for s in bump-version.sh create-tag-and-push.sh detect-bump-level.sh detect-changed-tools.sh \
         ensure-zig.sh lib.sh package-atlassian.sh publish-github-release.sh run-auto-release.sh; do
  if bash -n "$ROOT/$s"; then
    echo "  ✓ bash -n $s"; pass=$((pass+1))
  else
    echo "  ✗ bash -n $s"; fail=$((fail+1))
  fi
done

echo "== skip / retriable subject predicates =="
# Pure [skip ci] / [ci skip] (not chore(release):) → full skip
_pure_skip='docs: update readme [skip ci]'
if [[ "$_pure_skip" != chore\(release\):* ]] \
  && [[ "$_pure_skip" == *'[skip ci]'* || "$_pure_skip" == *'[ci skip]'* ]]; then
  assert_true "pure [skip ci] is full-skip"
else
  assert_fail_msg "pure [skip ci] should full-skip"
fi
_pure_ci_skip='chore: internal [ci skip]'
if [[ "$_pure_ci_skip" != chore\(release\):* ]] \
  && [[ "$_pure_ci_skip" == *'[skip ci]'* || "$_pure_ci_skip" == *'[ci skip]'* ]]; then
  assert_true "pure [ci skip] is full-skip"
else
  assert_fail_msg "pure [ci skip] should full-skip"
fi
# chore(release): … is retriable — NOT a full skip
_rel='chore(release): atlassian v0.1.1 [skip ci]'
if [[ "$_rel" == chore\(release\):* ]]; then
  assert_true "chore(release) is retriable path (not full-skip)"
else
  assert_fail_msg "chore(release) should be retriable"
fi
_noskip='feat(atlassian): add feature'
if [[ "$_noskip" != chore\(release\):* ]] \
  && { [[ "$_noskip" == *'[skip ci]'* || "$_noskip" == *'[ci skip]'* ]]; }; then
  assert_fail_msg "skip predicate false-positive on feat"
else
  assert_true "skip predicate ignores normal feat"
fi

echo "== parse release subject (retriable publish) =="
# Mirrors parse_release_subject in run-auto-release.sh
_parse() {
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
  printf '%s %s' "$tool_part" "$ver_part"
}
assert_eq "atlassian 0.1.1" "$(_parse 'chore(release): atlassian v0.1.1 [skip ci]')" "parse atlassian"
assert_eq "9cc 0.5.5" "$(_parse 'chore(release): 9cc v0.5.5 [skip ci]')" "parse 9cc"
assert_eq "atlassian 1.0.0" "$(_parse 'chore(release): atlassian v1.0.0')" "parse without skip marker"

echo "== main-only push guard logic =="
# Mirrors require_main_for_push decision (branch or env)
_is_main() {
  local current_branch="$1" env_raw="$2"
  local env_branch="${env_raw##*/}"
  if [[ "$current_branch" == "main" || "$env_branch" == "main" ]]; then
    echo yes
  else
    echo no
  fi
}
assert_eq yes "$(_is_main main '')" "local main"
assert_eq yes "$(_is_main HEAD main)" "detached + BRANCH_NAME=main"
assert_eq yes "$(_is_main HEAD origin/main)" "detached + GIT_BRANCH=origin/main"
assert_eq no "$(_is_main feature/x '')" "feature branch refused"
assert_eq no "$(_is_main HEAD feature/x)" "detached feature refused"
assert_eq yes "$(_is_main feature/x main)" "env main wins (Jenkins)"

echo "== tag-exists → skip bump (compute only) =="
# current 0.1.0 + patch → 0.1.1; if tag atlassian-v0.1.1 exists, skip write
_cur="0.1.0"
_new="$(semver_bump "$_cur" patch)"
assert_eq 0.1.1 "$_new" "compute next without writing"
_tag="atlassian-v${_new}"
# We only assert the naming contract used by orchestrator
assert_eq "atlassian-v0.1.1" "$_tag" "target tag name from current+level"

echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
