import CoreGraphics
import Foundation

// 检查系统当前真实修饰键状态 —— 如果 Option 卡住了,
// 说明我之前的实验把全局状态搞坏了, 同时也会解释 unicode 读数的异常。
for (name, id) in [("hidSystemState", CGEventSourceStateID.hidSystemState),
                   ("combinedSessionState", .combinedSessionState)] {
    let f = CGEventSource.flagsState(id)
    var on: [String] = []
    if f.contains(.maskAlternate) { on.append("⌥") }
    if f.contains(.maskCommand) { on.append("⌘") }
    if f.contains(.maskControl) { on.append("⌃") }
    if f.contains(.maskShift) { on.append("⇧") }
    print("\(name): flags=\(f.rawValue) 按下=\(on.isEmpty ? "无" : on.joined())")
}
