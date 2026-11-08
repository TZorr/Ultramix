#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ultramix-ui.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
OUT="$TEST_TMP/verify-ui"
PRODUCTS="$PWD/build/Verification"
mkdir -p "$PRODUCTS"
xcodebuild -project Ultramix.xcodeproj -scheme Ultramix -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build/VerificationData \
    CONFIGURATION_BUILD_DIR="$PRODUCTS" ENABLE_TESTABILITY=YES ENABLE_DEBUG_DYLIB=YES \
    build > "$PRODUCTS/build.log" 2>&1 \
    || { tail -n 30 "$PRODUCTS/build.log"; exit 1; }
DYLIB="$PRODUCTS/Ultramix.app/Contents/MacOS"
swiftc -O -parse-as-library -default-isolation MainActor -swift-version 5 -target arm64-apple-macos26.5 \
    -I "$PRODUCTS" -Xcc -I"$PWD/Ultramix/LAME" -Xlinker -rpath -Xlinker "$DYLIB" \
    "$DYLIB/Ultramix.debug.dylib" Verification/UI/main.swift -o "$OUT"
TMPDIR="$TEST_TMP/" "$OUT"
