//
//  ModifierText.swift — 「按住修饰键」的字符换算
//
//  为什么需要这一层?
//
//  macOS 的修饰键状态 (CGEventFlags) 是**系统级、只读**的:
//   - 注入 flagsChanged 事件 → 系统直接丢弃, 修饰键状态不变 (实测)
//   - 注入 keyDown(keycode=修饰键) → 同样不改变修饰键状态 (实测)
//   - 给事件设置 .maskAlternate → 只影响 event.flags 字段,
//     **不会**让输入法据此产出 ⌥ 字符
//
//  所以「按住右 Option」不能靠伪造修饰键状态来实现。
//
//  可行的做法是: 在按住期间, 把用户真实按下的每个键**改写成它本该输出的字符**。
//  用 UCKeyTranslate + 当前键盘布局算出「这个键在 ⌥ 按下时输出什么」,
//  再通过 keyboardSetUnicodeString 写进真实事件 —— 真实事件的 unicode 串
//  是会被系统采用的 (实测 k → ˚ 生效)。
//
//  这样做的取舍:
//    - 打得出 ⌥ 字符 (⌥K → ˚, ⌥A → å) ✅
//    - 不会真的让系统认为 Option 被按住, 所以某些应用里"按住 Option 点按"
//      的原生行为不会触发 ❌
//  对「用侧键输入特殊字符」这个主要诉求来说, 这是能满足的那条路。
//
//  ────────────────────────────────────────────────────────────────
//  三条必须遵守的规则 (改这个文件前请先读完)
// ────────────────────────────────────────────────────────────────
//
//  1) 修饰键状态要用 **Carbon 的低字节编码**:
//         cmd = 0x01, shift = 0x02, option = 0x08, control = 0x10
//     Carbon 常量 (cmdKey=0x0100 / shiftKey=0x0200 / optionKey=0x0800 /
//     controlKey=0x1000) 正好是这套编码左移 8 位的结果, 所以统一用
//     `constant >> 8` 取值。传高字节形式 (0x0800) 给 UCKeyTranslate 会
//     **静默失效** —— 实测传 0x0800 得到的是普通 "k" 而不是 "˚"。
//
//  2) 必须把**事件自带的修饰键** (用户自己按住的 Shift/⌘/⌥/⌃) 一起算进去。
//     否则「按住右 Option + 按住 Shift + K」会被算成 ⌥K 而不是 ⇧⌥K,
//     用户按的 Shift 被吞掉。
//
//  3) 缓存键必须包含上面这些修饰键状态, 否则带 Shift / 不带 Shift 的
//     查询会互相命中缓存, 后查的那个拿到错字符。
//

import Carbon
import CoreGraphics
import Foundation

/// 把一个键码按「是否按住某个修饰键」换算成实际应输出的字符串
enum ModifierText {

    // MARK: - 缓存

    /// 换算结果缓存。key = (keyCode, 虚拟修饰键, 事件自带的修饰键状态)
    ///
    /// 事件回调在热路径上, 每次按键都去查 TIS / 跑 UCKeyTranslate 太慢,
    /// 而且键盘布局在运行期间几乎不变 —— 缓存后只在布局切换时清空。
    private static var cache: [CacheKey: String] = [:]
    private static let lock = NSLock()

    private struct CacheKey: Hashable {
        let keyCode: Int64
        let modifier: ModifierKey
        /// 事件自带的修饰键状态 (Carbon 低字节编码)
        let eventState: UInt32
    }

