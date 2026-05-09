import Foundation

// MARK: - 协议

/// 多维 measurement 的验证器。在 phase harvest 阶段对整组 samples 一次性运行。
public protocol SeriesValidator: Sendable {
    /// 校验整组 samples
    /// - Parameters:
    ///   - samples: 采样矩阵，每行长度应等于 `dimensions.count + 1`（最后一列是 value）
    ///   - dimensions: 自变量维度
    ///   - value: 因变量维度
    func validate(
        samples: [[AnyCodableValue]],
        dimensions: [Dimension],
        value: Dimension
    ) -> MeasurementValidationResult

    /// 用于诊断输出的简短标签
    var label: String { get }
}

// MARK: - 声明式 series 规约

/// 多维 measurement 规约。声明 trace 元数据 + validator 链。
///
/// ```swift
/// Phase(
///     name: "IV-sweep",
///     series: [
///         .named("iv_curve")
///             .dimension("V", unit: "V")
///             .value("I", unit: "A")
///             .lengthAtLeast(10)
///             .each { sample in
///                 let i = sample[1].asDouble ?? 0
///                 return i < 0.1 ? .pass : .fail("over current")
///             }
///     ]
/// ) { @MainActor ctx in
///     try await ctx.recordSeries("iv_curve") { recorder in
///         for v in stride(from: 0.0, through: 5.0, by: 0.1) {
///             let i = await dut.measureCurrent(at: v)
///             recorder.append(v, i)
///         }
///     }
///     return .continue
/// }
/// ```
public struct SeriesMeasurementSpec: Sendable {
    public let name: String
    public let description: String?
    public let dimensions: [Dimension]
    public let value: Dimension?
    public let validators: [any SeriesValidator]

    public init(
        name: String,
        description: String? = nil,
        dimensions: [Dimension] = [],
        value: Dimension? = nil,
        validators: [any SeriesValidator] = []
    ) {
        self.name = name
        self.description = description
        self.dimensions = dimensions
        self.value = value
        self.validators = validators
    }

    /// 工厂入口
    public static func named(
        _ name: String,
        description: String? = nil
    ) -> SeriesMeasurementSpec {
        SeriesMeasurementSpec(name: name, description: description)
    }

    /// 追加自变量维度
    public func dimension(_ name: String, unit: String? = nil) -> SeriesMeasurementSpec {
        SeriesMeasurementSpec(
            name: self.name,
            description: description,
            dimensions: dimensions + [Dimension(name: name, unit: unit)],
            value: value,
            validators: validators
        )
    }

    /// 设置因变量维度（可重复调用，后者覆盖前者）
    public func value(_ name: String, unit: String? = nil) -> SeriesMeasurementSpec {
        SeriesMeasurementSpec(
            name: self.name,
            description: description,
            dimensions: dimensions,
            value: Dimension(name: name, unit: unit),
            validators: validators
        )
    }

    /// 追加 validator
    public func with(_ validator: any SeriesValidator) -> SeriesMeasurementSpec {
        SeriesMeasurementSpec(
            name: name,
            description: description,
            dimensions: dimensions,
            value: value,
            validators: validators + [validator]
        )
    }

    /// 跑全部 validator 聚合三态判定
    func run(
        on samples: [[AnyCodableValue]]
    ) -> (verdict: MeasurementSpec.Verdict, messages: [String]) {
        var messages: [String] = []
        var failed = false
        var marginal = false
        let dims = dimensions
        let val = value ?? Dimension(name: "value")
        for v in validators {
            switch v.validate(samples: samples, dimensions: dims, value: val) {
            case .pass: break
            case .marginal(let msg):
                marginal = true
                messages.append(msg)
            case .fail(let msg):
                failed = true
                messages.append(msg)
            }
        }
        if failed { return (.fail, messages) }
        if marginal { return (.marginal, messages) }
        return (.pass, messages)
    }
}

// MARK: - 链式 builder（内置 validator）

