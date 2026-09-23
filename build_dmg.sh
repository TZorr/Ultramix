#!/bin/bash
#
# build_dmg.sh
# Ultramix
#
# Release build -> /Applications -> a distributable .dmg.
#
# The image mounts straight away, with no licence to agree to first. MIT
# grants rights rather than asking for consent, so there is nothing to click
# through. LICENSE and THIRD_PARTY_NOTICES.md ride along in the image beside
# the app instead.
#
# Usage: ./build_dmg.sh [--no-install]
#
#   --no-install   build and package, but leave /Applications alone
#

set -euo pipefail

cd "$(dirname "$0")"

INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

APP_NAME="Ultramix"
VOL_NAME="Ultramix"
BUILD_DIR="$PWD/build"
RELEASE_DIR="$BUILD_DIR/Release"
STAGING="$BUILD_DIR/staging"

VERSION=$(grep -m1 "MARKETING_VERSION" Ultramix.xcodeproj/project.pbxproj \
          | sed -E 's/.*= *([^;]*);.*/\1/')
DMG="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"

echo "==> Ultramix $VERSION"

# ---------------------------------------------------------------- build

echo "==> Release build"
# build/ is not in the repository, so a fresh clone has nowhere to put the
# log yet - and the redirect below would fail before xcodebuild ever ran.
mkdir -p "$BUILD_DIR"
rm -rf "$RELEASE_DIR"
# CONFIGURATION_BUILD_DIR is not optional. Without it xcodebuild writes into
# DerivedData and leaves build/Release at whatever it was last time - which
# is how an old app gets installed and a working change looks broken.
xcodebuild -project Ultramix.xcodeproj -scheme "$APP_NAME" \
    -configuration Release -destination 'platform=macOS' \
    CONFIGURATION_BUILD_DIR="$RELEASE_DIR" \
    clean build > "$BUILD_DIR/build.log" 2>&1 \
  || { echo "build failed - see $BUILD_DIR/build.log"; exit 1; }

[[ -d "$RELEASE_DIR/$APP_NAME.app" ]] || { echo "no app produced"; exit 1; }

# --------------------------------------------------------------- install

if (( INSTALL )); then
    echo "==> Installing to /Applications"
    # A running copy cannot be replaced from under itself. Ask it to quit
    # rather than killing it: an abrupt end looks like a crash to macOS, and
    # the next launch then restores the windows of the session that "failed".
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    sleep 2
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$RELEASE_DIR/$APP_NAME.app" "/Applications/$APP_NAME.app"
fi

# --------------------------------------------------------------- staging

echo "==> Staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$RELEASE_DIR/$APP_NAME.app" "$STAGING/"
# The drag-here target. A symlink rather than a folder, so the window shows
# one app and one destination and dropping actually installs.
ln -s /Applications "$STAGING/Applications"
cp LICENSE "$STAGING/"
[[ -f THIRD_PARTY_NOTICES.md ]] && cp THIRD_PARTY_NOTICES.md "$STAGING/"

# ------------------------------------------------------------------- dmg

echo "==> Disk image"
rm -f "$DMG"
hdiutil create -srcfolder "$STAGING" -volname "$VOL_NAME" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 \
    -quiet "$DMG"

echo
echo "    $DMG"
echo "    $(du -h "$DMG" | cut -f1)"
(( INSTALL )) && echo "    installed: /Applications/$APP_NAME.app"
echo
