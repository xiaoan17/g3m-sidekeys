//
//  Binding.swift — 可自定义的按键绑定模型
//
//  把「物理来源」和「要执行的动作」彻底解耦:
//
//      来源 (BindingSource)  →  动作 (BindingAction)
//
//  来源是鼠标上真实存在的几个键 (侧键1/侧键2/滚轮按下/滚轮上/滚轮下),
//  动作可以是任意快捷键、模拟鼠标点击、禁用, 或者保留系统默认。
//
//  这一层是纯数据 + 纯逻辑, 不依赖 AppKit / 文件系统, 因此可以直接跑单元测试。
//

import CoreGraphics
import Foundation

// MARK: - 来源

/// 一个可以被绑定的物理来源
enum BindingSource: String, CaseIterable, Codable {
    /// 侧键 1 (靠前) —— G3M 固件上报 RightCtrl+C, 标准鼠标为 button 3
    case sideForward
    /// 侧键 2 (靠后) —— G3M 固件上报 RightCtrl+V, 标准鼠标为 button 4
    case sideBack
    /// 滚轮按下 (中键) —— 标准鼠标为 button 2
    case middleClick
    /// 滚轮向上滚动
    case scrollUp
    /// 滚轮向下滚动
    case scrollDown

    var displayName: String {
        switch self {
        case .sideForward: return "侧键 1（前）"
        case .sideBack:    return "侧键 2（后）"
        case .middleClick: return "滚轮按下（中键）"
        case .scrollUp:    return "滚轮上滚"
        case .scrollDown:  return "滚轮下滚"
        }
    }

    /// 供界面展示的物理来源说明, 帮用户确认自己的鼠标走的是哪条路径
    var hint: String {
        switch self {
        case .sideForward: return "G3M: RightCtrl+C ／ 标准鼠标: button 3"
        case .sideBack:    return "G3M: RightCtrl+V ／ 标准鼠标: button 4"
        case .middleClick: return "标准鼠标: button 2"
        case .scrollUp:    return "滚轮向上"
        case .scrollDown:  return "滚轮向下"
        }
    }
}

// MARK: - 快捷键

/// 一条组合键 (修饰键 + 主体键)
struct Shortcut: Equatable, Codable {
    var keyCode: Int64
    var command: Bool = false
    var option: Bool = false
    var control: Bool = false
    var shift: Bool = false

    // MARK: 常用预设

    static let copy       = Shortcut(keyCode: 8,  command: true)   // ⌘C
    static let paste      = Shortcut(keyCode: 9,  command: true)   // ⌘V
    static let cut        = Shortcut(keyCode: 7,  command: true)   // ⌘X
    static let undo       = Shortcut(keyCode: 6,  command: true)   // ⌘Z
    static let redo       = Shortcut(keyCode: 6,  command: true, shift: true)
    static let selectAll  = Shortcut(keyCode: 0,  command: true)   // ⌘A
    static let find       = Shortcut(keyCode: 3,  command: true)   // ⌘F
    static let closeWindow = Shortcut(keyCode: 13, command: true)  // ⌘W
    static let hideApp    = Shortcut(keyCode: 4,  command: true)   // ⌘H
    static let minimize   = Shortcut(keyCode: 46, command: true)   // ⌘M
    static let fullScreen = Shortcut(keyCode: 3,  command: true, control: true)
    static let nextTab    = Shortcut(keyCode: 48, control: true)
    static let prevTab    = Shortcut(keyCode: 48, control: true, shift: true)

    // MARK: 转换

    /// 显式写出成员初始化器 —— 一旦在结构体里自定义了 init,
    /// 编译器就不再自动合成成员初始化器了。
    init(keyCode: Int64,
         command: Bool = false,
         option: Bool = false,
         control: Bool = false,
         shift: Bool = false) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    /// 转成 CoreGraphics 的修饰键标志
    var flags: CGEventFlags {
        var f: CGEventFlags = []
        if command { f.insert(.maskCommand) }
        if option  { f.insert(.maskAlternate) }
        if control { f.insert(.maskControl) }
        if shift   { f.insert(.maskShift) }
        return f
    }

    /// 从 CoreGraphics 的修饰键标志构造 (忽略 caps lock 等非修饰状态)
    init(keyCode: Int64, flags: CGEventFlags) {
        self.init(keyCode: keyCode)
        command = flags.contains(.maskCommand)
        option  = flags.contains(.maskAlternate)
        control = flags.contains(.maskControl)
        shift   = flags.contains(.maskShift)
    }

    /// 界面展示用: ⌘⇧⌥⌃ 加上按键名
    var displayString: String {
        var s = ""
        if control { s += "⌃" }
        if option  { s += "⌥" }
        if shift   { s += "⇧" }
        if command { s += "⌘" }
        s += KeyNames.name(for: keyCode)
        return s
    }
}

// MARK: - 鼠标按键

