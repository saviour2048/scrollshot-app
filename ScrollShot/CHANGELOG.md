# ScrollShot 更新日志

## 0.8.84 (build 160) — 2026-11-05

### 修复

- **刘海屏菜单栏显示不完整**：系统监控数值此前会被画到刘海底下（屏幕上被黑边切掉，看起来像文字断了一半）。现已修正，数值完整显示在刘海左侧；只用笔记本屏幕时则合并成一个完整的两行项。本版包含 0.8.83 的改动。

---

## 0.8.83 (build 159) — 2026-11-05

### 修复

- **刘海屏 MacBook 的菜单栏布局**：只用笔记本屏幕时，系统监控指标会合并成一个两行项显示在刘海右侧，不再在刘海左边出现一条容易被误认为「菜单栏坏了」的浮动文字。接外接显示器时，内建屏仍用数值条、外屏保持独立项。
- 本版同时包含 0.8.82 的改动（见下）。

---

## 0.8.82 (build 158) — 2026-11-05

### 改进

- **线缆检测的功率卡片更直白**：只显示一行「Mac 当前取电」——你的 Mac 此刻从电源实际取的电（空闲时十几瓦是正常的，与充电器标称功率无关）。去掉了几乎总是空白的「约定功率」，那是充电器与 Mac 协商的档位上限，macOS 多数情况下并不提供。

---

## 0.8.81 (build 157) — 2026-11-05

### 新功能

- **用量面板支持 OpenCode Go 套餐**：菜单栏用量表和弹窗新增 OpenCode 来源，显示 5 小时滚动 / 本周 / 本月三个限流窗口的剩余额度与重置时间。无需配置——本机装过 opencode 并登录过 `opencode-go` 就会自动读取（复用 opencode CLI 的本地登录凭据）。设置 ▸ 用量 里能看到是否已检测到 key。

---

## 0.8.80 (build 156) — 2026-11-05

### 新功能

- **线缆检测面板新增「功率」卡片**：显示约定功率（充电器与设备协商好的供电档位）和实时功率（Mac 当前实际从电源取的电，每秒刷新）。拿不到的数字显示「—」，例如移动电源未公布协商合约时。约定功率是档位上限，不等于实时功率。

### 说明

- 本版与 0.8.79 功能相同，仅为修复 11 月 3 日一次误上传造成的版本号碰撞而重新发布。

---

## 0.8.76 (build 152) — 2026-11-01

### 新功能

- **外观支持跟随系统 / 浅色 / 深色**：设置 ▸ 通用 ▸ 外观可选择。选择「跟随系统」时，ScrollShot 会随 macOS 自动切换明暗主题。
- 设置页、用量面板、键盘映射、输入法切换、设备电量和外接显示器页面均完成明暗主题适配，并支持 iCloud 设置同步。

---

## 0.8.24 (build 100) — 2026-09-03

### 新功能

- **设置侧栏重新分组 + 每个功能带总开关**：左侧栏按「通用 / 截图 / 菜单栏与监控 / 键鼠与快捷键 / 效率工具 / 其他」分组；用量监控、系统监控、外接显示器、输入统计、键盘映射、输入法、鼠标精准、窗口分屏、启动器、AI 对话、剪贴板、暂存架等 12 个功能的条目右侧都有开关，平常不用的直接关掉。

### 修复

- **关掉 = 真停**：关闭功能后后台资源全部停掉（定时器、事件监听、菜单栏图标、全局快捷键一并移除），不再只是隐藏图标。外接显示器亮度关闭后启动时不再枚举显示器；启动器 / AI 对话 / 暂存架关闭后对应快捷键失效、菜单项隐藏；输入统计关闭后不再残留 iCloud 同步轮询。

---

## 0.8.23 (build 99) — 2026-09-01

### 修复

- **Claude 用量数字"冻住"不更新、却显示刚刚刷新过**：额度刷新失败时，面板仍把"更新于"刷成当前时间，而且只要还有旧数据就把失败原因完全藏起来——看起来一切正常，实际数字停在旧值。现在刷新失败不再改动"更新于"时间，额度卡片底部会直接显示橙色警告和失败原因（例如登录过期、需要重新登录）。
- **设置页"已登录 Claude"状态不准**：登录态被后台清理后（refresh token 失效），设置页仍显示"已登录"。现在该状态每次以钥匙串真实内容为准。

---

## 0.8.22 (build 98) — 2026-08-23

### 修复

