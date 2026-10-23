#!/bin/bash
# Build Pedal Scroll.app — an unsigned macOS menu bar app.
#
# Usage:
#   ./build.sh          # builds into ./build/Pedal Scroll.app
#   ./build.sh install  # also copies the result to /Applications
#
# Version: VERSION env var, else the latest vX.Y.Z git tag, else Info.plist's value.
# Build number: commit count on HEAD.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Pedal Scroll"
BUNDLE_ID="com.chuckconway.pedal-scroll"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
EXECUTABLE_NAME="PedalScroll"

echo "→ Cleaning previous build"
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS" "$RESOURCES"

echo "→ Compiling Swift"
swiftc main.swift PedalLogic.swift MenuBarIcon.swift \
    -o "$MACOS/$EXECUTABLE_NAME" \
    -framework Cocoa \
    -framework IOKit \
    -framework CoreGraphics \
    -framework ServiceManagement \
    -O

echo "→ Rendering app icon"
swiftc icon/AppIcon.swift -o "$BUILD_DIR/AppIcon"
"$BUILD_DIR/AppIcon" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$RESOURCES/AppIcon.icns"

echo "→ Writing Info.plist"
cp Info.plist "$CONTENTS/Info.plist"
TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
VERSION="${VERSION:-${TAG#v}}"
if [ -n "$VERSION" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS/Info.plist"
echo "  version $(plutil -extract CFBundleShortVersionString raw "$CONTENTS/Info.plist") ($BUILD_NUMBER)"

echo "→ Built: $APP_DIR"

if [ "${1:-}" = "install" ]; then
    DEST="/Applications/$APP_NAME.app"
    echo "→ Stopping any running instance"
    pkill -f "$EXECUTABLE_NAME" 2>/dev/null || true
    sleep 1
    echo "→ Installing to $DEST"
    rm -rf "$DEST"
    cp -R "$APP_DIR" "$DEST"
    echo "→ Launching"
    open "$DEST"
    echo "✓ Installed and launched"
fi
