#!/usr/bin/env bash
set -euo pipefail
# Usage: detect-changed-tools.sh
# Env: BASE_SHA (required for git mode), HEAD_SHA (default HEAD)
# Or: paths on stdin (one per line) for tests
# shellcheck source=/dev/null
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

match_glob() {
  # fnmatch-ish: support trailing /** only
  local path="$1" glob="$2"
  if [[ "$glob" == */** ]]; then
    local prefix="${glob%/**}"
    [[ "$path" == "$prefix" || "$path" == "$prefix"/* ]]
  else
    # unquoted RHS for bash pathname pattern matching
    # shellcheck disable=SC2254
    [[ "$path" == $glob ]]
  fi
}

# Return 0 if name already present in newline-separated list $1
list_has() {
  local list="$1" name="$2"
  [[ -n "$list" ]] || return 1
  printf '%s\n' "$list" | grep -Fxq -- "$name"
}

paths=()
if [[ -n "${BASE_SHA:-}" ]]; then
  HEAD_SHA="${HEAD_SHA:-HEAD}"
  # Avoid process substitution edge cases; use temp file for portability
  _diff_tmp="$(mktemp)"
  trap 'rm -f "$_diff_tmp"' EXIT
  git -C "$REPO_ROOT" diff --name-only "$BASE_SHA" "$HEAD_SHA" >"$_diff_tmp"
  while IFS= read -r p || [[ -n "$p" ]]; do
    [[ -n "$p" ]] && paths+=("$p")
  done <"$_diff_tmp"
  rm -f "$_diff_tmp"
  trap - EXIT
else
  while IFS= read -r p || [[ -n "$p" ]]; do
    [[ -n "$p" ]] && paths+=("$p")
  done
fi

# Portable unique set (bash 3.2 has no associative arrays)
matched=""
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^# ]] && continue
  [[ -z "$line" ]] && continue
  IFS='|' read -r name _k _vf _vk globs <<<"$line"
  # Split comma-separated globs portably (no mapfile / declare -A)
  _rest="$globs"
  while [[ -n "$_rest" ]]; do
    case "$_rest" in
      *,*)
        g="${_rest%%,*}"
        _rest="${_rest#*,}"
        ;;
      *)
        g="$_rest"
        _rest=""
        ;;
    esac
    # trim whitespace (xargs is fine for single token globs)
    g="$(printf '%s' "$g" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    [[ -n "$g" ]] || continue
    # Iterate paths; empty array safe under set -u
    if [[ ${#paths[@]} -gt 0 ]]; then
      for path in "${paths[@]}"; do
        if match_glob "$path" "$g"; then
          if ! list_has "$matched" "$name"; then
            matched="${matched}${matched:+$'\n'}${name}"
          fi
        fi
      done
    fi
  done
done <"$MANIFEST"

if [[ -n "$matched" ]]; then
  printf '%s\n' "$matched" | sort
fi
