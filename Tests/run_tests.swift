//
//  run_tests.swift — 纯逻辑单元测试
//
//  运行方式见 build.sh 的 test 目标; 测试目标只编译 Core/ 与 Diagnostics/, 不含 UI。
//

import Foundation
import CoreGraphics

// MARK: - 迷你测试框架

var passed = 0
var failed = 0
var currentCase = ""

func testCase(_ name: String, _ body: () -> Void) {
    currentCase = name
    body()
}

func expect(_ actual: SidekeyAction,
            _ expected: SidekeyAction,
            _ message: String = "") {
    if actual == expected {
        passed += 1
    } else {
        failed += 1
        let m = message.isEmpty ? "" : " — \(message)"
        print("❌ \(currentCase)\(m)")
        print("     期望: \(expected)")
        print("     实际: \(actual)")
    }
}

func expectTrue(_ condition: Bool, _ message: String = "") {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("❌ \(currentCase)\(message.isEmpty ? "" : " — \(message)")")
    }
}

// MARK: - 构造辅助

let ctrl: CGEventFlags = [.maskControl]
let cmd: CGEventFlags = [.maskCommand]

func ctx(enabled: Bool = true,
          bindings: BindingTable = .default,
          rightCtrl: Bool = true) -> MappingContext {
    MappingContext(enabled: enabled, bindings: bindings, rightControlDown: rightCtrl)
}

/// 只改一个来源的绑定, 其余保持默认
func table(_ source: BindingSource, _ action: BindingAction) -> BindingTable {
    var t = BindingTable.default
    t.set(action, for: source)
    return t
}

func decideKey(_ keycode: Int64, _ flags: CGEventFlags, _ context: MappingContext,
               type: CGEventType = .keyDown) -> SidekeyAction {
    SidekeyMapper.decide(type: type, keycode: keycode, flags: flags, context: context)
}

// MARK: - G3M PRO 主路径: RightCtrl+C/V → 用户指定的动作

testCase("默认: RightCtrl+C 转换为 Cmd+C") {
    expect(decideKey(8, ctrl, ctx()), .rewrite(keycode: 8, flags: cmd))
}

testCase("默认: RightCtrl+V 转换为 Cmd+V") {
    expect(decideKey(9, ctrl, ctx()), .rewrite(keycode: 9, flags: cmd))
}

testCase("转换后 flags 去掉 Control 加上 Command") {
    let action = decideKey(8, [.maskControl, .maskShift], ctx())
    if case .rewrite(_, let flags) = action {
        expectTrue(!flags.contains(.maskControl), "不应残留 Control")
        expectTrue(flags.contains(.maskCommand), "应带上 Command")
        expectTrue(flags.contains(.maskShift), "不应丢失 Shift")
    } else {
        expectTrue(false, "应为 rewrite, 实际 \(action)")
    }
}

testCase("keyUp 同样被改写 (保证按下/抬起成对)") {
    expect(decideKey(8, ctrl, ctx(), type: .keyUp), .rewrite(keycode: 8, flags: cmd))
}

// MARK: - 自定义绑定: 侧键 → 任意组合键

testCase("自定义: 侧键1 绑到 ⌘⇧A") {
    let custom = table(.sideForward, .shortcut(Shortcut(keyCode: 0, command: true, shift: true)))
    expect(decideKey(8, ctrl, ctx(bindings: custom)),
           .rewrite(keycode: 0, flags: [.maskCommand, .maskShift]))
}

testCase("自定义: 侧键2 绑到 ⌥⌘C") {
    let custom = table(.sideBack, .shortcut(Shortcut(keyCode: 8, command: true, option: true)))
    expect(decideKey(9, ctrl, ctx(bindings: custom)),
           .rewrite(keycode: 8, flags: [.maskCommand, .maskAlternate]))
}

testCase("自定义: 侧键1 绑到 ⌃F (功能键)") {
    let custom = table(.sideForward, .shortcut(Shortcut(keyCode: 3, control: true)))
    expect(decideKey(8, ctrl, ctx(bindings: custom)),
           .rewrite(keycode: 3, flags: [.maskControl]))
}

testCase("自定义: 侧键1 禁用 → 事件被吞掉") {
    let custom = table(.sideForward, .disabled)
    expect(decideKey(8, ctrl, ctx(bindings: custom)), .swallow)
    expect(decideKey(8, ctrl, ctx(bindings: custom), type: .keyUp), .swallow)
}

