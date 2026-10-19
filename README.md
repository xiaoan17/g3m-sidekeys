# G3M Sidekeys

极简 macOS 鼠标侧键映射工具（菜单栏 App）。为 HECATE G3M PRO 等无 macOS 官方驱动的鼠标而生，实际上对**任何 HID 鼠标**的侧键都生效。

## 功能

- 靠前侧键 → `Cmd+C` 复制，靠后侧键 → `Cmd+V` 粘贴（跟随鼠标固件原始定义）
- 菜单栏可一键交换两键、暂停映射、开机自启
- 兼容标准上报 button 3/4 的鼠标侧键（拦截并吞掉原始事件，浏览器不会再触发前进/后退）
- **不记录你的任何按键**（详见「隐私」）

## 原理

G3M PRO 的侧键**不上报鼠标按键**，而是模拟键盘发送 Windows 风格的 `RightCtrl+C` / `RightCtrl+V`（HID 探针实测：usage page 0x07，usage 0xe4 + 0x06/0x19），在 macOS 上本来无效。

本工具在 HID 层创建 `CGEventTap` 事件过滤器：

1. 通过 `flagsChanged` 事件追踪 Right Control 的按下状态；
2. 拦截带 Control 标志的 C/V 按键事件，把 Control 改写为 Command（即 `Cmd+C` / `Cmd+V`）；
3. 真实键盘的 `Left Ctrl+C`（如 Terminal 中断）不受影响——只有 Right Control 按下时才转换。

对标准上报 `buttonNumber 3/4` 的鼠标，则走传统的 `otherMouseDown/Up` 拦截 + 注入快捷键路径。纯用户态，无内核扩展，不依赖厂商私有协议。

## 安装使用（推荐）

1. 从 [Releases](../../releases) 下载 `G3MSidekeys-vX.Y.Z.zip`，解压得到 `G3MSidekeys.app`
2. 把 App 拖进「应用程序」（或任意位置），首次打开需「右键 → 打开」；如仍被拦截，执行：
   ```bash
   xattr -d com.apple.quarantine /Applications/G3MSidekeys.app
   ```
3. 按系统弹窗提示授予两项权限（也可点菜单栏图标里的对应条目直达设置页）：
   - 隐私与安全性 → 辅助功能 → G3M Sidekeys
   - 隐私与安全性 → 输入监控 → G3M Sidekeys
4. 点菜单栏图标 → 重新启动，之后侧键即可复制/粘贴

菜单栏图标里还可以：交换两个侧键、临时停用映射、设置开机自启、切换日志级别。

## 隐私

本工具**只在本机运行，不联网、不收集任何数据**。日志文件里也**不包含你按下的按键**：

- 日志默认级别是「仅错误」，只记录权限缺失、事件监听创建失败这类异常
- 只有手动切到「诊断」级别时，才会记录**侧键转换事件**（即本工具自己的动作），仍不记录普通按键
- 日志文件权限为 `0600`（仅本人可读写），目录 `0700`
- 日志有**双重上限**，不会无限膨胀：
  - **按体积**：单个文件超过 2 MB 自动轮转，最多保留 2 个历史文件
  - **按时间**：超过保留期的日志文件自动删除，**默认 7 天**
- 保留天数可在菜单里切换（1 / 3 / 7 / 30 天），改完立即执行一次清理

> v1.0.x 曾把每一次按键的 keycode 写入日志，且文件权限为 `0644`。v1.1.0 已彻底移除该行为。

## 从源码构建

只需 Xcode Command Line Tools：

```bash
./build.sh test     # 跑单元测试
./build.sh build    # 产出 G3MSidekeys.app
./build.sh all      # 测试 + 构建 + 打包 zip
./build.sh clean    # 清理

UNIVERSAL=1 ./build.sh build   # 生成 arm64 + x86_64 通用二进制
```

版本号写在 `VERSION` 文件里，构建时自动注入 `Info.plist`，不用手改 plist。

**部署目标固定为 macOS 13.0**（与 `Info.plist` 的 `LSMinimumSystemVersion` 一致），构建脚本会显式传 `-target` 并在构建后校验二进制的 `minos` 是否吻合。这一步不能省——`swiftc` 的默认部署目标会跟着本机工具链走，SDK 一升级就可能编出「要求 macOS 28」的二进制，结果在 macOS 27 上双击打不开（LaunchServices 报 `-10825`）。

## 项目结构

```
Sources/
  main.swift              程序入口
  Core/                   纯逻辑层（不依赖 UI / 文件系统，可单元测试）
    SidekeyMapper.swift     决策核心: (事件, 状态) → 动作
    AppState.swift          单一数据源 + 变更通知
    Settings.swift          UserDefaults 持久化
  Capture/                事件捕获层
    EventTapManager.swift   CGEventTap 生命周期 + 事件搬运
    EventInjector.swift     Cmd+key 注入
  Diagnostics/
    Logger.swift            可开关 / 0600 / 自动轮转 / 异步写
  App/
    AppDelegate.swift       菜单栏界面
Tests/
  run_tests.swift          SidekeyMapper 单元测试
```

核心决策逻辑全部集中在 `SidekeyMapper.decide(...)`，是一个不碰 UI、不碰磁盘的纯函数，因此可以脱离系统事件流直接跑单元测试：

```bash
./build.sh test
```

## 设计要点

**为什么事件回调里不写日志？** `CGEventTap` 的回调有严格的响应时间预算，回调太慢系统会直接禁用该事件流（表现为侧键偶发失灵）。所以日志写入走独立串行队列异步完成，回调里只做一次入队。

**为什么 Right Control 状态要做多重自愈？** 这个状态一旦因为漏掉一次 keyup 而卡在 `true`，之后真实键盘的 `Ctrl+C` 会被全部误转成 `Cmd+C`——恰恰是这个工具要避免的场景。当前有五条纠错路径：精确的 `flagsChanged` 事件、`flagsChanged` 里已无 Control 标志、键盘事件已无 Control 标志、2 秒兜底超时、事件监听被禁用时复位。

**为什么用 `Unmanaged.passUnretained`？** 事件回调收到的事件**我们不拥有所有权**，多 retain 一次就是每事件净泄漏一个 `CGEvent`。旧版本用的是 `passRetained`，按每天数千次击键估算，一个月可累积近百 MB。

## 已知限制

- 真实键盘的 **Right Ctrl + C/V** 也会被转成 `Cmd+C/V`（无法区分鼠标模拟的 Right Ctrl 与真实键盘的 Right Ctrl）。绝大多数键盘的 Ctrl 在左侧，不受影响。
- 需要 macOS 13 或更高。

## 分发说明

当前使用本地自签名证书 `G3MSidekeys Local Codesign` 签名（身份稳定，本机权限授予一次即永久生效）。构建脚本在找不到该证书时会自动回退到 ad-hoc 签名，但 ad-hoc 签名每次重建都会变成新身份，系统权限需要重新授予。

把 `G3MSidekeys.app` 发给别人时，对方首次打开需「右键 → 打开」，或执行：

```bash
xattr -d com.apple.quarantine G3MSidekeys.app
```

如需免提示正式分发，需要 Apple Developer 账号做 Developer ID 签名 + 公证（notarization），之后也可做成 Homebrew Cask。构建脚本已默认开启 `--options runtime`（Hardened Runtime），这是公证的硬性要求。
