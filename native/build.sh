#!/bin/bash
# Build the fully native ARDM: SwiftUI interface + Objective-C RESP/services core.
# Requires the Xcode developer directory (xcode-select -p -> /Applications/Xcode.app/Contents/Developer).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(dirname "$ROOT")"
BUILD="$ROOT/.build"
APP="$ROOT/ARDM Native.app"

echo "[0/6] Checking the toolchain..."
DEVDIR="$(xcode-select -p)"
# GitHub runners install Xcode as "Xcode_15.4.app", so match the family rather
# than the exact "/Applications/Xcode.app" string.
if [[ "$DEVDIR" != *"Xcode"* ]]; then
    echo "ERROR: SwiftUI needs the full Xcode toolchain. Run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi
echo "  developer dir: $DEVDIR"
xcrun swift --version | head -2

rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources/langs"

# Pin the deployment target. Without -target both clang and swiftc inherit the
# host SDK (macOS 27.x on a current machine), which stamps LC_BUILD_VERSION
# minos = the build machine's OS and makes the .app refuse to launch anywhere
# older — regardless of LSMinimumSystemVersion in Info.plist. Keep this value
# in sync with LSMinimumSystemVersion.
DEPLOY_TARGET="arm64-apple-macos14.0"

echo "[1/6] Compiling the Objective-C core (RESP / TLS / SSH / viewers / services)..."
for SOURCE in Redis.m Services.m Transport.m; do
    clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations \
        -target "$DEPLOY_TARGET" \
        -c "$ROOT/$SOURCE" -o "$BUILD/${SOURCE%.m}.o"
done

echo "[2/6] Compiling and linking the SwiftUI application..."
xcrun swiftc -O -parse-as-library \
    -target "$DEPLOY_TARGET" \
    -import-objc-header "$ROOT/Bridge.h" \
    "$ROOT"/swift/*.swift \
    "$BUILD/Redis.o" "$BUILD/Services.o" "$BUILD/Transport.o" \
    -framework AppKit -framework SwiftUI -framework JavaScriptCore \
    -framework WebKit -framework Network -framework Security \
    -lz \
    -o "$BUILD/ardm-native"

echo "[3/6] Assembling the .app bundle..."
cp "$BUILD/ardm-native" "$APP/Contents/MacOS/ardm-native"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "[4/6] Bundling project assets (13 languages, command reference, icon)..."
cp "$PROJECT"/src/i18n/langs/*.js "$APP/Contents/Resources/langs/"
cp "$PROJECT"/src/commands.js "$APP/Contents/Resources/commands.js"
if [ -f "$PROJECT/pack/electron/icons/icon.icns" ]; then
    cp "$PROJECT/pack/electron/icons/icon.icns" "$APP/Contents/Resources/icon.icns"
fi
# Declaring a zh-Hans localization lets AppKit localise the standard
# File/Edit/View/Window/Help menus to Chinese on Chinese macOS systems.
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
printf '/* Simplified Chinese localization marker for AppKit system menus */\n' \
    > "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"

echo "[5/6] Signing (ad-hoc) and verifying..."
codesign --force --sign - "$APP" 2>/dev/null || echo "  (ad-hoc signing skipped)"
file "$APP/Contents/MacOS/ardm-native"
plutil -lint "$APP/Contents/Info.plist"

# Guard the deployment target. A binary stamped with the build machine's OS
# version looks fine locally and is unlaunchable everywhere else, so fail loudly
# instead of shipping it.
WANT_MINOS="${DEPLOY_TARGET##*-apple-macos}"
GOT_MINOS="$(vtool -show-build "$APP/Contents/MacOS/ardm-native" | awk '/minos/{print $2; exit}')"
if [[ "$GOT_MINOS" != "$WANT_MINOS" ]]; then
    echo "ERROR: LC_BUILD_VERSION minos is '$GOT_MINOS', expected '$WANT_MINOS'." >&2
    echo "       The .app would refuse to launch on anything older than $GOT_MINOS." >&2
    exit 1
fi
echo "  deployment target: macOS $GOT_MINOS (arch arm64)"

echo "[6/6] Size report"
BYTES=$(find "$APP" -type f -exec stat -f '%z' {} + | awk '{s+=$1} END {print s}')
EXEC=$(stat -f '%z' "$APP/Contents/MacOS/ardm-native")
awk -v b="$BYTES" -v e="$EXEC" 'BEGIN {
    printf "  SwiftUI .app       : %.0f bytes (%.2f MB)\n", b, b/1048576
    printf "  executable         : %.0f bytes (%.0f KB)\n", e, e/1024
    printf "  Electron baseline  : 201188875 bytes (191.87 MB)\n"
    printf "  reduction          : %.2f%%\n", (1 - b/201188875) * 100
}'
echo "  output             : $APP"
