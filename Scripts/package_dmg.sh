#!/usr/bin/env zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DIR="/tmp/MacResourceGuardDerivedData"
RELEASE_APP="$DERIVED_DIR/Build/Products/Release/MacResourceGuard.app"
DIST_DIR="$PROJECT_DIR/dist"
DMG_STAGING="/tmp/MacResourceGuardDMGStaging"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Sources/MacResourceGuardApp/Resources/Info.plist")
DMG_NAME="MacResourceGuard-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

echo "==> [1/4] Generating Xcode project via XcodeGen (v${VERSION})..."
cd "$PROJECT_DIR"
xattr -cr "$PROJECT_DIR/Sources" "$PROJECT_DIR/Tests" 2>/dev/null || true
xcodegen generate

echo "==> [2/4] Building Release MacResourceGuard.app via xcodebuild..."
rm -rf "$DERIVED_DIR"
xcodebuild \
  -project "$PROJECT_DIR/MacResourceGuard.xcodeproj" \
  -scheme MacResourceGuard \
  -configuration Release \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build | tail -n 25

if [[ ! -d "$RELEASE_APP" ]]; then
  echo "Error: Release app not found at $RELEASE_APP"
  exit 1
fi

echo "==> [3/4] Stripping extended attributes & ad-hoc signing Release bundle..."
xattr -cr "$RELEASE_APP"
codesign --force --deep --sign - \
  --entitlements "$PROJECT_DIR/Sources/MacResourceGuardApp/Resources/MacResourceGuard.entitlements" \
  "$RELEASE_APP"
codesign --verify --deep --strict --verbose=2 "$RELEASE_APP"

mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/MacResourceGuard.app"
cp -R "$RELEASE_APP" "$DIST_DIR/MacResourceGuard.app"
xattr -cr "$DIST_DIR/MacResourceGuard.app" 2>/dev/null || true

echo "==> [4/4] Creating distributable DMG at $DMG_PATH..."
rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
cp -R "$RELEASE_APP" "$DMG_STAGING/MacResourceGuard.app"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "Mac Resource Guard" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$DMG_STAGING"

(cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt && cat SHA256SUMS.txt)
echo "==> Done! Release app: $DIST_DIR/MacResourceGuard.app"
echo "==> Done! Release DMG: $DMG_PATH"
