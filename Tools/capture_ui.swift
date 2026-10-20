//
//  capture_ui.swift — 把设置窗口渲染成 PNG (浅色 / 深色各一张)
//
//  用途: 界面改动后**肉眼看**效果, 而不是凭代码想象。
//  之前 docs/ 里的两张预览图是手工拼的, 和实际界面已经对不上。
//
//  用法:
//    mkdir -p /tmp/uishot && cp Tools/capture_ui.swift /tmp/uishot/main.swift
//    swiftc -O -target arm64-apple-macos13.0 -o /tmp/uishot/capture \
//      Sources/Core/*.swift Sources/App/*.swift /tmp/uishot/main.swift
//    /tmp/uishot/capture docs/
//
//  它离屏渲染窗口内容视图, 不需要真的把 App 显示在屏幕上。
//

import AppKit
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// 用独立 defaults, 别污染真实配置
Settings.store = UserDefaults(suiteName: "com.anbc.g3msidekeys.capture")!

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// 渲染指定外观下的设置窗口
func capture(appearance: NSAppearance, name: String) -> Bool {
    // 外观必须在**创建视图之前**设好 —— CardView 等控件在 init 里就把
    // 颜色烘成了 CGColor, 之后再改 NSApp.appearance 已经晚了。
    NSApp.appearance = appearance

    // 每次都新建一个控制器, 保证配色按当前外观重新计算
    let controller = BindingSettingsWindowController()
    guard let window = controller.window, let content = window.contentView else {
        print("  ❌ \(name): 拿不到窗口")
        return false
    }

    // 窗口自身也显式指定外观, 避免继承到上一次的设置
    window.appearance = appearance

    // contentView 本身是**透明**的 —— 平时窗口底色由外层 theme frame 画。
    // 但离屏截图只抓 contentView, 于是透明区域在 PNG 里变成黑色,
    // 浅色模式下的界面就「整块看不见了」。这里手动补一层窗口底色。
    content.wantsLayer = true
    appearance.performAsCurrentDrawingAppearance {
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    controller.present()
    // 让 Auto Layout 跑完, 尺寸才稳定
    content.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    content.layoutSubtreeIfNeeded()

    guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
        print("  ❌ \(name): 拿不到 bitmap")
        return false
    }
    content.cacheDisplay(in: content.bounds, to: rep)

    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("  ❌ \(name): 编码 PNG 失败")
        return false
    }

    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(name)
    do {
        try data.write(to: url)
        print("  ✅ \(name): \(Int(content.bounds.width))×\(Int(content.bounds.height)) → \(url.path)")
        return true
    } catch {
        print("  ❌ \(name): 写入失败 — \(error.localizedDescription)")
        return false
    }
}

print("渲染设置窗口预览:")

// 先让 NSApplication 走完一轮启动, 否则第一个窗口可能来不及布局就被截图
RunLoop.main.run(until: Date().addingTimeInterval(0.3))

let ok1 = capture(appearance: NSAppearance(named: .aqua)!, name: "ui-preview-light.png")
let ok2 = capture(appearance: NSAppearance(named: .darkAqua)!, name: "ui-preview-dark.png")

exit((ok1 && ok2) ? 0 : 1)
