import Combine
import Foundation
import SwiftHTF

/// 订阅 `TestSession` 的事件流，把每个 phase 的 `traces` 滚动归并到 `activeTraces` 供 SwiftUI 绘图。
///
/// 用法：
/// ```swift
/// @StateObject var live = LiveSeriesChartViewModel()
///
/// var body: some View {
///     VStack {
///         ForEach(live.activeTraces) { trace in
///             SeriesChart(trace: trace).frame(height: 160)
///         }
///     }
///     .task { await live.bind(to: session) }
/// }
/// ```
///
/// 行为：
/// - 相同 `(phaseName, traceName)` 复合 key 的多次写入按**最新**覆盖（traces 在 phase 完成时被发出一次完整快照，
///   因此覆盖语义足够；若同名 phase 多次跑则后者覆盖前者）
/// - testStarted 不重置 activeTraces（多次跑同 session 的 corner case 由调用方按需 `clear()`）
/// - bind(to:) 内部跑一个独立 Task 持续消费 events()，session.events() 自然结束就退出
///
/// 隔离：`@MainActor`，直接被 SwiftUI body 持有。
@MainActor
public final class LiveSeriesChartViewModel: ObservableObject {
    @Published public private(set) var activeTraces: [SeriesMeasurement] = []
    @Published public private(set) var planName: String?
    @Published public private(set) var outcome: TestOutcome?

    private var listener: Task<Void, Never>?
    private var index: [String: Int] = [:]

    public init() {}

    /// 绑定到某个 session。重复绑定会取消上一次的监听并清空状态。
    public func bind(to session: TestSession) async {
        listener?.cancel()
        clear()
        let stream = await session.events()
        listener = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                handle(event)
            }
        }
    }

    /// 停止监听并清空 trace 列表。
    public func clear() {
        listener?.cancel()
        listener = nil
        activeTraces = []
        index = [:]
        planName = nil
        outcome = nil
    }

    /// 直接吃一个事件（测试入口；运行时由 `bind(to:)` 内部调用）。
    public func handle(_ event: TestEvent) {
        switch event {
        case let .testStarted(name, _):
            planName = name
        case .serialNumberResolved:
            break
        case let .phaseCompleted(record):
            mergeTraces(from: record)
        case let .testCompleted(record):
            outcome = record.outcome
        case .log:
            break
        }
    }

    private func mergeTraces(from record: PhaseRecord) {
        for (name, trace) in record.traces {
            let key = "\(record.name)::\(name)"
            if let idx = index[key] {
                activeTraces[idx] = trace
            } else {
                index[key] = activeTraces.count
                activeTraces.append(trace)
            }
        }
    }
}
