#!/bin/bash
# Produce the release artifact the in-app updater can actually verify:
#   dist/ARDM-Native-<version>-arm64.zip   (zip keeps the .app wrapper)
#   dist/SHA256SUMS                        (attach BOTH files to the release)
#
# An ad-hoc signed bundle carries no provenance, so the updater refuses any
# download without a published SHA-256. This script is how that requirement is
# satisfied — a release without SHA256SUMS cannot be auto-installed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/ARDM Native.app"
OUT="$ROOT/dist"

if [[ ! -d "$APP" ]]; then
    echo "ERROR: $APP not found. Run 'bash build.sh' first." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="ARDM-Native-${VERSION}-arm64.zip"

echo "[1/3] Verifying the bundle signature (deep + strict)..."
codesign --verify --deep --strict "$APP"

echo "[2/3] Zipping with the .app wrapper preserved..."
rm -rf "$OUT"
mkdir -p "$OUT"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME"

echo "[3/3] Writing SHA256SUMS..."
(
    cd "$OUT"
    /usr/bin/shasum -a 256 "$NAME" > SHA256SUMS
    cat SHA256SUMS
)

echo
echo "Attach both files to the GitHub release (the updater reads SHA256SUMS):"
echo "  $OUT/$NAME"
echo "  $OUT/SHA256SUMS"
