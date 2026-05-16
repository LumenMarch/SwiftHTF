import Foundation
import Yams

/// 测试配置
///
/// 加载源：JSON / YAML 文件 / 数据 / 字典字面值；环境变量；命令行参数。
/// 多源合并：`a.merging(b)` 让 `b` 覆盖 `a`，典型组合 defaults → file → env → CLI。
/// 内部统一为 `[String: AnyCodableValue]`，phase 内通过 `ctx.config` 访问。
///
/// ```swift
/// // 单源
/// let cfg = try TestConfig.load(from: url)   // 按扩展名自动识别 json/yaml/yml
///
/// // 多源合并（OpenHTF 风格优先级 CLI > env > file > defaults）
/// let defaults = TestConfig(values: ["vcc.lower": .double(3.0)])
/// let file = try TestConfig.load(from: url)
/// let env = TestConfig.from(environment: ProcessInfo.processInfo.environment, prefix: "SWIFTHTF_")
/// let cli = TestConfig.from(arguments: CommandLine.arguments)
/// let cfg = defaults.merging(file).merging(env).merging(cli)
///
/// // phase 内：
/// let lower = ctx.config.double("vcc.lower") ?? 3.0
/// ```
public struct TestConfig: Sendable {
    public private(set) var values: [String: AnyCodableValue]
    /// 可选的声明 schema（由 `TestExecutor(plan:config:configSchema:)` 注入）。
    /// 携带 schema 的 TestConfig 在 phase 内通过 ctx.config 读取时会按 strictness
    /// 触发未声明 key 的 warning / strict fatal。
    public internal(set) var schema: ConfigSchema?
    /// 未声明 key 读取时的回调（默认 nil；TestExecutor 启动时注入，输出到 stderr）。
    /// 闭包形式让用户在外部捕获（测试 / 自定义日志路由）。
    var undeclaredKeyHandler: (@Sendable (String) -> Void)?

    public init(values: [String: AnyCodableValue] = [:], schema: ConfigSchema? = nil) {
        self.values = values
        self.schema = schema
    }

    // MARK: - 文件 / 数据加载

    /// 文件格式
    public enum Format: Sendable {
        case json
        case yaml
    }

    /// 从文件加载（按扩展名自动识别 .json / .yaml / .yml；未知扩展名报错）
    public static func load(from url: URL) throws -> TestConfig {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let format: Format
        switch ext {
        case "json": format = .json
        case "yaml", "yml": format = .yaml
        default:
            throw TestConfigError.unknownFileExtension(ext)
        }
        return try load(from: data, format: format)
    }

    /// 从原始数据加载（显式 format）
    public static func load(from data: Data, format: Format) throws -> TestConfig {
        switch format {
        case .json:
            let decoder = JSONDecoder()
            let dict = try decoder.decode([String: AnyCodableValue].self, from: data)
            return TestConfig(values: dict)
        case .yaml:
            guard let yamlString = String(data: data, encoding: .utf8) else {
                throw TestConfigError.invalidYAMLEncoding
            }
            let raw = try Yams.load(yaml: yamlString)
            guard let dict = raw as? [String: Any] else {
                throw TestConfigError.yamlTopLevelNotObject
            }
            return TestConfig(values: dict.mapValues { AnyCodableValue.from(yamlValue: $0) })
        }
    }

    /// 兼容旧 API：等价于 `load(from: data, format: .json)`
    public static func load(from data: Data) throws -> TestConfig {
        try load(from: data, format: .json)
    }

    // MARK: - 取值

    public subscript(key: String) -> AnyCodableValue? {
        checkDeclared(key)
        return values[key]
    }

    /// 是否包含某 key。不触发 declared 检查（containment query 不算"使用"）。
    public func contains(_ key: String) -> Bool {
        values[key] != nil
    }

    /// 解码到任意 Decodable 类型（通过 JSON 中转）
    public func value<T: Decodable>(_ key: String, as _: T.Type) -> T? {
        checkDeclared(key)
        guard let raw = values[key] else { return nil }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(raw) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(T.self, from: data)
    }

    // MARK: - 便利访问器

    public func string(_ key: String) -> String? {
        checkDeclared(key)
        return values[key]?.asString
    }

    public func int(_ key: String) -> Int? {
        checkDeclared(key)
        return values[key]?.asInt
    }

    public func double(_ key: String) -> Double? {
        checkDeclared(key)
        return values[key]?.asDouble
    }

    public func bool(_ key: String) -> Bool? {
        checkDeclared(key)
        return values[key]?.asBool
    }

    /// 数组（每项尝试转 T；无法转的项以 nil 占位被过滤）
    public func array<T>(_ key: String, as transform: (AnyCodableValue) -> T?) -> [T]? {
        checkDeclared(key)
        guard case let .array(arr) = values[key] else { return nil }
        return arr.compactMap(transform)
    }

