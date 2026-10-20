//
//  Settings.swift — 配置持久化层
//
//  只负责把 AppState 的状态读写到 UserDefaults, 不含任何业务逻辑。
//  store 可注入, 便于单元测试使用独立的 suite, 不污染真实配置。
//

import Foundation

/// 配置项的存储键
enum SettingsKey {
    static let enabled = "g3m.enabled"
    static let swapped = "g3m.swapped"
    static let logLevel = "g3m.logLevel"
    static let logRetentionDays = "g3m.logRetentionDays"
    /// 自定义绑定表 (JSON)
    static let bindings = "g3m.bindings"
    /// 老版本用的是 "enabled" / "swapped"（无前缀），这里做一次性迁移
    static let legacyEnabled = "enabled"
    static let legacySwapped = "swapped"
}

/// 读取/写入 UserDefaults
enum Settings {

    /// 存储后端。生产环境用 .standard; 测试注入独立 suite。
    static var store: UserDefaults = .standard

    private static var defaults: UserDefaults { store }

    /// 首次运行且读到旧键时，把它迁移到新键
    static func migrateIfNeeded() {
        let d = defaults
        if d.object(forKey: SettingsKey.legacyEnabled) != nil {
            if d.object(forKey: SettingsKey.enabled) == nil {
                d.set(d.bool(forKey: SettingsKey.legacyEnabled), forKey: SettingsKey.enabled)
            }
            d.removeObject(forKey: SettingsKey.legacyEnabled)
        }
        if d.object(forKey: SettingsKey.legacySwapped) != nil {
            if d.object(forKey: SettingsKey.swapped) == nil {
                d.set(d.bool(forKey: SettingsKey.legacySwapped), forKey: SettingsKey.swapped)
            }
            d.removeObject(forKey: SettingsKey.legacySwapped)
        }
    }

    /// 总开关，默认开启
    static var enabled: Bool {
        get {
            migrateIfNeeded()
            // 未设置过时默认 true —— 装上就能用
            guard defaults.object(forKey: SettingsKey.enabled) != nil else { return true }
            return defaults.bool(forKey: SettingsKey.enabled)
        }
        set { defaults.set(newValue, forKey: SettingsKey.enabled) }
    }

    /// 是否交换复制/粘贴，默认不交换
    ///
    /// v1.2.0 起这个开关只用于**一次性迁移**: 老版本的 "交换" 语义等价于
    /// 「把侧键1/侧键2 的绑定对调」, 迁移进绑定表之后就不再需要它了。
    static var swapped: Bool {
        get {
            migrateIfNeeded()
            return defaults.bool(forKey: SettingsKey.swapped)
        }
        set { defaults.set(newValue, forKey: SettingsKey.swapped) }
    }

    /// 自定义绑定表
    ///
    /// 首次读取时若本地还没有绑定表, 就按默认值生成 —— 并把老版本的
    /// 「交换复制/粘贴」开关折算成侧键1/侧键2 绑定对调, 保证升级后
    /// 用户的手感不变。
    static var bindings: BindingTable {
        get {
            if let data = defaults.data(forKey: SettingsKey.bindings),
               let table = try? JSONDecoder().decode(BindingTable.self, from: data) {
                return table
            }
            return defaultBindings()
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: SettingsKey.bindings)
        }
    }

    /// 默认绑定表 (考虑老版本的「交换」开关)
    static func defaultBindings() -> BindingTable {
        migrateIfNeeded()
        let legacy = defaults.bool(forKey: SettingsKey.swapped)
        return legacy ? BindingTable.default.swappingSides() : BindingTable.default
    }

    /// 日志级别，默认只记错误
    static var logLevel: LogLevel {
        get {
            // 注意: LogLevel.off 的 rawValue 是 0, 因此**不能**直接用
            // `LogLevel(rawValue: integer) ?? .error` —— 未设置时 integer 为 0,
            // 会被解析成 .off 而不是预期的 .error。必须先判断键是否存在。
            guard defaults.object(forKey: SettingsKey.logLevel) != nil else { return .error }
            return LogLevel(rawValue: defaults.integer(forKey: SettingsKey.logLevel)) ?? .error
        }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.logLevel) }
    }

    /// 日志保留天数, 默认 7 天
    static var logRetentionDays: Int {
        get {
            guard defaults.object(forKey: SettingsKey.logRetentionDays) != nil else { return 7 }
            let value = defaults.integer(forKey: SettingsKey.logRetentionDays)
            return value >= 1 ? value : 7
        }
        set { defaults.set(max(1, newValue), forKey: SettingsKey.logRetentionDays) }
    }
}
