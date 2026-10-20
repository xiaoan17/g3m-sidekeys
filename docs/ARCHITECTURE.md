# G3M Sidekeys — 系统架构与设计梳理

> 本文梳理当前代码的分层结构、已确认的问题、以及后续可做的改进。
> 文中每条「已修」都对应仓库里可运行的代码与回归测试，不是设想。

---

## 1. 这是一个什么形态的产品

先说清楚定位，因为它决定了后面所有取舍：

- **macOS 菜单栏 App**（`LSUIElement = true`），不占 Dock，没有主窗口
- **纯用户态**，不需要内核扩展，不做驱动，不联网
- **单进程、单二进制**，`swiftc` 直接编译，没有 Xcode 工程、没有 Swift Package、没有依赖管理
- 唯一界面是**菜单栏菜单** + 一个**设置窗口**

这几点合起来意味着：**任何会引入运行时依赖、后台进程或网络的设计都要非常谨慎。**
用户装它是为了「鼠标侧键能复制粘贴」，不是为了让 Mac 多一个常驻服务。

> 因此本项目**没有**前后端之分，也没有「Web 前端 + API 后端」这一层。
> 下面讲的「分层」指的是**进程内的逻辑分层**，它承担的是同样的职责：
> 把「难测的系统交互」关在最小的范围里，让绝大部分逻辑可以脱离系统事件流单测。

---

## 2. 现有分层

```
┌─────────────────────────────────────────────────────────┐
│  App/            界面层                                   │
│  ├─ AppDelegate              菜单栏菜单 + 应用生命周期      │
│  ├─ BindingSettingsWindow…   按键绑定设置窗口              │
│  ├─ ShortcutRecorder         快捷键录制面板                │
│  └─ DesignTokens             全局设计 token (v1.3.0 新增)   │
├─────────────────────────────────────────────────────────┤
│  Capture/        捕获层                                    │
│  ├─ EventTapManager   CGEventTap 生命周期 + 状态自愈      │
│  └─ EventInjector     组合键 / 鼠标点击注入                │
├─────────────────────────────────────────────────────────┤
│  Core/           纯逻辑层 (不碰 UI / 磁盘 / 全局状态)      │
│  ├─ Binding         来源 → 动作 的数据模型 + 绑定表        │
│  ├─ SidekeyMapper   决策核心: (事件, 上下文) → 动作        │
│  ├─ ModifierText    修饰键 → 字符 的换算                   │
│  ├─ AppState        单一数据源 + 变更通知                 │
│  └─ Settings        UserDefaults 持久化                   │
├─────────────────────────────────────────────────────────┤
│  Diagnostics/     日志层 (可开关 / 0600 / 自动轮转 / 异步)  │
└─────────────────────────────────────────────────────────┘
```

**依赖方向是单向的**：`App → Capture → Core`，`Core` 不反向依赖任何上层。
这是当前项目**最值得保留的设计**，下面所有建议都建立在它之上。

### 核心不变式

`SidekeyMapper.decide(type:keycode:flags:button:scrollDelta:context:) -> SidekeyAction`
是一个**纯函数**：不读磁盘、不碰 UI、不看全局状态、不产生副作用。
所有「该做什么」的判断都收敛在这一个函数里，因此可以脱离系统事件流直接单测。

---

## 3. 走一遍完整数据流

以「G3M 侧键按下」为例：

```
① 硬件事件到达
   G3M 上报 RightCtrl+C (Windows 风格, macOS 上本来无效)

② CGEventTap 回调 (EventTapManager.handle)
   ├─ 识别是自己注入的事件吗? → 是就直接放行 (防自触发递归)
   ├─ flagsChanged → 更新 rightControlDown 状态
   └─ 快照当前状态 → MappingContext

③ 纯决策 (SidekeyMapper.decide)
   输入: 事件类型 + 键码 + flags + 绑定表 + 状态
   输出: SidekeyAction (passThrough / rewrite / injectShortcut / …)

④ 执行动作
   ├─ .rewrite        → 改写键码与 flags, 事件继续往下走
   ├─ .rewriteText    → 改写 unicode 串 (「按住修饰键」用)
   ├─ .injectShortcut → EventInjector 注入, 原事件吞掉
   └─ .swallow        → 事件吞掉, 什么都不做
```

