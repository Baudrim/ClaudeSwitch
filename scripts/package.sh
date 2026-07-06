#!/usr/bin/env bash
#
# Builds a distributable ClaudeSwitch.app and zips it for sharing.
#
# Produces an ad-hoc signed (not notarized) build: recipients on another Mac must clear the
# quarantine flag once (`xattr -dr com.apple.quarantine /Applications/ClaudeSwitch.app`) or use
# System Settings > Privacy & Security > "Open Anyway". For frictionless distribution, replace the
# ad-hoc signing step with a Developer ID identity + notarization (see NOTARIZE note below).
#
# Usage:
#   ./scripts/package.sh
#
# Override the toolchain if Xcode lives elsewhere:
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/package.sh

set -euo pipefail

# Xcode 26+ is required (Icon Composer .icon, Liquid Glass, macOS 26 deployment target). Default to
# the beta install used during development; override via the DEVELOPER_DIR env var.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="ClaudeSwitch"
PROJECT="ClaudeSwitch.xcodeproj"
BUILD_DIR="build/dd"
DIST_DIR="dist"
APP_PATH="$BUILD_DIR/Build/Products/Release/$SCHEME.app"
ZIP_PATH="$DIST_DIR/$SCHEME.zip"

command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not found (brew install xcodegen)"; exit 1; }

echo "==> Generating Xcode project from project.yml"
xcodegen generate

echo "==> Building Release ($SCHEME)"
rm -rf "$BUILD_DIR"
"$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build

[ -d "$APP_PATH" ] || { echo "error: build did not produce $APP_PATH"; exit 1; }

echo "==> Ad-hoc signing"
# NOTARIZE: for public distribution, swap the line below for a Developer ID identity and notarize:
#   codesign --force --deep --options runtime --sign "Developer ID Application: <NAME> (<TEAMID>)" "$APP_PATH"
#   ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
#   xcrun notarytool submit "$ZIP_PATH" --keychain-profile <PROFILE> --wait
#   xcrun stapler staple "$APP_PATH"   # then re-zip
codesign --force --deep --sign - --timestamp=none "$APP_PATH"
codesign --verify --verbose=2 "$APP_PATH"

echo "==> Zipping"
mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo '?')"
ARCH="$(lipo -archs "$APP_PATH/Contents/MacOS/$SCHEME" 2>/dev/null || echo '?')"

echo ""
echo "Done."
echo "  App:     $APP_PATH"
echo "  Zip:     $REPO_ROOT/$ZIP_PATH"
echo "  Version: $VERSION | Arch: $ARCH | Min macOS: 26.0"
