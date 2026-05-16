import Foundation

/// 测试阶段定义
public struct PhaseDefinition: Identifiable, Sendable {
    public let id: UUID = .init()
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
    public let id: UUID = .init()
    public let definition: PhaseDefinition
    /// 声明式 measurement 规约。仅对通过 `ctx.measure(name, ...)` 写入的同名测量生效。
    public let measurements: [MeasurementSpec]
    /// 声明式多维 measurement（series / trace）规约。仅对通过
    /// `ctx.recordSeries(name) { ... }` 写入的同名 trace 生效。
    public let series: [SeriesMeasurementSpec]
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
    /// 周期采样 monitor 列表。声明式 / 链式装饰，由 `PhaseExecutor` 在每次 attempt
    /// 起始挂起独立 Task，Phase 主体退出后等 drainTimeout 后停止；采样数据写入
    /// `ctx.series[name]`（dimensions = `[("t","s")]`）。
    public var monitors: [MonitorSpec]
    /// `Phase.withArgs(...)` 注入的运行时参数快照。
    /// PhaseExecutor 在 attempt 起始把它写到 `ctx.arguments`；phase 内 `ctx.args` 读取；
    /// harvest 时回写到 `PhaseRecord.arguments` 持久化。
    public var arguments: [String: AnyCodableValue]
    /// `Phase.withPlug(_:replacedWith:)` 注入的 plug 重定向表，key/value 均为
    /// `String(describing: Type)`。仅在本 phase 生命周期内生效，不改 PlugManager 注册表。
    public var plugOverrides: [String: String]

    /// 初始化
    public init(
        definition: PhaseDefinition,
        measurements: [MeasurementSpec] = [],
        series: [SeriesMeasurementSpec] = [],
        runIf: RunIfPredicate? = nil,
        repeatOnMeasurementFail: Int = 0,
        diagnosers: [any PhaseDiagnoser] = [],
        failureExceptions: [any Error.Type] = [],
        monitors: [MonitorSpec] = [],
        arguments: [String: AnyCodableValue] = [:],
        plugOverrides: [String: String] = [:]
    ) {
        self.definition = definition
        self.measurements = measurements
        self.series = series
        self.runIf = runIf
        self.repeatOnMeasurementFail = repeatOnMeasurementFail
        self.diagnosers = diagnosers
        self.failureExceptions = failureExceptions
        self.monitors = monitors
        self.arguments = arguments
        self.plugOverrides = plugOverrides
    }

    /// 便捷初始化
    public init(
        name: String,
        timeout: TimeInterval? = nil,
        retryCount: Int = 0,
        measurements: [MeasurementSpec] = [],
        series: [SeriesMeasurementSpec] = [],
        runIf: RunIfPredicate? = nil,
        repeatOnMeasurementFail: Int = 0,
        diagnosers: [any PhaseDiagnoser] = [],
        failureExceptions: [any Error.Type] = [],
        monitors: [MonitorSpec] = [],
        arguments: [String: AnyCodableValue] = [:],
        plugOverrides: [String: String] = [:],
        execute: @escaping @Sendable @MainActor (TestContext) async throws -> PhaseResult
    ) {
        definition = PhaseDefinition(
            name: name,
            timeout: timeout,
            retryCount: retryCount,
            execute: execute
        )
        self.measurements = measurements
        self.series = series
        self.runIf = runIf
        self.repeatOnMeasurementFail = repeatOnMeasurementFail
        self.diagnosers = diagnosers
        self.failureExceptions = failureExceptions
        self.monitors = monitors
        self.arguments = arguments
        self.plugOverrides = plugOverrides
    }
}

// MARK: - 链式参数化装饰（withArgs / withPlug）

extension Phase {
    /// 注入 / 合并运行时参数，返回新 Phase。
    ///
    /// 同一 base Phase 多次 `withArgs` 累积合并（后者覆盖前者）。最终参数在 phase
    /// 内通过 `ctx.args.string(...) / .double(...) / .value(_:as:)` 读取，并随 record
    /// 持久化到 `PhaseRecord.arguments`。
    ///
    /// 命名策略：
    /// - 提供 `nameSuffix` → 直接拼到原 name 后
    /// - 未提供 → 按合并后 args 自动生成 `[k1=v1,k2=v2]`（按 key 字典序）
    ///
    /// 自动 suffix 仅适合"少量标量参数"——大对象 / 数组会被压成 JSON 字串，可读性较差，
    /// 此时建议显式传 `nameSuffix`。
    public func withArgs(
        _ extraArgs: [String: AnyCodableValue],
        nameSuffix: String? = nil
    ) -> Phase {
        let merged = arguments.merging(extraArgs) { _, new in new }
        let suffix = nameSuffix ?? Self.autoNameSuffix(for: extraArgs)
        let newDef = PhaseDefinition(
            name: definition.name + suffix,
            timeout: definition.timeout,
            retryCount: definition.retryCount,
            execute: definition.execute
        )
        return Phase(
            definition: newDef,
            measurements: measurements,
            series: series,
            runIf: runIf,
            repeatOnMeasurementFail: repeatOnMeasurementFail,
            diagnosers: diagnosers,
            failureExceptions: failureExceptions,
            monitors: monitors,
            arguments: merged,
            plugOverrides: plugOverrides
        )
    }

