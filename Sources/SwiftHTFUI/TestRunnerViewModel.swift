import Combine
import Foundation
import SwiftHTF

/// 把 `TestExecutor.events()` 的 `AsyncStream` 转成 SwiftUI 友好的 `@Published` 状态。
///
/// 用法：
/// ```swift
/// @StateObject private var vm = TestRunnerViewModel(executor: executor)
///
/// var body: some View {
///     VStack {
///         Button("Run") { vm.start(serialNumber: nil) }
///             .disabled(vm.isRunning)
///         List(vm.phases) { ... }
///     }
/// }
/// ```
@MainActor
public final class TestRunnerViewModel: ObservableObject {
    @Published public private(set) var phases: [PhaseRecord] = []
    @Published public private(set) var logLines: [String] = []
    @Published public private(set) var outcome: TestOutcome?
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var record: TestRecord?
    @Published public private(set) var planName: String?
    @Published public private(set) var serialNumber: String?

    public let logCapacity: Int
    private let executor: TestExecutor
    private var runner: Task<Void, Never>?
    private var currentSession: TestSession?

    public init(executor: TestExecutor, logCapacity: Int = 500) {
        self.executor = executor
        self.logCapacity = logCapacity
    }

    /// 启动测试。当前正在跑则忽略。订阅 session.events() 而非 executor 聚合流，
    /// 避免多 session 模式下事件混流。
    public func start(serialNumber: String? = nil) {
        guard !isRunning else { return }
        reset()
        isRunning = true
        let exec = executor

        runner = Task { @MainActor [weak self] in
            let session = await exec.startSession(serialNumber: serialNumber)
            self?.currentSession = session
            let stream = await session.events()

            let listener = Task { @MainActor [weak self] in
                for await event in stream {
                    guard let self else { return }
                    switch event {
                    case let .testStarted(name, sn):
                        planName = name
                        self.serialNumber = sn
                    case let .serialNumberResolved(sn):
                        // startup 完成后 UI 立刻刷新标题里的 SN（不必等整测试完成）
                        self.serialNumber = sn
                    case let .phaseCompleted(r):
                        phases.append(r)
                    case let .log(msg):
                        appendLog(msg)
                    case let .testCompleted(r):
                        outcome = r.outcome
                        record = r
                        self.serialNumber = r.serialNumber
                        return
                    }
                }
            }

            _ = await session.record()
            _ = await listener.value
            self?.isRunning = false
            self?.runner = nil
            self?.currentSession = nil
        }
    }

    /// 取消正在执行的测试（仅取消本 ViewModel 持有的 session）。
    public func cancel() {
        guard let session = currentSession else { return }
        Task { await session.cancel() }
    }

    /// 清空状态（保留 logCapacity / executor 引用）。
    public func reset() {
        phases = []
        logLines = []
        outcome = nil
        record = nil
        planName = nil
        serialNumber = nil
    }

    private func appendLog(_ s: String) {
        logLines.append(s)
        if logLines.count > logCapacity {
            logLines.removeFirst(logLines.count - logCapacity)
        }
    }
}
