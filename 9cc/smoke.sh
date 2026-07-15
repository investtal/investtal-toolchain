#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
PASS=0; FAIL=0

assert_eq() {
    if [ "$1" = "$2" ]; then echo "  ok: $3"; PASS=$((PASS+1));
    else echo "  FAIL: $3 — want '$2' got '$1'" >&2; FAIL=$((FAIL+1)); fi
}

PREV_TAG="${PREV_TAG:-v0.3.5}"
TARGET_TAG="${1:-v0.5.3}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HOME_DIR="$WORK/home"
BIN_DIR="$WORK/bin"
mkdir -p "$HOME_DIR" "$BIN_DIR"

printf '%s\n' "$PREV_TAG" > "$HOME_DIR/version"
cp "$DIR/9cc.sh" "$HOME_DIR/9cc.sh"
chmod +x "$HOME_DIR/9cc.sh"
ln -sfn "$HOME_DIR/9cc.sh" "$BIN_DIR/9cc"

GH_BIN="$WORK/ghbin"; mkdir -p "$GH_BIN"
cat > "$GH_BIN/gh" <<GHSTUB
#!/usr/bin/env bash
printf '%s' "\$(cat "$REPO_ROOT/9cc/install.sh")" | /usr/bin/base64 | fold -w 30
GHSTUB
chmod +x "$GH_BIN/gh"

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
