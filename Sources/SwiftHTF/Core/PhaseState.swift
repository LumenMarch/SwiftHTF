import Foundation

/// session 级共享状态字典。phase 间传中间值用——`TestConfig` 是只读配置，
/// `PhaseState` 是 phase 读写的可变态（一个 session 一份，phase 改写后续 phase 看得到）。
///
/// 隔离：`@MainActor`，与 phase 闭包一致；引用语义（class），ctx 上字段为 `let` 即可。
/// 持久化：**不进** `TestRecord`——想入 record 用 `ctx.measure(...)` 走 measurement 走 spec
/// validation，或用 `ctx.metadata`（如果有）。这里只承担"phase 间运行时传值"职责。
///
/// API 与 `TestConfig` 镜像（`string` / `int` / `double` / `bool` / `value(_:as:)`），便于切换。
///
/// ```swift
/// Phase(name: "ReadFW") { ctx in
///     let fw = await dut.readFirmwareVersion()
///     ctx.state.set("dut.fw_version", fw)
///     ctx.state.set("dut.boot_ms", 1234)
///     return .continue
/// }
/// Phase(name: "Calibrate", runIf: { ctx in
///     // runIf 也能读
///     ctx.state.string("dut.fw_version") == "1.2.3"
/// }) { ctx in
///     let bootMs = ctx.state.int("dut.boot_ms") ?? 0
///     ctx.logInfo("boot took \(bootMs) ms")
///     return .continue
/// }
/// ```
@MainActor
public final class PhaseState {
    public private(set) var values: [String: AnyCodableValue] = [:]

    public init() {}

    // MARK: - 基础读写

    public subscript(key: String) -> AnyCodableValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// 是否包含某 key
    public func contains(_ key: String) -> Bool {
        values[key] != nil
    }

    /// 移除某 key
    public func remove(_ key: String) {
        values.removeValue(forKey: key)
    }

    /// 清空全部
    public func clear() {
        values.removeAll()
    }

    /// 当前 key 集合（无序）
    public var keys: [String] {
        Array(values.keys)
    }

    // MARK: - 写入

    /// 写入一个 Encodable 值（规范化为 AnyCodableValue）
    public func set(_ key: String, _ value: some Encodable) {
        values[key] = AnyCodableValue.from(value)
    }

    /// 直接以 AnyCodableValue 形式写入（用于已规范化的值）
    public func set(_ key: String, codedValue: AnyCodableValue) {
        values[key] = codedValue
    }

    // MARK: - 类型化读取（与 TestConfig 镜像）

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
        let decoder = JSONDecoder()
        return try? decoder.decode(T.self, from: data)
    }
}