- **截图工具条的颜色选择和粗细（字号）调整失效**：原来的系统颜色选择器（NSColorWell）需要弹出系统颜色面板，但截图覆盖层是全屏置顶的模态会话，面板根本打不开，表现为「点了没反应」；macOS 26 上的粗细分段控件在覆盖层里也不可靠。改为 Flameshot/QQ截图 同款的 8 色预设色板 + 细/中/粗 三个按钮，单击即生效，截图和长截图编辑器里都可用。

---

## 0.8.21 (build 97) — 2026-08-23

### 新功能

- **序号标注**：截图工具条新增「序号」工具（1.circle 图标）——在选区内单击即放下一个彩色圆底白字的数字标签，从 1 开始自动自增，适合标注操作步骤、界面元素顺序。按住拖动可微调位置，颜色和大小跟随工具条的颜色/粗细设置；撤销序号后数字自动回退不留空号，重新框选后从 1 重新开始。长截图编辑器同样可用。

---

## 0.8.20 (build 96) — 2026-08-19

### 修复

- **长截图文字发虚、像被压缩过**：长截图抓帧走的是 `SCScreenshotManager`，它会按 1x 采样再放大到你显示器的 2x 尺寸——像素数对，但每一帧都是放大过的，文字又粗又糊（普通截图没这个问题）。现在长截图改用与普通截图完全相同的 SCStream 抓帧管线，帧像素逐一对应，文字恢复锐利；顺带补齐了选区贴到屏幕顶部时菜单栏缺失的问题。

---

## 0.8.19 (build 95) — 2026-08-16

### 修复

- **深色模式下设置面板文字不可见**：系统开深色模式时，设置面板里的开关标签、分段控件、输入框渲染成白字落在白底上。现在设置面板固定使用浅色渲染，与面板本身的浅色设计一致。
- **用量监控报错更可操作**：Claude 凭据缺失/过期、Kimi API Key 无效（401/403）、Base URL 错误（404）等情况，报错文案现在直接告诉你下一步该怎么做。

---

## 0.8.18 (build 94) — 2026-08-03

### 修复

- **「关闭鼠标加速」在 macOS 26 上完全没生效**:macOS 26 不再预置线性缩放开关,旧逻辑「检测到才写入」把所有鼠标判为不支持,开关实际空转——你感觉到的仍是系统默认加速。现在改为直接写入（实测生效）。
- **线性模式下手感发「肉」、不如 ExactMouse 跟手**:线性缩放只是固定倍率,旧默认倍率 0.6875 让每个微移都被打七折。现在速度滑杆拉到 **1.0 就是真正的 1:1 原始映射**（与 ExactMouse 一致），并且速度改写到设备级属性,不再被 Logi Options+ 顶掉。

---

## 0.8.17 (build 93) — 2026-08-03

### 新增

- **快捷键把窗口移到另一块屏幕**:窗口分屏新增「移到下一屏」「移到上一屏」两个动作,按一下就把当前窗口原样搬到相邻显示器(保持相对位置,屏幕分辨率不同时自动等比缩放尺寸),多屏时循环切换。在「设置 → 窗口分屏」里给它们录快捷键即可使用。

---

## 0.8.16 (build 92) — 2026-08-02

### 新功能

- **USB-C 线缆检测**（设置 ▸ 线缆检测）：插入 USB-C 线即可看到它的真实能力——数据速度档位（USB 2.0 ~ 40Gbps）、充电功率上限（60W/100W/240W）、e-marker 厂商；充电慢时直接告诉你瓶颈是线、充电器还是 Mac 本身（如「线缆限制了充电速度」）；附带充电器 PDO 档位列表和端口下挂载的 USB 设备。基于开源项目 WhatCable（MIT），需 macOS 14+ 及 Apple 芯片。

---

## 0.8.15 (build 91) — 2026-07-31

### 修复

- **Claude Code 用量"剩余额度"长期不更新（面板一直显示旧数据）**：App 自己登录的 Claude token 过期后，自动换新 token 的请求一旦失败（限流/网络），整个额度拉取就直接报错，不会再回退到 Claude Code 钥匙串里的有效凭据。修复：自有 token 失败时正常回退 Claude Code 本地凭据；refresh 失败后 5 分钟退避，避免反复请求触发 429 限流；refresh token 彻底失效时自动清除死登录态。

---

## 0.8.14 (build 90) — 2026-07-25

### 修复

