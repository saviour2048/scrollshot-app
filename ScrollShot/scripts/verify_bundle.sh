#!/bin/bash
#
# Post-build bundle verification. Run after ./scripts/build_notarize.sh succeeds.
# Checks: notarization ticket, key resources, critical localized strings.
# Exit non-zero if anything is missing/broken.
#
# Usage:
#   ./scripts/verify_bundle.sh [path/to/ScrollShot.app]
#
# Defaults to build/export/ScrollShot.app.

set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-build/export/ScrollShot.app}"

echo "▸ Verifying bundle: $APP"

if [[ ! -d "$APP" ]]; then
    echo "✗ App not found at $APP"
    exit 1
fi

echo "▸ Checking notarization…"
if ! spctl -a -vvv "$APP" 2>&1 | grep -q "accepted"; then
    echo "✗ Notarization check failed (spctl did not accept the app)"
    exit 1
fi
if ! xcrun stapler validate "$APP" 2>&1 | grep -q "validate action worked"; then
    echo "✗ Staple validation failed"
    exit 1
fi

echo "▸ Checking localized resources (.lproj folders)…"
for lang in en zh-Hans es; do
    LPROJ="$APP/Contents/Resources/$lang.lproj"
    if [[ ! -d "$LPROJ" ]]; then
        echo "✗ Missing localization folder: $LPROJ"
        exit 1
    fi
    STRINGS="$LPROJ/Localizable.strings"
    if [[ ! -f "$STRINGS" ]]; then
        echo "✗ Missing Localizable.strings in $lang.lproj"
        exit 1
    fi
    echo "  ✅ $lang.lproj"
done

echo "▸ Checking critical localized keys…"
REQUIRED_KEYS=(
    "settings.title"
    "settings.subtitle"
    "menu.launcher"
    "menu.capture"
    "menu.preferences"
    "menu.quit"
)

for key in "${REQUIRED_KEYS[@]}"; do
    if ! plutil -p "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings" | grep -q "\"$key\""; then
        echo "✗ Missing required key in zh-Hans: $key"
        exit 1
    fi
    if ! plutil -p "$APP/Contents/Resources/en.lproj/Localizable.strings" | grep -q "\"$key\""; then
        echo "✗ Missing required key in en: $key"
        exit 1
    fi
done

echo "▸ Checking version info…"
VERSION=$(defaults read "$(cd "$(dirname "$APP")"; pwd)/$(basename "$APP")/Contents/Info.plist" CFBundleShortVersionString)
BUILD=$(defaults read "$(cd "$(dirname "$APP")"; pwd)/$(basename "$APP")/Contents/Info.plist" CFBundleVersion)
echo "  Version: $VERSION ($BUILD)"

echo ""
echo "✅ Bundle verification passed for ScrollShot $VERSION (build $BUILD)"
