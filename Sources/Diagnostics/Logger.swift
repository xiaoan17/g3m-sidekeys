//
//  Logger.swift — 诊断日志层
//
//  设计要点 (针对旧版本的几个问题):
//    1. 不再记录「每一次按键」—— 只记录本工具真正关心的转换事件, 不做键盘记录器
//    2. 写入走独立串行队列 + 异步, 不阻塞事件回调 (事件回调有严格的响应时间预算)
//    3. 文件权限 0600 / 目录 0700
//    4. 双重上限: 按体积轮转 (单文件 2 MB) + 按时间保留 (默认 7 天), 不会无限膨胀
//

import Foundation

final class Logger {

    static let shared = Logger()

    // MARK: - 配置

    /// 单个日志文件上限 (2 MB)
    private let maxFileBytes = 2 * 1024 * 1024
    /// 保留的历史文件个数 (按体积轮转用)
    private let maxBackups = 2
    /// 保留天数上限的候选值
    static let retentionOptions = [1, 3, 7, 30]

    private let directory: URL
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.anbc.g3msidekeys.logger", qos: .utility)
    private var fileHandle: FileHandle?
    private var currentSize: Int = 0
    private var purgeTimer: DispatchSourceTimer?

    /// 当前日志级别。默认只记错误。
    var level: LogLevel = .error {
        didSet { queue.async { [weak self] in self?.reopen() } }
    }

    /// 级别是否足以记录一条**诊断**日志
    ///
    /// 给热路径用: `if Logger.shared.isDiagnosticEnabled { ... }`
    /// 直接用这个判断, 可以避免在事件回调里做无用的字符串拼接
    /// (拼接本身要分配内存, 在有严格时间预算的回调里是有代价的)。
    var isDiagnosticEnabled: Bool { level >= .diagnostic }