**这套设计的关键价值**：③ 是纯函数，所以 90% 的行为可以用 200 条断言覆盖，
不需要真的去按鼠标。`Tests/run_tests.swift` 现在有 **202 项断言**。

---

## 4. 已确认并修复的问题（v1.3.0）

下面每一条都是**实际复现过**的，不是代码审阅时的猜测。

### 4.1 修饰键换算写死了 ⌥ —— 「按住左 Command」会打出「˚」🔴 严重

`ModifierText.translate()` 里无条件执行 `set(optionKey)`，于是**无论按住的是哪个修饰键，
都按 ⌥ 去换算**。

实测（US 布局，键码 40 = K）：

| 按住的修饰键 | 实际算出 | 应该是 |
| --- | --- | --- |
| 右 Option | `˚` | `˚` ✅ |
| **左 Command** | **`˚`** | `k` ❌ |
| **左 Control** | **`˚`** | 控制字符 ❌ |
| **Shift** | **`˚`** | `K` ❌ |

**根因**：把「修饰键状态」和「字符生成」混为一谈了。
⌘ / ⌃ 根本不改变键帽上的字符（⌘K 的字符仍然是 `k`），它们的作用在**应用读到的
`modifierFlags`** 上。只有 ⌥ / ⇧ 会改变字形。

**修法**：新增 `ModifierText.altersGlyph(_:)`，只有 ⌥ / ⇧ 走改写字符的路，
⌘ / ⌃ 走「补 modifierFlags」的路。

### 4.2 用户自己按住的 Shift 被整个吞掉 🔴 严重

`ModifierText.character(for:holding:)` **根本不接收事件自带的 flags**。
所以「按住右 Option + 按住 Shift + K」算出来和「只按住右 Option + K」完全一样。

而这个 bug 还**逃过了原有测试** —— 原测试只断言「结果不是 k 也不是 K」，
而错的实现恰好返回 `˚`，也满足这个断言。**测试写得太松，让 bug 溜过去了。**

**修法**：`character()` 增加 `eventFlags` 参数，并把它纳入缓存键
（否则带 Shift / 不带 Shift 的查询会互相命中缓存，后查的拿到错字符）。

### 4.3 `UCKeyTranslate` 的修饰键编码搞错了方向 🔴 严重

`UCKeyTranslate` 要的是**低字节**形式：

```
cmd = 0x01   shift = 0x02   option = 0x08   control = 0x10
```

而 Carbon 常量是 `cmdKey = 0x0100` / `optionKey = 0x0800` ……
**传高字节形式会静默失效** —— 实测传 `0x0800` 得到的是普通 `k` 而不是 `˚`，
不报任何错。

原代码用 `carbonFlag >> 8` 恰好是对的，但这个「>> 8」没有任何注释说明，
很容易被后人「顺手清理」掉。

**修法**：新增 `ModifierText.carbonState(from:)` / `carbonState(for:)`，
把编码规则集中到一处，并在注释里写明为什么必须右移 8 位。

### 4.4 布局标识用指针地址，会误判 🔴 中等

`ModifierText.currentLayoutID()` 用 `String(describing: ptr)` 当布局标识 ——
那是 `kTISPropertyUnicodeKeyLayoutData` 的**指针地址**。

指针地址会被系统回收后复用，两个不同布局可能拿到同一个地址，导致缓存清空时机不对
（旧字符被当成新布局的结果继续用）。

**修法**：改用 **输入源 ID**（`kTISPropertyInputSourceID`，形如 `com.apple.keylayout.ABC`），
语义稳定。

### 4.5 每写一条日志就新建一个 `ISO8601DateFormatter` 🟡 性能

```swift
// 修复前
let line = "\(ISO8601DateFormatter().string(from: Date())): \(message)\n"
```

实测**单次 0.141 ms，比复用同一个实例慢 222 倍**。而这行代码跑在 `CGEventTap`
的回调里 —— 回调有严格的时间预算，超时系统会直接禁用事件流，
表现为「侧键偶发失灵」。

**修法**：复用一个静态实例，并把格式化挪到日志队列里做（顺带保证
`ISO8601DateFormatter` 只被一条线程使用）。

### 4.6 日志保留天数存在数据竞争 🟡 中等

`Logger._retentionDays` **主线程写**（菜单改设置）、**日志队列读**（清理定时器比较文件时间），
裸属性跨线程读写。