- **拖拽时暂存架经常不自动浮现**：全局鼠标事件经后台线程转发到主线程处理，而系统开始拖拽写剪贴板（changeCount +1）经常比 mouseDown 处理更早，导致基准值记成"+1 之后"，整次拖拽被判为无变化、暂存架不出现（是否漏检取决于任务调度时序，故时好时坏）。基准改为在上一次 mouseUp（手势结束）时记录，彻底避开这个毫秒级竞态窗口。

---

## 0.8.13 (build 89) — 2026-07-25

### 调整

- **暂存架宽度减半**（240 → 120）：减少对屏幕右侧空间的占用。

---

## 0.8.12 (build 88) — 2026-07-25

### 修复

- **AI 对话/翻译报 400「supported API model names are deepseek-v4-pro or deepseek-v4-flash」**：DeepSeek 官方接口已下线 `deepseek-chat` 模型名，默认模型改为 `deepseek-v4-flash`。已保存旧模型名的用户请在 设置 ▸ AI 对话 把模型改为 `deepseek-v4-flash` 或 `deepseek-v4-pro`。
- **Apple Silicon 读不到温度（显示「—°」）**：部分机型（实测 M1 / macOS 26）SMC 温度键全部返回零。现在 SMC 读不到值时自动回退到 IOHID 传感器（与 Stats 同方案），CPU 显示 pACC/eACC 核心簇平均温度，GPU 显示 GPU MTR 平均温度；Intel 机型行为不变。

---

## 0.8.11 (build 87) — 2026-07-22

### 修复

- **Shift 点按切换输入法"第一次总不生效"**：三个独立原因叠加——① 上一次 Shift 的抬起事件偶尔被系统丢弃，残留候选会毒化下一次点按（要连按几次才恢复）；② 触控板惯性滚动在手指离开后仍持续发事件，落在 Shift 按下/抬起之间就作废这次点按；③ 输入法候选窗打开时系统会静默忽略切换请求。修复：过期候选自动重置、滚轮事件不再参与判定、切换未生效时自动重试（最多 2 次）。

---

## 0.8.10 (build 86) — 2026-07-22

### 修复

- **长截图清晰度提升**：选区矩形直接来自鼠标拖拽，通常带小数坐标，ScreenCaptureKit 按分数坐标采样会对每一帧做双线性重采样（整张长图均匀发虚）。现在选区会先向外对齐到物理像素网格再采样，帧像素逐一对齐，肉眼可见更锐利；普通截图不受影响（本来就是整屏原生分辨率 + 整数裁剪）。
- 长截图拼接匹配的比对图加宽加密（64→128 宽、步长 3→2），文字密集内容的接缝错位减半。

---

## 0.8.9 (build 85) — 2026-07-22

### 修复

- **修复长时间运行后的内存暴涨**（实测 45 小时到 ~900 MB、8000+ Mach 端口）：macOS 26 系统层会为每个投递到 CGEventTap 的输入事件泄漏 ~1 KB（鼠标移动的量级下每天数百 MB）；IOKit 每次打开 HID 设备还会泄漏一条到 gamepolicyd 的 XPC 连接（端口的来源）。输入统计、Shift 切输入法改走不泄漏的 NSEvent 监听；键盘重映射 / 亮度键保留的事件 tap 只监听键盘事件；鼠标加速改为纯注册表读写，不再打开 HID 设备。
- 修复截图 overlay 拖拽时被吞事件未释放的小泄漏。

### 说明

- 排查过程与给 Apple 的最小复现见 `HANDOFF_MACOS26_INPUT_LEAKS.md`。

---

## 0.8.8 (build 84) — 2026-07-20

### 新功能

- **精准鼠标增加指针速度滑杆**：加速曲线保持关闭，跟踪速度可在 0.2–8.0 间自由调节（系统默认约 0.7），实时生效，设置可 iCloud 同步。**不拖动滑杆则 ScrollShot 不接管速度**，可以在 Logi Options+ 等工具里管理速度而不会被覆盖。

### 说明

- 经过实机排查：之前「发飘」的根因不是加速曲线没关掉（`HIDUseLinearScalingMouseAcceleration` 写入是有效的），而是跟踪速度被 Logi Options+ 拉到了约 9 倍（6.18）。曲线关闭后高速度显飘、默认速度又偏慢，所以把速度调节开放出来。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 需上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.8.6 (build 82) — 2026-07-20

### 改进

- **系统监控网速改为上传在上、下载在下**：菜单栏两行堆叠顺序按使用习惯对调。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 需上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.8.5 (build 81) — 2026-07-20

