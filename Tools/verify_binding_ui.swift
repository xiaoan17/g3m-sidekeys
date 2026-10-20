import AppKit
import Foundation

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
NSApp.appearance = NSAppearance(named: .aqua)

// 用独立 defaults, 别污染真实配置
Settings.store = UserDefaults(suiteName: "com.anbc.g3msidekeys.verify")!

let controller = BindingSettingsWindowController()
guard let window = controller.window, let content = window.contentView else { exit(2) }
content.layoutSubtreeIfNeeded()

func findPopups(_ v: NSView) -> [BindingPopUpButton] {
    var out: [BindingPopUpButton] = []
    if let p = v as? BindingPopUpButton { out.append(p) }
    for s in v.subviews { out += findPopups(s) }
    return out
}
let popups = findPopups(content)
print("下拉框数量:", popups.count)

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✅ \(msg)") } else { print("  ❌ \(msg)"); failures += 1 }
}

// 1) 所有菜单都不应再有子菜单
print("\n[1] 菜单里不该再有子菜单")
for p in popups {
    guard let src = p.source else { continue }
    let subs = (p.menu?.items ?? []).filter { $0.submenu != nil }
    check(subs.isEmpty, "\(src.rawValue): 子菜单数 = \(subs.count)")
}

// 2) 每一项「按住修饰键」都必须能被选中
print("\n[2] 用户真实点击路径: 选中每一项并派发 action")
for p in popups {
    guard let src = p.source else { continue }
    let menu = p.menu!
    let holdItems = menu.items.filter { item in
        if case .holdModifier? = item.representedObject as? BindingAction { return true }
        return false
    }
    for item in holdItems {
        // 完全按用户点击的方式: NSPopUpButton 选中 -> 派发 action
        p.select(item)
        NSApp.sendAction(p.action!, to: p.target, from: p)
        let got = AppState.shared.bindings[src]
        let want = item.representedObject as! BindingAction
        if got != want {
            check(false, "\(src.rawValue) 选「\(item.title)」后绑定 = \(got), 期望 \(want)")
        }
    }
    if !holdItems.isEmpty {
        check(true, "\(src.rawValue): \(holdItems.count) 个「按住修饰键」项全部可选中")
    }
}

// 3) 滚轮行本来就不该有「按住修饰键」
print("\n[3] 滚轮行不提供「按住修饰键」(按下/松开无法配对)")
for p in popups where p.source == .scrollUp || p.source == .scrollDown {
    let holds = (p.menu?.items ?? []).filter { item in
        if case .holdModifier? = item.representedObject as? BindingAction { return true }
        return false
    }
    check(holds.isEmpty, "\(p.source!.rawValue): 无 holdModifier 项")
}

// 4) 选中「按住右 Option」后, 刷新时下拉框应忠实回显
print("\n[4] 关键场景: 滚轮按下 → 按住右 Option, 并验证回显")
let mid = popups.first { $0.source == .middleClick }!
let rightOpt = mid.menu!.items.first { it in
    if case .holdModifier(.rightOption)? = it.representedObject as? BindingAction { return true }
    return false
}!
mid.select(rightOpt)
NSApp.sendAction(mid.action!, to: mid.target, from: mid)
check(AppState.shared.bindings[.middleClick] == .holdModifier(.rightOption),
      "绑定已写入 = \(AppState.shared.bindings[.middleClick])")
// 等 async 的 refresh 跑完
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
check(mid.titleOfSelectedItem == "按住右 Option",
      "下拉框回显 = 「\(mid.titleOfSelectedItem ?? "nil")」")

print(failures == 0 ? "\n✅ 全部通过" : "\n❌ 失败 \(failures) 项")
exit(failures == 0 ? 0 : 1)
