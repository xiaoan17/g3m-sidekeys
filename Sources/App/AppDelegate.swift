//
//  AppDelegate.swift — 应用生命周期
//

import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let tapManager = EventTapManager()
    private var statusItem: NSStatusItem!

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.level = AppState.shared.logLevel
        Logger.shared.retentionDays = AppState.shared.logRetentionDays

        setupStatusItem()
        requestPermissionsIfNeeded()
        applyState()

        // 状态变化时刷新菜单
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stateDidChange),
            name: .appStateDidChange,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        tapManager.stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "computermouse",
                                   accessibilityDescription: "G3M Sidekeys")
            button.image?.isTemplate = true
            button.setAccessibilityLabel("G3M Sidekeys")
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - 权限

    private func requestPermissionsIfNeeded() {
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
    }

    // MARK: - 状态应用

    /// 依据当前配置启停事件监听
    private func applyState() {
        if AppState.shared.enabled {
            _ = tapManager.start()
        } else {
            tapManager.stop()
        }
    }

    @objc private func stateDidChange() {
        applyState()
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        AppState.shared.enabled.toggle()
    }

    @objc private func toggleSwapped() {
        AppState.shared.swapped.toggle()
    }

    @objc private func cycleLogLevel() {
        let all = LogLevel.allCases
        guard let idx = all.firstIndex(of: AppState.shared.logLevel) else { return }
        let next = all[(idx + 1) % all.count]
        AppState.shared.logLevel = next
    }

    /// 切换日志保留天数 (1 / 3 / 7 / 30 天)
    @objc private func cycleLogRetention() {
        let options = Logger.retentionOptions
        guard let idx = options.firstIndex(of: AppState.shared.logRetentionDays) else { return }
        let next = options[(idx + 1) % options.count]
        AppState.shared.logRetentionDays = next
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func revealLogFile() {
        NSWorkspace.shared.activateFileViewerSelecting([Logger.shared.logFileURL])
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

    /// 重启自身
    ///
    /// 旧版本在这里无条件 terminate, 一旦新实例启动失败, App 就直接消失了。
    /// 现在改成: 只有新实例确实起来了才退出旧实例; 失败则弹窗告知。
    @objc private func restartApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "重新启动失败"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            } else {
                NSApp.terminate(nil)
            }
            _ = self
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - 菜单构建

extension AppDelegate: NSMenuDelegate {

    /// 每次点开菜单都重建, 保证显示的是最新状态
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let state = AppState.shared

        // 映射开关
        let toggle = NSMenuItem(title: "启用侧键映射", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = state.enabled ? .on : .off
        menu.addItem(toggle)

        // 交换两个侧键
        let swap = NSMenuItem(title: "交换 复制/粘贴 按键", action: #selector(toggleSwapped), keyEquivalent: "")
        swap.target = self
        swap.state = state.swapped ? .on : .off
        menu.addItem(swap)

        let mapping = NSMenuItem(title: SidekeyMapper.mappingDescription(swapped: state.swapped),
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
        if state.enabled && !tapManager.isRunning {
            let warn = NSMenuItem(title: "⚠️ 事件监听未运行 —— 请授予权限后重启本 App",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }

        menu.addItem(.separator())

        // 日志级别
        let logItem = NSMenuItem(title: "日志级别: \(state.logLevel.displayName)",
                                 action: #selector(cycleLogLevel), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        let retentionItem = NSMenuItem(title: "日志保留: \(state.logRetentionDays) 天",
                                       action: #selector(cycleLogRetention), keyEquivalent: "")
        retentionItem.target = self
        menu.addItem(retentionItem)

        let reveal = NSMenuItem(title: "在访达中显示日志", action: #selector(revealLogFile), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())

        // 开机自启
        let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let restart = NSMenuItem(title: "重新启动", action: #selector(restartApp), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)

        menu.addItem(.separator())

        let version = NSMenuItem(title: "版本 \(Bundle.main.appVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

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
}

// MARK: - 辅助

extension Bundle {
    /// 读取 Info.plist 里的版本号
    var appVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }
}
