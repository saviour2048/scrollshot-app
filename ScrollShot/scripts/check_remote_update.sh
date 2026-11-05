#!/bin/bash
#
# Verify that the public appcast matches the local one.
# Run after uploading build/appcast/ to your object storage.
#
# Usage:
#   ./scripts/check_remote_update.sh [remote-appcast-url]
#
# Defaults to the project's Aliyun OSS bucket.
#
# 除了版本号,还比对 enclosure 的 length / edSignature,以及远程 DMG 的
# sha256 与本地是否一致。2026-11-04 的事故:远端挂着另一个同版本号(155)的
# 旧构建,只比版本号的检查误报通过。版本号相同 ≠ 是同一个包。

set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE_URL="${1:-https://scrollshot-dl.oss-cn-beijing.aliyuncs.com/appcast.xml}"
LOCAL_FILE="build/appcast/appcast.xml"
LOCAL_DMG="build/appcast/ScrollShot.dmg"

fail() { echo "✗ $1"; exit 1; }

echo "▸ Remote appcast: $REMOTE_URL"
REMOTE_XML=$(curl -sSL "$REMOTE_URL") || fail "远程 appcast.xml 拿不到"
if [ -z "$REMOTE_XML" ]; then fail "远程 appcast.xml 为空"; fi
echo "$REMOTE_XML" | grep -E '<title>|<sparkle:version>|<sparkle:shortVersionString>' || true

echo ""
echo "▸ Local appcast: $LOCAL_FILE"
[ -f "$LOCAL_FILE" ] || fail "本地 $LOCAL_FILE 不存在"
grep -E '<title>|<sparkle:version>|<sparkle:shortVersionString>' "$LOCAL_FILE"

extract() {  # $1: xml, $2: attr regex
    printf '%s' "$1" | grep -o "$2" | head -1
}

echo ""
REMOTE_VER=$(extract "$REMOTE_XML" '<sparkle:version>[^<]*</sparkle:version>' | sed 's/[^0-9]//g')
LOCAL_VER=$(extract "$(cat "$LOCAL_FILE")" '<sparkle:version>[^<]*</sparkle:version>' | sed 's/[^0-9]//g')
[ "$REMOTE_VER" = "$LOCAL_VER" ] || { echo "✗ 版本不一致! 远程=$REMOTE_VER, 本地=$LOCAL_VER"; exit 1; }
echo "✓ 版本一致: $REMOTE_VER"

REMOTE_LEN=$(extract "$REMOTE_XML" 'length="[0-9]*"' | grep -o '[0-9]*')
LOCAL_LEN=$(extract "$(cat "$LOCAL_FILE")" 'length="[0-9]*"' | grep -o '[0-9]*')
[ "$REMOTE_LEN" = "$LOCAL_LEN" ] || fail "enclosure length 不一致! 远程=$REMOTE_LEN, 本地=$LOCAL_LEN (同版本号的另一个构建)"
echo "✓ DMG 长度一致: $REMOTE_LEN 字节"

REMOTE_SIG=$(extract "$REMOTE_XML" 'sparkle:edSignature="[^"]*"' | sed 's/^[^"]*"//;s/"$//')
LOCAL_SIG=$(extract "$(cat "$LOCAL_FILE")" 'sparkle:edSignature="[^"]*"' | sed 's/^[^"]*"//;s/"$//')
[ -n "$REMOTE_SIG" ] || fail "远程 appcast 缺少 edSignature"
[ "$REMOTE_SIG" = "$LOCAL_SIG" ] || fail "edSignature 不一致! 远程与本地不是同一对 appcast/DMG"
echo "✓ EdDSA 签名一致"

echo ""
echo "▸ 远程 DMG sha256 比对"
DMG_URL=$(extract "$REMOTE_XML" 'url="[^"]*"' | sed 's/^[^"]*"//;s/"$//')
[ -n "$DMG_URL" ] || fail "appcast 里解析不出 DMG url"
[ -f "$LOCAL_DMG" ] || fail "本地 $LOCAL_DMG 不存在"
LOCAL_SHA=$(shasum -a 256 "$LOCAL_DMG" | awk '{print $1}')
REMOTE_SHA=$(curl -sSL "$DMG_URL" -o /tmp/scrollshot_remote_dmg.check && shasum -a 256 /tmp/scrollshot_remote_dmg.check | awk '{print $1}')
[ "$REMOTE_SHA" = "$LOCAL_SHA" ] || fail "远程 DMG 与本地不一致! 远程=$REMOTE_SHA 本地=$LOCAL_SHA"
echo "✓ 远程 DMG 与本地完全一致: $REMOTE_SHA"

echo ""
echo "✅ 远程更新通道与本地产物完全一致,发布闭环。"
