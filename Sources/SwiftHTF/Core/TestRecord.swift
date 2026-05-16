import Foundation

/// 测试结果
public enum TestOutcome: String, Sendable, Codable {
    case pass = "PASS"
    /// 全部 phase 通过，但至少一个 phase 是 marginalPass — 算放行但需关注
    case marginalPass = "MARGINAL_PASS"
    case fail = "FAIL"
    case error = "ERROR"
    case timeout = "TIMEOUT"
    case aborted = "ABORTED"
}

/// Subtest 聚合结果
public enum SubtestOutcome: String, Sendable, Codable {
    case pass = "PASS"
    case fail = "FAIL"
    /// 取消 / 不可恢复异常
    case error = "ERROR"
    /// runIf=false 跳过整 subtest
    case skip = "SKIP"
}

/// Subtest 记录：内部 phase 仍写入 `TestRecord.phases`，本结构仅承载聚合 outcome + phase 引用。
///
/// `phaseIDs` 与 `TestRecord.phases` 内的 `PhaseRecord.id` 一一对应；消费方按此关联渲染。
public struct SubtestRecord: Sendable, Codable, Identifiable {
    public let id: UUID
    public let name: String
    public var outcome: SubtestOutcome
    public let startTime: Date
    public var endTime: Date?
    /// 该 subtest 内每个 phase 在 `TestRecord.phases` 里的 id（按执行顺序）
    public var phaseIDs: [UUID]
    /// 短路触发原因（哪个 phase / 子节点何种返回值）
    public var failureReason: String?

    public init(
        id: UUID = UUID(),
        name: String,
        outcome: SubtestOutcome = .pass,
        startTime: Date = Date(),
        endTime: Date? = nil,
        phaseIDs: [UUID] = [],
        failureReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.outcome = outcome
        self.startTime = startTime
        self.endTime = endTime
        self.phaseIDs = phaseIDs
        self.failureReason = failureReason
    }

    public var duration: TimeInterval {
        guard let endTime else { return 0 }
        return endTime.timeIntervalSince(startTime)
    }
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
    /// Subtest 聚合记录（按执行顺序）。subtest 内 phase 仍存于 `phases`，本数组仅作为聚合层。
    /// 旧 JSON 不含此字段时反序列化为空数组。
    public var subtests: [SubtestRecord]
    /// 测试级诊断结果（由 `TestPlan.diagnosers` 在测试收尾时产生）。
    /// 旧 JSON 不含此字段时反序列化为空数组。
    public var diagnoses: [Diagnosis]
    /// 工站元数据（站标识 / 位置 / 主机名）。session 启动时注入，运行中不可变。
    public var stationInfo: StationInfo?
    /// DUT 元数据（型号 / 制造日期 / 自定义属性）。session 启动时注入或扫码后回填。
    public var dutInfo: DUTInfo?
    /// 代码版本元数据（git hash / build id / environment）。一般由 CI 注入。
    public var codeInfo: CodeInfo?
    /// 操作员标识（用户名 / 工号）。
    public var operatorName: String?
    /// 用户自定义自由字段。OpenHTF 风格的"任何想留底的字符串"。
    public var metadata: [String: String]

    public init(planName: String, serialNumber: String?) {
        id = UUID()
        self.planName = planName
        self.serialNumber = serialNumber
        startTime = Date()
        endTime = nil
        outcome = .pass
        phases = []
        subtests = []
        diagnoses = []
        stationInfo = nil
        dutInfo = nil
        codeInfo = nil
        operatorName = nil
        metadata = [:]
    }

    /// 测试持续时间
    public var duration: TimeInterval {
        guard let endTime else { return Date().timeIntervalSince(startTime) }
        return endTime.timeIntervalSince(startTime)
    }

    /// 失败的阶段列表（含 `.fail / .error / .timeout`）
    public var failedPhases: [PhaseRecord] {
        phases.filter(\.isFailing)
    }

    /// 显式 Codable：兼容旧 JSON 中无 subtests / diagnoses / stationInfo / dutInfo /
    /// codeInfo / operatorName 字段
    private enum CodingKeys: String, CodingKey {
        case id, planName, serialNumber, startTime, endTime, outcome
        case phases, subtests, diagnoses
        case stationInfo, dutInfo, codeInfo, operatorName
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        planName = try c.decode(String.self, forKey: .planName)
        serialNumber = try c.decodeIfPresent(String.self, forKey: .serialNumber)
        startTime = try c.decode(Date.self, forKey: .startTime)
        endTime = try c.decodeIfPresent(Date.self, forKey: .endTime)
        outcome = try c.decode(TestOutcome.self, forKey: .outcome)
        phases = try c.decodeIfPresent([PhaseRecord].self, forKey: .phases) ?? []
        subtests = try c.decodeIfPresent([SubtestRecord].self, forKey: .subtests) ?? []
        diagnoses = try c.decodeIfPresent([Diagnosis].self, forKey: .diagnoses) ?? []
        stationInfo = try c.decodeIfPresent(StationInfo.self, forKey: .stationInfo)
        dutInfo = try c.decodeIfPresent(DUTInfo.self, forKey: .dutInfo)
        codeInfo = try c.decodeIfPresent(CodeInfo.self, forKey: .codeInfo)
        operatorName = try c.decodeIfPresent(String.self, forKey: .operatorName)
        metadata = try c.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(planName, forKey: .planName)
        try c.encodeIfPresent(serialNumber, forKey: .serialNumber)
        try c.encode(startTime, forKey: .startTime)
        try c.encodeIfPresent(endTime, forKey: .endTime)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(phases, forKey: .phases)
        try c.encode(subtests, forKey: .subtests)
        try c.encode(diagnoses, forKey: .diagnoses)
        try c.encodeIfPresent(stationInfo, forKey: .stationInfo)
        try c.encodeIfPresent(dutInfo, forKey: .dutInfo)
        try c.encodeIfPresent(codeInfo, forKey: .codeInfo)
        try c.encodeIfPresent(operatorName, forKey: .operatorName)
        try c.encode(metadata, forKey: .metadata)
    }
}
