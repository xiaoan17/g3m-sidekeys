//
//  EventTapManager.swift — 事件捕获层
//
//  职责: 维护 CGEventTap 生命周期, 把原始事件翻译成 SidekeyAction 并执行。
//  决策逻辑全部在 SidekeyMapper 里, 这里只做搬运。
//

import CoreGraphics
import Foundation

final class EventTapManager {

    // MARK: - 状态

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Right Control 当前是否按下 (G3M PRO 侧键以 RightCtrl+C/V 上报)
    ///
    /// 这个状态一旦因为漏掉 keyup 而卡在 true, 之后真实键盘的 Ctrl+C 会被
    /// 全部误转成 Cmd+C —— 正是本工具要避免的场景。
    /// 因此采用「多重自愈」, 任意一条证据都能把它纠正回来:
    ///   A. flagsChanged 事件精确更新 (keycode 62)
    ///   B. 任意 flagsChanged 事件里若已无 Control 标志 → 说明没有任何 Ctrl 被按住 → 复位
    ///   C. 任意键盘事件若不带 Control 标志 → 说明 Ctrl 已松开 → 复位
    ///   D. 兜底超时: 状态为 true 超过 2 秒 → 复位 (鼠标的 RightCtrl 脉冲 < 100ms)
    ///   E. 事件监听被系统禁用 → 复位 (禁用期间极可能漏掉 keyup)
    private var rightControlDown = false

    /// rightControlDown 变为 true 的时刻 (用于兜底超时)
    private var rightControlDownAt: Date?

    /// 状态对账定时器
    private var reconcileTimer: Timer?

    /// 事件回调是否已启动
    var isRunning: Bool { tap != nil }

    /// 回调被系统禁用过 (用于界面提示)
    private(set) var wasDisabledBySystem = false

    /// Right Control 按下与随后 C/V 按下之间的间隔 (毫秒), 仅用于诊断
    private var rightControlDownAtDate: Date?

    /// 滚轮绑定的节流: 同方向滚动在一段时间内只触发一次
    ///
    /// 一次「滚一格」在系统里可能派发多个 scrollWheel 事件 (高分辨率触控板
    /// 还会持续派发带动量的), 不节流的话每滚一格会触发好几次动作。
    private var lastScrollActionAt: [BindingSource: Date] = [:]

    /// 滚轮动作的最小触发间隔 (秒)
    private let scrollThrottleInterval: TimeInterval = 0.15

    /// 当前正被鼠标键「按住」的修饰键
    ///
    /// 标准鼠标 (button 3/4) 没有载荷按键可以改写, 只能靠这个状态:
    /// 在后续真实按键事件上补上对应的修饰键标志位, 让应用读到正确的 modifierFlags。
    /// G3M 路径则直接把载荷按键改写成修饰键按下 (系统级), 这个状态只用于兜底。
    private var heldModifier: ModifierKey?

    /// 已被改写成「修饰键按下」的载荷按键码
    ///
    /// 它的抬起必须成对地改写成「修饰键松开」, 否则修饰键会卡住不放。
    private var pendingModifierKeyCode: Int64?

    // MARK: - 生命周期

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        // 需要监听的事件:
        //   - 侧键鼠标事件 (兼容标准上报 button 3/4 的鼠标)
        //   - 键盘 C/V 与 Right Control (G3M PRO 主路径)
        //   - 滚轮事件 (滚轮按下属于 otherMouse, 滚动属于 scrollWheel)
        // 注意: **不要** 加入 leftMouseDown —— 旧版本监听它只为了打日志,
        // 徒增每个左键点击的回调开销, 没有任何功能价值。
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.scrollWheel.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()