    // MARK: - 声明校验

    /// 任一访问器路径都会调用此函数，按 schema.strictness 决定行为：
    /// - 无 schema / `.lax`：静默放行
    /// - `.warn`：调 undeclaredKeyHandler（默认 stderr）；不影响返回值
    /// - `.strict`：fatalError（约束应被启动时一次性扫描提前发现，这里是兜底）
    private func checkDeclared(_ key: String) {
        guard let schema, !schema.isDeclared(key) else { return }
        switch schema.strictness {
        case .lax: break
        case .warn:
            undeclaredKeyHandler?(key)
        case .strict:
            fatalError("strict ConfigSchema: undeclared config key '\(key)'")
        }
    }

    // MARK: - 多源加载

    /// 从环境变量加载。
    /// - Parameters:
    ///   - environment: 环境字典；默认 `ProcessInfo.processInfo.environment`
    ///   - prefix: 取以此 prefix 起头的 key（不含 prefix 时不收）。例：`"SWIFTHTF_"`
    ///   - keyTransform: 把去掉 prefix 后的 env key 名转为 config key。
    ///     默认：小写 + `_` 替换为 `.`。例：`SWIFTHTF_VCC_LOWER` → `vcc.lower`
    /// - Returns: 新 TestConfig，值类型由字符串推断（bool / int / double / string）
    public static func from(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        prefix: String,
        keyTransform: (String) -> String = { $0.lowercased().replacingOccurrences(of: "_", with: ".") }
    ) -> TestConfig {
        var values: [String: AnyCodableValue] = [:]
        for (envKey, raw) in environment where envKey.hasPrefix(prefix) {
            let stripped = String(envKey.dropFirst(prefix.count))
            guard !stripped.isEmpty else { continue }
            let cfgKey = keyTransform(stripped)
            values[cfgKey] = AnyCodableValue.from(stringValue: raw)
        }
        return TestConfig(values: values)
    }

    /// 从命令行参数加载。支持两种形式：`--key value` 与 `--key=value`。
    /// 未识别的 token（首个程序名 / 非 `--` 开头 / 单独的值）会被忽略。
    /// 不引 `swift-argument-parser`；用户需要复杂 CLI 应自己解析后用字典初始化。
    /// - Parameter arguments: 默认 `CommandLine.arguments`
    public static func from(arguments: [String] = CommandLine.arguments) -> TestConfig {
        var values: [String: AnyCodableValue] = [:]
        var i = 1 // 跳过程序名
        while i < arguments.count {
            let token = arguments[i]
            guard token.hasPrefix("--") else { i += 1; continue }
            let body = String(token.dropFirst(2))
            if let eqIdx = body.firstIndex(of: "=") {
                let key = String(body[..<eqIdx])
                let val = String(body[body.index(after: eqIdx)...])
                if !key.isEmpty { values[key] = AnyCodableValue.from(stringValue: val) }
                i += 1
            } else {
                // --key value 形式：下一个 token 是值（必须不以 -- 开头才视为值）
                if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
                    values[body] = AnyCodableValue.from(stringValue: arguments[i + 1])
                    i += 2
                } else {
                    // 裸 flag：`--enable-x` → bool true
                    values[body] = .bool(true)
                    i += 1
                }
            }
        }
        return TestConfig(values: values)
    }

    /// 合并：返回新 TestConfig，`override` 中的 key 覆盖本实例同名 key。
    /// schema 与 undeclaredKeyHandler 保留本实例的（合并不携带 schema 元数据）；
    /// 典型链路：`defaults.merging(file).merging(env).merging(cli)`（后者优先级高）
    public func merging(_ override: TestConfig) -> TestConfig {
        var merged = values
        for (k, v) in override.values {
            merged[k] = v
        }
        var result = TestConfig(values: merged, schema: schema)
        result.undeclaredKeyHandler = undeclaredKeyHandler
        return result
    }

    /// 用同一份 values 复制一份并注入 schema + handler。executor 启动时使用。
    func attaching(
        schema: ConfigSchema,
        undeclaredKeyHandler: @Sendable @escaping (String) -> Void
    ) -> TestConfig {
        var result = TestConfig(values: values, schema: schema)
        result.undeclaredKeyHandler = undeclaredKeyHandler
        return result
    }
}

/// TestConfig 加载错误
public enum TestConfigError: LocalizedError {
    case unknownFileExtension(String)
    case invalidYAMLEncoding
    case yamlTopLevelNotObject

    public var errorDescription: String? {
        switch self {
        case let .unknownFileExtension(ext):
            "Unsupported config file extension '.\(ext)'; expect .json / .yaml / .yml"
        case .invalidYAMLEncoding:
            "Config YAML data is not valid UTF-8"
        case .yamlTopLevelNotObject:
            "Config YAML top-level must be a mapping (object)"
        }
    }
}
