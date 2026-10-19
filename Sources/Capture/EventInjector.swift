//
//  EventInjector.swift — 快捷键注入层
//
//  只负责一件事: 发出一次 Cmd+<key>。不含任何判断逻辑。
//

import CoreGraphics

enum EventInjector {

    /// 注入一次 Cmd+<key> (按下 + 抬起)
    ///
    /// 注入到 .cghidEventTap 层, 因此 **不会** 被本工具自己的事件监听再次捕获,
    /// 形成无限递归。注入的事件本身带 .maskCommand, 即使被再次看到,
    /// SidekeyMapper 也会因为 "已带 Command" 而跳过, 形成双重保险。
    static func postCommandKey(_ keyCode: Int64) {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(keyCode),
                                 keyDown: true) else { return }
        guard let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(keyCode),
                               keyDown: false) else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
