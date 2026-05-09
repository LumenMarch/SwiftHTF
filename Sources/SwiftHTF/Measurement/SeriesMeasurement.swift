import Foundation

/// 维度声明：name + 可选单位。
///
/// 在 `SeriesMeasurement` 中区分自变量（dimensions）与因变量（value）：
/// - dimensions：扫描坐标，如 ("V", unit: "V")、("temperature", unit: "°C")
/// - value：被测量，如 ("I", unit: "A")
public struct Dimension: Sendable, Codable, Equatable {
    public let name: String
    public let unit: String?

    public init(name: String, unit: String? = nil) {
        self.name = name
        self.unit = unit
    }
}

/// 多维（series / dimensioned）测量结果
///
/// 与 `Measurement` 并列存在 `PhaseRecord.traces` 中。每条 trace 描述一组采样：
/// 每个采样形如 `[dim_0, dim_1, ..., dim_n, value]`，按 spec 的 `dimensions` + `value`
/// 拼装。例如 IV 曲线 `dimensions: [("V","V")], value: ("I","A")`，每个采样
/// 是 `[v, i]` 两元数组。
///
/// 序列化使用 JSON 友好的弱类型 `[[AnyCodableValue]]`，与现有 `AnyCodableValue` 体系对齐。
public struct SeriesMeasurement: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let description: String?
    public let dimensions: [Dimension]
    public let value: Dimension
    public var samples: [[AnyCodableValue]]
    public var outcome: PhaseOutcomeType
    public var validatorMessages: [String]
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        dimensions: [Dimension],
        value: Dimension,
        samples: [[AnyCodableValue]] = [],
        outcome: PhaseOutcomeType = .pass,
        validatorMessages: [String] = [],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.dimensions = dimensions
        self.value = value
        self.samples = samples
        self.outcome = outcome
        self.validatorMessages = validatorMessages
        self.timestamp = timestamp
    }

    /// 维度顺序：先所有 dimensions，最后是 value。每个 sample 行长度应等于该数组长度。
    public var columnLayout: [Dimension] {
        dimensions + [value]
    }

    /// 采样数
    public var count: Int {
        samples.count
    }
}
