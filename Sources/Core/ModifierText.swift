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

import Carbon
import CoreGraphics
import Foundation

/// 把一个键码按「是否按住某个修饰键」换算成实际应输出的字符串
enum ModifierText {

    /// 换算结果缓存。key = (keyCode, modifier)
    ///
    /// 事件回调在热路径上, 每次按键都去查 TIS / 跑 UCKeyTranslate 太慢,
    /// 而且键盘布局在运行期间几乎不变 —— 缓存后只在布局切换时清空。
    private static var cache: [CacheKey: String] = [:]
    private static let lock = NSLock()

    private struct CacheKey: Hashable {
        let keyCode: Int64
        let modifier: ModifierKey
    }

    /// 键盘布局变化时清空缓存 (由调用方在切换输入源时调用)
    static func invalidateCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// 当前键盘布局的标识, 用于检测布局是否变了
    private static func currentLayoutID() -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "unknown"
        }
        return String(describing: ptr)
    }

    private static var cachedLayoutID = ""

    /// 某个键码在「按住 modifier」时应输出的字符
    ///
    /// - Returns: 换算后的字符串; 换算不出来时返回 nil (调用方应回退到原事件)
    static func character(for keyCode: Int64, holding modifier: ModifierKey) -> String? {
        let key = CacheKey(keyCode: keyCode, modifier: modifier)

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

        let result = translate(keyCode: keyCode, modifier: modifier) ?? ""

        lock.lock()
        cache[key] = result
        lock.unlock()

        return result.isEmpty ? nil : result
    }

    /// 真正做换算的那一步
    private static func translate(keyCode: Int64, modifier: ModifierKey) -> String? {
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

            // UCKeyTranslate 要的 modifierKeyState 是「修饰键的高字节」,
            // 不是 CGEventFlags —— 传错的话换算结果会完全不对。
            var mods: UInt32 = 0
            func set(_ carbonFlag: Int) { mods |= UInt32(carbonFlag >> 8) }

            set(optionKey)                                  // 这个动作必然涉及 ⌥
            if modifier.flag.contains(.maskShift) { set(shiftKey) }

            let status = UCKeyTranslate(layout,
                                        UInt16(keyCode),
                                        UInt16(kUCKeyActionDisplay),
                                        mods,
                                        UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState,
                                        chars.count,
                                        &length,
                                        &chars)

            guard status == noErr, length > 0 else { return nil }

            // 过滤掉「换算出来了但根本不能当字符用」的结果:
            //   - 控制字符 (F1..F20 在 ⌥ 下会映射成 U+0010 这类东西)
            //   - 私有区字符
            // 这类结果拿去改写事件只会让应用收到乱码, 应当回退到补 flags。
            for unit in chars.prefix(length) {
                guard let scalar = Unicode.Scalar(unit) else { return nil }
                let category = scalar.properties.generalCategory
                switch category {
                case .control, .format, .surrogate, .privateUse, .unassigned:
                    return nil
                default:
                    break
                }
            }

            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
