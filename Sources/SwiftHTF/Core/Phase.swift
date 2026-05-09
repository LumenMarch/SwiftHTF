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

    /// 初始化
    /// - Parameters:
    ///   - definition: 阶段定义
    ///   - validators: 验证器列表
    ///   - lowerLimit: 下限
    ///   - upperLimit: 上限
    ///   - unit: 单位
    ///   - measurements: 声明式 measurement 规约
    public init(
        definition: PhaseDefinition,
        validators: [Validator] = [],
        lowerLimit: String? = nil,
        upperLimit: String? = nil,
        unit: String? = nil,
        measurements: [MeasurementSpec] = []
    ) {
        self.definition = definition
        self.validators = validators
        self.lowerLimit = lowerLimit
        self.upperLimit = upperLimit
        self.unit = unit
        self.measurements = measurements
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
    }
}