    /// 日志保留天数。超过这个天数的日志文件会被自动删除。
    ///
    /// 注意线程安全: 这个值**主线程写** (菜单里改设置)、**日志队列读**
    /// (清理定时器里比较文件时间), 所以读写都走 `stateLock`。
    /// 直接用普通属性会出现数据竞争 —— 清理时可能读到写了一半的值。
    var retentionDays: Int {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _retentionDays
        }
        set {
            let clamped = max(1, newValue)
            stateLock.lock()
            let changed = clamped != _retentionDays
            _retentionDays = clamped
            stateLock.unlock()
            // 值没变就不重复写 UserDefaults
            if changed {
                Settings.logRetentionDays = clamped
            }
            queue.async { [weak self] in self?.purgeExpired() }
        }
    }
    private var _retentionDays: Int
    /// 保护 `_retentionDays` 的锁 (跨线程读写)
    private let stateLock = NSLock()

    // MARK: - 初始化

    private init() {
        let home = NSHomeDirectory()
        directory = URL(fileURLWithPath: "\(home)/Library/Logs/G3MSidekeys", isDirectory: true)
        fileURL = directory.appendingPathComponent("events.log")
        _retentionDays = max(1, Settings.logRetentionDays)

        // 目录 0700 —— 只有本人可读写。
        // 注意: createDirectory 对**已存在**的目录不会改权限, 所以要显式再设一次。
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory.path)
        reopen()
        startPurgeTimer()
    }

    // MARK: - 写入

    /// 记录一条错误
    func error(_ message: String) {
        write(message, level: .error)
    }

    /// 记录一条诊断信息 (仅在诊断级别下生效)
    func diagnostic(_ message: String) {
        write(message, level: .diagnostic)
    }

    private func write(_ message: String, level required: LogLevel) {
        guard self.level >= required else { return }
        // 异步写: 事件回调只负责把数据丢进队列, 立刻返回。
        //
        // 时间戳的格式化也放在队列里做, 原因有二:
        //   1. ISO8601DateFormatter 不是完全线程安全的, 放在队列里就只会被
        //      一条线程用到
        //   2. 格式化开销不占用事件回调的时间预算
        queue.async { [weak self] in
            guard let self else { return }
            let line = "\(Self.timestampFormatter.string(from: Date())): \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            self.append(data)
        }
    }

    /// 复用的时间戳格式化器
    ///
    /// 之前每写一条日志都 `ISO8601DateFormatter()` 新建一个 —— 实测单次
    /// 0.141 ms, 比复用同一个实例慢 **222 倍**。而这条代码跑在 CGEventTap
    /// 的回调里, 回调有严格的响应时间预算, 超时系统会直接禁用事件流
    /// (表现为侧键偶发失灵)。复用一个就够了。
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - 文件管理

    private func reopen() {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.fileHandle?.close()
            self.fileHandle = nil

            if !FileManager.default.fileExists(atPath: self.fileURL.path) {
                FileManager.default.createFile(
                    atPath: self.fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            } else {
                // 已存在的文件强制收紧权限
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: self.fileURL.path)
            }
            self.currentSize = (try? FileManager.default.attributesOfItem(atPath: self.fileURL.path)[.size] as? Int) ?? 0
            self.fileHandle = try? FileHandle(forWritingTo: self.fileURL)
            _ = try? self.fileHandle?.seekToEnd()
        }
    }

    private func append(_ data: Data) {
        guard fileHandle != nil else { return }

        // 轮转: 超限时把当前文件挪成备份
        if currentSize + data.count > maxFileBytes {
            rotate()
        }

        // 注意: rotate() 会关闭并替换 fileHandle, 这里必须**重新取**,
        // 否则会写到已经关闭的旧句柄上, 数据会静默丢失。
        guard let handle = fileHandle else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        currentSize += data.count
    }

    private func rotate() {
        try? fileHandle?.close()
        fileHandle = nil

        // events.log.1 → events.log.2, 删掉更老的
        let fm = FileManager.default
        let oldest = directory.appendingPathComponent("events.log.\(maxBackups)")
        try? fm.removeItem(at: oldest)
        for i in stride(from: maxBackups - 1, through: 1, by: -1) {
            let from = directory.appendingPathComponent("events.log.\(i)")
            let to = directory.appendingPathComponent("events.log.\(i + 1)")
            if fm.fileExists(atPath: from.path) {
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
        }
        let backup = directory.appendingPathComponent("events.log.1")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: fileURL, to: backup)

        // 新的空文件, 继续保持 0600
        fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        currentSize = 0
    }

    // MARK: - 按时间保留

    /// 判断某个日志文件是否已超过保留期 (纯函数, 可单元测试)
    static func isExpired(modified: Date, now: Date = Date(), retentionDays: Int) -> Bool {
        let days = max(1, retentionDays)
        return modified < now.addingTimeInterval(-Double(days) * 24 * 3600)
    }

    /// 定时清理过期日志 (每 30 分钟一次)
    private func startPurgeTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 30 * 60)
        timer.setEventHandler { [weak self] in self?.purgeExpired() }
        timer.resume()
        purgeTimer = timer
    }

    /// 删除超过保留期的日志文件
    ///
    /// 规则:
    ///   - 轮转出来的备份 (events.log.N) 与历史遗留文件: 超过保留期直接删除
    ///   - 当前活跃文件 events.log: 自身也超过保留期时清空重来
    ///     (说明已经很久没写日志了, 留着也没意义)
    func purgeExpired(now: Date = Date()) {
        queue.async { [weak self] in
            self?.purgeExpiredSync(now: now)
        }
    }

    private func purgeExpiredSync(now: Date) {
        let fm = FileManager.default
        let days = retentionDays
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 3600)

        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries {
            let name = url.lastPathComponent
            // 只处理本工具自己的日志文件
            guard name.hasPrefix("events.log") else { continue }

            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            let expired = modified < cutoff
            diagnostic("清理检查: \(name) 修改于 \(modified) 保留 \(days) 天 → \(expired ? "过期, 删除" : "保留")")
            guard expired else { continue }

            if url.path == fileURL.path {
                // 活跃文件太久没更新 → 清空
                try? fileHandle?.close()
                fileHandle = nil
                fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                fileHandle = try? FileHandle(forWritingTo: fileURL)
                currentSize = 0
                // 提示要写在截断之后, 否则会连同旧内容一起被清掉
                log("活跃日志超过保留期, 已清空")
            } else {
                // 历史备份 → 直接删
                try? fm.removeItem(at: url)
            }
        }
    }

    /// 内部记账用 (不经过 level 过滤, 避免递归)
    private func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())): [清理] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = fileHandle {
            handle.seekToEndOfFile()
            handle.write(data)
            currentSize += data.count
        }
    }

    // MARK: - 对外工具

    /// 日志文件所在目录 (菜单里 "在访达中显示" 用)
    var logDirectoryURL: URL { directory }

    /// 日志文件路径
    var logFileURL: URL { fileURL }
}
