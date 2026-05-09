import Foundation
import Combine
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

    public init(executor: TestExecutor, logCapacity: Int = 500) {
        self.executor = executor
        self.logCapacity = logCapacity
    }

    /// 启动测试。当前正在跑则忽略。订阅会在 execute 之前完成，不丢事件。
    public func start(serialNumber: String? = nil) {
        guard !isRunning else { return }
        reset()
        isRunning = true
        let exec = executor

        runner = Task { @MainActor [weak self] in
            // 先订阅，再 execute —— 同一个 task 里串行 await 保证顺序
            let stream = await exec.events()

            let listener = Task { @MainActor [weak self] in
                for await event in stream {
                    guard let self else { return }
                    switch event {
                    case .testStarted(let name, let sn):
                        self.planName = name
                        self.serialNumber = sn
                    case .phaseCompleted(let r):
                        self.phases.append(r)
                    case .log(let msg):
                        self.appendLog(msg)
                    case .testCompleted(let r):
                        self.outcome = r.outcome
                        self.record = r
                        self.serialNumber = r.serialNumber
                    }
                }
            }

            _ = await exec.execute(serialNumber: serialNumber)
            // 给 listener 一点时间消费 testCompleted
            try? await Task.sleep(nanoseconds: 50_000_000)
            listener.cancel()
            self?.isRunning = false
            self?.runner = nil
        }
    }

    /// 取消正在执行的测试。
    public func cancel() {
        let exec = executor
        Task { await exec.cancel() }
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
