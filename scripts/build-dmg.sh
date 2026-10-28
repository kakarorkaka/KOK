#!/usr/bin/env bash
#
# 构建可下载的 KoK DMG。
#
# 默认使用本机已有的 Developer ID 证书签名；没有证书时退化为 ad-hoc，
# 但 ad-hoc 包在别人机器上会被 Gatekeeper 拦下，只适合本地测试。
#
# 公证（可选）：
#   xcrun notarytool store-credentials KoKNotary \
#     --apple-id "you@example.com" \
#     --team-id "KXWXY96P85" \
#     --password "<app-specific-password>"
#   NOTARY_PROFILE=KoKNotary ./scripts/build-dmg.sh
#
# 产物：build/release/KoK-<version>.dmg（build/ 已在 .gitignore）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(awk -F' = ' '/MARKETING_VERSION = / {gsub(/;/,"",$2); print $2; exit}' KoK.xcodeproj/project.pbxproj)"
BUILD="$(awk -F' = ' '/CURRENT_PROJECT_VERSION = / {gsub(/;/,"",$2); print $2; exit}' KoK.xcodeproj/project.pbxproj)"
DERIVED="$ROOT/build/release-dd"
OUT_DIR="$ROOT/build/release"
STAGE="$OUT_DIR/dmg"
APP="$DERIVED/Build/Products/Release/KoK.app"
DMG="$OUT_DIR/KoK-$VERSION.dmg"
IDENTITY="${DEVELOPER_ID_IDENTITY:-Developer ID Application: Kakar Zhang (KXWXY96P85)}"

echo "==> KoK $VERSION ($BUILD)"
rm -rf "$DERIVED" "$STAGE"
mkdir -p "$OUT_DIR" "$STAGE"

echo "==> Building universal Release"
xcodebuild \
  -project KoK.xcodeproj \
  -scheme KoK \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

test -d "$APP"

echo "==> Architectures"
lipo -info "$APP/Contents/MacOS/KoK"

if security find-identity -v -p codesigning | grep -Fq "$IDENTITY"; then
  echo "==> Signing with: $IDENTITY"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$IDENTITY" \
    "$APP"
else
  echo "!! Developer ID identity not found; using ad-hoc signature."
  echo "!! Downloaded copies will be blocked by Gatekeeper until signed with Developer ID."
  codesign --force --options runtime --sign - "$APP"
fi

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
if ! spctl --assess --type execute --verbose=4 "$APP"; then
  echo "!! Gatekeeper assessment failed (normal before notarization/stapling)."
fi

echo "==> Staging DMG"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "KoK" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

# DMG 本身也签名，便于后续公证 / staple。
if security find-identity -v -p codesigning | grep -Fq "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$DMG"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarizing with keychain profile: $NOTARY_PROFILE"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
else
  echo "!! NOTARY_PROFILE not set: DMG is signed but NOT notarized."
  echo "!! Users may need to right-click the app and choose Open."
fi

echo "==> Done"
du -h "$DMG"
echo "$DMG"
