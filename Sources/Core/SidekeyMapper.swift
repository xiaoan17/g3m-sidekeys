//
//  SidekeyMapper.swift — 纯逻辑核心层
//
//  这一层不引用任何 AppKit / 文件系统 / 全局状态, 只做一件事:
//  给定「一个事件」+「一份上下文」, 决定「这个事件该怎么处理」。
//
//  好处: 全部决策逻辑可以脱离系统事件流做单元测试, 不会出现"逻辑藏在
//  CGEvent 回调里, 改不动也测不了"的情况。
//
//  v1.2.0 起, 映射关系不再写死: 决策一律查 BindingTable,
//  用户可以在界面上为每个物理来源指定任意动作。
//

import CoreGraphics

// MARK: - 动作

/// 对一个被拦截的事件所采取的动作
enum SidekeyAction: Equatable {
    /// 原样放行
    case passThrough
    /// 放行, 但改写按键与修饰键标志
    case rewrite(keycode: Int64, flags: CGEventFlags)
    /// 吞掉事件, 并注入一条组合键
    case injectShortcut(Shortcut)
    /// 吞掉事件, 并模拟一次鼠标点击
    case injectMouseClick(MouseButton)
    /// 吞掉事件, 并「记下」某个修饰键正被按住 (nil = 释放)
    ///
    /// 用于没有真实载荷按键可改写的场景 (标准上报 button 3/4 的鼠标)。
    case setHeldModifier(ModifierKey?)
    /// 放行, 但把这个按键的**输出字符**改写成 text
    ///
    /// 「按住修饰键」真正生效靠的就是这个: 系统不让我们伪造修饰键状态,
    /// 那就把用户按下的每个键换成它本该输出的字符 (⌥K → ˚)。
    case rewriteText(String)
    /// 吞掉事件, 不做任何事 (例如吞掉侧键抬起)
    case swallow
}

// MARK: - 上下文

/// 处理事件所需的全部状态 (由调用方在事件发生那一刻快照而来)
struct MappingContext: Equatable {
    /// 映射总开关
    var enabled: Bool = true
    /// 当前的来源 → 动作 映射表
    var bindings: BindingTable = .default
    /// Right Control 当前是否处于按下状态 (G3M PRO 侧键模拟的就是它)
    var rightControlDown: Bool = false
    /// 当前正被「按住」的虚拟修饰键 (鼠标键按住期间)
    var heldModifier: ModifierKey? = nil
    /// 已被改写成「修饰键按下」的那个载荷按键码
    ///
    /// 它的**抬起**必须成对地改写成「修饰键松开」, 否则修饰键会卡住不放。
    /// 单靠 rightControlDown 判断是不够的 —— 按住期间真实按键会触发
    /// 「自愈证据 C」把 rightControlDown 复位掉。
    var pendingModifierKeyCode: Int64? = nil

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
    /// 标准上报 buttonNumber 2 = 滚轮按下 (中键)
    static let middleButton: Int64 = 2

    // MARK: 决策

    /// 核心决策函数
    ///
    /// - Parameters:
    ///   - type: 事件类型
    ///   - keycode: 键盘事件的 keycode (非键盘事件传 0)
    ///   - flags: 键盘事件的修饰键标志
    ///   - button: 鼠标事件的 buttonNumber (非鼠标事件传 0)
    ///   - scrollDelta: 滚动事件的纵向位移 (正=向上滚, 负=向下滚)
    ///   - ctx:  事件发生时刻的状态快照
    /// - Returns: 应当执行的动作
    static func decide(type: CGEventType,
                       keycode: Int64 = 0,
                       flags: CGEventFlags = [],
                       button: Int64 = 0,
                       scrollDelta: Double = 0,
                       context: MappingContext = .default) -> SidekeyAction {

        switch type {
        case .keyDown:
            return decideKeyboard(keycode: keycode, flags: flags, isDown: true, context: context)

        case .keyUp:
            return decideKeyboard(keycode: keycode, flags: flags, isDown: false, context: context)

        case .otherMouseDown:
            return decideMouse(button: button, isDown: true, context: context)

        case .otherMouseUp:
            return decideMouse(button: button, isDown: false, context: context)

        case .scrollWheel:
            return decideScroll(delta: scrollDelta, context: context)

        default:
            return .passThrough
        }
    }

    // MARK: 私有决策

