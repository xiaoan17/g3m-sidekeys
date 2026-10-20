//
//  AppDelegate.swift — 应用生命周期
//

import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let tapManager = EventTapManager()
    private var statusItem: NSStatusItem!
    private var bindingSettings: BindingSettingsWindowController?

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
        AppState.shared.swapSideBindings()
    }

    /// 打开按键绑定设置窗口
    @objc private func openBindingSettings() {
        if bindingSettings == nil {
            bindingSettings = BindingSettingsWindowController()
        }
        bindingSettings?.present()
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
        // 关闭 macOS 11+ 的「自动给菜单项加图标留白」行为,
        // 否则每一行左侧都会多出一块空白, 菜单看上去又宽又散。
        menu.autoenablesItems = false

        let state = AppState.shared

        // ── 状态区: 一句话说清「现在是什么状态」 ──
        let statusLine = NSMenuItem(title: statusTitle(for: state), action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        // ── 主操作 ──
        let toggle = NSMenuItem(title: state.enabled ? "暂停侧键映射" : "启用侧键映射",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = state.enabled ? .on : .off
        menu.addItem(toggle)

        let settings = NSMenuItem(title: "按键绑定设置…", action: #selector(openBindingSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // 交换两个侧键的绑定 (快捷操作, 完整自定义在「按键绑定设置」里)
        let swap = NSMenuItem(title: "交换侧键 1 与 2", action: #selector(toggleSwapped), keyEquivalent: "")
        swap.target = self
        menu.addItem(swap)

        // 绑定明细放进子菜单 —— 以前这里是一行 69 个字的摘要,
        // 直接把菜单撑到整屏宽度, 文字还会溢到菜单外面。
        let mappings = NSMenuItem(title: "当前绑定", action: nil, keyEquivalent: "")
        mappings.submenu = mappingSubmenu(for: state.bindings)
        menu.addItem(mappings)

        menu.addItem(.separator())

        // ── 权限: 只在没授全的时候占位置 ──
        let axOK = AXIsProcessTrusted()
        let listenOK = CGPreflightListenEventAccess()
        if !axOK || !listenOK || (state.enabled && !tapManager.isRunning) {
            if !axOK {
                menu.addItem(permissionItem(title: "辅助功能权限未授予", granted: false,
                                            action: #selector(openAccessibilitySettings)))
            }
            if !listenOK {
                menu.addItem(permissionItem(title: "输入监控权限未授予", granted: false,
                                            action: #selector(openInputMonitoringSettings)))
            }
            if state.enabled && !tapManager.isRunning {
                let warn = NSMenuItem(title: "监听未运行 · 授予权限后请重启 App",
                                      action: #selector(restartApp), keyEquivalent: "")
                warn.target = self
                menu.addItem(warn)
            }
            menu.addItem(.separator())
        }

        // ── 二级设置收进「更多设置」──
        let more = NSMenuItem(title: "更多设置", action: nil, keyEquivalent: "")
        more.submenu = moreSettingsMenu(for: state)
        menu.addItem(more)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 G3M Sidekeys", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// 菜单顶部的一行状态摘要 (控制在很短的一行内)
    private func statusTitle(for state: AppState) -> String {
        if !state.enabled { return "映射已暂停" }
        let axOK = AXIsProcessTrusted()
        let listenOK = CGPreflightListenEventAccess()
        if !axOK || !listenOK { return "缺少权限 · 映射未生效" }
        if !tapManager.isRunning { return "监听未运行" }
        return "映射运行中 · \(Bundle.main.appVersion)"
    }

    /// 「当前绑定」子菜单: 一行一个来源, 不再横向堆叠
    private func mappingSubmenu(for table: BindingTable) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for source in BindingSource.allCases {
            let item = NSMenuItem(title: "\(source.displayName)  →  \(table[source].displayName)",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        return submenu
    }

    /// 「更多设置」子菜单
    private func moreSettingsMenu(for state: AppState) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        submenu.addItem(loginItem)

        submenu.addItem(.separator())

        let logItem = NSMenuItem(title: "日志级别: \(state.logLevel.displayName)",
                                 action: #selector(cycleLogLevel), keyEquivalent: "")
        logItem.target = self
        submenu.addItem(logItem)

        let retentionItem = NSMenuItem(title: "日志保留: \(state.logRetentionDays) 天",
                                       action: #selector(cycleLogRetention), keyEquivalent: "")
        retentionItem.target = self
        submenu.addItem(retentionItem)

        let reveal = NSMenuItem(title: "在访达中显示日志", action: #selector(revealLogFile), keyEquivalent: "")
        reveal.target = self
        submenu.addItem(reveal)

        let resetPerms = NSMenuItem(title: "打开辅助功能设置", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        resetPerms.target = self
        submenu.addItem(.separator())
        submenu.addItem(resetPerms)

        let restart = NSMenuItem(title: "重新启动", action: #selector(restartApp), keyEquivalent: "r")
        restart.target = self
        submenu.addItem(restart)

        return submenu
    }

    private func permissionItem(title: String, granted: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: granted ? "\(title): 已授予" : "\(title) · 点此去授予",
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
