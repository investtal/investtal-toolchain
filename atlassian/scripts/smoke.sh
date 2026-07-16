#!/usr/bin/env bash
set -euo pipefail
BIN="${1:-zig-out/bin/atlassian}"
"$BIN" --help >/dev/null
"$BIN" version | grep -q .
"$BIN" config path >/dev/null
set +e
"$BIN" jira board create >/dev/null
code=$?
set -e
test "$code" -eq 6
echo smoke ok
