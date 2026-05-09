import Foundation

/// 日志级别
public enum LogLevel: String, Sendable, Codable, Comparable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    private var ordinal: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}

/// 一条 phase 日志条目
///
/// 由 `TestContext.log(...)` 写入，phase 结束时收集到 `PhaseRecord.logs`。
public struct LogEntry: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}
