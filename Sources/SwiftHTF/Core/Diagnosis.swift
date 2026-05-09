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

/// Phase 诊断器：phase 失败终态时调用。
///
/// 隔离：`@MainActor`。可读 ctx 已收集的状态（先前 phase 的写入），
/// 也可写 `ctx.attach(...)` / `ctx.measure(...)` 留下调试线索 —— 这些
/// 副作用会被合并进当前 phase 的 PhaseRecord（measurement 不再跑 spec
/// validation，attachments 直接追加）。
public protocol PhaseDiagnoser: Sendable {
    /// 用于调试 / 输出的简短标签
    var label: String { get }

    /// 跑诊断；返回的 Diagnosis 列表会追加到 PhaseRecord.diagnoses。
    @MainActor
    func diagnose(record: PhaseRecord, context: TestContext) async -> [Diagnosis]
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
    let block: @Sendable @MainActor (PhaseRecord, TestContext) async -> [Diagnosis]

    public init(
        _ label: String,
        _ block: @escaping @Sendable @MainActor (PhaseRecord, TestContext) async -> [Diagnosis]
    ) {
        self.label = label
        self.block = block
    }

    @MainActor
    public func diagnose(record: PhaseRecord, context: TestContext) async -> [Diagnosis] {
        await block(record, context)
    }
}
