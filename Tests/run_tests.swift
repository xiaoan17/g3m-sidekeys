//
//  run_tests.swift — SidekeyMapper 纯逻辑单元测试
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

func ctx(enabled: Bool = true, swapped: Bool = false, rightCtrl: Bool = true) -> MappingContext {
    MappingContext(enabled: enabled, swapped: swapped, rightControlDown: rightCtrl)
}

func decideKey(_ keycode: Int64, _ flags: CGEventFlags, _ context: MappingContext,
               type: CGEventType = .keyDown) -> SidekeyAction {
    SidekeyMapper.decide(type: type, keycode: keycode, flags: flags, context: context)
}

// MARK: - G3M PRO 主路径: RightCtrl+C/V → Cmd+C/V

testCase("RightCtrl+C 转换为 Cmd+C") {
    expect(decideKey(8, ctrl, ctx()), .rewrite(keycode: 8, flags: cmd))
}

testCase("RightCtrl+V 转换为 Cmd+V") {
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

testCase("RightCtrl 状态下交换: C → V") {
    expect(decideKey(8, ctrl, ctx(swapped: true)), .rewrite(keycode: 9, flags: cmd))
}

testCase("RightCtrl 状态下交换: V → C") {
    expect(decideKey(9, ctrl, ctx(swapped: true)), .rewrite(keycode: 8, flags: cmd))
}

// MARK: - 绝不能误伤真实键盘

testCase("Right Control 未按下 → 原样放行 (Terminal 的 Ctrl+C 安全)") {
    expect(decideKey(8, ctrl, ctx(rightCtrl: false)), .passThrough)
}

testCase("无 Control 标志 → 原样放行") {
    expect(decideKey(8, [], ctx()), .passThrough)
}

testCase("已带 Command → 原样放行 (避免与注入的 Cmd+key 互相干扰)") {
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
           .injectCommand(keycode: 8))
}

testCase("鼠标 button 4 按下 → 注入 Cmd+V") {
    expect(SidekeyMapper.decide(type: .otherMouseDown, button: 4, context: ctx()),
           .injectCommand(keycode: 9))
}

testCase("鼠标 button 3 交换后 → 注入 Cmd+V") {
    expect(SidekeyMapper.decide(type: .otherMouseDown, button: 3, context: ctx(swapped: true)),
           .injectCommand(keycode: 9))
}

testCase("鼠标 button 4 交换后 → 注入 Cmd+C") {
    expect(SidekeyMapper.decide(type: .otherMouseDown, button: 4, context: ctx(swapped: true)),
           .injectCommand(keycode: 8))
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

// MARK: - 常量与描述

testCase("键码常量正确") {
    expectTrue(SidekeyMapper.copyKeyCode == 8, "copyKeyCode")
    expectTrue(SidekeyMapper.pasteKeyCode == 9, "pasteKeyCode")
    expectTrue(SidekeyMapper.rightControlKeyCode == 62, "rightControlKeyCode")
}

testCase("映射描述随交换状态变化") {
    expectTrue(SidekeyMapper.mappingDescription(swapped: false).contains("复制"))
    expectTrue(SidekeyMapper.mappingDescription(swapped: true).contains("粘贴"))
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

testCase("Settings 默认: 不交换") {
    Settings.store = freshDefaults()
    expectTrue(Settings.swapped == false, "默认应为不交换")
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
    Settings.swapped = true
    Settings.logLevel = .diagnostic
    expectTrue(Settings.enabled == false, "enabled")
    expectTrue(Settings.swapped == true, "swapped")
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
