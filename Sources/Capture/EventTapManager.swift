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

    // MARK: - 生命周期

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        // 需要监听的事件:
        //   - 侧键鼠标事件 (兼容标准上报 button 3/4 的鼠标)
        //   - 键盘 C/V 与 Right Control (G3M PRO 主路径)
        // 注意: **不要** 加入 leftMouseDown —— 旧版本监听它只为了打日志,
        // 徒增每个左键点击的回调开销, 没有任何功能价值。
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

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

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let button = event.getIntegerValueField(.mouseEventButtonNumber)

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

        let action = SidekeyMapper.decide(type: type,
                                          keycode: keycode,
                                          flags: flags,
                                          button: button,
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
            Logger.shared.diagnostic("侧键转换: Ctrl+\(newKeycode == SidekeyMapper.copyKeyCode ? "C" : "V") -> Cmd+\(newKeycode == SidekeyMapper.copyKeyCode ? "C" : "V")")
            return Unmanaged.passUnretained(mutable)

        case .injectCommand(let keycode):
            Logger.shared.diagnostic("侧键(鼠标)触发: 注入 Cmd+\(keycode == SidekeyMapper.copyKeyCode ? "C" : "V")")
            EventInjector.postCommandKey(keycode)
            return nil   // 吞掉原始侧键事件, 阻止浏览器前进/后退

        case .swallow:
            return nil
        }
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
