//
//  SidekeyMapper.swift — 纯逻辑核心层
//
//  这一层不引用任何 AppKit / 文件系统 / 全局状态, 只做一件事:
//  给定「一个事件」+「一份上下文」, 决定「这个事件该怎么处理」。
//
//  好处: 全部决策逻辑可以脱离系统事件流做单元测试, 不会出现"逻辑藏在
//  CGEvent 回调里, 改不动也测不了"的情况。
//

import CoreGraphics

// MARK: - 动作

/// 对一个被拦截的事件所采取的动作
enum SidekeyAction: Equatable {
    /// 原样放行
    case passThrough
    /// 放行, 但改写按键与修饰键标志 (Control → Command)
    case rewrite(keycode: Int64, flags: CGEventFlags)
    /// 吞掉事件, 并注入一次 Cmd+<keycode>
    case injectCommand(keycode: Int64)
    /// 吞掉事件, 不做任何事 (例如吞掉侧键抬起)
    case swallow
}

// MARK: - 上下文

/// 处理事件所需的全部状态 (由调用方在事件发生那一刻快照而来)
struct MappingContext: Equatable {
    /// 映射总开关
    var enabled: Bool = true
    /// 是否交换复制/粘贴
    var swapped: Bool = false
    /// Right Control 当前是否处于按下状态 (G3M PRO 侧键模拟的就是它)
    var rightControlDown: Bool = false

    static let `default` = MappingContext()
}

// MARK: - 映射器

/// 侧键映射的决策逻辑
enum SidekeyMapper {

    // MARK: 按键码常量

    /// kVK_ANSI_C
    static let copyKeyCode: Int64 = 8
    /// kVK_ANSI_V
    static let pasteKeyCode: Int64 = 9
    /// kVK_RightControl —— G3M PRO 侧键模拟的修饰键
    static let rightControlKeyCode: Int64 = 62

    /// 传统路径: 标准上报 buttonNumber 3 = 前侧键 / 4 = 后侧键
    static let forwardButton: Int64 = 3
    static let backButton: Int64 = 4

    // MARK: 决策

    /// 核心决策函数
    ///
    /// - Parameters:
    ///   - type: 事件类型
    ///   - keycode: 键盘事件的 keycode (非键盘事件传 0)
    ///   - flags: 键盘事件的修饰键标志
    ///   - button: 鼠标事件的 buttonNumber (非鼠标事件传 0)
    ///   - ctx:  事件发生时刻的状态快照
    /// - Returns: 应当执行的动作
    static func decide(type: CGEventType,
                       keycode: Int64 = 0,
                       flags: CGEventFlags = [],
                       button: Int64 = 0,
                       context: MappingContext = .default) -> SidekeyAction {

        switch type {
        case .keyDown, .keyUp:
            return decideKeyboard(keycode: keycode, flags: flags, context: context)

        case .otherMouseDown:
            return decideMouseDown(button: button, context: context)

        case .otherMouseUp:
            return decideMouseUp(button: button, context: context)

        default:
            return .passThrough
        }
    }

    // MARK: 私有决策

    /// G3M PRO 主路径
    ///
    /// 侧键以 Windows 风格的 RightCtrl+C / RightCtrl+V 上报, 在 macOS 上无效。
    /// 这里把 Control 改写成 Command, 即 Cmd+C / Cmd+V。
    ///
    /// 关键约束: 仅当 **Right Control 确实处于按下状态** 时才转换。
    /// 真实键盘几乎都用 Left Control, 因此 Terminal 里的 Ctrl+C 中断不受影响。
    private static func decideKeyboard(keycode: Int64,
                                       flags: CGEventFlags,
                                       context: MappingContext) -> SidekeyAction {
        guard context.enabled else { return .passThrough }
        guard keycode == copyKeyCode || keycode == pasteKeyCode else { return .passThrough }
        guard context.rightControlDown else { return .passThrough }
        guard flags.contains(.maskControl) else { return .passThrough }
        // 已经带着 Command 的事件不处理, 避免和注入的 Cmd+key 互相干扰
        guard !flags.contains(.maskCommand) else { return .passThrough }

        var newFlags = flags
        newFlags.remove(.maskControl)
        newFlags.insert(.maskCommand)

        let newKeycode: Int64
        if context.swapped {
            newKeycode = (keycode == copyKeyCode) ? pasteKeyCode : copyKeyCode
        } else {
            newKeycode = keycode
        }

        return .rewrite(keycode: newKeycode, flags: newFlags)
    }

    /// 标准鼠标侧键按下: 吞掉原始事件并注入 Cmd+C / Cmd+V
    private static func decideMouseDown(button: Int64,
                                        context: MappingContext) -> SidekeyAction {
        guard context.enabled else { return .passThrough }
        guard button == forwardButton || button == backButton else { return .passThrough }

        // button 3 默认=复制, button 4 默认=粘贴; 交换时取反
        let isCopy = (button == forwardButton) != context.swapped
        return .injectCommand(keycode: isCopy ? copyKeyCode : pasteKeyCode)
    }

    /// 标准鼠标侧键抬起: 同样吞掉, 阻止浏览器前进/后退等默认行为
    private static func decideMouseUp(button: Int64,
                                      context: MappingContext) -> SidekeyAction {
        guard context.enabled else { return .passThrough }
        guard button == forwardButton || button == backButton else { return .passThrough }
        return .swallow
    }

    // MARK: 辅助

    /// 供 UI 展示的当前映射描述
    static func mappingDescription(swapped: Bool) -> String {
        swapped ? "当前: 侧键1=粘贴, 侧键2=复制" : "当前: 侧键1=复制, 侧键2=粘贴"
    }
}
