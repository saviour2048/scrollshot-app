# ScrollShot — macOS 滚动长截图 App · 需求与技术方案 v1

## 目标
一个 macOS 桌面 App：框选屏幕上一块区域（或一个窗口），用户滚动内容时连续抓帧，
自动把这些帧拼接成一张完整的长图，可保存 PNG / 复制到剪贴板。

## 交互第一原则（v3）
**不论是截图还是长截图，都是同一个快捷键触发，用户体验一致。**
- 一个全局快捷键（默认用户自定，如 ⇧⌘1）唤起冻结覆盖层。
- 框选后，工具条里既有标注工具，也有「长截图」按钮。
- 普通截图：标注→保存。
- 长截图：点「长截图」→ 解冻 → 默认手动滚轮，另有「自动滚动」按钮；屏幕左下角实时预览小窗 →
  点「完成」→ 拼好的长图进入**同样的编辑器**（标注+保存），与普通截图逻辑一致。
- 不再有独立的“截图中心”窗口；一切从快捷键进。

## 形态（v2：参照 Ubuntu 的 Flameshot）
- **菜单栏后台 App**（LSUIElement，不占 Dock），常驻菜单栏图标。
- **全局快捷键**触发：按一下 → 整屏冻结+变暗 → 鼠标框选 → 选区旁弹出工具条 →
  就地标注（箭头/矩形/椭圆/文字/画笔/马赛克）→ 保存到桌面 / 复制到剪贴板。
- 选区本身即"裁剪"，无需单独裁剪步骤。
- **滚动截图**因为需要实时滚动真实内容（不能冻结屏幕），放在菜单栏菜单里单独触发，
  流程为：实时框选 → 滚动 → 拼接长图 → 再标注 → 保存。

## 平台 & 技术栈
- macOS 13+（Ventura，ScreenCaptureKit 截图 API 更完善）
- Swift + SwiftUI（菜单栏菜单 / 偏好设置）+ AppKit（冻结覆盖层、选区、标注画布）
- ScreenCaptureKit：屏幕/窗口捕获（需"屏幕录制"权限）
- 全局快捷键：sindresorhus/KeyboardShortcuts（自带可录制快捷键的偏好 UI）
- CoreGraphics / Accelerate(vImage)：帧对齐与拼接（像素级、快）
- 工程用 XcodeGen（project.yml 生成 .xcodeproj）
- 无后端、无网络、全本地；产物默认自动存到桌面

## MVP 功能（Flameshot 流程）
1. **全局快捷键**：在任意时刻按下，立即对所有显示器截一张全屏，作为冻结背景铺满屏幕并变暗。
2. **框选**：鼠标拖拽出矩形选区，选区内亮、选区外暗；可重新拖拽。
3. **就地标注**：选区旁出现工具条 —— 箭头 / 矩形 / 椭圆 / 画笔 / 文字 / 马赛克 / 颜色 / 撤销。
4. **输出**：点"保存"→ 把选区+标注合成 PNG，自动存到桌面，同时复制到剪贴板；Esc 取消。
5. **滚动截图**（菜单栏单独入口）：实时框选 → 手动向下滚动 → 按节奏抓帧 → 检测垂直重叠拼接长图 → 标注 → 保存。
6. 窗口模式（后续）：选择某个窗口直接截。

## 拼接算法（核心）
- 相邻两帧 A（先）、B（后，向下滚动了）：求竖直偏移 dy，使 A 底部与 B 顶部最匹配。
- 方法：灰度 + 缩小后，对一条横向像素带做 SAD（绝对差之和）/ 互相关，取误差最小的 dy。
- 只把 B 中 dy 以下的新内容追加到输出长图。
- 边界处理（v2）：识别固定的页头/页尾（滚动时不动的区域）避免重复。

## 权限
- 屏幕录制（必需）：首次捕获触发系统授权；引导用户到 系统设置▸隐私与安全性▸屏幕录制 勾选本 App。
- 辅助功能：仅"自动滚动"模式（v2，用 CGEvent 发滚动事件）才需要。

## 工程结构
```
ScrollShot/
  App/         ScrollShotApp.swift（菜单栏+偏好）, AppConfig.swift, Shortcuts.swift
  Capture/     ScreenCapturer.swift（全屏/区域截图）, CaptureController.swift（编排）
  Overlay/     OverlayController.swift, OverlayCanvasView.swift（冻结层+选区+标注）, ActionBar.swift
  Editor/      Annotation.swift（标注模型+绘制）, AnnotationTool.swift
  Stitch/      ImageUtils.swift, FrameStitcher.swift（滚动拼接，后续）
  Selection/   RegionSelectorWindow.swift（旧的，滚动模式实时框选会复用）
  Preferences/ PreferencesView.swift（快捷键录制 + 权限状态）
  Resources/   Assets.xcassets, Info.plist, ScrollShot.entitlements
project.yml
```

## 里程碑（v2 修订）
- **M1 ✅**：权限流程 + 屏幕录制 + 框选区域 + 单帧截图保存（窗口原型，已完成）。
- **M2（进行中）**：改造为菜单栏后台 App + 全局快捷键 + 偏好设置（录制快捷键）。
- **M3**：Flameshot 冻结覆盖层 —— 全屏冻结 + 框选 + 选区旁工具条 + 保存桌面/复制剪贴板。
- **M4**：就地标注工具 —— 箭头 / 矩形 / 椭圆 / 画笔 / 文字 / 马赛克 + 颜色 + 撤销。
- **M5**：滚动截图 —— 实时框选 + 手动滚动抓帧 + 重叠检测拼接长图 + 标注。
- **M6**：窗口模式、固定头尾处理、菜单栏图标打磨。
- 分发：Developer ID 签名 + 公证。

## 构建 & 运行
1. 装 xcodegen（brew install xcodegen）。
2. cd ScrollShot && xcodegen generate && open ScrollShot.xcodeproj。
3. Xcode 选 My Mac 运行；首次按提示授予"屏幕录制"权限后重开。

## 分发（以后）
- 自己用：本地 Xcode 跑即可。
- 给别人：需 Developer ID 签名 + 公证（notarize）。
