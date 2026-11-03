#!/bin/bash
# Builds the DMG and publishes a GitHub release for it.
# Usage: ./scripts/release.sh v1.1.0
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:?Usage: ./scripts/release.sh vX.Y.Z}"
REPO="${RELEASE_REPO:-yb1997/WallpaperChanger}"

# The tag must match the app's version, or the in-app update check misfires.
APP_VERSION=$(grep -E '^ *MARKETING_VERSION:' project.yml | sed -E 's/^[^:]*: *"?([0-9.]+)"?.*$/\1/')
if [ "v${APP_VERSION}" != "$VERSION" ]; then
  echo "ERROR: project.yml MARKETING_VERSION is ${APP_VERSION}, but the tag is ${VERSION}"
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: commit your changes first; the release is built from main"
  exit 1
fi

# Release notes: this version's section of CHANGELOG.md ("## [X.Y.Z] - date").
NOTES=$(mktemp)
awk -v v="## [${APP_VERSION}]" 'index($0, v) == 1 {p=1; next} /^## \[/ && p {exit} /^\[.*\]: / {next} p' CHANGELOG.md > "$NOTES"
if ! grep -q '[^[:space:]]' "$NOTES"; then
  echo "ERROR: no '## [${APP_VERSION}]' section in CHANGELOG.md"
  exit 1
fi

./scripts/build-dmg.sh
DMG="WallpaperChanger-${APP_VERSION}.dmg"

echo "=== Publishing ${VERSION} on ${REPO} ==="
git push origin main
gh release create "$VERSION" "$DMG" \
  --repo "$REPO" \
  --target main \
  --title "Wallpaper Changer ${APP_VERSION}" \
  --notes-file "$NOTES"
git fetch --tags --quiet origin

rm -f "$NOTES"
echo "=== Release ${VERSION} published ==="
