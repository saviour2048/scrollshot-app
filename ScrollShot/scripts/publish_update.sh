#!/bin/bash
#
# Publish a ScrollShot auto-update: take the freshly built, notarized DMG, write
# an EdDSA-signed appcast.xml, and upload both to your web server. After this,
# running copies of ScrollShot will see the new version on their next check.
#
#   ./scripts/build_notarize.sh      # build + sign + notarize → build/ScrollShot.dmg
#   ./scripts/publish_update.sh      # → sign appcast + upload
#
# One-time setup:
#   1. Generate the Sparkle EdDSA key pair (private key is stored in your
#      Keychain, the public key is printed — paste it into Info.plist
#      `SUPublicEDKey`):
#        "$SPARKLE_BIN/generate_keys"
#   2. Point Info.plist `SUFeedURL` at  $SPARKLE_DOWNLOAD_PREFIX/appcast.xml
#   3. Configure the two env vars below (e.g. in your shell profile).
#
# Required env var:
#   SPARKLE_DOWNLOAD_PREFIX   public URL of the folder that holds the DMG,
#                             e.g. https://your-bucket.oss-cn-hangzhou.aliyuncs.com/
#
# Optional:
#   SPARKLE_UPLOAD_DEST   scp/rsync destination for that same folder (advanced).
#                         If unset, the script just generates the files locally
#                         and you upload them manually (drag into your object
#                         storage / OSS / COS web console).
#   SPARKLE_BIN           dir containing generate_appcast/sign_update
#                         (auto-detected from the SwiftPM artifacts if unset)

set -euo pipefail
cd "$(dirname "$0")/.."   # → ScrollShot project dir

# Public URL of the folder holding the DMG. Defaults to the project's Aliyun OSS
# bucket (Beijing); override by exporting SPARKLE_DOWNLOAD_PREFIX before running.
SPARKLE_DOWNLOAD_PREFIX="${SPARKLE_DOWNLOAD_PREFIX:-https://scrollshot-dl.oss-cn-beijing.aliyuncs.com/}"

DMG="build/ScrollShot.dmg"
[ -f "$DMG" ] || { echo "✗ 找不到 $DMG —— 先跑 ./scripts/build_notarize.sh"; exit 1; }

# Locate Sparkle's command-line tools (shipped inside the SwiftPM artifact).
if [ -z "${SPARKLE_BIN:-}" ]; then
  SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -type d -path '*/artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -n1 || true)"
fi
GEN="$SPARKLE_BIN/generate_appcast"
if [ ! -x "$GEN" ]; then
  echo "✗ 找不到 generate_appcast。"
  echo "  先在 Xcode 里 build 一次(拉取 Sparkle 包),或手动设 SPARKLE_BIN=Sparkle 工具目录。"
  exit 1
fi

# generate_appcast wants a folder of archives; collect the DMG there.
STAGE="build/appcast"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$DMG" "$STAGE/"

echo "▸ 生成并签名 appcast.xml…"
"$GEN" --download-url-prefix "$SPARKLE_DOWNLOAD_PREFIX" "$STAGE"

if [ -n "${SPARKLE_UPLOAD_DEST:-}" ]; then
  echo "▸ 上传到 $SPARKLE_UPLOAD_DEST …"
  rsync -avz "$STAGE"/ "$SPARKLE_UPLOAD_DEST"
  echo ""
  echo "✅ 已发布。用户下次检查更新时即可看到新版本。"
else
  echo ""
  echo "✅ 文件已生成,在这个文件夹里:"
  echo "      $(pwd)/$STAGE"
  echo ""
  echo "   下一步:把这个文件夹里的两个文件上传到对象存储,放到这个地址对应的目录:"
  echo "      ${SPARKLE_DOWNLOAD_PREFIX%/}/"
  echo "   即:"
  echo "      ${SPARKLE_DOWNLOAD_PREFIX%/}/ScrollShot.dmg"
  echo "      ${SPARKLE_DOWNLOAD_PREFIX%/}/appcast.xml"
  echo ""
  echo "   阿里云 OSS 网页控制台: 拖进 bucket 根目录,覆盖旧文件,设为公共读。"
  echo "   ossutil 命令示例(如果已配置):"
  echo "      ossutil cp -f $(pwd)/$STAGE/ScrollShot.dmg oss://scrollshot-dl/ScrollShot.dmg"
  echo "      ossutil cp -f $(pwd)/$STAGE/appcast.xml oss://scrollshot-dl/appcast.xml"
  echo ""
  echo "   上传后务必验证:"
  echo "      ./scripts/check_remote_update.sh"
  # Reveal the folder in Finder so the files are easy to drag up.
  command -v open >/dev/null && open "$STAGE" || true
fi

echo ""
echo "   appcast 地址应为: ${SPARKLE_DOWNLOAD_PREFIX%/}/appcast.xml"
echo "   (确认它和 Info.plist 里的 SUFeedURL 完全一致)"
echo ""
echo "提示:每次发版前记得把 project.yml 的 CURRENT_PROJECT_VERSION 加 1"
echo "      (Sparkle 用它判断谁更新),MARKETING_VERSION 改成给人看的版本号。"
