#!/usr/bin/env bash
# Cross-build atlassian for 6 platform targets and write checksums.
# Env:
#   VERSION  — bare semver (required), e.g. 0.1.1
#   OUT_DIR  — output directory for archives + checksums (required)
#   ZIG_VERSION — default 0.16.0
# Asset names match proto/atlassian/plugin.toml:
#   atlassian_{version}_{os}_{arch}.tar.gz|zip
#   atlassian_{version}_checksums.txt
# os ∈ linux|macos|windows; arch ∈ amd64|arm64
set -euo pipefail
# shellcheck source=/dev/null
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
# shellcheck source=/dev/null
source "$RELEASE_ROOT/ensure-zig.sh"

VERSION="${VERSION:?VERSION bare semver required}"
OUT_DIR="${OUT_DIR:?OUT_DIR required}"
ZIG_VERSION="${ZIG_VERSION:-0.16.0}"

# Basic semver sanity (digits.digits.digits…)
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "VERSION must be bare semver (got: $VERSION)" ;;
esac

command -v tar >/dev/null 2>&1 \
  || die "tar not found (required for linux/macos atlassian packages)"
# Windows packages need zip CLI or python3 (zipfile). Prefer zip when present.
if ! command -v zip >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  die "need zip or python3 to create Windows atlassian packages (neither found on PATH)"
fi

# Write a zip containing a single file as its basename (cwd-relative).
# Args: <output.zip> <file-in-cwd>
# Prefer Info-ZIP; fall back to python3 zipfile. Return status of the command that ran.
make_zip() {
  local out="$1" file="$2"
  if command -v zip >/dev/null 2>&1; then
    zip -q "$out" "$file"
  else
    # Agent images often lack Info-ZIP; stdlib zipfile is enough.
    python3 - "$out" "$file" <<'PY'
import sys
import zipfile

out_path, name = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    zf.write(name, arcname=name)
PY
  fi
}

mkdir -p "$OUT_DIR"
# Resolve absolute OUT_DIR so archives land correctly after cd
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

ensure_zig

# target_triple|asset_os|asset_arch|ext
# asset_os/arch must match plugin.toml [install.arch] + download-file patterns
MATRIX=(
  "x86_64-linux-gnu|linux|amd64|tar.gz"
  "aarch64-linux-gnu|linux|arm64|tar.gz"
  "x86_64-macos|macos|amd64|tar.gz"
  "aarch64-macos|macos|arm64|tar.gz"
  "x86_64-windows|windows|amd64|zip"
  "aarch64-windows|windows|arm64|zip"
)

cd "$REPO_ROOT/atlassian"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/atlassian-pkg.XXXXXX")"
trap '[[ -n "${workdir:-}" && -d "$workdir" ]] && rm -rf "$workdir"' EXIT

for row in "${MATRIX[@]}"; do
  # Portable: no mapfile; IFS split
  triple="${row%%|*}"
  rest="${row#*|}"
  aos="${rest%%|*}"
  rest="${rest#*|}"
  aarch="${rest%%|*}"
  ext="${rest#*|}"

  echo "building $triple …"
  zig build -Doptimize=ReleaseSafe -Dtarget="$triple"

  name="atlassian_${VERSION}_${aos}_${aarch}"
  if [[ "$ext" == "tar.gz" ]]; then
    bin="zig-out/bin/atlassian"
    [[ -f "$bin" ]] || die "missing $bin after build for $triple"
    mkdir -p "$workdir/pkg"
    cp "$bin" "$workdir/pkg/atlassian"
    chmod +x "$workdir/pkg/atlassian"
    tar -C "$workdir/pkg" -czf "$OUT_DIR/${name}.tar.gz" atlassian
    rm -rf "$workdir/pkg"
  else
    bin="zig-out/bin/atlassian.exe"
    [[ -f "$bin" ]] || die "missing $bin after build for $triple"
    mkdir -p "$workdir/pkg"
    cp "$bin" "$workdir/pkg/atlassian.exe"
    # zip stores relative path from cwd
    (
      cd "$workdir/pkg"
      make_zip "$OUT_DIR/${name}.zip" atlassian.exe
    )
    rm -rf "$workdir/pkg"
  fi
  echo "  → $OUT_DIR/${name}.${ext}"
done

cd "$OUT_DIR"
# Hash archives only (never the checksums file itself)
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum \
    atlassian_"${VERSION}"_*.tar.gz \
    atlassian_"${VERSION}"_*.zip \
    >"atlassian_${VERSION}_checksums.txt"
else
  shasum -a 256 \
    atlassian_"${VERSION}"_*.tar.gz \
    atlassian_"${VERSION}"_*.zip \
    >"atlassian_${VERSION}_checksums.txt"
fi

echo "=== atlassian ${VERSION} packages ==="
ls -la
echo "=== checksums ==="
cat "atlassian_${VERSION}_checksums.txt"
