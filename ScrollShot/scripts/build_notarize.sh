#!/bin/bash
#
# Build → sign (Developer ID) → notarize → staple → package a distributable
# ScrollShot.app + ScrollShot.dmg. Run on a Mac, from the ScrollShot dir:
#
#     ./scripts/build_notarize.sh
#
# Prerequisites (one-time):
#   1. Apple Developer Program membership.
#   2. A "Developer ID Application" certificate in your login keychain
#      (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + Developer ID Application).
#   3. Notary credentials live in a DEDICATED keychain (profile scrollshot-notary):
#        ~/Library/Keychains/scrollshot-notary.keychain-db
#      Why not login keychain: agent shells without GUI get "User interaction is
#      not allowed" writing there; a dedicated keychain we own works headless.
#      Its unlock password is in the login keychain:
#        security find-generic-password -s scrollshot-notary-keychain -a scrollshot -w
#      The script auto-unlocks it before notarizing (it relocks on reboot/sleep).
#      Rebuild from scratch (app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials scrollshot-notary \
#          --apple-id "<your-apple-id>" --team-id 5QZY8FV25Y \
#          --password <app-specific-password> \
#          --keychain ~/Library/Keychains/scrollshot-notary.keychain-db
#
# Override the notary profile name with: NOTARY_PROFILE=xxx ./scripts/build_notarize.sh
# Build a test build with a different bundle ID to avoid TCC conflicts with the
# released /Applications/ScrollShot.app:
#     BUNDLE_ID=com.scrollshot.app.dev SKIP_NOTARIZE=1 ./scripts/build_notarize.sh

set -euo pipefail
cd "$(dirname "$0")/.."   # → ScrollShot project dir

NOTARY_PROFILE="${NOTARY_PROFILE:-scrollshot-notary}"
BUNDLE_ID="${BUNDLE_ID:-com.scrollshot.app}"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/ScrollShot.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/ScrollShot.app"
ZIP="$BUILD_DIR/ScrollShot.zip"
DMG="$BUILD_DIR/ScrollShot.dmg"

echo "▸ Regenerating project + app icon…"
command -v xcodegen >/dev/null && xcodegen generate || echo "  (xcodegen not found, using existing .xcodeproj)"
swift scripts/make_icon.swift || echo "  (icon generation skipped)"
command -v xcodegen >/dev/null && xcodegen generate || true

rm -rf "$BUILD_DIR"

echo "▸ Archiving (Release) with bundle ID $BUNDLE_ID..."
xcodebuild -project ScrollShot.xcodeproj -scheme ScrollShot \
  -configuration Release -archivePath "$ARCHIVE" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  archive | xcpretty 2>/dev/null || xcodebuild -project ScrollShot.xcodeproj -scheme ScrollShot \
  -configuration Release -archivePath "$ARCHIVE" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" archive

echo "▸ Exporting with Developer ID…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$EXPORT_DIR"

# Sign any embedded helper executables with hardened runtime. Xcode's automatic
# signing covers the app bundle and frameworks, but command-line tools copied
# into Resources are not automatically hardened-runtime signed, which causes
# notarization to reject the archive.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"  # override with your full identity if needed
if [ -f "$APP/Contents/Resources/m1ddc" ]; then
  echo "▸ Hardening embedded m1ddc executable…"
  codesign --sign "$SIGN_IDENTITY" \
    --options runtime --timestamp --force \
    "$APP/Contents/Resources/m1ddc"

  echo "▸ Re-signing app bundle after embedding hardened executable…"
  codesign --sign "$SIGN_IDENTITY" \
    --options runtime --timestamp --force \
    --preserve-metadata=entitlements,requirements,identifier,resource-rules,runtime \
    "$APP"
fi

if [ -n "${SKIP_NOTARIZE:-}" ]; then
  echo "▸ SKIP_NOTARIZE set — skipping notarization (DMG will be signed but not notarized)."
else
  echo "▸ Zipping for notarization…"
  ditto -c -k --keepParent "$APP" "$ZIP"

  NOTARY_KEYCHAIN="$HOME/Library/Keychains/scrollshot-notary.keychain-db"
  if [ -f "$NOTARY_KEYCHAIN" ]; then
    echo "▸ Ensuring notary keychain unlocked + in search list…"
    KC_PASS="$(security find-generic-password -s scrollshot-notary-keychain -a scrollshot -w 2>/dev/null || true)"
    if [ -n "$KC_PASS" ]; then
      security unlock-keychain -p "$KC_PASS" "$NOTARY_KEYCHAIN" 2>/dev/null || true
    fi
    security list-keychains -d user -s ~/Library/Keychains/login.keychain-db "$NOTARY_KEYCHAIN"
  fi

  echo "▸ Submitting to Apple notary service (this can take a few minutes)…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "▸ Stapling ticket…"
  xcrun stapler staple "$APP"
fi

echo "▸ Building DMG…"
rm -f "$DMG"
# ULMO = lzma 压缩只读 DMG，挂载需 macOS 10.15+（本 app 要求 13+，安全）；
# 比 UDZO 小约 26%（0.8.58 实测 9.76MB → 7.22MB）。
hdiutil create -volname "ScrollShot" -srcfolder "$APP" -ov -format ULMO "$DMG"

echo ""
echo "✅ Done."
echo "   App:  $APP"
echo "   DMG:  $DMG   ← 把这个发给别人,双击安装即可"
echo ""
echo "验证签名/公证:"
echo "   spctl -a -vvv \"$APP\""
echo "   xcrun stapler validate \"$APP\""
