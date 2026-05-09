import Foundation

// MARK: - 协议

/// 作用在 `AnyCodableValue` 上的 measurement 验证器。
///
/// 与旧的字符串 `Validator` 协议并存：旧协议仍服务 `phase.value`（来自 `ctx.setValue`）；
/// 本协议服务 `ctx.measure(...)` 写入的类型化测量值。
public protocol MeasurementValidator: Sendable {
    /// 校验单个值
    func validate(_ value: AnyCodableValue) -> MeasurementValidationResult

    /// 用于诊断输出的简短标签（如 "in_range[3.0, 3.6]"）
    var label: String { get }
}

/// Measurement 校验结果
public enum MeasurementValidationResult: Sendable, Equatable {
    case pass
    case fail(String)
}

// MARK: - 声明式 measurement 规约

/// 测量规约：声明一条 measurement 的元数据 + validator 链
///
/// ```swift
/// Phase(
///     name: "VccCheck",
///     measurements: [
///         .named("vcc", unit: "V").inRange(3.0, 3.6)
///     ]
/// ) { @MainActor ctx in
///     ctx.measure("vcc", 3.32, unit: "V")
///     return .continue
/// }
/// ```
public struct MeasurementSpec: Sendable {
    public let name: String
    public let unit: String?
    public let description: String?
    public let validators: [any MeasurementValidator]

    public init(
        name: String,
        unit: String? = nil,
        description: String? = nil,
        validators: [any MeasurementValidator] = []
    ) {
        self.name = name
        self.unit = unit
        self.description = description
        self.validators = validators
    }

    /// 工厂入口
    public static func named(
        _ name: String,
        unit: String? = nil,
        description: String? = nil
    ) -> MeasurementSpec {
        MeasurementSpec(name: name, unit: unit, description: description)
    }

    /// 追加任意 validator，返回新 spec（值语义）
    public func with(_ validator: any MeasurementValidator) -> MeasurementSpec {
        MeasurementSpec(
            name: name,
            unit: unit,
            description: description,
            validators: validators + [validator]
        )
    }

    /// 跑全部 validator，返回 (pass?, messages)
    func run(on value: AnyCodableValue) -> (passed: Bool, messages: [String]) {
        var messages: [String] = []
        var ok = true
        for v in validators {
            if case .fail(let msg) = v.validate(value) {
                ok = false
                messages.append(msg)
            }
        }
        return (ok, messages)
    }
}

// MARK: - 链式 builder（内置 validator）

public extension MeasurementSpec {
    /// 数值落在 [lower, upper]（默认闭区间）
    func inRange(_ lower: Double, _ upper: Double, inclusive: Bool = true) -> MeasurementSpec {
        with(InRangeValidator(lower: lower, upper: upper, inclusive: inclusive))
    }

    /// 仅下限
    func atLeast(_ lower: Double, inclusive: Bool = true) -> MeasurementSpec {
        with(InRangeValidator(lower: lower, upper: nil, inclusive: inclusive))
    }

    /// 仅上限
    func atMost(_ upper: Double, inclusive: Bool = true) -> MeasurementSpec {
        with(InRangeValidator(lower: nil, upper: upper, inclusive: inclusive))
    }

    /// 等于某 Encodable 值
    func equals<T: Encodable>(_ expected: T) -> MeasurementSpec {
        with(EqualsValueValidator(expected: AnyCodableValue.from(expected)))
    }

    /// 字符串值匹配正则
    func matchesRegex(_ pattern: String) -> MeasurementSpec {
        with(RegexMeasurementValidator(pattern: pattern))
    }

    /// 数值在 target 的 ±percent% 范围内
    func withinPercent(of target: Double, percent: Double) -> MeasurementSpec {
        with(WithinPercentValidator(target: target, percent: percent))
    }

    /// 字符串 / 数组 / 对象非空（忽略前后空白）
    func notEmpty() -> MeasurementSpec {
        with(NotEmptyMeasurementValidator())
    }

    /// 自定义闭包
    func custom(
        label: String,
        _ block: @escaping @Sendable (AnyCodableValue) -> MeasurementValidationResult
    ) -> MeasurementSpec {
        with(CustomMeasurementValidator(label: label, block: block))
    }
}

// MARK: - 内置 validator 实现

