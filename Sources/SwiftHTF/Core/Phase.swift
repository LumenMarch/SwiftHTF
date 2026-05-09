import Foundation

/// 测试阶段定义
public struct PhaseDefinition: Identifiable, Sendable {
    public let id: UUID = UUID()
    public let name: String
    public let timeout: TimeInterval?
    public let retryCount: Int
    public let execute: @Sendable @MainActor (TestContext) async throws -> PhaseResult
    
    /// 初始化
    /// - Parameters:
    ///   - name: 阶段名称
    ///   - timeout: 超时时间（秒）
    ///   - retryCount: 重试次数
    ///   - execute: 执行闭包
    public init(
        name: String,
        timeout: TimeInterval? = nil,
        retryCount: Int = 0,
        execute: @escaping @Sendable @MainActor (TestContext) async throws -> PhaseResult
    ) {
        self.name = name
        self.timeout = timeout
        self.retryCount = retryCount
        self.execute = execute
    }
}

/// 运行时条件门：phase / group 在执行前查询。返回 false 时整节点 outcome 标 .skip
/// 且不计入失败。
public typealias RunIfPredicate = @Sendable @MainActor (TestContext) async -> Bool

/// 测试阶段（带验证规则）
public struct Phase: Identifiable, Sendable {
    public let id: UUID = UUID()
    public let definition: PhaseDefinition
    public let validators: [Validator]
    public let lowerLimit: String?
    public let upperLimit: String?
    public let unit: String?
    /// 声明式 measurement 规约。仅对通过 `ctx.measure(name, ...)` 写入的同名测量生效，
    /// 不影响旧的 `phase.value` 字符串验证路径（仍由 `lowerLimit/upperLimit` + `validators` 控制）。
    public let measurements: [MeasurementSpec]
    /// 运行时条件门：返回 false 跳过此 phase（outcome=.skip，不计 fail）
    public let runIf: RunIfPredicate?
    /// 当 phase 闭包返回 `.continue` 但有 measurement 验证失败时，最多再尝试几次。
    /// 与 `retryCount`（处理异常 / 显式 `.retry`）独立计数，互不消耗。
    public let repeatOnMeasurementFail: Int
    /// 失败时跑的诊断器（仅 phase 终态 outcome=.fail/.error 时触发）
    public let diagnosers: [any PhaseDiagnoser]
    /// 异常类型白名单：phase 闭包抛出此处列出的精确类型时，outcome 标 .fail（业务失败），
    /// 否则维持 .error（程序错误）。retry 行为不受影响 —— throw 仍触发 retryCount 重试。
    public let failureExceptions: [any Error.Type]

    /// 初始化
    public init(
        definition: PhaseDefinition,
        validators: [Validator] = [],
        lowerLimit: String? = nil,
        upperLimit: String? = nil,
        unit: String? = nil,
        measurements: [MeasurementSpec] = [],
        runIf: RunIfPredicate? = nil,
        repeatOnMeasurementFail: Int = 0,
        diagnosers: [any PhaseDiagnoser] = [],
        failureExceptions: [any Error.Type] = []
    ) {
        self.definition = definition
        self.validators = validators
        self.lowerLimit = lowerLimit
        self.upperLimit = upperLimit
        self.unit = unit
        self.measurements = measurements
        self.runIf = runIf
        self.repeatOnMeasurementFail = repeatOnMeasurementFail
        self.diagnosers = diagnosers
        self.failureExceptions = failureExceptions
    }

    /// 便捷初始化
    public init(
        name: String,
        timeout: TimeInterval? = nil,
        retryCount: Int = 0,
        lowerLimit: String? = nil,
        upperLimit: String? = nil,
        unit: String? = nil,
        measurements: [MeasurementSpec] = [],
        runIf: RunIfPredicate? = nil,
        repeatOnMeasurementFail: Int = 0,
        diagnosers: [any PhaseDiagnoser] = [],
        failureExceptions: [any Error.Type] = [],
        execute: @escaping @Sendable @MainActor (TestContext) async throws -> PhaseResult
    ) {
        self.definition = PhaseDefinition(
            name: name,
            timeout: timeout,
            retryCount: retryCount,
            execute: execute
        )
        self.validators = []
        self.lowerLimit = lowerLimit
        self.upperLimit = upperLimit
        self.unit = unit
        self.measurements = measurements
        self.runIf = runIf
        self.repeatOnMeasurementFail = repeatOnMeasurementFail
        self.diagnosers = diagnosers
        self.failureExceptions = failureExceptions
    }
}