testCase("自定义: 侧键1 保留系统默认 → 原样放行") {
    let custom = table(.sideForward, .passThrough)
    expect(decideKey(8, ctrl, ctx(bindings: custom)), .passThrough)
}

testCase("自定义: 侧键1 模拟鼠标左键 → 吞掉并注入点击") {
    let custom = table(.sideForward, .mouseClick(.left))
    expect(decideKey(8, ctrl, ctx(bindings: custom)), .injectMouseClick(.left))
    // 抬起时只吞掉, 不重复点击
    expect(decideKey(8, ctrl, ctx(bindings: custom), type: .keyUp), .swallow)
}

// MARK: - 模拟按住修饰键 (含右 Option)

testCase("按住右 Option: 载荷按键被改写成修饰键按下 (G3M 路径)") {
    let custom = table(.sideForward, .holdModifier(.rightOption))
    // 改写成 keyDown(61) + ⌥ —— 系统会真的认为右 Option 被按住
    expect(decideKey(8, ctrl, ctx(bindings: custom)),
           .rewrite(keycode: 61, flags: [.maskAlternate]))
}

testCase("按住右 Option: 载荷抬起被改写成修饰键松开, flags 里不再有 ⌥") {
    let custom = table(.sideForward, .holdModifier(.rightOption))
    expect(decideKey(8, ctrl, ctx(bindings: custom), type: .keyUp),
           .rewrite(keycode: 61, flags: []))
}

testCase("按住修饰键: 后续真实按键的字符被改写成 ⌥ 变体") {
    var c = ctx()
    c.heldModifier = .rightOption
    // 键码 40 = K。按住右 Option 时按 K 应该打出 ˚
    //
    // 注意: 这里**不能**期望 .rewrite(keycode:flags:) —— 实测只补 flags
    // 是不会改变输出字符的, 系统的字符生成不读 event.flags。
    // 真正生效的是改写 unicode 串, 所以期望 .rewriteText。
    let action = decideKey(40, [], c)
    expectTrue(action == .rewriteText("˚"),
               "按住⌥时按 K 应改写字符为 ˚, 实际 \(action)")
}

testCase("按住修饰键: 换算不出字符时回退到补 flags") {
    var c = ctx()
    c.heldModifier = .rightOption
    // 键码 122 = F1, 功能键没有对应的 ⌥ 字符 —— 应当回退到旧行为,
    // 至少保证应用读到的 modifierFlags 是对的
    let action = decideKey(122, [], c)
    if case .rewrite(let kc, let flags) = action {
        expectTrue(kc == 122 && flags.contains(.maskAlternate),
                   "应回退为补 flags, 实际 \(action)")
    } else {
        expectTrue(false, "F1 应回退为 .rewrite, 实际 \(action)")
    }
}

testCase("按住修饰键: 原有修饰键参与字符换算 (⇧⌥)") {
    var c = ctx()
    c.heldModifier = .rightOption
    // 按住 Shift 时再叠加 ⌥, 换算是另一组字符; 只要不是普通 'K' 就说明
    // 换算路径生效了
    let action = decideKey(40, [.maskShift], c)
    if case .rewriteText(let s) = action {
        expectTrue(s != "k" && s != "K", "字符应被改写, 实际 '\(s)'")
    } else {
        expectTrue(false, "应走 .rewriteText, 实际 \(action)")
    }
}

testCase("没有按住修饰键时, 真实按键原样放行") {
    expect(decideKey(40, [], ctx()), .passThrough)
}

testCase("按住修饰键: 标准鼠标路径没有载荷可改写, 走状态记录") {
    let custom = table(.sideForward, .holdModifier(.rightOption))
    expect(SidekeyMapper.decide(type: .otherMouseDown, button: 3, context: ctx(bindings: custom)),
           .setHeldModifier(.rightOption))
    expect(SidekeyMapper.decide(type: .otherMouseUp, button: 3, context: ctx(bindings: custom)),
           .setHeldModifier(nil))
}

testCase("按住修饰键: 滚轮不提供 (滚动无按下/松开之分)") {
    let custom = table(.scrollUp, .holdModifier(.rightOption))
    expect(SidekeyMapper.decide(type: .scrollWheel, scrollDelta: 10, context: ctx(bindings: custom)),
           .passThrough)
}

testCase("修饰键键码左右可区分 (右 Option = 61, 左 Option = 58)") {
    expectTrue(ModifierKey.rightOption.rawValue == 61, "右 Option 应为 61")
    expectTrue(ModifierKey.leftOption.rawValue == 58, "左 Option 应为 58")
    expectTrue(ModifierKey.rightCommand.rawValue == 54, "右 Command 应为 54")
    expectTrue(ModifierKey.rightControl.rawValue == 62, "右 Control 应为 62")
}

