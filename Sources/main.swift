//
//  main.swift — 程序入口
//
//  G3MSidekeys — 极简 macOS 鼠标侧键映射工具 (菜单栏 App)
//
//  默认映射:
//    侧键 (G3M PRO 固件上报为 RightCtrl+C / RightCtrl+V) -> Cmd+C 复制 / Cmd+V 粘贴
//    兼容: 标准上报 buttonNumber 3/4 的鼠标侧键 -> Cmd+C / Cmd+V
//
//  原理: 在 HID 层创建 CGEventTap 过滤器。G3M PRO 的侧键不发鼠标按键,
//  而是模拟键盘发送 Windows 风格的 RightCtrl+C (复制) / RightCtrl+V (粘贴),
//  在 macOS 上无效; 这里拦截带 Control 标志的 C/V 按键事件, 改写为 Command+C/V。
//  为不误伤真实键盘 (如 Terminal 里的 Ctrl+C), 只有追踪到 Right Control
//  处于按下状态时才转换 —— 真实键盘的 Ctrl 几乎都是 Left Control。
//
//  分层:
//    Core/        纯逻辑 (可单元测试, 不依赖 UI/文件系统)
//    Capture/     事件捕获与快捷键注入
//    Diagnostics/ 日志
//    App/         菜单栏界面
//

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 不显示 Dock 图标, 纯菜单栏 App
app.run()