/// 可被模拟点击的鼠标键
enum MouseButton: Int, Equatable, Codable {
    case left = 0
    case right = 1
    case middle = 2

    var displayName: String {
        switch self {
        case .left:   return "鼠标左键"
        case .right:  return "鼠标右键"
        case .middle: return "鼠标中键"
        }
    }
}

// MARK: - 修饰键

/// 可以被「模拟按住」的修饰键
///
/// 为什么需要单独左右两个版本? 因为 macOS 的修饰键标志 (`CGEventFlags`) 里
/// Alternate / Command / Control 各只有**一个** bit, 并不记录是哪一侧的物理键。
/// 但**键码**能区分:
///   左 Option = 58 / 右 Option = 61
///   左 Command = 55 / 右 Command = 54
///   左 Control = 59 / 右 Control = 62
/// Shift 两侧共用键码 56, 无法区分 (macOS 本身也不区分)。
///
/// 「右 Option」在实用上是有意义的: macOS 上输入 Ω ± 等特殊字符
/// 必须用**右** Option, 左 Option 不行。
enum ModifierKey: Int, Equatable, Codable, CaseIterable {
    case leftOption = 58
    case rightOption = 61
    case leftCommand = 55
    case rightCommand = 54
    case leftControl = 59
    case rightControl = 62
    case shift = 56

    /// 该修饰键对应的标志位
    var flag: CGEventFlags {
        switch self {
        case .leftOption, .rightOption: return .maskAlternate
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftControl, .rightControl: return .maskControl
        case .shift:                   return .maskShift
        }
    }

    var displayName: String {
        switch self {
        case .leftOption:   return "左 Option"
        case .rightOption:  return "右 Option"
        case .leftCommand:  return "左 Command"
        case .rightCommand: return "右 Command"
        case .leftControl:  return "左 Control"
        case .rightControl: return "右 Control"
        case .shift:        return "Shift"
        }
    }
}

// MARK: - 动作

/// 一个绑定要执行的动作
enum BindingAction: Equatable {
    /// 保留系统默认行为 (滚动照常滚, 侧键照常前进/后退)
    case passThrough
    /// 拦截掉这个键, 什么都不做
    case disabled
    /// 执行一条组合键
    case shortcut(Shortcut)
    /// 模拟一次鼠标点击
    case mouseClick(MouseButton)
    /// 模拟「按住」某个修饰键 —— 按下鼠标键期间一直按住, 松开鼠标键才恢复
    case holdModifier(ModifierKey)

    var displayName: String {
        switch self {
        case .passThrough:       return "保留系统默认"
        case .disabled:          return "禁用此键"
        case .shortcut(let sc):  return sc.displayString
        case .mouseClick(let b): return "模拟\(b.displayName)单击"
        case .holdModifier(let m): return "按住\(m.displayName)"
        }
    }
}

// MARK: - 绑定表

/// 来源 → 动作 的完整映射表
struct BindingTable: Equatable {

    /// 每个来源对应的动作。未设置的来源按 `.passThrough` 处理。
    var entries: [BindingSource: BindingAction]

    init(entries: [BindingSource: BindingAction] = [:]) {
        self.entries = entries
    }

    subscript(source: BindingSource) -> BindingAction {
        entries[source] ?? .passThrough
    }

    mutating func set(_ action: BindingAction, for source: BindingSource) {
        entries[source] = action
    }

    /// 默认绑定 —— 与 1.1.x 的行为完全一致
    static let `default` = BindingTable(entries: [
        .sideForward: .shortcut(.copy),
        .sideBack:    .shortcut(.paste),
        .middleClick: .passThrough,
        .scrollUp:    .passThrough,
        .scrollDown:  .passThrough
    ])

    /// 交换侧键 1 / 2 的绑定 (对应旧版的「交换复制/粘贴」)
    func swappingSides() -> BindingTable {
        var copy = self
        let a = self[.sideForward]
        let b = self[.sideBack]
        copy.set(b, for: .sideForward)
        copy.set(a, for: .sideBack)
        return copy
    }

    /// 界面展示用的汇总描述
    ///
    /// 两个侧键永远列出 (它们是主用途), 其余来源只在偏离默认值时才追加。
    /// v1.2.0 这里是"五个来源全列"的 69 字长串, 放进菜单会把菜单撑到
    /// 接近整屏宽 —— 菜单空间小, 摘要必须短。
    var summary: String {
        let defaults = BindingTable.default

        // 侧键是主用途, 始终显示
        var sources: [BindingSource] = [.sideForward, .sideBack]
        // 其余来源只在用户改过之后才出现, 避免一堆「=保留系统默认」占地方
        let others: [BindingSource] = [.middleClick, .scrollUp, .scrollDown]
        sources.append(contentsOf: others.filter { self[$0] != defaults[$0] })

        let parts = sources.map { "\($0.displayName)=\(self[$0].displayName)" }
        let text = parts.joined(separator: " · ")
        // 兜底: 极端情况下 (多个来源都自定义成长名字) 也别把菜单撑爆
        return text.count <= 48 ? text : "\(sources.count) 项自定义绑定"
    }
}