testCase("修饰键标志映射正确") {
    expectTrue(ModifierKey.rightOption.flag == .maskAlternate, "右 Option 应映射到 maskAlternate")
    expectTrue(ModifierKey.rightCommand.flag == .maskCommand, "右 Command 应映射到 maskCommand")
    expectTrue(ModifierKey.rightControl.flag == .maskControl, "右 Control 应映射到 maskControl")
    expectTrue(ModifierKey.shift.flag == .maskShift, "Shift 应映射到 maskShift")
}

testCase("按住修饰键: Codable 往返") {
    var t = BindingTable.default
    t.set(.holdModifier(.rightOption), for: .sideForward)
    guard let data = try? JSONEncoder().encode(t),
          let back = try? JSONDecoder().decode(BindingTable.self, from: data) else {
        expectTrue(false, "编解码不应失败")
        return
    }
    expectTrue(back[.sideForward] == .holdModifier(.rightOption), "右 Option 绑定应保留")
}

// MARK: - 绝不能误伤真实键盘

testCase("Right Control 未按下 → 原样放行 (Terminal 的 Ctrl+C 安全)") {
    expect(decideKey(8, ctrl, ctx(rightCtrl: false)), .passThrough)
}

testCase("无 Control 标志 → 原样放行") {
    expect(decideKey(8, [], ctx()), .passThrough)
}

testCase("已带 Command → 原样放行 (避免与注入的快捷键互相干扰)") {
    expect(decideKey(8, [.maskControl, .maskCommand], ctx()), .passThrough)
}

testCase("非 C/V 按键 → 原样放行") {
    expect(decideKey(11, ctrl, ctx()), .passThrough)   // 11 = B
}

testCase("总开关关闭 → 原样放行") {
    expect(decideKey(8, ctrl, ctx(enabled: false)), .passThrough)
}

testCase("flagsChanged 事件本身原样放行") {
    expect(SidekeyMapper.decide(type: .flagsChanged, keycode: 62, flags: ctrl), .passThrough)
}

testCase("未列入掩码的事件类型原样放行") {
    expect(SidekeyMapper.decide(type: .mouseMoved), .passThrough)
}

// MARK: - 标准鼠标侧键路径 (button 3/4)

testCase("鼠标 button 3 按下 → 注入 Cmd+C") {
    expect(SidekeyMapper.decide(type: .otherMouseDown, button: 3, context: ctx()),
           .injectShortcut(.copy))
}

testCase("鼠标 button 4 按下 → 注入 Cmd+V") {
    expect(SidekeyMapper.decide(type: .otherMouseDown, button: 4, context: ctx()),
           .injectShortcut(.paste))
}

testCase("鼠标 button 3 抬起 → 吞掉 (阻止浏览器前进/后退)") {
    expect(SidekeyMapper.decide(type: .otherMouseUp, button: 3, context: ctx()), .swallow)
}

testCase("鼠标 button 5 → 原样放行 (不误伤其他鼠标键)") {
    expect(SidekeyMapper.decide(type: .otherMouseDown, button: 5, context: ctx()), .passThrough)
    expect(SidekeyMapper.decide(type: .otherMouseUp, button: 5, context: ctx()), .passThrough)
}

testCase("总开关关闭时鼠标侧键 → 原样放行") {
    expect(SidekeyMapper.decide(type: .otherMouseDown, button: 3, context: ctx(enabled: false)),
           .passThrough)
    expect(SidekeyMapper.decide(type: .otherMouseUp, button: 3, context: ctx(enabled: false)),
           .passThrough)
}

testCase("鼠标侧键自定义: button 3 → ⌘⇧K") {
    let custom = table(.sideForward, .shortcut(Shortcut(keyCode: 40, command: true, shift: true)))
    expect(SidekeyMapper.decide(type: .otherMouseDown, button: 3, context: ctx(bindings: custom)),
           .injectShortcut(Shortcut(keyCode: 40, command: true, shift: true)))
}

testCase("鼠标侧键保留默认 → 按下与抬起都放行 (鼠标不会卡在按下状态)") {
    let custom = table(.sideForward, .passThrough)
    expect(SidekeyMapper.decide(type: .otherMouseDown, button: 3, context: ctx(bindings: custom)),
           .passThrough)
    expect(SidekeyMapper.decide(type: .otherMouseUp, button: 3, context: ctx(bindings: custom)),
           .passThrough)
}

