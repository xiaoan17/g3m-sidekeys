//
//  EventInjector.swift — 事件注入层
//
//  只负责一件事: 把一条「动作」真正打到系统里。
//  不含任何判断逻辑 —— 判断全在 SidekeyMapper 里。
//

import CoreGraphics

enum EventInjector {

    /// 注入事件的标记
    ///
    /// 所有自己注入的事件都会在 eventSourceUserData 里写上这个魔数。
    /// EventTapManager 看到它就直接放行, 从而**杜绝自触发递归**:
    /// 例如「侧键 → 模拟中键」如果不做标记, 注入的中键事件会再次
    /// 命中中键的绑定, 无限循环。
    static let magicUserData: Int64 = 0x4733_4D53_4944_4B31   // "G3MSIDK1"

    // MARK: - 组合键

    /// 注入一次组合键 (按下 + 抬起)
    ///
    /// 注入到 .cghidEventTap 层, 因此 **不会** 被本工具自己的事件监听再次捕获,
    /// 形成无限递归。注入的事件本身带 .maskCommand, 即使被再次看到,
    /// SidekeyMapper 也会因为 "已带 Command" 而跳过, 形成双重保险。
    static func postShortcut(_ shortcut: Shortcut) {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(shortcut.keyCode),
                                 keyDown: true) else { return }
        guard let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(shortcut.keyCode),
                               keyDown: false) else { return }

        down.flags = shortcut.flags
        up.flags = shortcut.flags

        tag(down)
        tag(up)

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - 鼠标点击

    /// 在当前光标位置模拟一次鼠标点击
    static func postMouseClick(_ button: MouseButton) {
        let source = CGEventSource(stateID: .hidSystemState)
        let location = currentCursorLocation()

        let downType: CGEventType
        let upType: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case .left:
            downType = .leftMouseDown;  upType = .leftMouseUp;  cgButton = .left
        case .right:
            downType = .rightMouseDown; upType = .rightMouseUp; cgButton = .right
        case .middle:
            downType = .otherMouseDown; upType = .otherMouseUp; cgButton = .center
        }

        guard let down = CGEvent(mouseEventSource: source,
                                 mouseType: downType,
                                 mouseCursorPosition: location,
                                 mouseButton: cgButton) else { return }
        guard let up = CGEvent(mouseEventSource: source,
                               mouseType: upType,
                               mouseCursorPosition: location,
                               mouseButton: cgButton) else { return }

        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 0)

        tag(down)
        tag(up)

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - 辅助

    /// 当前光标位置 (全局坐标)
    static func currentCursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// 给事件打上「本工具注入」的标记
    private static func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: magicUserData)
    }
}
