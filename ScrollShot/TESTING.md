# ScrollShot 测试指南

## 为什么会反复弹出 Accessibility 权限提示

ScrollShot 的键盘重映射（`KeyMappingStore`）和输入统计（`InputEventTap`）依赖 macOS 的 **Accessibility** 权限。这个权限是跟**代码签名身份**绑定的，而不仅仅是 bundle ID 或 Team ID。

日常开发/测试构建用的是本地 Development 证书，正式发布包用的是 Developer ID Application 证书。因此：

- `/Applications/ScrollShot.app`（正式发布版）已经授权 ≠ 测试版也被授权
- 每次跑测试启动测试版 App 时，系统会把它当成一个“新 App”索要权限
- 即使用户在系统设置里看到权限已勾选，测试版依然会被判定为未授权

## 解决方案

`ScrollShotApp.swift` 在启动时检测是否正在作为 **XCTest host** 运行：

```swift
private var isRunningUnitTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
```

如果是测试模式，App 进程只保留最小初始化（语言、基本生命周期），**跳过**所有会触发权限提示或产生副作用的服务：

- `KeyMappingStore.reload()`（会弹 Accessibility 授权提示）
- `InputStatsStatusItemController.reload()` / `InputEventTap.start()`
- `MainMenuBarController.reload()` / `UsageStatusItemController.start()`
- `CaptureController.prewarm()` / `ClipboardMonitor.start()`
- `KeyboardShortcuts` 全局热键注册
- `SettingsSync` / `InputStatsSync` iCloud 文件同步
- Sparkle 更新检查、ConflictDetector 弹窗等

这样单元测试只验证纯逻辑，不会打扰用户授权。

## 如何运行测试

```bash
cd ScrollShot
xcodegen generate
xcodebuild -project ScrollShot.xcodeproj -scheme ScrollShot -configuration Debug -derivedDataPath build/derivedDebug test
```

> 建议用 **Debug** 配置跑测试；Release 配置需要额外处理 testability 和签名匹配。

## 如何添加新测试

1. 在 `ScrollShot/Tests/` 下新建 `XxxTests.swift`
2. 使用 `@testable import ScrollShot` 访问 internal 成员
3. 只测试不依赖 AppKit 权限、不依赖 iCloud、不依赖全局事件 tap 的纯逻辑
4. 如果你的测试需要启动完整 App 服务，请重新考虑：那更接近 UI/集成测试，应单独评估权限和签名方案

## 当前测试覆盖

- `InputStatsMergeTests`：验证 `DailyInputStats` 跨设备合并时各计数器正确相加
- `LauncherCalculatorTests`：验证 DDMathParser 表达式求值、非法输入过滤、格式化

## 发布前仍然要做的

单元测试通过 ≠ 可以直接发版。正式发布前必须跑：

```bash
cd ScrollShot
xcodegen generate
./scripts/build_notarize.sh
./scripts/verify_bundle.sh
```

这两个脚本会用正式签名重新构建，并验证 notarization、staple、.lproj 资源、关键本地化键等。