public extension SeriesMeasurementSpec {
    /// 至少 N 个采样
    func lengthAtLeast(_ n: Int) -> SeriesMeasurementSpec {
        with(SeriesLengthValidator(lower: n, upper: nil))
    }

    /// 采样数在 [lower, upper]
    func lengthInRange(_ lower: Int, _ upper: Int) -> SeriesMeasurementSpec {
        with(SeriesLengthValidator(lower: lower, upper: upper))
    }

    /// 对每个采样跑闭包；任一 .fail → fail，任一 .marginal → marginal，否则 pass
    func each(
        label: String = "each",
        _ block: @escaping @Sendable ([AnyCodableValue]) -> MeasurementValidationResult
    ) -> SeriesMeasurementSpec {
        with(PerSampleValidator(label: label, block: block))
    }

    /// 自定义全量校验
    func custom(
        label: String,
        _ block: @escaping @Sendable (
            [[AnyCodableValue]],
            [Dimension],
            Dimension
        ) -> MeasurementValidationResult
    ) -> SeriesMeasurementSpec {
        with(CustomSeriesValidator(label: label, block: block))
    }
}

// MARK: - 内置 validator 实现

/// 采样数范围
public struct SeriesLengthValidator: SeriesValidator {
    public let lower: Int?
    public let upper: Int?

    public init(lower: Int?, upper: Int?) {
        self.lower = lower
        self.upper = upper
    }

    public func validate(
        samples: [[AnyCodableValue]],
        dimensions: [Dimension],
        value: Dimension
    ) -> MeasurementValidationResult {
        let n = samples.count
        if let lower, n < lower {
            return .fail("\(label): 采样数 \(n) < \(lower)")
        }
        if let upper, n > upper {
            return .fail("\(label): 采样数 \(n) > \(upper)")
        }
        return .pass
    }

    public var label: String {
        switch (lower, upper) {
        case (.some(let lo), .some(let hi)): return "length[\(lo), \(hi)]"
        case (.some(let lo), nil): return "length>=\(lo)"
        case (nil, .some(let hi)): return "length<=\(hi)"
        case (nil, nil): return "length"
        }
    }
}

/// 对每个 sample 行执行闭包，聚合三态结果
public struct PerSampleValidator: SeriesValidator {
    public let label: String
    let block: @Sendable ([AnyCodableValue]) -> MeasurementValidationResult

    public init(
        label: String,
        block: @escaping @Sendable ([AnyCodableValue]) -> MeasurementValidationResult
    ) {
        self.label = label
        self.block = block
    }

    public func validate(
        samples: [[AnyCodableValue]],
        dimensions: [Dimension],
        value: Dimension
    ) -> MeasurementValidationResult {
        var failedMsgs: [String] = []
        var marginalMsgs: [String] = []
        for (idx, row) in samples.enumerated() {
            switch block(row) {
            case .pass: continue
            case .marginal(let msg):
                marginalMsgs.append("[#\(idx)] \(msg)")
            case .fail(let msg):
                failedMsgs.append("[#\(idx)] \(msg)")
            }
        }
        if !failedMsgs.isEmpty {
            return .fail("\(label): " + failedMsgs.joined(separator: "; "))
        }
        if !marginalMsgs.isEmpty {
            return .marginal("\(label): " + marginalMsgs.joined(separator: "; "))
        }
        return .pass
    }
}

/// 自定义全量 validator
public struct CustomSeriesValidator: SeriesValidator {
    public let label: String
    let block: @Sendable ([[AnyCodableValue]], [Dimension], Dimension) -> MeasurementValidationResult

    public init(
        label: String,
        block: @escaping @Sendable (
            [[AnyCodableValue]],
            [Dimension],
            Dimension
        ) -> MeasurementValidationResult
    ) {
        self.label = label
        self.block = block
    }

    public func validate(
        samples: [[AnyCodableValue]],
        dimensions: [Dimension],
        value: Dimension
    ) -> MeasurementValidationResult {
        block(samples, dimensions, value)
    }
}
