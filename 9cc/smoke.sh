#!/usr/bin/env bash
# 9cc update smoke test — proves `9cc update` can fetch + decode + run the
# installer end to end. Hermetic: no network. Uses a fake `gh` that returns the
# installer wrapped in base64 with line breaks, exactly as the GitHub Contents
# API does, so the macOS-strict decode path is exercised.
#
# Usage:
#   bash 9cc/smoke.sh                 # default target tag from $1 or v0.5.3
#   bash 9cc/smoke.sh <ref>           # pretend the latest release is <ref>
# Run by hand or from CI (Jenkinsfile stage 2).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
PASS=0; FAIL=0

assert_eq() { # <actual> <expected> <label>
    if [ "$1" = "$2" ]; then echo "  ok: $3"; PASS=$((PASS+1));
    else echo "  FAIL: $3 — want '$2' got '$1'" >&2; FAIL=$((FAIL+1)); fi
}

# Pretend a previous release is installed so `update` has work to do.
PREV_TAG="${PREV_TAG:-v0.3.5}"
TARGET_TAG="${1:-v0.5.3}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HOME_DIR="$WORK/home"
BIN_DIR="$WORK/bin"
mkdir -p "$HOME_DIR" "$BIN_DIR"

# Seed a fake prior install: version file + a launcher the bin symlink points at.
printf '%s\n' "$PREV_TAG" > "$HOME_DIR/version"
cp "$DIR/9cc.sh" "$HOME_DIR/9cc.sh"
chmod +x "$HOME_DIR/9cc.sh"
ln -sfn "$HOME_DIR/9cc.sh" "$BIN_DIR/9cc"

# Fake `gh`: respond to the contents-API call with the REAL install.sh, base64
# encoded and folded to 30 cols (GitHub wraps content). Ignore every other arg.
GH_BIN="$WORK/ghbin"; mkdir -p "$GH_BIN"
cat > "$GH_BIN/gh" <<GHSTUB
#!/usr/bin/env bash
# Mimic: gh api .../contents/9cc/install.sh?ref=<tag> --jq '.content'
printf '%s' "\$(cat "$REPO_ROOT/9cc/install.sh")" | /usr/bin/base64 | fold -w 30
GHSTUB
chmod +x "$GH_BIN/gh"

# Fake latest-tag fixture so get_latest_tag is offline + deterministic.
LATEST_FIXTURE="$WORK/latest.json"
printf '{"tag_name":"%s"}\n' "$TARGET_TAG" > "$LATEST_FIXTURE"

echo "Smoke: update $PREV_TAG -> $TARGET_TAG (hermetic, fake gh)"
OUT="$(CC9_HOME="$HOME_DIR" \
      CC9_BIN_DIR="$BIN_DIR" \
      CC9_VERSION="$PREV_TAG" \
      CC9_LATEST_API_FIXTURE="$LATEST_FIXTURE" \
      PATH="$GH_BIN:$BIN_DIR:$PATH" \
      "$HOME_DIR/9cc.sh" update 2>&1)" || { echo "  FAIL: update exited non-zero" >&2; FAIL=$((FAIL+1)); }

assert_eq "$?" "0" "update exit 0"
echo "$OUT" | grep -q "9cc update: $PREV_TAG -> $TARGET_TAG" && { echo "  ok: announces transition"; PASS=$((PASS+1)); } || { echo "  FAIL: transition line missing" >&2; FAIL=$((FAIL+1)); }
assert_eq "$(cat "$HOME_DIR/version")" "$TARGET_TAG" "version file advanced"
[ -x "$BIN_DIR/9cc" ] && { echo "  ok: bin launcher present"; PASS=$((PASS+1)); } || { echo "  FAIL: bin launcher missing" >&2; FAIL=$((FAIL+1)); }

echo "----"
echo "SMOKE PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ] || exit 1
