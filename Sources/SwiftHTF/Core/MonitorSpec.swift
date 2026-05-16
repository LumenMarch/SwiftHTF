import Foundation

/// Monitor（周期性采样）规约。
///
/// 与 OpenHTF 的 `@monitor(...)` 装饰器对齐：在 Phase 执行期间，由框架以
/// 固定周期调用 `sampler`，将返回的 `Double` 连同自 Phase 开始算起的秒数
/// 追加到 `PhaseRecord.traces[name]`（dimensions = `[("t","s")]`，
/// value = `(name, unit)`）。
///
/// 数据落点复用 `SeriesMeasurement`：若用户在 `phase.series` 上声明同名
/// spec，则 `lengthAtLeast` / `each` 等校验器自动作用于 monitor 采样。
///
/// 建议通过 `Phase.monitor(...)` / `Phase.monitorBackground(...)` 链式 modifier
/// 构造，不直接调用本类型的 init。
public struct MonitorSpec: Sendable {
    /// 默认采样周期（秒）
    public static let defaultPeriod: TimeInterval = 1.0
    /// Phase 退出后等待飞行中采样收尾的默认时长（秒）
    public static let defaultDrainTimeout: TimeInterval = 0.1
    /// 默认连续采样错误阈值，达到后该 monitor 自行停止
    public static let defaultErrorThreshold: Int = 5

    public typealias MainActorSampler = @MainActor @Sendable (TestContext) async throws -> Double
    public typealias BackgroundSampler = @Sendable () async throws -> Double

    /// 采样闭包的隔离选择。
    public enum Sampler: Sendable {
        /// 在 MainActor 上执行；可读取 `TestContext` / `getPlug` 等。
        case mainActor(MainActorSampler)
        /// 在后台执行；不接 ctx，sampler 自行 await plug actor。
        /// 适合高频采样（例如 100ms 以下）避免阻塞 UI。
        case background(BackgroundSampler)
    }

    public let name: String
    public let unit: String?
    /// 相邻两次采样之间的等待时长（秒）。注意是采样间隔而非"严格周期"——
    /// 如果 sampler 本身耗时较长，相邻采样的绝对间隔会大于 `period`。
    public let period: TimeInterval
    /// Phase 退出（return / throw / cancel）时，每个 monitor 任务在收到
    /// cancel 信号后还能拿到的最大执行窗口。超时则丢弃飞行中的采样。
    public let drainTimeout: TimeInterval
    /// 连续累计抛出 N 次后停止该 monitor。停止只影响该 monitor 自身，
    /// 不影响 Phase outcome；其它 monitor 与 Phase 主体不受影响。
    public let errorThreshold: Int
    public let sampler: Sampler

    public init(
        name: String,
        unit: String? = nil,
        period: TimeInterval = MonitorSpec.defaultPeriod,
        drainTimeout: TimeInterval = MonitorSpec.defaultDrainTimeout,
        errorThreshold: Int = MonitorSpec.defaultErrorThreshold,
        sampler: Sampler
    ) {
        self.name = name
        self.unit = unit
        self.period = period
        self.drainTimeout = drainTimeout
        self.errorThreshold = errorThreshold
        self.sampler = sampler
    }

    /// `Duration` 版本初始化（macOS 13+）。语义更明确，例如 `.seconds(1)` /
    /// `.milliseconds(200)`；内部仍以 `TimeInterval` 存储，调度路径自动选择 Clock
    /// 或 fallback。
    @available(macOS 13, *)
    public init(
        name: String,
        unit: String? = nil,
        period: Duration,
        drainTimeout: Duration = .milliseconds(Int(MonitorSpec.defaultDrainTimeout * 1000)),
        errorThreshold: Int = MonitorSpec.defaultErrorThreshold,
        sampler: Sampler
    ) {
        self.init(
            name: name,
            unit: unit,
            period: period.asTimeInterval,
            drainTimeout: drainTimeout.asTimeInterval,
            errorThreshold: errorThreshold,
            sampler: sampler
        )
    }
}

@available(macOS 13, *)
extension Duration {
    /// `Duration` → 秒（TimeInterval）。`components.seconds` + 亚秒部分按 1e-18 归一化。
    var asTimeInterval: TimeInterval {
        let comps = components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1.0e18
    }
}
