# Third-Party Notices

ScrollShot 使用了以下第三方代码 / 素材。各组件的版权与许可如下。

## 随源码分发的代码与素材

### WhatCable — MIT
- 位置：`ScrollShot/CableInfo/`（Core 与 Backend 部分）
- 上游：https://github.com/darrylmorley/whatcable
- Copyright (c) 2026 Darryl Morley
- 许可全文：`ScrollShot/CableInfo/LICENSE-WHATCABLE.txt`
- 说明：上游仓库中的专有部分（WhatCablePlugins）未被引入。

### RunCat 猫咪图标 — Apache License 2.0
- 位置：`ScrollShot/Resources/RunnerCat/`
- 上游：https://github.com/Kyome22/RunCat_for_mac
- 许可全文：`ScrollShot/Resources/RunnerCat/LICENSE-menubar_runcat.txt`
- 使用方式：菜单栏动画图标素材。

### m1ddc — MIT
- 位置：`ScrollShot/Resources/m1ddc`（预编译 arm64 二进制）
- 上游：https://github.com/waydabber/m1ddc
- Copyright (c) 2021 waydabber
- 许可全文：`ScrollShot/Resources/m1ddc-LICENSE.txt`

## 参考实现（算法思路改编，未整体复制）

### Stats / SMCKit — MIT
- 用于 SMC 温度读取（`ScrollShot/SystemMonitor/SMCTemperature.swift` 注释中说明）
- Stats: https://github.com/exelban/stats
- SMCKit: https://github.com/beltex/SMCKit

### Rectangle — MIT
- 窗口分屏的 AX 操作方式参考（`ScrollShot/WindowTiling/AXWindow.swift` 注释中说明）
- https://github.com/rxhanson/Rectangle

### NotchDrop — MIT
- 刘海区域几何与卡片展示的思路参考（API 用法为通用实现）
- https://github.com/Lakr233/NotchDrop

## Swift Package Manager 依赖

| 包 | 许可 | 上游 |
|---|---|---|
| KeyboardShortcuts | MIT | https://github.com/sindresorhus/KeyboardShortcuts |
| Sparkle | MIT | https://github.com/sparkle-project/Sparkle |
| DDMathParser | MIT | https://github.com/davedelong/DDMathParser |

---

## MIT License（适用于上述标注 MIT 的组件）

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