            // 系统因超时/用户输入禁用事件流时, 重新启用。
            // 同时必须复位 rightControlDown —— 被禁用期间很可能漏掉了 keyup,
            // 状态卡在 true 会导致真实的 Ctrl+C 被误转成 Cmd+C。
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                manager.handleTapDisabled()
                return nil
            }

            return manager.handle(type: type, event: event)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            Logger.shared.error("!!! 事件监听创建失败 (通常是「输入监控」权限未授予)")
            return false
        }

        tap = newTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        runLoopSource = source

        startReconcileTimer()
        Logger.shared.error("事件监听已启动")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
        resetRightControlState(reason: "监听停止")
        reconcileTimer?.invalidate()
        reconcileTimer = nil
    }

    // MARK: - 事件处理

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {

        // 0) 本工具自己注入的事件 —— 直接放行。
        //    否则「侧键 → 模拟中键」这类绑定会自己触发自己, 形成无限递归。
        if event.getIntegerValueField(.eventSourceUserData) == EventInjector.magicUserData {
            return Unmanaged.passUnretained(event)
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let button = event.getIntegerValueField(.mouseEventButtonNumber)

        // 诊断: 鼠标按键事件原样记录 —— 排查「按了没反应」时,
        // 先要能分清「事件根本没到」和「到了但被决策层忽略」。
        // 只在诊断级别下写, 不影响默认的「仅错误」日志。
        if type == .otherMouseDown || type == .otherMouseUp || type == .rightMouseDown {
            Logger.shared.diagnostic(
                "鼠标事件: \(type == .otherMouseDown ? "otherDown" : type == .otherMouseUp ? "otherUp" : "rightDown") button=\(button)"
            )
        }

        // 1) 追踪 Right Control 的按下/抬起状态
        if type == .flagsChanged {
            handleFlagsChanged(keycode: keycode, flags: flags)
            return Unmanaged.passUnretained(event)
        }

        // 2) 自愈证据 C: 键盘事件不带 Control 标志 → 没有任何 Ctrl 被按住
        if (type == .keyDown || type == .keyUp), !flags.contains(.maskControl), rightControlDown {
            resetRightControlState(reason: "键盘事件已无 Control 标志")
        }

        // 3) 交给纯逻辑层决策
        var context = AppState.shared.mappingContext
        context.rightControlDown = rightControlDown
        context.heldModifier = heldModifier
        context.pendingModifierKeyCode = pendingModifierKeyCode

        // 滚轮方向要单独算出来, 用于节流
        var scrollDelta: Double = 0
        if type == .scrollWheel {
            scrollDelta = currentScrollDelta(event)
        }

        let action = SidekeyMapper.decide(type: type,
                                          keycode: keycode,
                                          flags: flags,
                                          button: button,
                                          scrollDelta: scrollDelta,
                                          context: context)

        switch action {
        case .passThrough:
            return Unmanaged.passUnretained(event)

        case .rewrite(let newKeycode, let newFlags):
            // 记录 RightCtrl↓ 与 C/V↓ 的间隔, 仅诊断用途
            if type == .keyDown, let downAt = rightControlDownAtDate {
                let delta = Date().timeIntervalSince(downAt) * 1000
                Logger.shared.diagnostic(String(format: "侧键转换: RightCtrl→键 间隔 %.1f ms", delta))
            }
            let mutable = event
            mutable.setIntegerValueField(.keyboardEventKeycode, value: newKeycode)
            mutable.flags = newFlags
            // 载荷被改写成修饰键按下 / 松开时, 同步相关状态
            updateHeldModifierIfNeeded(keycode: newKeycode, flags: newFlags, isDown: type == .keyDown)
            updatePendingModifierKeyCode(originalKeyCode: keycode,
                                          newKeyCode: newKeycode,
                                          flags: newFlags)
            Logger.shared.diagnostic("侧键转换: 改写为 \(KeyNames.name(for: newKeycode))")
            return Unmanaged.passUnretained(mutable)

        case .rewriteText(let text):
            // 只改写 keyDown —— keyUp 不带字符, 改了没有意义,
            // 而且某些应用会因此把抬起当成一次额外的输入。
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            let units = Array(text.utf16)
            guard !units.isEmpty else { return Unmanaged.passUnretained(event) }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            Logger.shared.diagnostic("按住修饰键: 字符改写为 \(text)")
            return Unmanaged.passUnretained(event)

        case .injectShortcut(let shortcut):
            // 滚轮需要节流, 否则一次滚动会触发多次
            if type == .scrollWheel, !shouldTriggerScroll(scrollDelta) {
                return nil
            }
            Logger.shared.diagnostic("侧键触发: 注入 \(shortcut.displayString)")
            EventInjector.postShortcut(shortcut)
            return nil   // 吞掉原始事件, 阻止浏览器前进/后退

        case .injectMouseClick(let mouseButton):
            if type == .scrollWheel, !shouldTriggerScroll(scrollDelta) {
                return nil
            }
            Logger.shared.diagnostic("侧键触发: 模拟\(mouseButton.displayName)单击")
            EventInjector.postMouseClick(mouseButton)
            return nil

        case .setHeldModifier(let modifier):
            heldModifier = modifier
            if let modifier {
                Logger.shared.diagnostic("侧键触发: 按住\(modifier.displayName)")
            } else {
                Logger.shared.diagnostic("侧键触发: 松开修饰键")
            }
            return nil

        case .swallow:
            return nil
        }
    }

    /// 载荷被改写成修饰键时, 同步「被按住的修饰键」状态
    ///
    /// 改写后的 keycode 正好是某个 ModifierKey 的键码 —— 那就说明这个事件
    /// 承载的是该修饰键的按下 / 松开。
    private func updateHeldModifierIfNeeded(keycode: Int64, flags: CGEventFlags, isDown: Bool) {
        guard let modifier = ModifierKey(rawValue: Int(keycode)) else { return }
        if flags.contains(modifier.flag) {
            if isDown { heldModifier = modifier }
        } else if heldModifier == modifier {
            // 释放事件: flags 里已经没有这个修饰键了
            heldModifier = nil
        }
    }

    /// 记住「载荷按键被改写成了修饰键按下」
    ///
    /// 之后这个按键码的抬起要成对地改写成修饰键松开。
    private func updatePendingModifierKeyCode(originalKeyCode: Int64,
                                              newKeyCode: Int64,
                                              flags: CGEventFlags) {
        guard let modifier = ModifierKey(rawValue: Int(newKeyCode)) else { return }
        if flags.contains(modifier.flag) {
            // 按下: 记住这个载荷按键码
            pendingModifierKeyCode = originalKeyCode
        } else if pendingModifierKeyCode == originalKeyCode {
            // 松开: 配对完成
            pendingModifierKeyCode = nil
        }
    }

    // MARK: - 滚轮辅助

    /// 取滚轮事件的纵向位移 (正=向上滚, 负=向下滚)
    ///
    /// 优先用 pointDelta (像素级, 高分辨率设备才有意义), 没有再用 lineDelta (行级)。
    private func currentScrollDelta(_ event: CGEvent) -> Double {
        let point = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        if point != 0 { return point }
        return Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
    }

    /// 滚轮动作是否应该触发 (同方向 150ms 内只触发一次)
    private func shouldTriggerScroll(_ delta: Double) -> Bool {
        let source: BindingSource = delta > 0 ? .scrollUp : .scrollDown
        let now = Date()
        if let last = lastScrollActionAt[source],
           now.timeIntervalSince(last) < scrollThrottleInterval {
            return false
        }
        lastScrollActionAt[source] = now
        return true
    }

    // MARK: - Right Control 状态维护

    private func handleFlagsChanged(keycode: Int64, flags: CGEventFlags) {
        // 证据 A: keycode 62 精确更新
        if keycode == SidekeyMapper.rightControlKeyCode {
            let nowDown = flags.contains(.maskControl)
            if nowDown != rightControlDown {
                Logger.shared.diagnostic("Right Control \(nowDown ? "按下" : "抬起")")
            }
            rightControlDown = nowDown
            rightControlDownAtDate = nowDown ? Date() : nil
            if nowDown {
                rightControlDownAt = Date()
            } else {
                rightControlDownAt = nil
            }
            return
        }

        // 证据 B: 任意 flagsChanged 事件里若已无 Control 标志,
        // 说明此刻没有任何 Ctrl 被按住, 那么记录中的 Right Control 必然已松开。
        if !flags.contains(.maskControl), rightControlDown {
            resetRightControlState(reason: "flagsChanged 已无 Control 标志")
        }
    }

    private func resetRightControlState(reason: String) {
        if rightControlDown {
            Logger.shared.diagnostic("Right Control 状态复位 (\(reason))")
        }
        rightControlDown = false
        rightControlDownAt = nil
        rightControlDownAtDate = nil
    }

    // MARK: - 兜底超时

    /// 兜底自愈 D: Right Control 状态为 true 超过 2 秒则复位。
    ///
    /// 鼠标的 RightCtrl 是一个毫秒级脉冲, 正常情况下 keyup 会在 100ms 内到达,
    /// 根本不会触发这个兜底。只有 keyup 丢失时它才生效, 把「永久卡死」
    /// 变成「最多 2 秒的影响窗口」。
    private func startReconcileTimer() {
        reconcileTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.enforceRightControlTimeout()
        }
        // 放在 common modes, 菜单打开时也能继续跑
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
    }

    private func enforceRightControlTimeout() {
        guard rightControlDown, let since = rightControlDownAt else { return }
        if Date().timeIntervalSince(since) > 2.0 {
            resetRightControlState(reason: "超过 2 秒未收到抬起")
        }
    }

    /// tap 被系统禁用时的恢复
    private func handleTapDisabled() {
        wasDisabledBySystem = true
        resetRightControlState(reason: "事件监听被禁用")
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        Logger.shared.error("事件监听被系统禁用, 已自动重新启用")
    }
}
