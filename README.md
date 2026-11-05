# ScrollShot

ScrollShot 是一个 macOS 菜单栏工具集：截图 / 滚动长截图 / 标注，外加一组日常效率工具
（用量监控、启动器、剪贴板历史、系统监控、线缆检测、窗口分屏等）。

截图交互参照 Ubuntu 的 [Flameshot](https://github.com/flameshot-org/flameshot)：
菜单栏常驻、全局快捷键唤起、整屏冻结后框选、就地标注，保存到桌面并复制到剪贴板。

## 功能

- **截图 / 长截图**：框选、标注（箭头/矩形/椭圆/文字/画笔/马赛克/序号）、滚动拼接成一张长图
- **用量监控**：Claude / Kimi / Codex / DeepSeek / OpenCode 的额度与消耗，菜单栏常驻显示
- **启动器**：快捷键搜索并启动 App（含中英文名索引）
- **剪贴板历史、暂存架、智能粘贴**
- **系统监控**：CPU / 内存 / 网络 / 温度 / 进程，菜单栏指标与弹出详情
- **线缆检测**：USB-C 端口能力、PD 供电与实时功率（内置 [WhatCable](https://github.com/darrylmorley/whatcable) 的 MIT 部分）
- **外接显示器亮度**（经 DDC，内置 [m1ddc](https://github.com/waydabber/m1ddc)）
- 键盘重映射、输入法指示、鼠标精准、窗口分屏、设备电量、磁盘扫描
- **Agent 审批刘海卡片**：把 Codex / Kimi / DSH / Claude 的审批请求显示在刘海处（可选）

## 系统要求

- macOS 13 Ventura 及以上
- **Apple Silicon（arm64）**

## 构建

```bash
brew install xcodegen
cd ScrollShot
xcodegen generate
open ScrollShot.xcodeproj
```

在 Xcode 选择 **My Mac** 运行（Debug）。App 没有 Dock 图标，运行后出现在菜单栏（相机图标）。

### 签名（重要）

`project.yml` 里的 `DEVELOPMENT_TEAM` 是作者自己的 Team ID，**请改成你自己的**（或使用
Xcode 的自动签名），否则无法签名运行。屏幕录制等 TCC 授权绑定签名身份，换签名后需要重新授权。

发布用的签名/公证脚本见 `ScrollShot/scripts/build_notarize.sh`，需要自己的
Developer ID 证书与 App 专用密码；脚本里的身份与凭据都是占位符，按注释替换即可。
只想本地测试可以 `SKIP_NOTARIZE=1 ./scripts/build_notarize.sh`。

## 隐私

- 所有截图、剪贴板内容都只在本机处理，不上传。
- 用量监控读取本机已有的登录凭据（如 Claude / Codex / OpenCode 的本地配置），只用于向你展示你自己的额度。
- 匿名使用统计（`AnalyticsReporter`）**默认关闭**，且仓库里未配置上报端点（endpoint 为空）——
  不做任何联网上报，除非使用者自己启用并配置端点。

## 第三方组件

本项目包含或改编了若干第三方代码/素材，许可见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。其中：

- WhatCable（MIT）的 Core + Backend，位于 `ScrollShot/CableInfo/`
- RunCat 猫咪图标（Apache-2.0），位于 `ScrollShot/Resources/RunnerCat/`
- m1ddc（MIT）预编译二进制，位于 `ScrollShot/Resources/m1ddc`
- 键鼠/窗口分屏算法分别参考了 Stats/SMCKit 与 Rectangle（均为 MIT，见代码注释）

## 许可

[MIT](LICENSE)。第三方组件保留其原始许可，详见 `THIRD_PARTY_NOTICES.md` 与各目录下的 LICENSE 文件。
