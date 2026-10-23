#!/bin/bash
# Build Pedal Scroll.app — an unsigned macOS menu bar app.
#
# Usage:
#   ./build.sh          # builds into ./build/Pedal Scroll.app
#   ./build.sh install  # also copies the result to /Applications

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
swiftc main.swift PedalLogic.swift \
    -o "$MACOS/$EXECUTABLE_NAME" \
    -framework Cocoa \
    -framework IOKit \
    -framework CoreGraphics \
    -framework ServiceManagement \
    -O

echo "→ Writing Info.plist"
cp Info.plist "$CONTENTS/Info.plist"

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
