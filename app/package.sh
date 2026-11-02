#!/bin/bash
# Build, sign, notarize and zip Pedal Scroll for distribution.
#
# Usage: ./package.sh            # writes build/PedalScroll-<version>.zip
#
# Signing and notarization run only when their credentials are set:
#   SIGN_IDENTITY     "Developer ID Application: Name (TEAMID)"
#   NOTARY_APPLE_ID   Apple ID email
#   NOTARY_TEAM_ID    10-character team ID
#   NOTARY_PASSWORD   app-specific password for the Apple ID
# or, instead of the three NOTARY_* values above:
#   NOTARY_PROFILE    a keychain profile saved with `xcrun notarytool store-credentials`
# Without them the zip is ad-hoc signed and Gatekeeper will block it on download.

set -euo pipefail

cd "$(dirname "$0")"

./build.sh

APP_DIR="build/Pedal Scroll.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_DIR/Contents/Info.plist")"
ZIP="build/PedalScroll-$VERSION.zip"

zip_app() {
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP"
}

zip_app

NOTARY_AUTH=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
    NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
fi

if [ -n "${SIGN_IDENTITY:-}" ] && [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
    echo "→ Notarizing"
    xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
    echo "→ Stapling"
    xcrun stapler staple "$APP_DIR"
    # Re-zip so the download carries the stapled ticket.
    zip_app
    spctl --assess --type execute --verbose "$APP_DIR"
else
    echo "→ Skipping notarization (credentials not set)"
fi

echo "✓ $ZIP"