    /// G3M PRO 主路径
    ///
    /// 侧键以 Windows 风格的 RightCtrl+C / RightCtrl+V 上报, 在 macOS 上无效。
    /// 这里识别出是哪个侧键, 再按绑定表决定要做什么。
    ///
    /// 关键约束: 仅当 **Right Control 确实处于按下状态** 时才转换。
    /// 真实键盘几乎都用 Left Control, 因此 Terminal 里的 Ctrl+C 中断不受影响。
    private static func decideKeyboard(keycode: Int64,
                                       flags: CGEventFlags,
                                       isDown: Bool,
                                       context: MappingContext) -> SidekeyAction {
        guard context.enabled else { return .passThrough }

        // 1) 是不是侧键载荷? (G3M: RightCtrl + C/V)
        //    关键约束: 仅当 **Right Control 确实处于按下状态** 时才转换。
        //    真实键盘几乎都用 Left Control, 因此 Terminal 里的 Ctrl+C 中断不受影响。
        let hasControl = flags.contains(.maskControl)
        let isPayload = context.rightControlDown
            && hasControl
            && !flags.contains(.maskCommand)
            && SidekeyMapper.sideKeySource(forPayloadKeyCode: keycode) != nil
        // 载荷被改写成修饰键按下后, 它的抬起要成对地改写成修饰键松开
        let isPendingRelease = context.pendingModifierKeyCode == keycode && hasControl

        if isPayload || isPendingRelease,
           let source = SidekeyMapper.sideKeySource(forPayloadKeyCode: keycode) {

            switch context.bindings[source] {
            case .passThrough:
                return .passThrough

            case .disabled:
                return .swallow

            case .shortcut(let shortcut):
                // 原事件带的是 Right Control —— 那是鼠标伪装出来的, 必须剥掉。
                // 其余修饰键 (用户自己按住的 Shift / Option 等) 保留, 再叠加绑定
                // 里指定的修饰键: 这样「按住 Shift 点侧键」仍然是 Shift+⌘C。
                var newFlags = flags
                newFlags.remove([.maskCommand, .maskControl])
                newFlags.formUnion(shortcut.flags)
                return .rewrite(keycode: shortcut.keyCode, flags: newFlags)

            case .mouseClick(let button):
                // 按下时点一次, 抬起时只需吞掉, 保证左右配对
                return isDown ? .injectMouseClick(button) : .swallow

            case .holdModifier(let modifier):
                // 把这个载荷按键**本身**改写成目标修饰键的按下 / 松开。
                // 这条路很关键: 事件是真实硬件事件, 只是内容被改了,
                // 系统会真的认为「右 Option」被按住 (而合成事件会被系统丢弃)。
                if isDown {
                    return .rewrite(keycode: Int64(modifier.rawValue), flags: modifier.flag)
                } else {
                    // 松开时 flags 里不能再有这个修饰键, 否则系统会一直以为它按着
                    var newFlags = flags
                    newFlags.remove(modifier.flag)
                    newFlags.remove(.maskControl)   // 鼠标伪装的 Right Ctrl
                    return .rewrite(keycode: Int64(modifier.rawValue), flags: newFlags)
                }
            }
        }

        // 2) 其余真实按键: 若某个修饰键正被鼠标键「按住」, 把输出字符换成
        //    它在该修饰键下本该输出的字符 (⌥K → ˚)。
        //
        //    为什么不是「给它补上 flags」? 因为**只改 flags 没用** ——
        //    系统的字符生成不读 event.flags, 实测补了 .maskAlternate 之后
        //    输入法照样输出普通字符。真正有效的是改写 unicode 串。
        //    换算不出来 (比如功能键) 时, 退回到补 flags 的老做法,
        //    至少让应用读到的 modifierFlags 是对的。
        //
        //    但**只对会改变字形的修饰键**才改写字符 (⌥ / ⇧):
        //    ⌘ 和 ⌃ 不改变键帽上的字符 (⌘K 仍然是 "k"), 它们的作用在
        //    应用读到的 modifierFlags 上。v1.3.0 之前一律改写字符,
        //    于是「按住左 Command」会打出 "˚" —— 完全是错的。
        if let held = context.heldModifier, keycode != rightControlKeyCode {
            if ModifierText.altersGlyph(held),
               let text = ModifierText.character(for: keycode, holding: held, eventFlags: flags) {
                return .rewriteText(text)
            }
            var newFlags = flags
            newFlags.insert(held.flag)
            return .rewrite(keycode: keycode, flags: newFlags)
        }

        return .passThrough
    }

    /// G3M 载荷按键码 → 来源
    ///
    /// 固件把前侧键定义为 C, 后侧键定义为 V。
    static func sideKeySource(forPayloadKeyCode keycode: Int64) -> BindingSource? {
        switch keycode {
        case copyKeyCode:  return .sideForward
        case pasteKeyCode: return .sideBack
        default:           return nil
        }
    }

    /// 标准鼠标侧键 / 中键: 吞掉原始事件并执行绑定动作
    private static func decideMouse(button: Int64,
                                    isDown: Bool,
                                    context: MappingContext) -> SidekeyAction {
        guard context.enabled else { return .passThrough }

        let source: BindingSource
        switch button {
        case forwardButton: source = .sideForward
        case backButton:    source = .sideBack
        case middleButton:  source = .middleClick
        default:            return .passThrough
        }

        switch context.bindings[source] {
        case .passThrough:
            // 保留系统默认: 按下和抬起都要放行, 否则鼠标会卡在"按下"状态
            return .passThrough

        case .disabled:
            return .swallow

        case .shortcut(let shortcut):
            return isDown ? .injectShortcut(shortcut) : .swallow

        case .mouseClick(let target):
            return isDown ? .injectMouseClick(target) : .swallow

        case .holdModifier(let modifier):
            // 标准鼠标没有「载荷按键」可以改写, 只能记下「这个修饰键被按住了」,
            // 由捕获层在后续真实按键上补标志位。
            return isDown ? .setHeldModifier(modifier) : .setHeldModifier(nil)
        }
    }

    /// 滚轮滚动: 无法"改写", 只能拦截后另行触发
    private static func decideScroll(delta: Double,
                                     context: MappingContext) -> SidekeyAction {
        guard context.enabled else { return .passThrough }
        guard delta != 0 else { return .passThrough }

        let source: BindingSource = delta > 0 ? .scrollUp : .scrollDown

        switch context.bindings[source] {
        case .passThrough:
            return .passThrough

        case .disabled:
            return .swallow

        case .shortcut(let shortcut):
            return .injectShortcut(shortcut)

        case .mouseClick(let button):
            return .injectMouseClick(button)

        case .holdModifier:
            // 滚动没有「按下 / 松开」之分, 按住修饰键在这里没有意义
            // (界面里也不会给滚轮提供这个选项), 保守地放行。
            return .passThrough
        }
    }

    // MARK: 辅助

    /// 供 UI 展示的当前映射描述
    static func mappingDescription(bindings: BindingTable) -> String {
        bindings.summary
    }
}
