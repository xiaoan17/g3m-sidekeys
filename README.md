# G3M Sidekeys

极简 macOS 鼠标侧键映射工具（菜单栏 App）。为 HECATE G3M PRO 等无 macOS 官方驱动的鼠标而生，实际上对**任何 HID 鼠标**的侧键都生效。

## 功能

- 靠前侧键 → `Cmd+C` 复制，靠后侧键 → `Cmd+V` 粘贴（跟随鼠标固件原始定义）
- 菜单栏可一键交换两键、暂停映射、开机自启
- 兼容标准上报 button 4/5 的鼠标侧键（拦截并吞掉原始事件，浏览器不会再触发前进/后退）

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

菜单栏图标里还可以：交换两个侧键、临时停用映射、设置开机自启。

## 从源码构建

只需 Xcode Command Line Tools：

```bash
./build.sh        # 产出 G3MSidekeys.app (自签名)
```

构建产物的权限授予和首次打开方式与上文「安装使用」相同。

## 分发说明

当前使用本地自签名证书 `G3MSidekeys Local Codesign` 签名（身份稳定，本机权限授予一次即永久生效）。

把 `G3MSidekeys.app` 发给别人时，对方首次打开需「右键 → 打开」，或执行：

```bash
xattr -d com.apple.quarantine G3MSidekeys.app
```

如需免提示正式分发，需要 Apple Developer 账号做 Developer ID 签名 + 公证（notarization），之后也可做成 Homebrew Cask。
