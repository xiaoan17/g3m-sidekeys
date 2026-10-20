//
//  ShortcutRecorder.swift — 快捷键录制器
//
//  弹一个模态小面板, 用户直接在键盘上按下想要的组合键, 录下来。
//
//  事件监听用两层保险:
//    - local monitor: 本 App 处于前台时生效, 并且会**吞掉**按键 (返回 nil),
//      所以被录的组合键不会同时触发到当前应用里
//    - global monitor: 本 App 不在前台时兜底 (需要辅助功能权限, 本 App 本来就要)
//

import AppKit

final class ShortcutRecorderController: NSObject, NSWindowDelegate {

    /// 录制结果。nil 表示用户取消。
    private var result: Shortcut?
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    /// 弹窗录制一个组合键, 返回 nil 表示取消
    static func record() -> Shortcut? {
        let controller = ShortcutRecorderController()
        return controller.run()
    }

    // MARK: - 生命周期

    private func run() -> Shortcut? {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = "录制快捷键"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.hidesOnDeactivate = false

        let title = NSTextField(labelWithString: "请按下想绑定的组合键")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.alignment = .center

        let hint = NSTextField(labelWithString: "例如 ⌘⇧A ／ ⌥⌘C。按 Esc 取消。")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center

        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: panel.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor)
        ])

        self.panel = panel

        // 开始监听
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil    // 吞掉, 不让被录的组合键真的触发出去
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)

        cleanup()
        return result
    }

    private func cleanup() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        panel = nil
    }

    // MARK: - 按键处理

    private func handle(_ event: NSEvent) {
        // Esc = 取消
        if event.keyCode == 53 {
            finish(with: nil)
            return
        }
        // 修饰键本身只产生 flagsChanged, 少数布局下也会产生 keyDown —— 忽略
        if KeyNames.modifierKeyCodes.contains(Int64(event.keyCode)) {
            return
        }

        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        finish(with: Shortcut(keyCode: Int64(event.keyCode), flags: flags))
    }

    private func finish(with shortcut: Shortcut?) {
        result = shortcut
        NSApp.stopModal()
        panel?.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 点关闭按钮 = 取消
        if result == nil {
            NSApp.stopModal()
        }
        return true
    }
}