### 修复

- **修复「去除 Caps Lock 长按延迟」开关点击无反馈的问题**：与自启开关同一原因，页面状态不刷新。现在开关立即显示勾选状态。
- 同一板块的三个下拉（触发键、中/英文输入法）改为相同修复，选择立即生效并显示。

### 改进

- **Caps Lock 开关下方新增真实状态回显**：通过 `hidutil --get` 回读系统实际值，显示「已生效 / 已关闭 / 未生效（橙色）」，执行结果一眼可确认。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 需上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.8.4 (build 80) — 2026-07-20

### 修复

- **修复「登录时自动启动」开关勾选后界面无反馈的问题**：注册实际已成功（系统设置的登录项里能看到 ScrollShot），但设置页的勾选状态不刷新，看起来像没生效。现在开关状态与系统登录项保持一致。

### 改进

- **设置页合并**：「菜单栏」页并入「截图与保存」——相机图标开关本来就是截图功能的一部分，侧边栏少一个入口。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 需上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.8.3 (build 79) — 2026-07-20

### 新功能

- **Caps Lock 去除长按延迟**：输入法设置页新增开关，开启后点按 Caps Lock 立即锁定/解除大小写（`hidutil CapsLockDelayOverride=0`，无需重启；重启后 App 启动时自动重新应用）。解决 macOS 刻意忽略快速点按的问题。

### 改进

- **单击 Shift 切换对齐 macOS 语义**：现在与「最近使用的中文输入法」切换（通过系统输入法变更通知跟踪），简体拼音、繁体拼音等任意中文输入模式都可以，不再写死某一个；英文一侧仍可在设置中指定。
- **精准鼠标重写**（对齐 LinearMouse 的成熟方案）：macOS Sonoma 及以上改为逐设备设置 `HIDUseLinearScalingMouseAcceleration`，只关闭加速曲线、不再连累跟踪速度，并改为唤醒/设备插拔时自动重刷（去掉每 3 秒的定时重刷）。旧系统回退原方案。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 需上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.8.2 (build 78) — 2026-07-20

### 新功能

- **单击 Shift 切换中英文**：单独点按 Shift（1 秒内松开）在中文/英文输入法间切换；按住 Shift 或与其他键组合时行为完全不变。触发键可选左/右/任意 Shift，中、英文输入法可自选（默认自动识别 ABC + 拼音）。借鉴 Karabiner-Elements 的 to_if_alone 设计，只观察按键、不改写事件。需要辅助功能权限。
- **Caps Lock 恢复大小写锁定引导**：输入法设置页新增说明和「打开键盘设置」按钮，引导关闭 macOS 的「使用大写锁定键切换输入法」，让 Caps Lock 回归锁定大小写。
- **登录时自动启动**：通用设置新增开关（SMAppService），状态直接读取系统，不跨设备同步。

### 修复

- **修复浏览器 AX 树无界递归导致的主线程栈溢出崩溃**（开启按域名切换输入法后，某些窗口的 AX 树极深或有循环）：`BrowserURLDetector` 搜索限制深度 ≤30、节点 ≤2000。
- **修复剪贴板/启动器面板偶发 NSException 崩溃**：窗口隐藏中或 field editor 中间态时，延迟聚焦搜索框前会先校验窗口可见性、输入框仍在视图树内、且未已持有焦点。

### 说明

- Shift 切换的设置（开关、触发键、中英输入法选择）加入 iCloud 多机同步。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 需上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.8.1 (build 77) — 2026-07-16

### 改进

- **系统监控菜单栏网络改为上下两行**：下载在上、上传在下堆叠显示，用模板图渲染、自动跟随菜单栏明暗与高亮，宽度只按单行最宽计算，比原来的单行 `↓… ↑…` 省近一半宽度。
- **系统监控各项整体收窄**：菜单栏各项左右边距 12px → 6px，项与项之间空当明显缩小。

### 致谢

- 补上 0.8.0 两处灵感来源：系统监控（CPU/内存/网络/温度）学习自 **Stats**（exelban），键盘窗口分屏学习自 **Rectangle**（Ryan Hanson）。均为概念/技术借鉴，未复制代码或素材。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 已上传 `build/appcast/ScrollShot.dmg` 与 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录（公共读），Sparkle 更新已生效。

---

## 0.8.0 (build 76) — 2026-07-16

### 新功能

