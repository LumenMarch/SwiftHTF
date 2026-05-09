import Foundation

/// 测试配置
///
/// 加载顺序：JSON 文件 / 数据 / 字典字面值。内部统一为
/// `[String: AnyCodableValue]`，phase 内通过 `ctx.config` 访问。
///
/// ```swift
/// let cfg = try TestConfig.load(from: url)
/// let exec = TestExecutor(plan: plan, config: cfg)
///
/// // phase 内：
/// let lower = ctx.config.double("vcc.lower") ?? 3.0
/// ```
public struct TestConfig: Sendable {
    public private(set) var values: [String: AnyCodableValue]

    public init(values: [String: AnyCodableValue] = [:]) {
        self.values = values
    }

    /// 从 JSON 文件加载（顶层必须是对象）
    public static func load(from url: URL) throws -> TestConfig {
        let data = try Data(contentsOf: url)
        return try load(from: data)
    }

    /// 从 JSON 数据加载（顶层必须是对象）
    public static func load(from data: Data) throws -> TestConfig {
        let decoder = JSONDecoder()
        let dict = try decoder.decode([String: AnyCodableValue].self, from: data)
        return TestConfig(values: dict)
    }

    // MARK: - 取值

    public subscript(key: String) -> AnyCodableValue? {
        values[key]
    }

    /// 是否包含某 key
    public func contains(_ key: String) -> Bool {
        values[key] != nil
    }

    /// 解码到任意 Decodable 类型（通过 JSON 中转）
    public func value<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let raw = values[key] else { return nil }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(raw) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(T.self, from: data)
    }

    // MARK: - 便利访问器

    public func string(_ key: String) -> String? { values[key]?.asString }
    public func int(_ key: String) -> Int? { values[key]?.asInt }
    public func double(_ key: String) -> Double? { values[key]?.asDouble }
    public func bool(_ key: String) -> Bool? { values[key]?.asBool }

    /// 数组（每项尝试转 T；无法转的项以 nil 占位被过滤）
    public func array<T>(_ key: String, as transform: (AnyCodableValue) -> T?) -> [T]? {
        guard case .array(let arr) = values[key] else { return nil }
        return arr.compactMap(transform)
    }
}
