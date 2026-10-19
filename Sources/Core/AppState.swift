//
//  AppState.swift — 应用状态层 (单一数据源)
//
//  UI 和事件处理都从这里读状态, 改状态也只走这里, 改完自动通知 UI 刷新。
//  事件回调里读的是内存缓存, 不去碰 UserDefaults, 避免在热路径上做磁盘 IO。
//

import Foundation

/// 日志级别
enum LogLevel: Int, Comparable, CaseIterable {
    /// 完全不写日志
    case off = 0
    /// 只记录错误 (默认) —— 例如权限缺失、事件监听创建失败
    case error = 1
    /// 记录诊断信息 —— 侧键转换、鼠标侧键事件等
    case diagnostic = 2

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var displayName: String {
        switch self {
        case .off:    return "关闭"
        case .error:  return "仅错误"
        case .diagnostic: return "诊断"
        }
    }
}

/// 状态变化通知
extension Notification.Name {
    static let appStateDidChange = Notification.Name("com.anbc.g3msidekeys.appStateDidChange")
}

/// 全局状态
final class AppState {

    static let shared = AppState()

    private var _enabled: Bool
    private var _swapped: Bool
    private var _logLevel: LogLevel
    private var _logRetentionDays: Int

    init() {
        _enabled = Settings.enabled
        _swapped = Settings.swapped
        _logLevel = Settings.logLevel
        _logRetentionDays = Settings.logRetentionDays
    }

    // MARK: - 存储

    /// 映射总开关
    var enabled: Bool {
        get { _enabled }
        set {
            guard newValue != _enabled else { return }
            _enabled = newValue
            Settings.enabled = newValue
            notifyChange()
        }
    }

    /// 是否交换复制/粘贴
    var swapped: Bool {
        get { _swapped }
        set {
            guard newValue != _swapped else { return }
            _swapped = newValue
            Settings.swapped = newValue
            notifyChange()
        }
    }

    /// 日志级别
    var logLevel: LogLevel {
        get { _logLevel }
        set {
            guard newValue != _logLevel else { return }
            _logLevel = newValue
            Settings.logLevel = newValue
            Logger.shared.level = newValue
            notifyChange()
        }
    }

    /// 日志保留天数
    var logRetentionDays: Int {
        get { _logRetentionDays }
        set {
            let clamped = max(1, newValue)
            guard clamped != _logRetentionDays else { return }
            _logRetentionDays = clamped
            Settings.logRetentionDays = clamped
            Logger.shared.retentionDays = clamped
            notifyChange()
        }
    }

    /// 供事件处理路径使用的轻量快照 (值类型, 无锁开销)
    var mappingContext: MappingContext {
        MappingContext(enabled: _enabled, swapped: _swapped, rightControlDown: false)
    }

    // MARK: - 通知

    private func notifyChange() {
        NotificationCenter.default.post(name: .appStateDidChange, object: self)
    }
}
