import Foundation

/// 测试上下文，传递给 Phase 函数
///
/// 持有当前测试运行所需的运行时数据：
/// - 序列号
/// - 测试值（字符串 K-V，向后兼容）
/// - 类型化测量（推荐 — 通过 `measure(...)`）
/// - 已解析的 Plug 实例
///
/// `measurements` 字典在 phase 完成时被收集到 `PhaseRecord.measurements`。
@MainActor
public final class TestContext {
    /// 当前测试的序列号
    public var serialNumber: String?

    /// 测试值存储（Phase 输出的字符串结果，与 `getValue/setValue` 配对，向后兼容）
    public private(set) var testValues: [String: String] = [:]

    /// 当前 phase 收集的类型化测量值（每次 phase 开始时由 PhaseExecutor 重置）
    public internal(set) var measurements: [String: Measurement] = [:]

    /// 当前 phase 收集的多维 measurement / trace（每次 phase 开始时由 PhaseExecutor 重置）
    public internal(set) var series: [String: SeriesMeasurement] = [:]

    /// 当前 phase 注入的 series spec 字典（PhaseExecutor 在 attempt 起始注入；
    /// `recordSeries` 默认从这里取维度/单位）
    internal var seriesSpecs: [String: SeriesMeasurementSpec] = [:]

    /// 当前 phase 收集的二进制附件（按写入顺序，每次 phase 开始时由 PhaseExecutor 重置）
    public internal(set) var attachments: [Attachment] = []

    /// 已解析的 Plug 实例字典（按类型名索引）
    private let resolvedPlugs: [String: any PlugProtocol]

    /// 测试配置（由 TestExecutor 注入）
    public let config: TestConfig

    init(
        serialNumber: String? = nil,
        resolvedPlugs: [String: any PlugProtocol],
        config: TestConfig = TestConfig()
    ) {
        self.serialNumber = serialNumber
        self.resolvedPlugs = resolvedPlugs
        self.config = config
    }

    // MARK: - 测试值（旧 API，仍可用）

    /// 设置测试值（用于参与限值校验的字符串结果）
    public func setValue(_ key: String, _ value: String) {
        testValues[key] = value
    }

    /// 获取测试值
    public func getValue(_ key: String) -> String? {
        testValues[key]
    }

    // MARK: - 类型化测量（推荐 API）

    /// 记录一个类型化测量值
    /// - Parameters:
    ///   - name: 测量名（在 phase 内唯一）
    ///   - value: 任意 `Encodable` 值（Bool/Int/Double/String/嵌套结构）
    ///   - unit: 单位（可选，例如 "V"、"mA"、"%"）
    public func measure<T: Encodable>(_ name: String, _ value: T, unit: String? = nil) {
        let coded = AnyCodableValue.from(value)
        measurements[name] = Measurement(
            name: name,
            value: coded,
            unit: unit
        )
    }

    /// 直接以 `AnyCodableValue` 形式写入（用于已经规范化的值）
    public func measure(_ name: String, codedValue: AnyCodableValue, unit: String? = nil) {
        measurements[name] = Measurement(
            name: name,
            value: codedValue,
            unit: unit
        )
    }

    // MARK: - 多维 measurement（trace）

    /// 记录一段多维测量（IV 曲线、扫频、扫温等）。在 block 内通过 `SeriesRecorder`
    /// 增量 append 采样行；block 返回后整段 trace 写入 `ctx.series[name]` 供 harvest 读取。
    ///
    /// 维度优先级：显式传入 > phase.series 中同名 spec > 默认 (`value` 列名占位)
    ///
    /// ```swift
    /// try await ctx.recordSeries("iv_curve") { recorder in
    ///     for v in stride(from: 0.0, through: 5.0, by: 0.1) {
    ///         let i = await dut.measureCurrent(at: v)
    ///         recorder.append(v, i)
    ///     }
    /// }
    /// ```
    public func recordSeries(
        _ name: String,
        dimensions: [Dimension]? = nil,
        value: Dimension? = nil,
        description: String? = nil,
        _ block: (SeriesRecorder) async throws -> Void
    ) async rethrows {
        let spec = seriesSpecs[name]
        let dims = dimensions ?? spec?.dimensions ?? []
        let val = value ?? spec?.value ?? Dimension(name: "value")
        let desc = description ?? spec?.description
        let recorder = SeriesRecorder(name: name, columnLayout: dims + [val])
        try await block(recorder)
        series[name] = SeriesMeasurement(
            name: name,
            description: desc,
            dimensions: dims,
            value: val,
            samples: recorder.samples
        )
    }

    // MARK: - 附件

    /// 写入一条二进制附件
    /// - Parameters:
    ///   - name: 名称（在 phase 内通常唯一，但允许重复）
    ///   - data: 二进制内容
    ///   - mimeType: MIME 类型（如 "image/png"、"text/plain"）
    public func attach(_ name: String, data: Data, mimeType: String) {
        attachments.append(Attachment(name: name, mimeType: mimeType, data: data))
    }

    /// 从文件读入并写入附件
    /// - Parameters:
    ///   - url: 源文件 URL
    ///   - name: 附件名（默认用文件名）
    ///   - mimeType: 显式 MIME；为 nil 时按扩展名推断
    public func attachFromFile(
        _ url: URL,
        name: String? = nil,
        mimeType: String? = nil
    ) throws {
        let data = try Data(contentsOf: url)
        let resolvedName = name ?? url.lastPathComponent
        let resolvedMime = mimeType ?? Attachment.mimeType(forPathExtension: url.pathExtension)
        attachments.append(Attachment(name: resolvedName, mimeType: resolvedMime, data: data))
    }

    // MARK: - Plug

    /// 获取已注册的 Plug 实例
    /// - Note: 必须在 TestExecutor 初始化后通过 `register(_:)` 或 `register(_:factory:)` 登记过
    public func getPlug<T: PlugProtocol>(_ type: T.Type) -> T {
        let key = String(describing: type)
        guard let plug = resolvedPlugs[key] as? T else {
            fatalError("Plug \(key) is not registered with the TestExecutor")
        }
        return plug
    }
}