- **键盘窗口分屏**：通过全局快捷键把当前窗口贴到左/右/上/下半屏或四个角落（四分之一屏），支持最大化与居中；快捷键在设置中按需绑定，需辅助功能权限。灵感来自 **Rectangle**（Ryan Hanson）。
- **系统监控菜单栏**：菜单栏实时显示 CPU、内存、网络上下行速率和温度（Apple Silicon SMC），点击可展开详情面板查看占用最高的进程。灵感来自 **Stats**（exelban）。

### 改进

- 窗口分屏与系统监控的设置项加入 iCloud 多机同步白名单。

### 发版状态

- 已提交并推送至 GitHub
- build 75 为首个 0.8.0 构建；补上同步白名单后以 build 76 重出（Sparkle 按 build 号比较版本）。
- 本条目为 0.8.1 发布时补记。

---

## 0.7.37 (build 74) — 2026-07-15

### 修复

- **修复网站域名输入法切换对 Feishu 等地址栏不暴露 scheme 的浏览器失效的问题**：
  - 之前 Accessibility API 读到的 URL 可能是 `example.feishu.cn/wiki/...`（无 `https://` 前缀）。
  - `BrowserURLDetector` 现在会补齐 `https://` 后再解析 host，确保 `example.feishu.cn` 能正确匹配 `feishu.cn` 规则。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.36 (build 73) — 2026-07-15

### 修复与诊断

- **为按网站域名切换输入法增加详细诊断日志**，便于排查未生效的问题：
  - 记录監視器重載、規則評估、域名輪詢事件。
  - 記錄輔助功能權限狀態和瀏覽器 URL 讀取結果。
  - 修正 `AXIsProcessTrustedWithOptions` 的調用方式。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.35 (build 72) — 2026-07-15

### 新功能

- **按网站域名自动切换输入法（Phase 2）**：
  - 新增「启用按网站域名切换」开关，需要辅助功能权限。
  - 使用 Accessibility API 读取浏览器地址栏 URL。
  - 支持为指定浏览器 + 域名配置输入法，例如 Chrome + `feishu.cn` → 简体拼音。
  - 域名规则支持匹配自身及其子域名。
  - 支持 Safari、Chrome、Arc、Edge、Brave、Firefox 等主流浏览器。

### 改进

- 输入法规则添加界面支持「应用」和「网站」两种模式。
- 规则列表中同时显示域名和输入法名称。
- 更新 Info.plist 辅助功能说明文案。
- 新增/更新英文、西班牙文、简体中文本地化。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.34 (build 71) — 2026-07-15

### 修复

- **修复输入法应用选择器无法选择 VS Code 等 Electron App 的问题**：
  - 文件过滤同时接受 `UTType.applicationBundle` 和 `UTType.bundle`，提高兼容性。
  - Bundle ID 读取改用 `Bundle(path:)`，失败时回退到直接解析 `Contents/Info.plist` 的 `CFBundleIdentifier`。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.33 (build 70) — 2026-07-14

### 改进

- **输入法规则添加体验优化**：新增「选择应用…」按钮，打开文件选择器从 `/Applications` 选应用后自动填入 Bundle Identifier，不再需要手动查找和输入。
- 同步更新英文、西班牙文、简体中文本地化。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.32 (build 69) — 2026-07-10

### 新功能

- **按应用自动切换输入法（Input Source Pro 风格，Phase 1）**：
  - 监听当前前台应用变化，自动为不同应用切换到指定输入法。
  - 默认规则：Xcode / Terminal → ABC，微信 → 拼音。
  - 支持在设置面板中增删改规则、恢复默认、开关总开关。
  - 规则通过 iCloud 设置同步在多台 Mac 间同步。
  - Phase 1 仅实现应用级切换，不需要辅助功能权限。

### 说明

- 修正 `Info.plist` 中的辅助功能说明文案：应用级输入法切换不需要辅助功能权限；该权限用于长截图自动滚动和键盘重映射。
- 新增西班牙语、简体中文、英文本地化文本。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.31 (build 68) — 2026-07-10

### 新功能

- **匿名使用统计**：
  - 新增可选匿名统计，默认关闭。
  - 启用后生成随机匿名 ID，不上传任何个人内容或截图。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.30 (build 67) — 2026-07-10

### 修复

