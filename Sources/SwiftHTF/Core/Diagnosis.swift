import Foundation

/// 诊断严重度
public enum DiagnosisSeverity: String, Sendable, Codable {
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"
}

/// 诊断结果：故障码 + 描述 + 任意 details
///
/// 由 phase.diagnosers 在 phase 失败终态产生，绑定到 PhaseRecord.diagnoses。
public struct Diagnosis: Sendable, Codable, Identifiable {
    public let id: UUID
    public let code: String
    public let severity: DiagnosisSeverity
    public let message: String
    public let details: [String: AnyCodableValue]
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        code: String,
        severity: DiagnosisSeverity = .error,
        message: String,
        details: [String: AnyCodableValue] = [:],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.code = code
        self.severity = severity
        self.message = message
        self.details = details
        self.timestamp = timestamp
    }
}

/// 诊断器触发时机控制。
///
/// 各协议默认值贴近旧行为：
/// - `PhaseDiagnoser` 默认 `.onlyOnFail`（旧实现就是仅在 phase 失败时跑）
/// - `TestDiagnoser` 默认 `.always`（旧实现就是无条件跑，用户在闭包内 guard）
public enum DiagnoserTrigger: String, Sendable, Codable {
    /// 总是触发（pass / marginalPass / skip 终态也跑），用于 metric / log 类诊断器。
    case always = "ALWAYS"
    /// 仅在失败族（`.fail / .error / .timeout`）终态触发。
    case onlyOnFail = "ONLY_ON_FAIL"
}

/// Phase 诊断器：按 `trigger` 决定是否在某终态触发。
///
/// 隔离：`@MainActor`。可读 ctx 已收集的状态（先前 phase 的写入），
/// 也可写 `ctx.attach(...)` / `ctx.measure(...)` 留下调试线索 —— 这些
/// 副作用会被合并进当前 phase 的 PhaseRecord（measurement 不再跑 spec
/// validation，attachments 直接追加）。
public protocol PhaseDiagnoser: Sendable {
    /// 用于调试 / 输出的简短标签
    var label: String { get }

    /// 触发时机；默认实现 `.onlyOnFail`，与既有行为兼容。
    var trigger: DiagnoserTrigger { get }

    /// 跑诊断；返回的 Diagnosis 列表会追加到 PhaseRecord.diagnoses。
    @MainActor
    func diagnose(record: PhaseRecord, context: TestContext) async -> [Diagnosis]
}

public extension PhaseDiagnoser {
    var trigger: DiagnoserTrigger {
        .onlyOnFail
    }
}

/// 闭包形式的 PhaseDiagnoser（轻量定义临时诊断逻辑）
///
/// ```swift
/// Phase(
///     name: "VccCheck",
///     diagnosers: [
///         ClosureDiagnoser("vcc-overshoot") { record, ctx in
///             guard let v = record.measurements["vcc"]?.value.asDouble, v > 4.0 else { return [] }
///             ctx.attach("vcc-trace.log", data: ..., mimeType: "text/plain")
///             return [Diagnosis(code: "VCC_OVERSHOOT", message: "vcc=\(v) > 4V")]
///         }
///     ]
/// ) { ... }
/// ```
public struct ClosureDiagnoser: PhaseDiagnoser {
    public let label: String
    public let trigger: DiagnoserTrigger
    let block: @Sendable @MainActor (PhaseRecord, TestContext) async -> [Diagnosis]

    public init(
        _ label: String,
        trigger: DiagnoserTrigger = .onlyOnFail,
        _ block: @escaping @Sendable @MainActor (PhaseRecord, TestContext) async -> [Diagnosis]
    ) {
        self.label = label
        self.trigger = trigger
        self.block = block
    }

    @MainActor
    public func diagnose(record: PhaseRecord, context: TestContext) async -> [Diagnosis] {
        await block(record, context)
    }
}

// MARK: - 测试级诊断器

/// 测试级诊断器：测试收尾时（outcome 已定、tearDown 之前）调用一次，对整个 `TestRecord` 跑后处理。
///
/// 与 `PhaseDiagnoser` 的区别：
/// - PhaseDiagnoser 绑定到单个 phase 失败终态；TestDiagnoser 绑定到 plan 末尾，跑且仅跑一次
/// - TestDiagnoser 不限制触发条件——自己读 `record.outcome` 决定要不要 emit Diagnosis
/// - 只读语义：返回的 Diagnosis 列表追加到 `TestRecord.diagnoses`；不写副作用（无 ctx）
public protocol TestDiagnoser: Sendable {
    /// 用于调试 / 输出的简短标签
    var label: String { get }

    /// 触发时机；默认 `.onlyOnFail`（仅当 record.outcome 为失败族时跑）。
    var trigger: DiagnoserTrigger { get }

    /// 跑测试级诊断；返回的 Diagnosis 列表会追加到 `TestRecord.diagnoses`。
    func diagnose(record: TestRecord) async -> [Diagnosis]
}

public extension TestDiagnoser {
    /// 默认 `.always` —— 与旧实现一致（无条件跑，由闭包自己 guard）。
    var trigger: DiagnoserTrigger {
        .always
    }
}

extension TestOutcome {
    /// 失败族判定（聚合层 / 诊断器触发条件用）。
    var isFailing: Bool {
        switch self {
        case .fail, .error, .timeout, .aborted: true
        case .pass, .marginalPass: false
        }
    }
}

/// 闭包形式的 TestDiagnoser（轻量定义临时诊断逻辑）
///
/// ```swift
/// TestPlan(
///     name: "Smoke",
///     diagnosers: [
///         ClosureTestDiagnoser("multi-rail-degraded") { record in
///             let marginalCount = record.phases.filter { $0.outcome == .marginalPass }.count
///             guard marginalCount >= 3 else { return [] }
///             return [Diagnosis(
///                 code: "MULTI_RAIL_DEGRADED",
///                 severity: .warning,
///                 message: "\(marginalCount) phases hit marginal band"
///             )]
///         }
///     ]
/// ) { ... }
/// ```
public struct ClosureTestDiagnoser: TestDiagnoser {
    public let label: String
    public let trigger: DiagnoserTrigger
    let block: @Sendable (TestRecord) async -> [Diagnosis]

    public init(
        _ label: String,
        trigger: DiagnoserTrigger = .always,
        _ block: @escaping @Sendable (TestRecord) async -> [Diagnosis]
    ) {
        self.label = label
        self.trigger = trigger
        self.block = block
    }

    public func diagnose(record: TestRecord) async -> [Diagnosis] {
        await block(record)
    }
}
