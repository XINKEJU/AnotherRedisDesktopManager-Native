#!/bin/bash
# Regenerate native/icons/icon.icns from the official Redis SVG.
#
#   bash native/icons/make-icns.sh
#
# The .icns is committed so that build.sh stays a pure compile+assemble step and
# CI never depends on an SVG rasterizer. Re-run this only when the artwork
# changes. Needs the Xcode toolchain (`xcrun swift`), like build.sh does.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SVG="$DIR/redis.svg"
OUT="$DIR/icon.icns"
SET="$DIR/redis.iconset"

[[ -f "$SVG" ]] || { echo "ERROR: $SVG is missing." >&2; exit 1; }

rm -rf "$SET"
mkdir -p "$SET"

# iconutil wants every size in the Apple iconset vocabulary, @1x and @2x each.
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    px="${spec%% *}"
    name="${spec##* }"
    xcrun swift "$DIR/svg2png.swift" "$SVG" "$SET/icon_$name.png" "$px" >/dev/null
done

rm -f "$OUT"
iconutil -c icns "$SET" -o "$OUT"
rm -rf "$SET"

echo "  wrote $OUT ($(stat -f '%z' "$OUT") bytes)"