    /// 键盘布局变化时清空缓存 (由调用方在切换输入源时调用)
    static func invalidateCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// 当前键盘布局的标识, 用于检测布局是否变了
    ///
    /// 用 **输入源 ID** (如 "com.apple.keylayout.ABC"), 而不是
    /// `kTISPropertyUnicodeKeyLayoutData` 的**指针地址** —— 指针地址会
    /// 被系统回收后复用, 两个不同的布局可能拿到同一个地址, 导致缓存
    /// 清空时机不对 (旧字符被当成新布局的结果继续用)。
    private static func currentLayoutID() -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return "unknown"
        }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private static var cachedLayoutID = ""

    // MARK: - 对外接口

    /// 某个键码在「按住 modifier」时应输出的字符
    ///
    /// - Parameters:
    ///   - keyCode:  键码
    ///   - modifier: 鼠标键正在「按住」的那个虚拟修饰键
    ///   - eventFlags: 该次按键事件**自带**的修饰键 (用户自己按住的
    ///                 Shift / ⌘ / ⌥ / ⌃)。必须一起参与换算, 否则用户
    ///                 额外按下的 Shift 会被吞掉。
    /// - Returns: 换算后的字符串; 换算不出来时返回 nil (调用方应回退到补 flags)
    static func character(for keyCode: Int64,
                          holding modifier: ModifierKey,
                          eventFlags: CGEventFlags = []) -> String? {
        let eventState = carbonState(from: eventFlags)
        let key = CacheKey(keyCode: keyCode, modifier: modifier, eventState: eventState)

        lock.lock()
        if cachedLayoutID != currentLayoutID() {
            cache.removeAll()
            cachedLayoutID = currentLayoutID()
        }
        if let hit = cache[key] {
            lock.unlock()
            return hit.isEmpty ? nil : hit
        }
        lock.unlock()

        let result = translate(keyCode: keyCode,
                               carbonState: carbonState(for: modifier) | eventState) ?? ""

        lock.lock()
        cache[key] = result
        lock.unlock()

        return result.isEmpty ? nil : result
    }

    /// 这个虚拟修饰键会不会**改变按键本身输出的字符**
    ///
    /// - ⌥ 会 (⌥K → ˚), ⇧ 会 (⇧K → K)
    /// - ⌘ 不会 (⌘K 的字符仍是 k —— 它的作用在应用层的 modifierFlags 上)
    /// - ⌃ 不会 (⌃K 是控制字符, 本来就不该作为文本输出)
    ///
    /// 区分这一点很重要: 对 ⌘ / ⌃ 来说, 正确的做法是**补 modifierFlags**,
    /// 而不是改写字符。v1.3.0 之前一律改写字符, 于是「按住左 Command」
    /// 会打出 "˚" —— 完全是错的。
    static func altersGlyph(_ modifier: ModifierKey) -> Bool {
        switch modifier {
        case .leftOption, .rightOption, .shift:
            return true
        case .leftCommand, .rightCommand, .leftControl, .rightControl:
            return false
        }
    }

    // MARK: - 修饰键编码

    /// CGEventFlags → Carbon 的 modifierKeyState 低字节编码
    ///
    /// 只取会影响字符生成的 4 位, 其余 (caps lock / 数字键盘 / 功能键) 忽略。
    static func carbonState(from flags: CGEventFlags) -> UInt32 {
        var state: UInt32 = 0
        if flags.contains(.maskCommand)   { state |= UInt32(cmdKey >> 8) }
        if flags.contains(.maskShift)     { state |= UInt32(shiftKey >> 8) }
        if flags.contains(.maskAlternate) { state |= UInt32(optionKey >> 8) }
        if flags.contains(.maskControl)   { state |= UInt32(controlKey >> 8) }
        return state
    }

    /// 虚拟修饰键 → Carbon 的 modifierKeyState 低字节编码
    ///
    /// 左 / 右的区别只在**键码**层面 (左 Option=58 / 右 Option=61),
    /// 对字符生成没有影响 —— 左右 Option 打出来的字符完全一样。
    static func carbonState(for modifier: ModifierKey) -> UInt32 {
        switch modifier {
        case .leftOption, .rightOption:   return UInt32(optionKey >> 8)
        case .leftCommand, .rightCommand: return UInt32(cmdKey >> 8)
        case .leftControl, .rightControl: return UInt32(controlKey >> 8)
        case .shift:                      return UInt32(shiftKey >> 8)
        }
    }

    // MARK: - 真正做换算的那一步

    /// 真正做换算的那一步
    private static func translate(keyCode: Int64, carbonState: UInt32) -> String? {
        guard keyCode >= 0, keyCode <= 127 else { return nil }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return nil
            }

            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 8)
            var length = 0

            let status = UCKeyTranslate(layout,
                                        UInt16(keyCode),
                                        UInt16(kUCKeyActionDisplay),
                                        carbonState,
                                        UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState,
                                        chars.count,
                                        &length,
                                        &chars)
            guard status == noErr, length > 0 else { return nil }

            // 过滤掉「换算出来了但根本不能当字符用」的结果:
            //   - 控制字符 (F1..F20 在 ⌥ 下会映射成 U+0010, 方向键映射成
            //     U+001C 等 —— 这些不是文字, 写进事件只会让应用收到乱码)
            //   - 私有区字符 (除苹果 logo 外)
            // 这类结果应当回退到补 flags 的老做法, 至少让应用读到正确的
            // modifierFlags。
            for unit in chars.prefix(length) {
                guard let scalar = Unicode.Scalar(unit) else { return nil }
                let category = scalar.properties.generalCategory
                switch category {
                case .control, .format, .surrogate, .unassigned:
                    return nil
                case .privateUse:
                    // U+F8FF 是苹果 logo —— 它**不是**乱码, 而是 macOS 在
                    // ⌥⇧K 上真实输出的字符 (实测确认)。macOS 的字体栈普遍
                    // 认识这个码位, 所以放行; 其它私有区字符仍然挡掉。
                    guard scalar.value == 0xF8FF else { return nil }
                default:
                    break
                }
            }

            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
