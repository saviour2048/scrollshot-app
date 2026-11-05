# ScrollShot

macOS 截图 / 滚动长截图 App，交互参照 Ubuntu 的 **Flameshot**：
菜单栏后台常驻，全局快捷键唤起，整屏冻结后框选、就地标注，自动存桌面 + 复制剪贴板。
完整需求见仓库根目录的 [`SPEC.md`](../SPEC.md)。

## 构建 & 运行

```bash
brew install xcodegen          # 仅首次
cd ScrollShot
xcodegen generate             # 由 project.yml 生成 ScrollShot.xcodeproj（含 SPM 依赖）
open ScrollShot.xcodeproj
```

在 Xcode 选择 **My Mac** 运行。App 没有 Dock 图标，会出现在**菜单栏**（相机图标）。

- 首次截图触发「屏幕录制」授权：系统设置 ▸ 隐私与安全性 ▸ 屏幕录制 勾选 ScrollShot 后重开。
- 默认快捷键 **⌃⌥A**，可在「偏好设置」里重录。

> 要求 macOS 13+（Ventura）。`SCScreenshotManager` 在 macOS 14+ 使用，
> macOS 13 自动回退到一次性 `SCStream` 抓帧。
> 全局快捷键依赖 SPM 包 [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)，
> 首次 `xcodegen generate` 后 Xcode 会自动拉取。

## 进度

- **M1 ✅** 权限流程 + 屏幕录制 + 框选区域 + 单帧截图（窗口原型）。
- **M2 ✅** 改造为菜单栏后台 App + 全局快捷键 + 偏好设置（可录制快捷键）。
- **M3 ✅** Flameshot 冻结覆盖层：全屏冻结 + 框选 + 选区旁工具条 + 保存桌面/复制剪贴板。
- **M4 ✅** 就地标注：箭头 / 矩形 / 椭圆 / 画笔 / 文字 / 马赛克 + 颜色 + 撤销。
- **M5 ✅** 滚动截图：**统一从快捷键进**,长截图是冻结工具条里的一个按钮 —— 框选后点
  「长截图」→ 解冻 → 默认手动滚轮 / 可切「自动滚动」+ 左下角实时预览小窗 + 重叠检测拼接长图。
  - 自动滚动用 CGEvent 发滚动事件,需「辅助功能」权限,到底自动停止。
  - 拼好的长图进入**同一套标注编辑器**(箭头/框/文字/马赛克…)→ 存桌面 + 复制,与普通截图逻辑一致。
  - 拼接阈值/抓帧节奏/自动滚动方向可能需在真实页面上微调。
- **M6 ⏳** 固定头尾处理、窗口模式、菜单栏图标打磨。

> ⚠️ 当前环境是 Linux 容器，无法编译 macOS App；以上代码需在 Mac 上用 Xcode 编译验证。

## 流程（一个快捷键，体验一致）

1. 按全局快捷键 → 所有显示器立即截图并冻结、变暗。
2. 鼠标拖拽框选区域。
3. 选区旁工具条：标注工具（箭头/矩形/椭圆/画笔/文字/马赛克 + 颜色/粗细/撤销）、**「长截图」**、保存/复制/取消。
4. **普通截图**：标注 → 保存（存桌面 PNG + 复制剪贴板）。Esc 取消，回车保存。
5. **长截图**：点「长截图」→ 解冻 → 左下角出现预览小窗：
   - 默认自己向下滚轮，或点「自动滚动」让 App 替你滚（首次需「辅助功能」授权，到底自动停）。
   - 点「完成」→ 长图进入编辑器，标注后保存到桌面 + 复制，跟普通截图一样。

## 目录结构

```
ScrollShot/
  App/         ScrollShotApp.swift（菜单栏+偏好场景）, AppConfig.swift, Shortcuts.swift
  Capture/     ScreenCapturer.swift, CaptureController.swift（冻结+路由）,
               LongCaptureController.swift（滚动拼接编排）, LongCaptureRegion.swift, AutoScroller.swift
  Overlay/     OverlayController.swift, OverlayCanvasView.swift（选区+标注+长截图按钮）,
               AnnotationBar.swift（工具条）, LongCapturePanel.swift（左下预览小窗）
  Editor/      Annotation.swift（标注模型）, AnnotationEditorView.swift（长图可编辑画布）,
               AnnotationEditorWindowController.swift（编辑窗口）
  Stitch/      ImageUtils.swift（PNG/剪贴板/存桌面）, FrameStitcher.swift（重叠检测拼接）
  Selection/   RegionSelectorWindow.swift（暂留备用）
  Preferences/ PreferencesView.swift（快捷键录制 + 权限入口）
  Resources/   Assets.xcassets, Info.plist（LSUIElement）, ScrollShot.entitlements
  project.yml
```