**修法**：读写都走 `stateLock`。

### 4.7 热路径上的无谓字符串拼接 🟡 性能

事件回调里 `Logger.shared.diagnostic("...\(button)")` 的插值**在检查级别之前就执行了** ——
即使日志级别是「仅错误」（默认），字符串照样被拼出来、照样分配内存。

**修法**：新增 `Logger.isDiagnosticEnabled`，热路径先判断再拼接。

---

## 5. 界面层：v1.3.0 的改进

### 5.1 引入单一 design token 层（`Sources/App/DesignTokens.swift`）

原来界面里散落着魔法数字：内边距 20/18/16/14/12、圆角 10、字号 15/13/12/11……
换一处就得再猜一次。

现在集中为**语义 token**：

```swift
Space.xxs / xs / sm / md / lg / xl   // 4 的倍数, 方便对齐 8pt 网格
Radius.control / Radius.card
Typography.title / sectionTitle / body / caption / shortcut
Palette.cardBackground / cardBorder / primaryText / …
Motion.fast / Motion.normal
Layout.windowMinWidth / badgeMinWidth / hoverAlpha
```

规则：**只暴露语义，不暴露像素值**；所有颜色用 `NSColor` 动态色，自动跟随系统深浅色。

### 5.2 设置窗口的可用性改进

| 改动 | 解决的问题 |
| --- | --- |
| **状态胶囊**（右上角） | 不用点开菜单栏就知道「映射运行中 / 已暂停」 |
| **「已自定义」圆点** | 改过的行会亮一个小圆点，一眼看出哪些动过，不用逐行比对默认值 |
| **悬停高亮** | 明确「这一行是可点的」 |
| **徽标紧挨下拉框** | 原来快捷键被推到窗口最右边，和下拉框隔着一大段空白，关联很弱 |
| **卡片加副标题** | 「鼠标侧键 / 滚轮」不再是干巴巴的四个字，补上 `G3M 侧键 · 标准鼠标的 button 3 / 4` |
| **「恢复默认」右对齐** | 和下拉框右边缘对齐，视觉上收口 |
| **弹层宽度量全部菜单** | 原来只量滚轮那份菜单，量短了下拉框会被 Auto Layout 悄悄拉变形 |

### 5.3 界面可以「看见」了（`Tools/capture_ui.swift`）

之前 `docs/` 里的预览图是手工拼的，**和实际界面已经对不上**。

新增工具可以离屏渲染真实窗口，输出浅色 / 深色两张 PNG：

```bash
mkdir -p /tmp/uishot && cp Tools/capture_ui.swift /tmp/uishot/main.swift
swiftc -O -target arm64-apple-macos13.0 -o /tmp/uishot/capture \
  Sources/Core/*.swift Sources/Capture/*.swift Sources/Diagnostics/*.swift Sources/App/*.swift \
  /tmp/uishot/main.swift
/tmp/uishot/capture docs/
```

界面改动之后跑一下，肉眼确认，而不是凭代码想象。

---

## 6. 后续建议（按性价比排序）

### P0 —— 功能正确性

**6.1 菜单栏菜单里的「当前绑定」子菜单只读不写**
现在只能看，改还得回设置窗口。建议直接让菜单项可点：点了就打开设置窗口并高亮对应行。
菜单栏是这类工具的**主入口**，能少一次窗口往返就少一次。

**6.2 缺少「按下侧键时的即时反馈」**
用户改完绑定后，**没有任何办法确认它生效了**。建议在设置窗口加一个「测试」区：
点一下，工具就注入一次当前绑定的动作，让用户立刻看到效果。
这是目前最容易让用户困惑的点 —— 「我改了，到底生效没有？」

**6.3 `MappingContext` 快照的边界**
`AppState.mappingContext` 永远返回 `rightControlDown: false`，实际值由
`EventTapManager` 在调用点逐个覆盖。目前只有一处调用，所以没问题；
但**将来若加第二处调用，极易漏覆盖**。
建议把这三个易变字段从 `MappingContext` 里拆出去，改由 `EventTapManager` 显式组装。

### P1 —— 健壮性