    /// 声明本 phase 内 `ctx.getPlug(Real.self)` 实际取 `Mock` 类型的实例。
    ///
    /// 与 session 级 `executor.swap(...)` 的区别：本 modifier 只作用于本 phase
    /// 生命周期，PlugManager 注册表不变；典型用于"同一 plan 中部分 phase 用真硬件、
    /// 部分用 mock"的混合场景。
    ///
    /// 限制：`Mock` 必须已经在 PlugManager 注册（否则运行时 fatal）；`Real` 与
    /// `Mock` 需共享一致的访问 API（例如继承同一基类 / 实现同一 protocol），
    /// `ctx.getPlug(Real.self)` 的强制类型转换才能成功。
    public func withPlug(
        _ real: (some PlugProtocol).Type,
        replacedWith mock: (some PlugProtocol).Type
    ) -> Phase {
        var copy = self
        copy.plugOverrides[String(describing: real)] = String(describing: mock)
        return copy
    }

    private static func autoNameSuffix(for args: [String: AnyCodableValue]) -> String {
        guard !args.isEmpty else { return "" }
        let parts = args.keys.sorted().map { k -> String in
            let v = args[k] ?? .null
            return "\(k)=\(shortDescription(v))"
        }
        return "[" + parts.joined(separator: ",") + "]"
    }

    private static func shortDescription(_ v: AnyCodableValue) -> String {
        switch v {
        case .null: return "null"
        case let .bool(b): return String(b)
        case let .int(i): return String(i)
        case let .double(d): return String(d)
        case let .string(s): return s
        case .array, .object:
            let data = (try? JSONEncoder().encode(v)) ?? Data()
            return String(data: data, encoding: .utf8) ?? "?"
        }
    }
}

// MARK: - 链式 monitor 装饰

public extension Phase {
    /// 装饰一个 MainActor 采样的 monitor，复用已有的 ctx / plug。
    ///
    /// 与 OpenHTF `@monitor('name', sample_fn)` 装饰器对齐。100ms 以下的高频
    /// 采样建议改用 `monitorBackground(...)` 避免阻塞 UI。
    ///
    /// ```swift
    /// Phase(name: "Soak") { @MainActor ctx in
    ///     try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
    ///     return .continue
    /// }
    /// .monitor("temp_C", unit: "°C", every: 1.0) { @MainActor ctx in
    ///     await ctx.getPlug(Thermo.self).read()
    /// }
    /// ```
    func monitor(
        _ name: String,
        unit: String? = nil,
        every period: TimeInterval = MonitorSpec.defaultPeriod,
        drainTimeout: TimeInterval = MonitorSpec.defaultDrainTimeout,
        errorThreshold: Int = MonitorSpec.defaultErrorThreshold,
        _ sample: @escaping @MainActor @Sendable (TestContext) async throws -> Double
    ) -> Phase {
        appendingMonitor(MonitorSpec(
            name: name,
            unit: unit,
            period: period,
            drainTimeout: drainTimeout,
            errorThreshold: errorThreshold,
            sampler: .mainActor(sample)
        ))
    }

    /// 装饰一个后台采样的 monitor。sampler 不接 ctx，需自行 await plug actor。
    /// 适合高频采样（avoid MainActor hop）或纯感知共享单例。
    func monitorBackground(
        _ name: String,
        unit: String? = nil,
        every period: TimeInterval = MonitorSpec.defaultPeriod,
        drainTimeout: TimeInterval = MonitorSpec.defaultDrainTimeout,
        errorThreshold: Int = MonitorSpec.defaultErrorThreshold,
        _ sample: @escaping @Sendable () async throws -> Double
    ) -> Phase {
        appendingMonitor(MonitorSpec(
            name: name,
            unit: unit,
            period: period,
            drainTimeout: drainTimeout,
            errorThreshold: errorThreshold,
            sampler: .background(sample)
        ))
    }

    private func appendingMonitor(_ spec: MonitorSpec) -> Phase {
        var copy = self
        copy.monitors.append(spec)
        return copy
    }
}

// MARK: - Duration 风格 monitor modifier（macOS 13+）

@available(macOS 13, *)
public extension Phase {
    /// `Duration` 版本的 `monitor(...)`：`.seconds(1) / .milliseconds(200)` 风格。
    /// macOS 13+ 可见；内部转 `TimeInterval` 存储，调度自动走 SuspendingClock 路径。
    func monitor(
        _ name: String,
        unit: String? = nil,
        every period: Duration,
        drainTimeout: Duration = .milliseconds(Int(MonitorSpec.defaultDrainTimeout * 1000)),
        errorThreshold: Int = MonitorSpec.defaultErrorThreshold,
        _ sample: @escaping @MainActor @Sendable (TestContext) async throws -> Double
    ) -> Phase {
        monitor(
            name,
            unit: unit,
            every: period.asTimeInterval,
            drainTimeout: drainTimeout.asTimeInterval,
            errorThreshold: errorThreshold,
            sample
        )
    }

    /// `Duration` 版本的 `monitorBackground(...)`。
    func monitorBackground(
        _ name: String,
        unit: String? = nil,
        every period: Duration,
        drainTimeout: Duration = .milliseconds(Int(MonitorSpec.defaultDrainTimeout * 1000)),
        errorThreshold: Int = MonitorSpec.defaultErrorThreshold,
        _ sample: @escaping @Sendable () async throws -> Double
    ) -> Phase {
        monitorBackground(
            name,
            unit: unit,
            every: period.asTimeInterval,
            drainTimeout: drainTimeout.asTimeInterval,
            errorThreshold: errorThreshold,
            sample
        )
    }
}
