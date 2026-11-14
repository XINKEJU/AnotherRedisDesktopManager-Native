#!/bin/bash
# Builds a minimal ad-hoc-signed .app used by tests/updater/main.swift when no real
# build is available (CI, or a checkout that has never run build.sh).
#
# It exists so the signature tests stay meaningful without depending on Xcode:
# the probe needs *a* sealed bundle that passes SecStaticCodeCheckValidity and
# that it is allowed to corrupt.
set -euo pipefail

OUT="${1:?usage: fixture.sh <output .app>}"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/main.c" <<'EOF'
int main(void) { return 0; }
EOF
clang -target arm64-apple-macos14.0 -O0 "$TMP/main.c" -o "$OUT/Contents/MacOS/Fixture"

cat > "$OUT/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>me.qii404.ardm.native</string>
    <key>CFBundleName</key><string>ARDM Fixture</string>
    <key>CFBundleExecutable</key><string>Fixture</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.7.4</string>
    <key>CFBundleVersion</key><string>1.7.4</string>
</dict>
</plist>
EOF

# A sealed resource: appending to it must invalidate the code signature.
printf '// fixture command reference\n' > "$OUT/Contents/Resources/commands.js"

codesign --force --sign - "$OUT" 2>/dev/null
codesign --verify --strict "$OUT"
echo "  fixture bundle: $OUT"
