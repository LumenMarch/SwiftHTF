import Foundation

/// 阶段执行结果
public enum PhaseOutcomeType: String, Sendable, Codable {
    case pass = "PASS"
    /// 在硬限值内但落入 marginal 警告带 — 算通过但需关注
    case marginalPass = "MARGINAL_PASS"
    case fail = "FAIL"
    case skip = "SKIP"
    case error = "ERROR"
}

/// 阶段记录
public struct PhaseRecord: Sendable, Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let startTime: Date
    public var endTime: Date?
    public var outcome: PhaseOutcomeType
    public var value: String?
    public var measurements: [String: Measurement]
    /// 多维 measurement 结果（IV 曲线、扫频、扫温等）。与 `measurements` 平行存放。
    public var traces: [String: SeriesMeasurement]
    public var attachments: [Attachment]
    public var errorMessage: String?
    /// 所属 group 的祖先路径（顶层 phase 为空数组）。例：["PowerRail"], ["PowerRail", "Inner"]。
    public var groupPath: [String]
    /// 诊断结果（由 phase.diagnosers 在 fail/error 终态产生）
    public var diagnoses: [Diagnosis]

    public init(name: String) {
        self.id = UUID()
        self.name = name
        self.startTime = Date()
        self.endTime = nil
        self.outcome = .pass
        self.value = nil
        self.measurements = [:]
        self.traces = [:]
        self.attachments = []
        self.errorMessage = nil
        self.groupPath = []
        self.diagnoses = []
    }

    /// 阶段持续时间
    public var duration: TimeInterval {
        guard let endTime else { return Date().timeIntervalSince(startTime) }
        return endTime.timeIntervalSince(startTime)
    }
}
