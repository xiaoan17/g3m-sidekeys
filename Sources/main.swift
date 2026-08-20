//
//  G3MSidekeys — 极简鼠标侧键映射工具 (菜单栏 App)
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

import Cocoa
import ServiceManagement

// kVK_ANSI_C = 8, kVK_ANSI_V = 9
private let kKeyCopy: CGKeyCode = 8
private let kKeyPaste: CGKeyCode = 9
// kVK_RightControl = 62 (G3M PRO 侧键模拟的是 Right Control)
private let kKeyRightControl: Int64 = 62

private enum DefaultsKey {
    static let enabled = "enabled"
    static let swapped = "swapped"
}

// MARK: - 调试日志

private let kLogPath: String = {
    let home = NSHomeDirectory()
    let dir = "\(home)/Library/Logs/G3MSidekeys"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return "\(dir)/events.log"
}()

private func debugLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: kLogPath) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: kLogPath))
    }
}

// MARK: - 事件拦截核心

final class EventTapManager {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Right Control 是否处于按下状态 (G3M PRO 侧键模拟 RightCtrl+C/V)
    fileprivate var rightControlDown = false

    var isRunning: Bool { tap != nil }

    /// 注入一次 Cmd+<key>
    private static func postCommandKey(_ key: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        // 需要监听: 侧键鼠标事件(兼容标准鼠标) + 键盘 C/V 与 Right Control(G3M PRO)
        let mask: CGEventMask =
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()

            // 系统因超时等原因禁用事件流时, 重新启用
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return nil
            }

            // 诊断日志
            switch type {
            case .otherMouseDown, .otherMouseUp:
                debugLog("鼠标其他键 \(type == .otherMouseDown ? "按下" : "抬起") button=\(event.getIntegerValueField(.mouseEventButtonNumber))")
            case .leftMouseDown:
                debugLog("鼠标左键按下")
            case .keyDown:
                debugLog("键盘按下 keycode=\(event.getIntegerValueField(.keyboardEventKeycode)) flags=\(event.flags.rawValue)")
            default:
                break
            }

            // 追踪 Right Control 按下/抬起 (修饰键走 flagsChanged 事件)
            if type == .flagsChanged {
                if event.getIntegerValueField(.keyboardEventKeycode) == kKeyRightControl {
                    manager.rightControlDown = event.flags.contains(.maskControl)
                }
                return Unmanaged.passRetained(event)
            }

            // G3M PRO 主路径: 侧键上报为 RightCtrl+C / RightCtrl+V, 改写为 Cmd+C / Cmd+V。
            // 仅在 Right Control 按下时转换, 真实键盘的 Left Ctrl+C (如 Terminal 中断) 不受影响。
            if type == .keyDown || type == .keyUp {
                let keycode = event.getIntegerValueField(.keyboardEventKeycode)
                if (keycode == Int64(kKeyCopy) || keycode == Int64(kKeyPaste)),
                   manager.rightControlDown,
                   event.flags.contains(.maskControl), !event.flags.contains(.maskCommand) {
                    var flags = event.flags
                    flags.remove(.maskControl)
                    flags.insert(.maskCommand)
                    event.flags = flags
                    var newKeycode = keycode
                    if UserDefaults.standard.bool(forKey: DefaultsKey.swapped) {
                        newKeycode = (keycode == Int64(kKeyCopy)) ? Int64(kKeyPaste) : Int64(kKeyCopy)
                        event.setIntegerValueField(.keyboardEventKeycode, value: newKeycode)
                    }
                    debugLog("侧键转换: Ctrl+\(keycode == Int64(kKeyCopy) ? "C" : "V") -> Cmd+\(newKeycode == Int64(kKeyCopy) ? "C" : "V")")
                }
                return Unmanaged.passRetained(event)
            }

            guard type == .otherMouseDown || type == .otherMouseUp else {
                return Unmanaged.passRetained(event)
            }

            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            guard button == 3 || button == 4 else {
                return Unmanaged.passRetained(event) // 其他按键原样放行
            }

            if type == .otherMouseDown {
                let swapped = UserDefaults.standard.bool(forKey: DefaultsKey.swapped)
                let isCopy = (button == 3) != swapped
                EventTapManager.postCommandKey(isCopy ? kKeyCopy : kKeyPaste)
            }
            return nil // 吞掉原始侧键事件 (阻止浏览器前进/后退等默认行为)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            debugLog("!!! 事件监听创建失败 (通常是输入监控权限未授予或未重启)")
            return false // 通常是缺少「输入监控」权限
        }

        tap = newTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        runLoopSource = source
        debugLog("事件监听已启动 OK")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }
}

// MARK: - 菜单栏 App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tapManager = EventTapManager()

    private var enabled: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.enabled) }
    }
    private var swapped: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.swapped) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.swapped) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "G3M Sidekeys")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // 首次启动时主动触发系统权限申请弹窗
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }

        applyState()
    }

    private func applyState() {
        if enabled {
            _ = tapManager.start()
        } else {
            tapManager.stop()
        }
    }

    // 每次点开菜单时刷新状态显示
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // 映射开关
        let toggle = NSMenuItem(title: "启用侧键映射", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        // 交换两个侧键
        let swap = NSMenuItem(title: "交换 复制/粘贴 按键", action: #selector(toggleSwapped), keyEquivalent: "")
        swap.target = self
        swap.state = swapped ? .on : .off
        menu.addItem(swap)

        let mapping = NSMenuItem(title: swapped ? "当前: 侧键4=粘贴, 侧键5=复制" : "当前: 侧键4=复制, 侧键5=粘贴",
                                 action: nil, keyEquivalent: "")
        mapping.isEnabled = false
        menu.addItem(mapping)

        menu.addItem(.separator())

        // 权限状态
        let axOK = AXIsProcessTrusted()
        let listenOK = CGPreflightListenEventAccess()
        menu.addItem(permissionItem(title: "辅助功能权限", granted: axOK,
                                    action: #selector(openAccessibilitySettings)))
        menu.addItem(permissionItem(title: "输入监控权限", granted: listenOK,
                                    action: #selector(openInputMonitoringSettings)))
        if enabled && !tapManager.isRunning {
            let warn = NSMenuItem(title: "⚠️ 事件监听未运行 —— 请授予权限后重启本 App", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }

        menu.addItem(.separator())

        // 开机自启 (SMAppService)
        let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let restart = NSMenuItem(title: "重新启动", action: #selector(restartApp), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 G3M Sidekeys", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func permissionItem(title: String, granted: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "\(title): \(granted ? "✅ 已授予" : "❌ 未授予 (点击去设置)")",
                              action: granted ? nil : action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        enabled.toggle()
        applyState()
    }

    @objc private func toggleSwapped() {
        swapped.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "设置开机自启失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func restartApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            NSApp.terminate(nil)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 不显示 Dock 图标, 纯菜单栏 App
app.run()