- **彻底重写剪贴板图片异步加载**：
  - 移除手动的 `ThumbnailLoader` / `@StateObject`。
  - 改用 SwiftUI 原生的 `.task(id:)`，由框架自动处理旧任务取消和新任务启动。
  - 切换 item 时立即清空旧图，避免 `LazyVStack` 复用行显示前一张缩略图。
  - 这是 SwiftUI 异步图片加载的推荐做法（类似 `AsyncImage` 的生命周期）。

### 说明

- 如果此前因异步加载 race condition 导致内存缓存中混入错误图片，**重启应用**会清空内存缓存。
- 若重启后仍然出现「左/右/粘贴三张图不一致」，说明本地已持久化的图片/index 关联已损坏，需要清空剪贴板历史重新积累。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.29 (build 66) — 2026-07-10

### 修复

- **修复剪贴板缩略图显示不完整/不一致**：
  - 列表图片缩略图从 `.fill`（裁剪填充）改为 `.fit`（完整缩放），让用户看到整张缩略图而非中间一小块。
  - 缩略图尺寸从 26×26 增大到 36×36，更容易辨认内容。
  - `ThumbnailLoader` 记录当前加载的 item id，避免为同一 item 重复加载，也避免旧任务把图片写回已切换的视图。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.28 (build 65) — 2026-07-10

### 修复

- **修复剪贴板缩略图与详情图不一致**：
  - `ThumbnailLoader` 在加载新 item 前立即清空旧图片，避免 `LazyVStack` 复用行时短暂显示前一张缩略图。
  - 异步解码任务被取消后不再把结果写回 UI。
  - 列表图片行增加 `.id(item.id)`，确保不同 item 的缩略图视图不被 SwiftUI 复用。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.27 (build 64) — 2026-07-10

### 性能优化

- **修复大文本剪贴板切换卡顿**：
  - 当剪贴板文本超过 1000 字符时，右侧详情面板改用 AppKit `NSTextView` 显示。
  - `NSTextView` 只渲染可见区域，避免 SwiftUI `Text` 对数千字符一次性排版导致的秒级卡顿。
  - 小文本仍使用 SwiftUI `Text`，保持轻量和一致的外观。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.26 (build 63) — 2026-07-10

### 性能优化

- **修复剪贴板历史搜索卡顿**：
  - `ClipboardItem.searchText` 改为在创建/解码时预计算，搜索时不再重复拼接字符串。
  - `ClipboardPickerModel` 过滤逻辑改为后台线程执行，并对输入做 100ms debounce。
  - 过滤结果缓存到 `filteredItems`，避免同一帧内多次全量遍历 + 排序。
  - 排序从 `O(n log n)` 改为按置顶/时间一次拆分的 `O(n)`。

- **剪贴板图片异步加载**：
  - 新增 `AsyncThumbnailImage` / `ThumbnailLoader`，缩略图在后台线程解码。
  - 列表行和详情面板不再在主线程同步读取/解码图片文件。
  - 旧请求在 item 切换时自动取消，防止搜索过程中出现旧图闪烁。

### 修复

- **修复置顶功能失效**：`ClipboardStore.togglePin` 现在正确修改数组中的 struct 元素并持久化。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.25 (build 62) — 2026-07-09

### 性能优化

- **修复长截图内存泄漏**：
  - 长截图完成或取消后，`FrameStitcher` 的中间帧缓存立即释放，不再持续占用内存。

- **合并全局 Event Tap，降低 CPU 占用**：
  - 输入统计、键盘重映射、亮度键拦截现在共享同一个 `CGEventTap`。
  - 同一份键盘/鼠标事件不再被多次处理，CPU 开销显著降低。

- **剪贴板图片缩略图 + 内存缓存**：
  - 复制图片时自动生成 400px 缩略图文件。
  - UI 列表和详情面板只加载缩略图，避免把高清原图解码到内存。
  - 使用 `NSCache` 缓存最近使用的缩略图，滚动/切换时不再重复解码。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.13 (build 50) — 2026-07-06

### 修复

- **启动器「清空废纸篓」真正可用**：
  - 改用 `FileManager.urls(for: .trashDirectory)` 定位系统废纸篓（含外接盘的 `.Trashes/<uid>`）。
  - 单个文件删除失败时继续删其余文件，不再因为某一个文件卡住就全部放弃。
  - FileManager 搞不定的文件（锁定、占用、权限）会自动回退到 `osascript` 让 Finder 处理。
  - 失败时给出具体的错误描述，而不是模糊提示。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.12 (build 49) — 2026-07-06

### 修复