**6.4 `rightControlDown` 的自愈逻辑可以更收敛**
当前有五条自愈路径（A~E），写在注释里很详细，但**逻辑分散在
`handleFlagsChanged` / `handle` / `enforceRightControlTimeout` 三处**。
建议抽成一个 `RightControlState` 小类型，把状态和自愈规则收到一起 ——
这个状态一旦卡住，用户的真实 `Ctrl+C` 会被全部误转成 `Cmd+C`，
后果比任何 UI 问题都严重，值得单独一个文件。

**6.5 注入事件的时间戳**
`EventInjector` 注入的事件用的是 `CGEventSource(stateID: .hidSystemState)`，
没有设置 `eventSourceUserData` 之外的其它标记。
虽然已经用魔数防递归，但建议再加一层：**注入前记录当前时间，注入后校验时间戳**，
防止极端情况下被系统重新排序导致配对错乱。

**6.6 测试覆盖缺口**
目前 202 条断言覆盖的是**决策层**。以下三块还没有自动测试：

- `EventInjector` 的注入事件是否真的带上了正确的 flags
- `Logger` 的轮转 / 清理逻辑（`isExpired` 有测，但 `rotate()` 没有）
- `Settings` 在**真实 UserDefaults** 下的迁移路径（现在测的是独立 suite）

建议引入 Swift Package Manager，把测试变成 `swift test`。
目前 `build.sh test` 是手工 `swiftc` 拼的，加测试文件要改脚本；
换成 SPM 后 CI 会简单很多，也更符合社区惯例。
**但要注意**：引入 SPM 会改变构建方式，`build.sh` 需要相应调整，
且发布流程（`--options runtime` 硬编码运行时 + 自签名证书）不能破坏。

### P2 —— 体验

**6.7 首次启动的引导**
新用户装上后面临三个问题：不知道要开辅助功能权限、不知道要重启、不知道侧键到底生效没有。
建议做一个**首次启动引导窗口**：一条条列出「授予权限 → 重启 → 测试」，
每一步都能直接点。

**6.8 设置窗口支持搜索 / 过滤**
现在只有 5 个来源，暂时没必要。但**如果未来加入「按键序列」「多设备配置」**，
就需要了。

**6.9 支持导入 / 导出配置**
`BindingTable` 已经是 `Codable` 的，导出成 JSON 很简单。
用户可以把自己的配置发给同事，或者在换机后恢复。**成本极低，收益明确。**

**6.10 考虑支持多套配置（Profile）**
比如「办公模式」用侧键复制粘贴，「游戏模式」用侧键切窗口。
数据结构上只需要在 `BindingTable` 外面再包一层 profile 列表。

### P3 —— 工程

**6.11 补一份 `CONTRIBUTING.md`**
说明「怎么加一个新动作类型」——目前要改 `Binding.swift` 的 enum、
`Binding.swift` 的 Codable、`BindingSettingsWindowController` 的菜单、
以及 `SidekeyMapper` 的 switch。**四个地方，漏一个就是运行时崩溃。**
建议用 protocol + 注册表收敛，或者至少在 README 里写清楚这四处。

**6.12 `probe.swift` / `g3m-probe` 的归属**
根目录还留着早期 HID 探针的产物。建议移到 `Tools/hid-probe/` 下，
并写清楚它是「一次性排查工具」，不是 App 的一部分。

---

## 7. 当前项目状态

| 项目 | 状态 |
| --- | --- |
| 单元测试 | **202 项断言全部通过** |
| 构建 | ✅ 部署目标校验通过 (minos 13.0) |
| 签名 | ✅ 本地稳定证书 `G3MSidekeys Local Codesign` |
| UI 行为验证 | ✅ `Tools/verify_binding_ui.swift` 全部通过 |
| 界面预览 | ✅ 浅色 / 深色两张，由真实界面渲染 |
| 外部依赖 | **零**（仍是纯 `swiftc` 单二进制） |

---

## 8. 一句话总结

**架构底子是对的** —— 纯函数决策核心 + 单向分层 + 零依赖，值得保留。
这一轮的主要收获是**在核心逻辑里揪出了三个静默的错误**（修饰键换算、
Shift 丢失、编码方向），它们都表现为「看起来能跑，但结果是错的」，
这类问题靠读代码看不出来，必须实测。

接下来最该做的是 **6.2（改完能看到效果）** 和 **6.7（首次启动引导）** ——
两者都直指同一个用户痛点：**「我改了，到底生效没有？」**