// MARK: - 滚轮按下 (中键)

testCase("滚轮按下 (button 2) 默认 → 保留系统默认") {
    expect(SidekeyMapper.decide(type: .otherMouseDown, button: 2, context: ctx()), .passThrough)
    expect(SidekeyMapper.decide(type: .otherMouseUp, button: 2, context: ctx()), .passThrough)
}

testCase("滚轮按下自定义 → 注入指定组合键") {
    let custom = table(.middleClick, .shortcut(.paste))
    expect(SidekeyMapper.decide(type: .otherMouseDown, button: 2, context: ctx(bindings: custom)),
           .injectShortcut(.paste))
    expect(SidekeyMapper.decide(type: .otherMouseUp, button: 2, context: ctx(bindings: custom)),
           .swallow)
}

// MARK: - 滚轮滚动

testCase("滚轮滚动默认 → 放行 (正常滚动)") {
    expect(SidekeyMapper.decide(type: .scrollWheel, scrollDelta: 10, context: ctx()), .passThrough)
    expect(SidekeyMapper.decide(type: .scrollWheel, scrollDelta: -10, context: ctx()), .passThrough)
}

testCase("滚轮上滚自定义 → 注入组合键") {
    let custom = table(.scrollUp, .shortcut(.undo))
    expect(SidekeyMapper.decide(type: .scrollWheel, scrollDelta: 10, context: ctx(bindings: custom)),
           .injectShortcut(.undo))
}

testCase("滚轮下滚自定义 → 注入组合键") {
    let custom = table(.scrollDown, .shortcut(.redo))
    expect(SidekeyMapper.decide(type: .scrollWheel, scrollDelta: -10, context: ctx(bindings: custom)),
           .injectShortcut(.redo))
}

testCase("滚轮禁用 → 吞掉滚动") {
    let custom = table(.scrollUp, .disabled)
    expect(SidekeyMapper.decide(type: .scrollWheel, scrollDelta: 10, context: ctx(bindings: custom)),
           .swallow)
}

testCase("滚轮位移为 0 → 放行") {
    expect(SidekeyMapper.decide(type: .scrollWheel, scrollDelta: 0, context: ctx()), .passThrough)
}

// MARK: - 常量与描述

testCase("键码常量正确") {
    expectTrue(SidekeyMapper.copyKeyCode == 8, "copyKeyCode")
    expectTrue(SidekeyMapper.pasteKeyCode == 9, "pasteKeyCode")
    expectTrue(SidekeyMapper.rightControlKeyCode == 62, "rightControlKeyCode")
}

testCase("映射描述反映当前绑定") {
    let desc = SidekeyMapper.mappingDescription(bindings: .default)
    expectTrue(desc.contains("复制") || desc.contains("⌘C"), "应显示复制绑定")
    expectTrue(desc.contains("侧键 1"), "应包含来源名称")
}

testCase("菜单摘要不会撑爆菜单宽度") {
    // 回归测试: v1.2.0 的菜单里有一行 69 字的绑定摘要, 把菜单撑到
    // 屏幕 97% 宽, 文字还溢到菜单外面。这里锁住「一行摘要不超过 40 字」。
    let desc = SidekeyMapper.mappingDescription(bindings: .default)
    expectTrue(desc.count <= 40, "摘要过长会撑爆菜单: \(desc.count) 字 — \(desc)")
    expectTrue(desc.contains("侧键"), "摘要仍应能看出关键绑定")
    expectTrue(desc.contains("复制") || desc.contains("⌘C"), "摘要应显示复制")
}

// MARK: - 键名表

testCase("键名表: 字母区键码与 Carbon 常量一致") {
    // 回归测试: 旧版这张表整段错位 (28 显示成 ';'、31 显示成 '/'、
    // 37/38 的 L/J 互换 ...), 录制出来的快捷键会显示成不相干的字符。
    let expected: [(Int64, String)] = [
        (0, "A"), (1, "S"), (2, "D"), (3, "F"), (4, "H"), (5, "G"),
        (6, "Z"), (7, "X"), (8, "C"), (9, "V"), (11, "B"),
        (12, "Q"), (13, "W"), (14, "E"), (15, "R"), (16, "Y"), (17, "T"),
        (31, "O"), (32, "U"), (34, "I"), (35, "P"),
        (37, "L"), (38, "J"), (40, "K"), (45, "N"), (46, "M"),
    ]
    for (code, name) in expected {
        let actual = KeyNames.name(for: code)
        expectTrue(actual == name, "键码 \(code) 应为 \(name)，实际 \(actual)")
    }
}

