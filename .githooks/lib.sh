#!/usr/bin/env bash

IVT_HOOK_MARKER="ivt-hooks-chain"

IVT_ALLOWED_EXACT="main master develop dev"
IVT_ALLOWED_PREFIX="release/ hotfix/"

# bash 3.2 ERE has no reliable {4} quantifier; spell out the digit classes.
IVT_TASK_REGEX='(IVT-[0-9][0-9][0-9][0-9])([^[:alnum:]]|$)'

ivt_hook_debug() {
  [ -n "${IVT_HOOK_DEBUG:-}" ] && echo "[ivt-hook] $*" >&2
}

ivt_current_branch() {
  git symbolic-ref --quiet --short HEAD 2>/dev/null
}

ivt_branch_is_infra() {
  local branch="$1"
  [ -z "$branch" ] && return 1

  local allowed
  for allowed in $IVT_ALLOWED_EXACT; do
    [ "$branch" = "$allowed" ] && return 0
  done

  local prefix
  for prefix in $IVT_ALLOWED_PREFIX; do
    case "$branch" in
      ${prefix}*) return 0 ;;
    esac
  done

  return 1
}

ivt_branch_is_valid() {
  local branch="$1"
  [ -z "$branch" ] && return 1
  ivt_branch_is_infra "$branch" && return 0
  # shellcheck disable=SC2076
  [[ "$branch" =~ $IVT_TASK_REGEX ]]
}

ivt_print_policy() {
  cat >&2 <<'EOF'

[branch policy] Investtal task-id branch naming is enforced.

  Allowed branch names must be EITHER:
    • an infra branch: main, master, develop, dev, release/*, hotfix/*
    • contain a task id of the form IVT-XXXX (4 digits), e.g.
        IVT-0999
        feat/IVT-0999-broker-view
        IVT-0999-broker-view

  Examples of INVALID names:
    feat/broker-view          (no task id)
    chore/cleanup             (no task id)
    IVT-999                   (only 3 digits — must be 4)
    IVT-0999X                 (extra chars after the 4 digits)
    IVT-69696969              (more than 4 digits)

To create a correctly-named branch from your current one:
    git branch -m IVT-XXXX-short-description
EOF
}

ivt_extract_task_id() {
  local s="$1"
  if [[ "$s" =~ $IVT_TASK_REGEX ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

ivt_resolve_symlink() {
  local target="$1"

  if command -v greadlink >/dev/null 2>&1; then
    greadlink -f "$target" 2>/dev/null && return
  fi
  if command -v readlink >/dev/null 2>&1 \
     && readlink -f -- / >/dev/null 2>&1; then
    readlink -f -- "$target" 2>/dev/null && return
  fi

  local cur="$target"
  local hops=0
  while [ -L "$cur" ] && [ "$hops" -lt 40 ]; do
    hops=$((hops + 1))
    local dir
    dir="$(cd -P "$(dirname "$cur")" >/dev/null 2>&1 && pwd)"
    local link
    link="$(readlink "$cur")"
    case "$link" in
      /*) cur="$link" ;;
      *)  cur="$dir/$link" ;;
    esac
  done
  local d
  d="$(cd -P "$(dirname "$cur")" >/dev/null 2>&1 && pwd)" || { printf '%s\n' "$cur"; return; }
  printf '%s/%s\n' "$d" "$(basename "$cur")"
}

ivt_hook_dir() {
  local resolved
  resolved="$(ivt_resolve_symlink "$0")"
  dirname "$resolved"
}

ivt_chain_next_hook() {
  local hook_name="$1"
  shift

  local depth="${IVT_HOOK_CHAIN_DEPTH:-0}"
  if [ "$depth" -gt 8 ]; then
    ivt_hook_debug "chain depth limit hit at $hook_name, stopping"
    return 0
  fi

  local hooks_dir
  hooks_dir="$(ivt_hook_dir)"
  [ -z "$hooks_dir" ] && return 0

  local previous="$hooks_dir/${hook_name}.pre-ivt"
  if [ -x "$previous" ]; then
    ivt_hook_debug "chaining $previous (depth=$((depth + 1)))"
    IVT_HOOK_CHAIN_DEPTH=$((depth + 1)) "$previous" "$@"
    return $?
  fi
}
