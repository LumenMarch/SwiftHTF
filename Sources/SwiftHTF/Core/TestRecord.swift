import Foundation

/// 测试结果
public enum TestOutcome: String, Sendable, Codable {
    case pass = "PASS"
    case fail = "FAIL"
    case error = "ERROR"
    case timeout = "TIMEOUT"
    case aborted = "ABORTED"
}

/// 测试记录
public struct TestRecord: Sendable, Codable, Identifiable {
    public let id: UUID
    public let planName: String
    /// 序列号。execute(serialNumber:) 的入参作为初值，phase 内可通过 `ctx.serialNumber = ...`
    /// 修改（例如扫码后回填），收尾时由 TestExecutor 同步回 record。
    public var serialNumber: String?
    public let startTime: Date
    public var endTime: Date?
    public var outcome: TestOutcome
    public var phases: [PhaseRecord]
    public var metadata: [String: String]

    public init(planName: String, serialNumber: String?) {
        self.id = UUID()
        self.planName = planName
        self.serialNumber = serialNumber
        self.startTime = Date()
        self.endTime = nil
        self.outcome = .pass
        self.phases = []
        self.metadata = [:]
    }

    /// 测试持续时间
    public var duration: TimeInterval {
        guard let endTime else { return Date().timeIntervalSince(startTime) }
        return endTime.timeIntervalSince(startTime)
    }

    /// 失败的阶段列表
    public var failedPhases: [PhaseRecord] {
        phases.filter { $0.outcome == .fail || $0.outcome == .error }
    }
}
