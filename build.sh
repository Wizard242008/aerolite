#!/bin/bash
# Build, sign and install Pulsar.
#
# TWO things here are deliberate and load-bearing:
#
# 1. swiftc instead of `swift build`: the CommandLineTools install on this machine has a broken
#    XCBuild ("Unknown error parsing property list"), so SwiftPM cannot run at all.
#
# 2. Signing with a real (self-signed) identity instead of ad-hoc. An ad-hoc signature's identity
#    *is* the binary hash, so every rebuild looks like a brand new app to TCC and the Accessibility
#    grant is silently discarded — the "it keeps asking for permission" loop. A certificate gives
#    a designated requirement of `identifier + certificate hash`, which is stable across rebuilds.
#
# Only ONE copy of the bundle is ever left on disk: a second copy with the same bundle id shows up
# as a separate entry in System Settings and is a reliable way to grant permission to the wrong app.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Pulsar.app"
DEST="/Applications/Pulsar.app"
IDENTITY="Hyprmac Dev Signing"
BUNDLE_ID="com.devansh.pulsar"

echo "==> compiling"
mkdir -p build
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
    Sources/Pulsar/*.swift -o build/Pulsar

echo "==> icon"
swiftc -O -swift-version 5 Tools/makeicon/main.swift -o build/makeicon
rm -rf build/AppIcon.iconset
./build/makeicon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o build/Pulsar.icns
ls -lh build/Pulsar.icns | awk '{print "    icns: " $5}'

echo "==> bundling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/Pulsar.icns "$APP/Contents/Resources/Pulsar.icns"
cp README.md "$APP/Contents/Resources/README.md"
cp build/Pulsar "$APP/Contents/MacOS/Pulsar"
chmod +x "$APP/Contents/MacOS/Pulsar"

echo "==> signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --identifier "$BUNDLE_ID" --timestamp=none --sign "$IDENTITY" "$APP" 2>&1 | sed 's/^/    /'
else
    echo "    !! identity \"$IDENTITY\" not found — falling back to ad-hoc"
    echo "    !! TCC approval will NOT survive the next rebuild"
    codesign --force --identifier "$BUNDLE_ID" --timestamp=none --sign - "$APP" 2>&1 | sed 's/^/    /'
fi

codesign --verify --strict "$APP" && echo "    signature ok"
codesign -dvv "$APP" 2>&1 | grep -E "^Authority|^Signature" | sed 's/^/    /'
ls -lh "$APP/Contents/MacOS/Pulsar" | awk '{print "    binary: " $5}'

echo "==> disk image"
rm -rf build/dmg
mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Pulsar" -srcfolder build/dmg -ov -format UDZO -quiet build/Pulsar.dmg
rm -rf build/dmg
ls -lh build/Pulsar.dmg | awk '{print "    dmg: " $5}'

if [ "${1:-}" = "--dmg-only" ]; then
    echo "==> skipping install (--dmg-only); artifact is build/Pulsar.dmg"
    exit 0
fi

echo "==> installing (single copy only)"
pkill -x Pulsar 2>/dev/null || true
sleep 0.3
rm -rf "$DEST"
cp -R "$APP" "$DEST"
rm -rf "$APP"          # leave exactly one bundle on disk

echo "==> done: $DEST"
