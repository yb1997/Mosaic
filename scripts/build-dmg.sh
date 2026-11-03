#!/bin/bash
# Builds a signed Release and packages it as a drag-to-Applications DMG.
# Usage:  ./scripts/build-dmg.sh
# Output: WallpaperChanger-<version>.dmg in the repository root.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="WallpaperChanger"
BUILD_DIR="$(pwd)/build"
VERSION=$(grep -E '^ *MARKETING_VERSION:' project.yml | sed -E 's/^[^:]*: *"?([0-9.]+)"?.*$/\1/')
DMG_OUTPUT="$(pwd)/${APP_NAME}-${VERSION}.dmg"

# Sign with a stable certificate so installed copies accept this build as an
# update (an ad-hoc signature changes every build). SIGN_IDENTITY=- for ad-hoc.
SIGN_IDENTITY="${SIGN_IDENTITY:-FreeDisplay Local}"

echo "=== Building ${APP_NAME} ${VERSION} (Release) ==="
xcodegen generate >/dev/null
# Skip Xcode's signing; the app is signed below after stripping extended attributes.
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  clean build 2>&1 | grep -E "error:|BUILD" || true

APP_PATH="$BUILD_DIR/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: ${APP_NAME}.app not found in build output"
  exit 1
fi

BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
if [ "$BUILT_VERSION" != "$VERSION" ]; then
  echo "ERROR: built app reports ${BUILT_VERSION}, project.yml says ${VERSION}"
  exit 1
fi

echo "=== Signing with: ${SIGN_IDENTITY} ==="
xattr -cr "$APP_PATH"
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH"

echo "=== Creating DMG ==="
STAGING_DIR="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_OUTPUT"
hdiutil create -volname "Wallpaper Changer" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_OUTPUT" >/dev/null

echo "=== Done ==="
ls -lh "$DMG_OUTPUT"
shasum -a 256 "$DMG_OUTPUT"
