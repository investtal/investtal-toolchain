#!/usr/bin/env bash
set -u

IVT_HOOKS=(commit-msg post-checkout)
SHARED_LIB_NAME="lib.sh"

script_path="$0"
while [ -L "$script_path" ]; do
  d="$(cd -P "$(dirname "$script_path")" >/dev/null 2>&1 && pwd)"
  script_path="$(readlink "$script_path")"
  case "$script_path" in
    /*) ;;
    *)  script_path="$d/$script_path" ;;
  esac
done
SHARED_DIR="$(cd -P "$(dirname "$script_path")" >/dev/null 2>&1 && pwd)"
LANDTAL_ROOT="$(cd -P "$SHARED_DIR/../.." >/dev/null 2>&1 && pwd)"

MARKER="# installed-by: ivt-hooks"

log()  { printf '%s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
err()  { printf '[error] %s\n' "$*" >&2; }

is_our_hook() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -q "^${MARKER}" "$f" 2>/dev/null
}

set_hookspath() {
  local repo="$1"
  git -C "$repo" config core.hooksPath .githooks
}

install_repo() {
  local repo_dir="$1"
  local repo_name
  repo_name="$(basename "$repo_dir")"

  if [ ! -d "$repo_dir/.git" ]; then
    warn "$repo_name: not a git repo (no .git), skipping"
    return 1
  fi

  local hooks_dir="$repo_dir/.githooks"
  mkdir -p "$hooks_dir"

  local rc=0
  for name in "${IVT_HOOKS[@]}"; do
    local src="$SHARED_DIR/$name"
    local dst="$hooks_dir/$name"

    if [ ! -e "$src" ]; then
      err "$repo_name: shared file missing: $src"
      rc=1
      continue
    fi

    if [ -e "$dst" ] && [ ! -L "$dst" ] && ! is_our_hook "$dst"; then
      local preserved="$hooks_dir/${name}.pre-ivt"
      if [ -e "$preserved" ]; then
        if cmp -s "$dst" "$preserved"; then
          rm -f "$dst"
        else
          warn "$repo_name: $name.pre-ivt already exists and $name differs; leaving $name (manual review)"
          rc=1
          continue
        fi
      else
        mv "$dst" "$preserved"
        log "$repo_name: preserved existing $name → ${name}.pre-ivt (chained)"
      fi
    fi

    if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
      cp "$src" "$dst"
      chmod +x "$dst" 2>/dev/null || true
      log "$repo_name: ${name} → .githooks/${name}"
    fi
  done

  local lib_src="$SHARED_DIR/$SHARED_LIB_NAME"
  local lib_dst="$hooks_dir/$SHARED_LIB_NAME"
  if [ -e "$lib_src" ]; then
    if [ ! -f "$lib_dst" ] || ! cmp -s "$lib_src" "$lib_dst"; then
      cp "$lib_src" "$lib_dst"
      chmod +x "$lib_dst" 2>/dev/null || true
      log "$repo_name: ${SHARED_LIB_NAME} → .githooks/${SHARED_LIB_NAME}"
    fi
  fi

  if ! set_hookspath "$repo_dir"; then
    warn "$repo_name: could not set core.hooksPath"
    rc=1
  fi

  for f in "$hooks_dir"/*; do
    [ -f "$f" ] || continue
    [ -x "$f" ] || chmod +x "$f" 2>/dev/null || true
  done

  return $rc
}

sync_repo() { install_repo "$@"; }

uninstall_repo() {
  local repo_dir="$1"
  local repo_name
  repo_name="$(basename "$repo_dir")"

  if [ ! -d "$repo_dir/.git" ]; then
    warn "$repo_name: not a git repo, skipping"
    return 1
  fi

  local hooks_dir="$repo_dir/.githooks"
  for name in "${IVT_HOOKS[@]}" "$SHARED_LIB_NAME"; do
    local dst="$hooks_dir/$name"
    local preserved="$hooks_dir/${name}.pre-ivt"
    if is_our_hook "$dst"; then
      rm -f "$dst"
      log "$repo_name: removed $name"
      if [ -e "$preserved" ]; then
        mv "$preserved" "$dst"
        chmod +x "$dst" 2>/dev/null || true
        log "$repo_name: restored previous $name"
      fi
    fi
  done

  local hp
  hp="$(git -C "$repo_dir" config --get core.hooksPath 2>/dev/null || true)"
  if [ "$hp" = ".githooks" ]; then
    if [ -z "$(ls -A "$hooks_dir" 2>/dev/null)" ]; then
      git -C "$repo_dir" config --unset core.hooksPath 2>/dev/null || true
      rmdir "$hooks_dir" 2>/dev/null || true
      log "$repo_name: removed empty .githooks and unset core.hooksPath"
    else
      log "$repo_name: kept core.hooksPath=.githooks (quality hooks remain)"
    fi
  fi
}

status_repo() {
  local repo_dir="$1"
  local repo_name
  repo_name="$(basename "$repo_dir")"
  printf '%-26s' "$repo_name"
  if [ ! -d "$repo_dir/.git" ]; then
    printf '  (not a git repo)\n'
    return
  fi
  local hooks_dir="$repo_dir/.githooks"
  local hp
  hp="$(git -C "$repo_dir" config --get core.hooksPath 2>/dev/null || true)"
  printf '  hooksPath=%s' "${hp:-<unset>}"
  if [ ! -d "$hooks_dir" ]; then
    printf '  .githooks=(none)\n'
    return
  fi
  for name in "${IVT_HOOKS[@]}" "$SHARED_LIB_NAME"; do
    local f="$hooks_dir/$name"
    if is_our_hook "$f"; then
      local chain=""
      [ -e "$hooks_dir/${name}.pre-ivt" ] && chain="+chain"
      printf '  %s=ivt%s' "$name" "$chain"
    fi
  done
  local extras=""
  for f in "$hooks_dir"/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    local b
    b="$(basename "$f")"
    case "$b" in
      commit-msg|post-checkout|lib.sh) ;;
      *.pre-ivt) ;;
      *) extras="$extras $b" ;;
    esac
  done
  [ -n "$extras" ] && printf '  quality:%s' "$extras"
  printf '\n'
}

mode="install"
repos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) mode="uninstall"; shift ;;
    --sync)      mode="sync";      shift ;;
    --status)    mode="status";    shift ;;
    --all)       repos=();         shift ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do repos+=("$1"); shift; done ;;
    -*) err "unknown flag: $1"; exit 2 ;;
    *)  repos+=("$1"); shift ;;
  esac
done

if [ "${#repos[@]}" -eq 0 ]; then
  for d in "$LANDTAL_ROOT"/*/; do
    [ -d "$d/.git" ] || continue
    repos+=("$d")
  done
fi

for f in "$SHARED_LIB_NAME" "${IVT_HOOKS[@]}"; do
  if [ ! -e "$SHARED_DIR/$f" ]; then
    err "shared file missing: $SHARED_DIR/$f"
    exit 1
  fi
done

for f in "${IVT_HOOKS[@]}" "$SHARED_LIB_NAME"; do
  [ -x "$SHARED_DIR/$f" ] || chmod +x "$SHARED_DIR/$f" 2>/dev/null || true
done

case "$mode" in
  install|sync)
    for r in "${repos[@]}"; do install_repo "$r"; done ;;
  uninstall)
    for r in "${repos[@]}"; do uninstall_repo "$r"; done ;;
  status)
    for r in "${repos[@]}"; do status_repo "$r"; done ;;
esac

log "done."
