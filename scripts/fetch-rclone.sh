#!/usr/bin/env bash
# Vendor rclone for Sefirah.app's Finder mount (SFTP -> local WebDAV bridge).
# Idempotent. `--force` re-fetches. RCLONE_FETCH_TMP=<dir> reuses already-downloaded zips.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=rclone.lock
source "$ROOT/scripts/rclone.lock"
OUT="$ROOT/Vendor/rclone"
BASE="https://downloads.rclone.org/v${RCLONE_VERSION}"
STAMP="${RCLONE_VERSION}:${RCLONE_AARCH64_SHA256}:${RCLONE_X86_64_SHA256}"
WORK="${RCLONE_FETCH_TMP:-$(mktemp -d)}"
[[ -n "${RCLONE_FETCH_TMP:-}" ]] || trap 'rm -rf "$WORK"' EXIT

if [[ "${1:-}" != "--force" && -f "$OUT/.stamp" && "$(cat "$OUT/.stamp")" == "$STAMP" && -x "$OUT/rclone" ]]; then
  echo "rclone $RCLONE_VERSION already vendored at $OUT"; exit 0
fi

fetch() { # <arch> <sha256>
  local name="rclone-v${RCLONE_VERSION}-osx-$1.zip" file
  file="$WORK/$name"
  [[ -f "$file" ]] || curl -fsSL --retry 3 -o "$file" "$BASE/$name"
  echo "$2  $file" | shasum -a 256 -c - >/dev/null || { echo "error: sha256 mismatch for $name" >&2; exit 1; }
  rm -rf "$WORK/$1"; mkdir -p "$WORK/$1"
  unzip -q "$file" -d "$WORK/$1"
}
fetch arm64 "$RCLONE_AARCH64_SHA256"
fetch amd64 "$RCLONE_X86_64_SHA256"
A="$WORK/arm64/rclone-v${RCLONE_VERSION}-osx-arm64/rclone"
X="$WORK/amd64/rclone-v${RCLONE_VERSION}-osx-amd64/rclone"
[[ -x "$A" && -x "$X" ]] || { echo "error: rclone binaries not found in zips" >&2; exit 1; }

mkdir -p "$OUT"
rm -f "$OUT"/rclone "$OUT"/LICENSE "$OUT"/VERSION "$OUT"/.stamp
lipo -create "$A" "$X" -output "$OUT/rclone"
chmod 755 "$OUT/rclone"
xattr -c "$OUT/rclone" 2>/dev/null || true
curl -fsSL --retry 3 -o "$OUT/LICENSE" "https://raw.githubusercontent.com/rclone/rclone/v${RCLONE_VERSION}/COPYING" \
  || { echo "error: could not fetch rclone LICENSE" >&2; exit 1; }

# Ad-hoc sign with a stable identifier. Xcode's Copy Files phase re-signs with the app identity
# using --preserve-metadata=identifier, so this identifier is what ships.
codesign --force --sign - --identifier io.github.madeye.sefirah.rclone "$OUT/rclone"

# Sanity: universal, self-contained, runnable.
lipo -info "$OUT/rclone" | grep -q 'x86_64 arm64' || { echo "error: rclone is not universal" >&2; exit 1; }
if otool -L "$OUT/rclone" | grep -Eq '@rpath|@executable_path|@loader_path|/opt/|/usr/local/'; then
  echo "error: vendored rclone has non-system dylib dependencies" >&2; exit 1
fi
"$OUT/rclone" version | head -1
printf '%s\n' "$RCLONE_VERSION" > "$OUT/VERSION"
printf '%s\n' "$STAMP" > "$OUT/.stamp"
echo "vendored rclone $RCLONE_VERSION -> $OUT"
