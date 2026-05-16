import Foundation

/// 配置项的语义类型标签。仅用于 schema 导出 / 表单生成 / type-hint，
/// 框架内部 **不** 做强制类型转换（值仍然以 `AnyCodableValue` 存储，读取时
/// 按 `string/int/double/bool` 等访问器各自尝试转换）。
public enum ConfigType: String, Sendable, Codable {
    case string
    case int
    case double
    case bool
    case object
    case array
}

/// 单个配置项声明（key + 元数据），与 OpenHTF `conf.declare(...)` 对齐。
///
/// - 不带 default 的 required 项：启动时若 config values 内缺失则 throw
/// - 带 default 的项：默认值在 `TestExecutor` 初始化时被 merge 进 config（最低优先级，
///   被用户传入的 config / 文件 / 环境 / CLI 都能覆盖）
/// - 未声明的 key：根据 `ConfigSchema.strictness` 决定 lax / warn / strict 行为
public struct ConfigDeclaration: Sendable, Codable, Equatable {
    public let name: String
    public let description: String?
    public let defaultValue: AnyCodableValue?
    public let isRequired: Bool
    public let type: ConfigType?

    public init(
        name: String,
        description: String? = nil,
        defaultValue: AnyCodableValue? = nil,
        isRequired: Bool = false,
        type: ConfigType? = nil
    ) {
        self.name = name
        self.description = description
        self.defaultValue = defaultValue
        self.isRequired = isRequired
        self.type = type
    }

    /// 便捷工厂：必填项（无默认值），缺失时启动 throw。
    public static func required(
        _ name: String,
        type: ConfigType? = nil,
        description: String? = nil
    ) -> ConfigDeclaration {
        ConfigDeclaration(
            name: name, description: description,
            defaultValue: nil, isRequired: true, type: type
        )
    }

    /// 便捷工厂：可选项（带默认值或全空）。
    public static func optional(
        _ name: String,
        default defaultValue: AnyCodableValue? = nil,
        type: ConfigType? = nil,
        description: String? = nil
    ) -> ConfigDeclaration {
        ConfigDeclaration(
            name: name, description: description,
            defaultValue: defaultValue, isRequired: false, type: type
        )
    }
}

/// 一组 `ConfigDeclaration` + 严格度策略。
///
/// 提供：
/// - `declaration(_:)`：按 key 查声明
/// - `defaultsConfig()`：所有带 default 的项构成的 base TestConfig（最低优先级）
/// - `requiredKeysMissing(in:)`：检查 required keys 在给定 config 中是否齐全
/// - `undeclaredKeys(in:)`：找出 config 中未声明的 keys
public struct ConfigSchema: Sendable {
    /// 未声明 key 的处理策略。
    public enum Strictness: String, Sendable, Codable {
        /// 静默放行。schema 仅用于 defaults + required 检查。
        case lax
        /// 写一条 warning（启动一次性扫描 + 每次 ctx.config 读时 emit）。默认。
        case warn
        /// 启动时未声明 keys 直接 throw；运行期读未声明 key 触发 fatalError。
        case strict
    }

    public let declarations: [ConfigDeclaration]
    public let strictness: Strictness
    private let byName: [String: ConfigDeclaration]

    public init(_ declarations: [ConfigDeclaration], strictness: Strictness = .warn) {
        self.declarations = declarations
        self.strictness = strictness
        byName = Dictionary(uniqueKeysWithValues: declarations.map { ($0.name, $0) })
    }

    /// 按 key 查声明；未声明则返回 nil。
    public func declaration(_ name: String) -> ConfigDeclaration? {
        byName[name]
    }

    /// 是否已声明该 key。
    public func isDeclared(_ name: String) -> Bool {
        byName[name] != nil
    }

    /// 把所有 `defaultValue` 不为 nil 的声明组装成一个 TestConfig，
    /// 用作多源合并的最低优先级 base。
    public func defaultsConfig() -> TestConfig {
        var values: [String: AnyCodableValue] = [:]
        for d in declarations {
            if let v = d.defaultValue { values[d.name] = v }
        }
        return TestConfig(values: values)
    }

    /// 检查 required 项是否在给定 config 中都有值。
    /// - Returns: 缺失的 required key 名数组（保持声明顺序）
    public func requiredKeysMissing(in config: TestConfig) -> [String] {
        declarations
            .filter { $0.isRequired && !config.contains($0.name) }
            .map(\.name)
    }

    /// 找出 config 中未声明的 keys（与 declared 不交集）。
    public func undeclaredKeys(in config: TestConfig) -> [String] {
        config.values.keys.filter { byName[$0] == nil }.sorted()
    }
}

/// `ConfigSchema` 校验 / 启动期错误。
public enum ConfigSchemaError: LocalizedError {
    /// 必填项缺失（startup-time 检查）。
    case requiredKeysMissing([String])
    /// strict 模式下 config 携带未声明的 keys（startup-time 检查）。
    case undeclaredKeysInStrictMode([String])

    public var errorDescription: String? {
        switch self {
        case let .requiredKeysMissing(keys):
            "Required config keys missing: \(keys.joined(separator: ", "))"
        case let .undeclaredKeysInStrictMode(keys):
            "Undeclared config keys in strict mode: \(keys.joined(separator: ", "))"
        }
    }
}

// MARK: - JSON Schema 导出

public extension ConfigSchema {
    /// 把声明导出为 JSON Schema Draft-07 文档（pretty + sortedKeys）。
    /// 用途：UI 自动生成配置表单、外部系统校验配置文件。
    func exportJSONSchema(title: String = "TestConfig") throws -> Data {
        let object = exportJSONSchemaObject(title: title)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(object)
    }

    /// 直接拿到 `AnyCodableValue` 树（便于嵌入其它 schema / 单元测试比较）。
    func exportJSONSchemaObject(title: String = "TestConfig") -> AnyCodableValue {
        var properties: [String: AnyCodableValue] = [:]
        var required: [AnyCodableValue] = []
        for d in declarations {
            var p: [String: AnyCodableValue] = [:]
            if let desc = d.description { p["description"] = .string(desc) }
            if let t = d.type { p["type"] = .string(t.jsonSchemaType) }
            if let v = d.defaultValue { p["default"] = v }
            properties[d.name] = .object(p)
            if d.isRequired { required.append(.string(d.name)) }
        }
        var schema: [String: AnyCodableValue] = [
            "$schema": .string("http://json-schema.org/draft-07/schema#"),
            "title": .string(title),
            "type": .string("object"),
            "properties": .object(properties),
            "x-swifthtf-strictness": .string(strictness.rawValue),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required)
        }
        return .object(schema)
    }
}

private extension ConfigType {
    /// 映射到 JSON Schema 的 type 关键字。
    var jsonSchemaType: String {
        switch self {
        case .string: "string"
        case .int: "integer"
        case .double: "number"
        case .bool: "boolean"
        case .object: "object"
        case .array: "array"
        }
    }
}
