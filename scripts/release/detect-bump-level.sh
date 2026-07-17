#!/usr/bin/env bash
set -euo pipefail
# Usage: detect-bump-level.sh "<pr title>"
# Prints: major | minor | patch | none
title="${1-}"
if [[ -z "$title" || "$title" == "none" ]]; then
  echo none
  exit 0
fi
# BREAKING CHANGE token
if [[ "$title" == BREAKING\ CHANGE:* || "$title" == BREAKING-CHANGE:* ]]; then
  echo major
  exit 0
fi
# Conventional commit with breaking bang: type!: or type(scope)!:
# Use vars for bash 3.2 (inline ) in =~ breaks the conditional parser)
_re_bang='^[[:alnum:]]+!:'
_re_bang_scope='^[[:alnum:]]+\([^)]*\)!:'
if [[ "$title" =~ $_re_bang || "$title" =~ $_re_bang_scope ]]; then
  echo major
  exit 0
fi
# feat: or feat(scope):
_re_feat='^feat:'
_re_feat_scope='^feat\([^)]*\):'
if [[ "$title" =~ $_re_feat || "$title" =~ $_re_feat_scope ]]; then
  echo minor
  exit 0
fi
# any other conventional type or free text → patch
echo patch