- **启动器系统命令真正免授权**：
  - `清空废纸篓` 改为直接操作 `~/.Trash`，不再需要辅助功能或 Apple Events。
  - `睡眠` 改为调用 `pmset sleepnow`（IOKit 兜底），不再需要辅助功能。
  - `锁定屏幕` 改为 `SACLockScreenImmediate` 私有 API（⌃⌘Q 兜底），不再需要辅助功能。
  - `显示桌面` 改为直接发送 F11 CGEvent，不再经过 AppleScript。
  - `重新启动 / 关机 / 注销` 保留 AppleScript，但增加 `osascript` 进程兜底；若仍失败会给出更明确的提示。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.11 (build 48) — 2026-07-06

### 修复

- **长截图编辑窗口显示不全**：编辑器窗口现在会尽量占满可用屏幕空间显示长图，超出屏幕时才滚动；移除了之前 540×780 的窗口尺寸上限，并修复了滚动条不出现的问题。
- **启动器系统命令不生效**：`sleep`、`empty trash`、`lock screen` 等系统命令现在会先检查辅助功能权限，未授权时弹出系统授权框并提示用户；同时 `sleep` 和 `静音` 改用 IOKit / CoreAudio 原生 API，无需辅助功能即可生效。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.10 (build 47) — 2026-07-06

### 新功能

- **可隐藏外接显示器亮度菜单栏图标**：在「偏好设置 → 外接显示器」中新增「在菜单栏显示亮度图标」开关，关闭后菜单栏不再显示小太阳图标，亮度键控制和滑块调节仍然可用。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.9 (build 46) — 2026-07-06

### 新功能

- **菜单栏 Claude + Kimi 并排显示**：选择「数据来源: Claude + Kimi」后，菜单栏 meter 改为一只跑步猫 + 左右两列，左列 Claude、右列 Kimi。
- **可隐藏菜单栏跑步猫图标**：在「偏好设置 → 用量监控」中新增「显示跑步猫图标」开关，关闭后只显示百分比文字。

### 修复与改进

- **修复用量监控设置不同步**：之前界面选了「Claude + Kimi」但实际未写入 `UserDefaults`，导致菜单栏仍只显示 Claude。现在设置绑定直接写入，切换后立即生效。
- **启动时不再自动弹出授权框**：亮度键拦截、键盘映射等需要辅助功能权限的模块，启动时若未授权不再弹系统对话框，避免每次 Debug 测试都被重复打扰。需要在系统设置或对应偏好设置面板里手动授权。
- **测试安全开关**：设置环境变量 `SCROLLSHOT_SKIP_PERMISSION_PROMPTS=1` 可屏蔽所有授权弹窗，用于本地 Debug / 自动化测试。

### 发版状态

- 已提交并推送至 GitHub
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.7.8 (build 45) — 2026-07-06

### 新功能：外接显示器亮度控制

新增「偏好设置 → 外接显示器」，通过 `m1ddc` 控制支持 DDC 协议的外接显示器亮度。

- 启动时自动扫描外接显示器，检测到 DDC 兼容显示器后在菜单栏显示小太阳图标。
- 点击菜单栏图标弹出滑块，可单独调节每台显示器亮度。
- 可选开启「用 F1/F2 亮度键控制外接显示器」（需辅助功能权限）。
- 软件 Gamma 回退，用于不支持 DDC 的场景。
- 新增 `DisplayBrightness/` 模块、`Resources/m1ddc` 资源、亮度相关本地化。

### 新功能：菜单栏同时显示 Claude + Kimi 剩余额度

在「偏好设置 → 用量监控 → 数据来源」中选择 **Claude + Kimi**，菜单栏 meter 将两行同时显示：

- 上行：Claude 数据
- 下行：Kimi 数据

不同显示模式下会自动对应合适的窗口（例如「本周剩余 %」显示 Claude 本周 / Kimi 本周）。

### 改进：用量仪表盘自动刷新

- 仪表盘每秒检查一次，当 Claude 或 Kimi 的额度窗口到达重置时间点时自动刷新数据，避免重置后仍显示「0% 剩余」的 stale 状态。

### 修复

- **标注编辑器窗口**：现在会限制在当前屏幕可视区域内并居中显示，不再被 Dock / 菜单栏遮挡或贴到底部左下角。

### 工程与文档