/// 数值范围（lower / upper 任选；inclusive 控端点是否包含）
public struct InRangeValidator: MeasurementValidator {
    public let lower: Double?
    public let upper: Double?
    public let inclusive: Bool

    public init(lower: Double?, upper: Double?, inclusive: Bool = true) {
        self.lower = lower
        self.upper = upper
        self.inclusive = inclusive
    }

    public func validate(_ value: AnyCodableValue) -> MeasurementValidationResult {
        guard let n = value.asDouble else {
            return .fail("\(label): 值非数字 (\(value.displayString))")
        }
        if let lower {
            let ok = inclusive ? n >= lower : n > lower
            if !ok { return .fail("\(label): \(n) < \(lower)") }
        }
        if let upper {
            let ok = inclusive ? n <= upper : n < upper
            if !ok { return .fail("\(label): \(n) > \(upper)") }
        }
        return .pass
    }

    public var label: String {
        let lo = lower.map { String($0) } ?? "-∞"
        let hi = upper.map { String($0) } ?? "+∞"
        return inclusive ? "in_range[\(lo), \(hi)]" : "in_range(\(lo), \(hi))"
    }
}

/// 值相等（按 AnyCodableValue.Equatable）
public struct EqualsValueValidator: MeasurementValidator {
    public let expected: AnyCodableValue

    public init(expected: AnyCodableValue) {
        self.expected = expected
    }

    public func validate(_ value: AnyCodableValue) -> MeasurementValidationResult {
        if value == expected { return .pass }
        return .fail("\(label): 实际 \(value.displayString)")
    }

    public var label: String { "equals(\(expected.displayString))" }
}

/// 正则匹配（仅作用在 string 值）
public struct RegexMeasurementValidator: MeasurementValidator {
    public let pattern: String

    public init(pattern: String) {
        self.pattern = pattern
    }

    public func validate(_ value: AnyCodableValue) -> MeasurementValidationResult {
        guard let s = value.asString else {
            return .fail("\(label): 非字符串值")
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return .fail("\(label): 无效正则")
        }
        let range = NSRange(s.startIndex..., in: s)
        if regex.firstMatch(in: s, range: range) != nil {
            return .pass
        }
        return .fail("\(label): \"\(s)\" 不匹配")
    }

    public var label: String { "regex(\(pattern))" }
}

/// 数值在 target 的 ±percent% 容差内（percent 用百分号原值，例如 5 表示 ±5%）
public struct WithinPercentValidator: MeasurementValidator {
    public let target: Double
    public let percent: Double

    public init(target: Double, percent: Double) {
        self.target = target
        self.percent = percent
    }

    public func validate(_ value: AnyCodableValue) -> MeasurementValidationResult {
        guard let n = value.asDouble else {
            return .fail("\(label): 非数字")
        }
        let tolerance = abs(target) * (percent / 100.0)
        if abs(n - target) <= tolerance { return .pass }
        return .fail("\(label): 实际 \(n) 偏离 \(target) 超过 ±\(percent)%")
    }

    public var label: String { "within_percent(\(target), ±\(percent)%)" }
}

/// 非空：string trim 非空 / array 非空 / object 非空 / null 视为空
public struct NotEmptyMeasurementValidator: MeasurementValidator {
    public init() {}

    public func validate(_ value: AnyCodableValue) -> MeasurementValidationResult {
        switch value {
        case .null:
            return .fail("\(label): null")
        case .string(let s):
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .fail("\(label): 空字符串")
            }
            return .pass
        case .array(let a):
            return a.isEmpty ? .fail("\(label): 空数组") : .pass
        case .object(let o):
            return o.isEmpty ? .fail("\(label): 空对象") : .pass
        case .bool, .int, .double:
            return .pass
        }
    }

    public var label: String { "not_empty" }
}

/// 自定义闭包
public struct CustomMeasurementValidator: MeasurementValidator {
    public let label: String
    let block: @Sendable (AnyCodableValue) -> MeasurementValidationResult

    public init(
        label: String,
        block: @escaping @Sendable (AnyCodableValue) -> MeasurementValidationResult
    ) {
        self.label = label
        self.block = block
    }

    public func validate(_ value: AnyCodableValue) -> MeasurementValidationResult {
        block(value)
    }
}
