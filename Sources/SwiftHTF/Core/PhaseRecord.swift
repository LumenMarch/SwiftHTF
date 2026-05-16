import Foundation

/// 阶段执行结果
public enum PhaseOutcomeType: String, Sendable, Codable {
    case pass = "PASS"
    /// 在硬限值内但落入 marginal 警告带 — 算通过但需关注
    case marginalPass = "MARGINAL_PASS"
    case fail = "FAIL"
    case skip = "SKIP"
    case error = "ERROR"
    /// phase 执行超过 `Phase.timeout` —— 与 `.error` 区分，便于上游决定是否
    /// 重试或告警。聚合到 `TestRecord.outcome` 时：若所有失败 phase 都是
    /// `.timeout`，record 标 `.timeout`；混合 fail/error 仍优先 `.fail`。
    case timeout = "TIMEOUT"
}

/// 阶段记录
public struct PhaseRecord: Sendable, Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let startTime: Date
    public var endTime: Date?
    public var outcome: PhaseOutcomeType
    public var measurements: [String: Measurement]
    /// 多维 measurement 结果（IV 曲线、扫频、扫温等）。与 `measurements` 平行存放。
    public var traces: [String: SeriesMeasurement]
    public var attachments: [Attachment]
    public var errorMessage: String?
    /// 所属 group 的祖先路径（顶层 phase 为空数组）。例：["PowerRail"], ["PowerRail", "Inner"]。
    public var groupPath: [String]
    /// 诊断结果（由 phase.diagnosers 在 fail/error 终态产生）
    public var diagnoses: [Diagnosis]
    /// phase 闭包写入的日志（按写入顺序）
    public var logs: [LogEntry]
    /// phase 闭包返回 `.failSubtest` 时由 PhaseExecutor 置为 true。
    /// 在 Subtest 内 → 触发 subtest 短路；不在 Subtest 内 → 字段保留但无效。
    public var subtestFailRequested: Bool
    /// phase 闭包返回 `.stop` 时由 PhaseExecutor 置为 true。
    /// TestSession 据此向外冒泡 GroupOutcome.stopped，不被 Subtest 的失败隔离吞掉。
    public var stopRequested: Bool
    /// 参数化 phase 的运行时参数快照（由 `Phase.withArgs(...)` 设定）。
    /// `ctx.args.string(...) / .double(...) / .value(_:as:)` 读取的同一份字典。
    /// 旧 JSON 反序列化时缺字段则为空 dict。
    public var arguments: [String: AnyCodableValue]

    public init(name: String) {
        id = UUID()
        self.name = name
        startTime = Date()
        endTime = nil
        outcome = .pass
        measurements = [:]
        traces = [:]
        attachments = []
        errorMessage = nil
        groupPath = []
        diagnoses = []
        logs = []
        subtestFailRequested = false
        stopRequested = false
        arguments = [:]
    }

    /// 显式 Codable：兼容旧 JSON 中无新增字段
    private enum CodingKeys: String, CodingKey {
        case id, name, startTime, endTime, outcome
        case measurements, traces, attachments, errorMessage
        case groupPath, diagnoses, logs
        case subtestFailRequested, stopRequested
        case arguments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        startTime = try c.decode(Date.self, forKey: .startTime)
        endTime = try c.decodeIfPresent(Date.self, forKey: .endTime)
        outcome = try c.decode(PhaseOutcomeType.self, forKey: .outcome)
        measurements = try c.decodeIfPresent([String: Measurement].self, forKey: .measurements) ?? [:]
        traces = try c.decodeIfPresent([String: SeriesMeasurement].self, forKey: .traces) ?? [:]
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        groupPath = try c.decodeIfPresent([String].self, forKey: .groupPath) ?? []
        diagnoses = try c.decodeIfPresent([Diagnosis].self, forKey: .diagnoses) ?? []
        logs = try c.decodeIfPresent([LogEntry].self, forKey: .logs) ?? []
        subtestFailRequested = try c.decodeIfPresent(Bool.self, forKey: .subtestFailRequested) ?? false
        stopRequested = try c.decodeIfPresent(Bool.self, forKey: .stopRequested) ?? false
        arguments = try c.decodeIfPresent([String: AnyCodableValue].self, forKey: .arguments) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(startTime, forKey: .startTime)
        try c.encodeIfPresent(endTime, forKey: .endTime)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(measurements, forKey: .measurements)
        try c.encode(traces, forKey: .traces)
        try c.encode(attachments, forKey: .attachments)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encode(groupPath, forKey: .groupPath)
        try c.encode(diagnoses, forKey: .diagnoses)
        try c.encode(logs, forKey: .logs)
        try c.encode(subtestFailRequested, forKey: .subtestFailRequested)
        try c.encode(stopRequested, forKey: .stopRequested)
        try c.encode(arguments, forKey: .arguments)
    }

    /// 阶段持续时间
    public var duration: TimeInterval {
        guard let endTime else { return Date().timeIntervalSince(startTime) }
        return endTime.timeIntervalSince(startTime)
    }

    /// 终态是否为失败族（`.fail / .error / .timeout`），便于聚合层统一短路 / failed 判定。
    public var isFailing: Bool {
        switch outcome {
        case .fail, .error, .timeout: true
        case .pass, .marginalPass, .skip: false
        }
    }
}
