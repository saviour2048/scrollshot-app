#!/bin/bash
#
# 把刚构建好的 ScrollShot 装到 /Applications 并重启 —— 发版的最后一步（本机自用）。
#
#   ./scripts/build_notarize.sh      # 构建 + 公证 + DMG
#   ./scripts/publish_update.sh      # 生成 appcast（交用户传 OSS）
#   ./scripts/install_local.sh       # ← 本脚本：装到本机并重启
#
# 为什么要有这一步：以前「本机也更新到最新版」靠各 session 临时敲 `ditto`，
# 换一个 session 就漏（2026-10-27 用户问到「为什么别的 session 会自动更新，你不行」）。
# 现在固化成脚本 + 写进 AGENTS.md 发版清单，谁执行都一样。
#
# 幂等：已经是同一个 build 也会正常退出/覆盖/重启，不会报错。

set -euo pipefail
cd "$(dirname "$0")/.."

APP_SRC="build/export/ScrollShot.app"
APP_DST="/Applications/ScrollShot.app"

[ -d "$APP_SRC" ] || { echo "✗ 找不到 $APP_SRC —— 先跑 ./scripts/build_notarize.sh"; exit 1; }

want_short="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist")"
want_build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_SRC/Contents/Info.plist")"
old_short="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_DST/Contents/Info.plist" 2>/dev/null || echo "未安装")"
old_build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_DST/Contents/Info.plist" 2>/dev/null || echo "-")"

echo "▸ 本机：$old_short ($old_build)  →  $want_short ($want_build)"

# 1) 先优雅退出旧实例（它会释放屏幕录制等资源），退不掉再强杀
echo "▸ 退出正在运行的 ScrollShot…"
osascript -e 'tell application "ScrollShot" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  pgrep -f "$APP_DST/Contents/MacOS/ScrollShot" >/dev/null 2>&1 || break
  sleep 0.5
done
if pgrep -f "$APP_DST/Contents/MacOS/ScrollShot" >/dev/null 2>&1; then
  echo "  (仍在运行，强制结束)"
  pkill -f "$APP_DST/Contents/MacOS/ScrollShot" 2>/dev/null || true
  sleep 1
fi

# 2) 覆盖安装（ditto 保留签名/属性，比 cp -R 安全）
echo "▸ 安装到 $APP_DST …"
if ! ditto "$APP_SRC" "$APP_DST" 2>"build/ditto.err"; then
  # macOS 14+ App Management：非授权进程原地改 /Applications 里已有的 app 会被
  # 拒绝（Operation not permitted，逐文件满屏报错）。改名/移走是允许的，所以退到
  # 「旧包改名备份 → 全新复制 → 校验 → 删备份」；复制失败就把旧包放回去。
  echo "  (原位覆盖被 App Management 拒绝，改用改名备份 + 全新复制)"
  backup="$APP_DST.backup-$(date +%Y%m%d-%H%M%S)"
  if ! mv "$APP_DST" "$backup"; then
    echo "✗ 连改名备份都失败，无法安装；请用 Finder 拖 build/export/ScrollShot.app 覆盖。" >&2
    sed 's/^/  ditto: /' build/ditto.err | head -5 >&2
    exit 1
  fi
  if ! ditto "$APP_SRC" "$APP_DST"; then
    echo "✗ 全新复制失败，恢复旧版本" >&2
    rm -rf "$APP_DST"
    mv "$backup" "$APP_DST"
    exit 1
  fi
  rm -rf "$backup" || echo "  ⚠ 旧版本备份没删掉：$backup（可手动删除）"
fi
# 从 build 目录复制过来的不会带 quarantine，但外部来源的包可能有；清掉更省心
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true

# 3) 校验（签名 + 版本；失败就明确退出，别静默装个坏的）
echo "▸ 校验签名…"
spctl -a -vv "$APP_DST" 2>&1 | sed 's/^/  /'
installed_short="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_DST/Contents/Info.plist")"
installed_build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_DST/Contents/Info.plist")"
if [ "$installed_build" != "$want_build" ]; then
  echo "✗ 安装后的 build ($installed_build) 与构建产物 ($want_build) 不一致" >&2
  exit 1
fi

# 4) 重新启动
echo "▸ 重新启动…"
open -a "$APP_DST"

echo ""
echo "✅ 本机已更新：$installed_short ($installed_build)"
echo "   进程：$(pgrep -f "$APP_DST/Contents/MacOS/ScrollShot" | head -1 | sed 's/^/pid /')"

# macOS 26 起屏幕录制授权与「具体构建」绑定：同 Team、同 Bundle ID 的新构建也不会
# 继承旧授权，表现是截图快捷键没反应（2026-11-02 实际踩过，用户已授权仍失效）。
if [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] 2>/dev/null; then
  echo ""
  echo "⚠ macOS 26 注意：屏幕录制授权不随构建继承。"
  echo "   请确认 系统设置 → 隐私与安全性 → 屏幕录制 里 ScrollShot 已勾选；"
  echo "   若刚勾选/刚在弹窗点允许，需要再退出重开 ScrollShot 才生效。"
  echo "   验证：/usr/bin/log show --info --last 5m --predicate 'subsystem == \"com.scrollshot.app\"' | grep preflight"
fi
