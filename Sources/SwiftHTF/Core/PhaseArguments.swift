import Foundation

/// `phase.withArgs(...)` 注入的运行时参数视图（值类型，只读）。
///
/// 与 `TestConfig` / `PhaseState` 的读 API 镜像（`string` / `int` / `double` /
/// `bool` / `value(_:as:)`），便于在 phase 闭包内统一切换数据来源：
///
/// ```swift
/// Phase(name: "VccCheck") { @MainActor ctx in
///     let v = ctx.args.double("voltage") ?? 3.3
///     let ch = ctx.args.int("channel") ?? 0
///     await ctx.getPlug(PSU.self).setOutput(v, channel: ch)
///     return .continue
/// }
/// ```
///
/// 写入由 `Phase.withArgs(...)` 在 plan 构造时完成，本视图不提供 setter。
public struct PhaseArguments: Sendable {
    public let values: [String: AnyCodableValue]

    public init(_ values: [String: AnyCodableValue] = [:]) {
        self.values = values
    }

    public var isEmpty: Bool {
        values.isEmpty
    }

    public var keys: [String] {
        Array(values.keys)
    }

    public func contains(_ key: String) -> Bool {
        values[key] != nil
    }

    public subscript(key: String) -> AnyCodableValue? {
        values[key]
    }

    public func string(_ key: String) -> String? {
        values[key]?.asString
    }

    public func int(_ key: String) -> Int? {
        values[key]?.asInt
    }

    public func double(_ key: String) -> Double? {
        values[key]?.asDouble
    }

    public func bool(_ key: String) -> Bool? {
        values[key]?.asBool
    }

    /// 解码到任意 Decodable 类型（通过 JSON 中转）
    public func value<T: Decodable>(_ key: String, as _: T.Type) -> T? {
        guard let raw = values[key] else { return nil }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(raw) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