// MARK: - Codable

extension BindingAction: Codable {

    private enum CodingKeys: String, CodingKey {
        case type, keyCode, command, option, control, shift, button, modifier
    }

    private enum Kind: String, Codable {
        case passThrough, disabled, shortcut, mouseClick, holdModifier
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .passThrough:
            self = .passThrough
        case .disabled:
            self = .disabled
        case .shortcut:
            self = .shortcut(Shortcut(
                keyCode: try c.decode(Int64.self, forKey: .keyCode),
                command: try c.decodeIfPresent(Bool.self, forKey: .command) ?? false,
                option:  try c.decodeIfPresent(Bool.self, forKey: .option) ?? false,
                control: try c.decodeIfPresent(Bool.self, forKey: .control) ?? false,
                shift:   try c.decodeIfPresent(Bool.self, forKey: .shift) ?? false
            ))
        case .mouseClick:
            let raw = try c.decode(Int.self, forKey: .button)
            self = .mouseClick(MouseButton(rawValue: raw) ?? .left)
        case .holdModifier:
            let raw = try c.decode(Int.self, forKey: .modifier)
            self = .holdModifier(ModifierKey(rawValue: raw) ?? .leftOption)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .passThrough:
            try c.encode(Kind.passThrough, forKey: .type)
        case .disabled:
            try c.encode(Kind.disabled, forKey: .type)
        case .shortcut(let sc):
            try c.encode(Kind.shortcut, forKey: .type)
            try c.encode(sc.keyCode, forKey: .keyCode)
            try c.encode(sc.command, forKey: .command)
            try c.encode(sc.option, forKey: .option)
            try c.encode(sc.control, forKey: .control)
            try c.encode(sc.shift, forKey: .shift)
        case .mouseClick(let button):
            try c.encode(Kind.mouseClick, forKey: .type)
            try c.encode(button.rawValue, forKey: .button)
        case .holdModifier(let modifier):
            try c.encode(Kind.holdModifier, forKey: .type)
            try c.encode(modifier.rawValue, forKey: .modifier)
        }
    }
}

extension BindingTable: Codable {

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: BindingAction].self, forKey: .entries) ?? [:]
        var entries: [BindingSource: BindingAction] = [:]
        for (key, value) in raw {
            if let source = BindingSource(rawValue: key) {
                entries[source] = value
            }
        }
        self.entries = entries
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var raw: [String: BindingAction] = [:]
        for (key, value) in entries {
            raw[key.rawValue] = value
        }
        try c.encode(raw, forKey: .entries)
    }
}

// MARK: - 按键名

/// 键码 → 可读名称。覆盖日常会用到的键, 覆盖不到的显示成「键码 N」。
enum KeyNames {

    /// 修饰键自身的键码 —— 录制时忽略 (它们只产生 flagsChanged)
    static let modifierKeyCodes: Set<Int64> = [55, 56, 57, 58, 59, 60, 61, 62, 63]

    static func name(for keyCode: Int64) -> String {
        if let known = knownNames[keyCode] { return known }
        return "键码 \(keyCode)"
    }

    /// 键码表
    ///
    /// 全部按 Carbon 的 `kVK_*` 常量逐条核对过 —— 旧版这张表有一大半是错的
    /// (28/31/32/34/35/37-42 整段错位, F 键与方向键也全错), 录制出来的快捷键
    /// 会显示成完全不相干的字符, 所以这里补齐并加了回归测试。
    private static let knownNames: [Int64: String] = [
        // 字母 (注意: ANSI 键盘的字母区不是按字母顺序排的)
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        31: "O", 32: "U", 34: "I", 35: "P",
        37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        // 数字行
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9", 29: "0",
        // 符号
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\",
        43: ",", 44: "/", 47: ".", 50: "`",
        // 编辑键
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        76: "小键盘 Enter", 117: "Forward Delete",
        // 功能键 (注意 F1..F20 的键码同样是乱序的)
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        // 导航
        114: "Help", 115: "Home", 116: "Page Up",
        119: "End", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        // 数字小键盘
        65: "小键盘 .", 67: "小键盘 *", 69: "小键盘 +", 71: "小键盘 清除",
        75: "小键盘 /", 78: "小键盘 -", 81: "小键盘 =",
        82: "小键盘 0", 83: "小键盘 1", 84: "小键盘 2", 85: "小键盘 3",
        86: "小键盘 4", 87: "小键盘 5", 88: "小键盘 6", 89: "小键盘 7",
        91: "小键盘 8", 92: "小键盘 9",
        // 其他
        10: "§", 93: "¥",
    ]
}
