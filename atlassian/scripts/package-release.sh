#!/usr/bin/env bash
# Thin local wrapper → monorepo package-atlassian.sh
# Usage: VERSION=0.1.1 OUT_DIR=./dist ./scripts/package-release.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "$ROOT/scripts/release/package-atlassian.sh"
