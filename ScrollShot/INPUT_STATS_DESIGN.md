# ScrollShot 输入统计功能设计

## 背景

用户希望 ScrollShot 拥有类似 [KeyStats](https://github.com/debugtheworldbot/keyStats) 的输入统计功能：在菜单栏实时显示每日按键数、鼠标点击数、鼠标移动距离、滚动距离，点击后弹出详细统计面板（含按键排行和历史图表）。

## 对标方案

- **KeyStats** (`debugtheworldbot/keyStats`) — MIT License，Swift/macOS。
- 已克隆到本地 `keyStats-research/` 作为参考（已加入 `.gitignore`，不提交）。

从 KeyStats 借鉴的核心模式：
- 使用 `CGEvent.tapCreate(tap: .cgSessionEventTap, options: .listenOnly, ...)` 全局监听输入事件。
- 事件类型：`keyDown`、`leftMouseDown`、`rightMouseDown`、`mouseMoved`/`leftMouseDragged`/`rightMouseDragged`、`scrollWheel`。
- 鼠标移动限流到 30Hz，避免高频事件消耗 CPU。
- 每天一个 `DailyStats` 结构，存 `UserDefaults`，午夜自动重置。
- 菜单栏状态项 + `NSPopover` 展示 SwiftUI 仪表盘。

## 简化与差异

ScrollShot 的实现是 KeyStats 的精简版：
- **不记录具体输入内容**：只统计按键次数、按键名（用于排行，不记录组合/文本）、点击次数、距离。
- **无辅助进程**：KeyStats 把事件监听放在独立的 `KeyStatsHelper` 登录项中；ScrollShot 直接复用主应用的 `CGEventTap` 能力（键盘映射、截图遮罩已经在用）。
- **无高级功能**：不做应用维度统计、热图、KPS/CPS 峰值、校准、通知。
- **数据格式更简单**：`DailyInputStats` 只保留核心字段，便于后续扩展。

## 文件结构

```
InputStats/
  InputEventTap.swift              # CGEventTap 监听 + 辅助功能权限
  InputStatsStore.swift            # 统计存储、持久化、午夜重置、设置
  InputStatsModels.swift           # DailyInputStats + 格式化
  InputStatsStatusItemController.swift  # 菜单栏状态项 + popover
  InputStatsDashboardView.swift    # SwiftUI 仪表盘
```

## 集成点

- `App/ScrollShotApp.swift`：启动时根据设置加载状态项/事件 tap。
- `App/MainMenuBarController.swift`：主菜单增加「输入统计(菜单栏)」开关。
- `Preferences/PreferencesView.swift`：设置卡片增加「输入统计」开关和「菜单栏显示」开关。
- `project.yml`：加入 `InputStats` 源目录。

## 权限

需要「系统偏好设置 → 隐私与安全 → 辅助功能」授权。未授权时：
- 设置里的开关打开后会弹出系统授权提示；
- 菜单栏开关也会触发授权提示；
- 授权后需要重新打开开关（或重启 App）才能开始监听。

## 隐私说明

- 只保存在本机 `UserDefaults`，不上传。
- 按键排行只记录 keyCode 映射后的按键名（如 "A", "Space", "Return"），不记录输入顺序、组合键语义或实际输入内容。

## 后续可扩展

- 历史图表可替换为真正的图表库（如 SwiftUI Charts）。
- 可增加导出/导入数据、按应用统计、KPS/CPS 峰值、鼠标距离校准。
