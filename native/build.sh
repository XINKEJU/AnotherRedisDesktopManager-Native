#!/bin/bash
# Build the fully native ARDM: pure Swift (SwiftUI interface + RESP/services core).
# Requires the Xcode developer directory (xcode-select -p -> /Applications/Xcode.app/Contents/Developer).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(dirname "$ROOT")"
BUILD="$ROOT/.build"
APP="$ROOT/RDM Native.app"

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
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
echo "  sdk: macOS $SDK_VERSION"
# sed, not head: `head -2` exits while the writer still has bytes, and under
# `set -o pipefail` that SIGPIPE would fail the build on a slower machine.
xcrun swift --version 2>&1 | sed -n '1,2p'

# Glass symbols are guarded in UITheme.swift by `#if compiler(>=6.1)` as well as
# `#available(macOS 26.0)`: an older SDK/compiler builds the material fallback
# instead of failing on a symbol that does not exist at compile time. CI still
# uses macos-26 so the Glass path is exercised on every release.
if [[ "${SDK_VERSION%%.*}" -lt 26 ]]; then
    echo "  note: SDK $SDK_VERSION has no Glass symbols; UITheme will use material fallbacks."
fi

PLIST_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Info.plist")"
NODE_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PROJECT/package.json")"
LOCK_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PROJECT/package-lock.json")"
if [[ "$PLIST_VERSION" != "$NODE_VERSION" || "$PLIST_VERSION" != "$LOCK_VERSION" ]]; then
    echo "ERROR: version drift: Info.plist=$PLIST_VERSION package.json=$NODE_VERSION package-lock.json=$LOCK_VERSION." >&2
    echo "       native/Info.plist is the release version; update the other two before building." >&2
    exit 1
fi
echo "  version: $PLIST_VERSION (plist / package.json / lock agree)"

rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources/langs"

# Pin the deployment target. Without -target both clang and swiftc inherit the
# host SDK (macOS 27.x on a current machine), which stamps LC_BUILD_VERSION
# minos = the build machine's OS and makes the .app refuse to launch anywhere
# older — regardless of LSMinimumSystemVersion in Info.plist. Keep this value
# in sync with LSMinimumSystemVersion.
DEPLOY_TARGET="arm64-apple-macos14.0"

echo "[1/6] Checking that no Objective-C sources remain..."
if compgen -G "$ROOT/*.m" >/dev/null || [[ -f "$ROOT/Bridge.h" ]]; then
    echo "ERROR: Objective-C sources are still present; this build is Swift-only." >&2
    exit 1
fi

echo "[2/6] Compiling and linking the SwiftUI application..."
xcrun swiftc -O -parse-as-library \
    -target "$DEPLOY_TARGET" \
    "$ROOT"/swift/*.swift \
    -framework AppKit -framework SwiftUI -framework JavaScriptCore \
    -framework WebKit -framework Network -framework Security \
    -lz \
    -o "$BUILD/rdm-native"

echo "[3/6] Assembling the .app bundle..."
cp "$BUILD/rdm-native" "$APP/Contents/MacOS/rdm-native"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "[4/6] Bundling project assets (13 languages, command reference, icon)..."
cp "$PROJECT"/src/i18n/langs/*.js "$APP/Contents/Resources/langs/"
cp "$PROJECT"/src/commands.js "$APP/Contents/Resources/commands.js"
# The app icon is the folder + Redis-stack mark, rendered from native/icons/redis.svg
# by native/icons/make-icns.sh and committed as .icns so this step stays a copy.
# Required, not optional: a silent skip ships a generic-document icon and nobody
# notices until the release is out.
if [ ! -s "$ROOT/icons/icon.icns" ]; then
    echo "ERROR: $ROOT/icons/icon.icns is missing or empty. Run 'bash native/icons/make-icns.sh'." >&2
    exit 1
fi
cp "$ROOT/icons/icon.icns" "$APP/Contents/Resources/icon.icns"
# Declaring a zh-Hans localization lets AppKit localise the standard
# File/Edit/View/Window/Help menus to Chinese on Chinese macOS systems.
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
printf '/* Simplified Chinese localization marker for AppKit system menus */\n' \
    > "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"

echo "[5/6] Signing (ad-hoc) and verifying..."
codesign --force --sign - "$APP" 2>/dev/null || echo "  (ad-hoc signing skipped)"
file "$APP/Contents/MacOS/rdm-native"
plutil -lint "$APP/Contents/Info.plist"

# Guard the deployment target. A binary stamped with the build machine's OS
# version looks fine locally and is unlaunchable everywhere else, so fail loudly
# instead of shipping it.
WANT_MINOS="${DEPLOY_TARGET##*-apple-macos}"
# Resolve the inspector through xcrun (Mach-O tools live in the developer
# directory, not always in PATH), print "minos 14" where a newer toolchain
# prints "14.0", and compare the numbers rather than the strings.
VTOOL="$(xcrun -f vtool 2>/dev/null || true)"
[[ -x "$VTOOL" ]] || VTOOL="/Library/Developer/CommandLineTools/usr/bin/vtool"
BUILD_INFO="$("$VTOOL" -show-build "$APP/Contents/MacOS/rdm-native" 2>&1 || true)"
GOT_MINOS="$(printf '%s\n' "$BUILD_INFO" | awk '/minos/ {gsub(/[^0-9.]/, "", $2); print $2; exit}')"
minmaj() { awk -v v="$1" 'BEGIN {split(v, a, "."); printf "%d.%d", a[1], (a[2] == "" ? 0 : a[2])}'; }
if [[ "$(minmaj "${GOT_MINOS:-none}")" != "$(minmaj "$WANT_MINOS")" ]]; then
    echo "ERROR: expected LC_BUILD_VERSION minos $WANT_MINOS, got '${GOT_MINOS:-<none>}'." >&2
    echo "       '$VTOOL -show-build' said:" >&2
    printf '%s\n' "$BUILD_INFO" >&2
    exit 1
fi
echo "  deployment target: macOS $GOT_MINOS (arch arm64)"

echo "[6/6] Size report"
BYTES=$(find "$APP" -type f -exec stat -f '%z' {} + | awk '{s+=$1} END {print s}')
EXEC=$(stat -f '%z' "$APP/Contents/MacOS/rdm-native")
awk -v b="$BYTES" -v e="$EXEC" 'BEGIN {
    printf "  SwiftUI .app       : %.0f bytes (%.2f MB)\n", b, b/1048576
    printf "  executable         : %.0f bytes (%.0f KB)\n", e, e/1024
    printf "  Electron baseline  : 201188875 bytes (191.87 MB)\n"
    printf "  reduction          : %.2f%%\n", (1 - b/201188875) * 100
}'
echo "  output             : $APP"