testCase("键名表: 数字与符号区键码一致") {
    let expected: [(Int64, String)] = [
        (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"),
        (26, "7"), (28, "8"), (25, "9"), (29, "0"),
        (24, "="), (27, "-"), (30, "]"), (33, "["), (39, "'"),
        (41, ";"), (43, ","), (44, "/"), (47, "."), (50, "`"),
        (36, "Return"), (48, "Tab"), (49, "Space"), (51, "Delete"), (53, "Esc"),
    ]
    for (code, name) in expected {
        let actual = KeyNames.name(for: code)
        expectTrue(actual == name, "键码 \(code) 应为 \(name)，实际 \(actual)")
    }
}

testCase("键名表: 功能键与方向键正确") {
    let expected: [(Int64, String)] = [
        (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"),
        (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"),
        (111, "F12"), (105, "F13"), (107, "F14"), (113, "F15"), (106, "F16"),
        (64, "F17"), (79, "F18"), (80, "F19"), (90, "F20"),
        (123, "←"), (124, "→"), (125, "↓"), (126, "↑"),
        (115, "Home"), (119, "End"), (116, "Page Up"), (121, "Page Down"),
    ]
    for (code, name) in expected {
        let actual = KeyNames.name(for: code)
        expectTrue(actual == name, "键码 \(code) 应为 \(name)，实际 \(actual)")
    }
}

testCase("键名表: 未知键码回退为「键码 N」而不是胡说一个字符") {
    expectTrue(KeyNames.name(for: 300) == "键码 300",
               "未知码应回退, 实际 \(KeyNames.name(for: 300))")
}

// MARK: - 绑定表

testCase("绑定表: 未设置的来源按 passThrough 处理") {
    let t = BindingTable()
    expectTrue(t[.sideForward] == .passThrough, "未设置应等同 passThrough")
}

testCase("绑定表: 交换侧键 1/2") {
    let swapped = BindingTable.default.swappingSides()
    expectTrue(swapped[.sideForward] == .shortcut(.paste), "侧键1 应变成粘贴")
    expectTrue(swapped[.sideBack] == .shortcut(.copy), "侧键2 应变成复制")
}

testCase("绑定表: 交换两次回到原样") {
    let round = BindingTable.default.swappingSides().swappingSides()
    expectTrue(round == BindingTable.default, "交换两次应还原")
}

testCase("绑定表: Codable 往返") {
    var t = BindingTable.default
    t.set(.shortcut(Shortcut(keyCode: 0, command: true, shift: true)), for: .sideForward)
    t.set(.mouseClick(.right), for: .middleClick)
    t.set(.disabled, for: .scrollUp)

    guard let data = try? JSONEncoder().encode(t),
          let back = try? JSONDecoder().decode(BindingTable.self, from: data) else {
        expectTrue(false, "编解码不应失败")
        return
    }
    expectTrue(back == t, "编码解码后应完全一致")
    expectTrue(back[.sideForward] == .shortcut(Shortcut(keyCode: 0, command: true, shift: true)),
               "自定义组合键应保留")
    expectTrue(back[.middleClick] == .mouseClick(.right), "模拟点击应保留")
    expectTrue(back[.scrollUp] == .disabled, "禁用应保留")
}

testCase("快捷键显示串: 修饰键顺序为 ⌃⌥⇧⌘") {
    let sc = Shortcut(keyCode: 0, command: true, option: true, control: true, shift: true)
    expectTrue(sc.displayString == "⌃⌥⇧⌘A", "实际 \(sc.displayString)")
}

testCase("快捷键 flags 与显示串一致") {
    let sc = Shortcut(keyCode: 9, command: true, shift: true)
    expectTrue(sc.flags == [.maskCommand, .maskShift], "flags 应含 Command 与 Shift")
    expectTrue(sc.displayString == "⇧⌘V", "实际 \(sc.displayString)")
}

// MARK: - Settings 持久化 (用独立 suite, 不污染真实配置)

/// 指向一个全新的 UserDefaults suite, 保证测试之间互不干扰
func freshDefaults() -> UserDefaults {
    let suite = "com.anbc.g3msidekeys.tests.\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}

testCase("Settings 默认: 映射开启") {
    Settings.store = freshDefaults()
    expectTrue(Settings.enabled == true, "默认应为开启")
}

testCase("Settings 默认: 日志级别为「仅错误」(不是「关闭」)") {
    Settings.store = freshDefaults()
    // 回归测试: LogLevel.off 的 rawValue 是 0, 若用
    // `LogLevel(rawValue: integer) ?? .error` 解析未设置的键会得到 .off
    expectTrue(Settings.logLevel == .error, "默认应为 .error, 实际 \(Settings.logLevel)")
}

testCase("Settings 读写往返") {
    Settings.store = freshDefaults()
    Settings.enabled = false
    Settings.logLevel = .diagnostic
    expectTrue(Settings.enabled == false, "enabled")
    expectTrue(Settings.logLevel == .diagnostic, "logLevel")
}

testCase("Settings 日志级别可显式设为关闭") {
    Settings.store = freshDefaults()
    Settings.logLevel = .off
    expectTrue(Settings.logLevel == .off, "应能显式关闭")
}

testCase("Settings 迁移旧版键名") {
    let d = freshDefaults()
    d.set(true, forKey: SettingsKey.legacyEnabled)
    d.set(true, forKey: SettingsKey.legacySwapped)
    Settings.store = d
    Settings.migrateIfNeeded()
    expectTrue(Settings.enabled == true, "旧键 enabled 应迁移")
    expectTrue(Settings.swapped == true, "旧键 swapped 应迁移")
    expectTrue(d.object(forKey: SettingsKey.legacyEnabled) == nil, "旧键应被清除")
    expectTrue(d.object(forKey: SettingsKey.legacySwapped) == nil, "旧键应被清除")
}

testCase("Settings 默认绑定 = 侧键1复制 / 侧键2粘贴") {
    Settings.store = freshDefaults()
    let b = Settings.bindings
    expectTrue(b[.sideForward] == .shortcut(.copy), "侧键1 应为复制")
    expectTrue(b[.sideBack] == .shortcut(.paste), "侧键2 应为粘贴")
    expectTrue(b[.middleClick] == .passThrough, "中键应为保留默认")
}

testCase("Settings 旧版「交换」开关会折算成侧键绑定对调") {
    let d = freshDefaults()
    d.set(true, forKey: SettingsKey.legacySwapped)
    Settings.store = d
    let b = Settings.bindings
    expectTrue(b[.sideForward] == .shortcut(.paste), "侧键1 应为粘贴")
    expectTrue(b[.sideBack] == .shortcut(.copy), "侧键2 应为复制")
}

testCase("Settings 绑定表读写往返") {
    Settings.store = freshDefaults()
    var t = BindingTable.default
    t.set(.shortcut(Shortcut(keyCode: 40, command: true, shift: true)), for: .sideForward)
    t.set(.mouseClick(.middle), for: .middleClick)
    Settings.bindings = t
    expectTrue(Settings.bindings == t, "绑定表应原样读回")
}

testCase("Settings 日志保留天数默认 7 天") {
    Settings.store = freshDefaults()
    expectTrue(Settings.logRetentionDays == 7, "默认应为 7 天")
}

testCase("Settings 日志保留天数读写往返") {
    Settings.store = freshDefaults()
    Settings.logRetentionDays = 30
    expectTrue(Settings.logRetentionDays == 30, "应为 30 天")
    Settings.logRetentionDays = 0
    expectTrue(Settings.logRetentionDays == 1, "0 应被夹到 1 天")
}

testCase("日志过期判定: 7 天前的文件应过期") {
    let now = Date()
    let old = now.addingTimeInterval(-8 * 24 * 3600)
    expectTrue(Logger.isExpired(modified: old, now: now, retentionDays: 7), "8 天前应过期")
    let recent = now.addingTimeInterval(-6 * 24 * 3600)
    expectTrue(!Logger.isExpired(modified: recent, now: now, retentionDays: 7), "6 天前不该过期")
    expectTrue(!Logger.isExpired(modified: now, now: now, retentionDays: 7), "刚刚不该过期")
}

testCase("日志过期判定: 保留 1 天时 2 天前应过期") {
    let now = Date()
    let old = now.addingTimeInterval(-2 * 24 * 3600)
    expectTrue(Logger.isExpired(modified: old, now: now, retentionDays: 1), "保留 1 天时 2 天前应过期")
}

// MARK: - 结果

print("")
if failed == 0 {
    print("✅ 全部通过: \(passed) 项断言")
    exit(0)
} else {
    print("❌ 失败 \(failed) 项 / 通过 \(passed) 项")
    exit(1)
}