- 新增 `AGENTS.md`：多机器协作规范、分支管理、发版流程、每日同步仪式。
- 新增 `HANDOFF_KEYBOARD_REMAPPING.md`：记录 right ⌘ + hjkl 方向键重映射问题的现状和后续方案。
- `scripts/build_notarize.sh` 支持 `BUNDLE_ID` 覆盖，方便打出与正式版不同 bundle ID 的 dev 包，避免 TCC 授权冲突。

### 发版状态

- 已提交并推送至 GitHub：`80c756c`
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动上传 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 至 OSS `scrollshot-dl` 根目录，公共读。

---

## 0.6.0 (build 36) — 2026-07-03

### 开发中：输入统计（Input Stats）

新增类似 KeyStats 的输入统计功能：

- 在「偏好设置 → 输入统计」中开启。
- 需要「辅助功能」权限。
- 记录每日：按键次数、左右点击次数、鼠标移动距离、滚动距离。
- 菜单栏显示实时按键数 / 点击数，点击弹出详细面板（含按键排行和 7/30 天历史柱状图）。
- 数据只保存在本机 `UserDefaults`，不上传。

实现参考 KeyStats (`debugtheworldbot/keyStats`, MIT) 并做了简化。详见 `INPUT_STATS_DESIGN.md`。

### 新功能：Yoink 式拖拽暂存架（Shelf / 暂存架）

### 新功能：Yoink 式拖拽暂存架（Shelf / 暂存架）

新增全局快捷键 **⌥⌘Y** 唤起一个 Yoink 风格的悬浮暂存架，用于临时停放文件、图片、文字，再拖到目标位置。

- **自动浮现**：按住左键开始真正拖拽时，暂存架自动从屏幕右边缘滑出；普通点击/选中文本不会触发。
  - 检测逻辑：全局鼠标监听 + 拖拽距离阈值（5 pt）+ `NSPasteboard(name: .drag).changeCount` 变化。
- **多文件堆叠**：从 Finder 拖入多个文件会合并为一条堆叠项，拖出时以 `.stack` 形态一起带走。
- **拖出即移除**：把条目拖到 Finder/其他 App 后，条目从暂存架消失（Yoink 行为）。
- **文件安全**：文件被复制到 `~/Library/Application Support/ScrollShot/Shelf/` 并保留原文件名；拖出后延迟 2 秒删除物理文件，避免 Finder 报 -43 错误。
- **支持内容**：文件/文件夹、图片（含网页直接拖出的位图）、纯文本。

### 修复

- **文本选择卡顿**：前一版测试包中，全局鼠标监听器在每次 `leftMouseDragged` 都读取 drag pasteboard 的 `changeCount` 和 `types`，导致所有 App 里选中文本时鼠标跟随滞后。已改为只在鼠标移动超过阈值且 `changeCount` 真的变化后才读取内容类型。
- **AppKit/SwiftUI 拖拽兼容**：用 `NSDraggingDestination` 透明 overlay 替代 SwiftUI `.onDrop`，解决图片文件被系统转成位图、原文件名丢失、多文件散开等问题。

### 主要新增/修改文件

```
Shelf/
  ShelfWindowController.swift   # 浮窗管理 + 自动浮现逻辑
  ShelfDropTarget.swift         # AppKit 拖拽接收 overlay
  ShelfDragSource.swift         # AppKit 拖拽源（拖出）
  ShelfStore.swift              # 文件复制/存储/持久化
  ShelfView.swift               # SwiftUI 面板内容
App/
  Shortcuts.swift               # 注册 ⌥⌘Y
  ScrollShotApp.swift           # 启动时初始化 Shelf
  MainMenuBarController.swift   # 菜单栏入口
  SettingsSync.swift            # 同步设置键
Launcher/LauncherWindowController.swift   # 启动器命令
Preferences/PreferencesView.swift         # 设置卡片
Capture/ScreenCapturer.swift              # 截图阴影/菜单栏修复（同版本附带）
project.yml                               # 加入 Shelf 源目录; build 35 → 36
```

### 发版状态

- 已提交并推送至 GitHub：`a18acc2`
- 已签名、公证、staple 通过
- 产物：`build/ScrollShot.dmg`、`build/appcast/{ScrollShot.dmg, appcast.xml}`
- 用户需手动将 `build/appcast/ScrollShot.dmg` 和 `build/appcast/appcast.xml` 上传至 OSS `scrollshot-dl` 根目录，公共读。

### 后续可能打磨点（当前未做）

- 锁定条目（拖出不移除）
- 堆叠拆分/单独拖出其中某个文件
- Handoff 跨设备同步
