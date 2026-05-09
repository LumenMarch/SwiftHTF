import Foundation

/// 工厂连续测试循环。
///
/// 模式：trigger 返回 SN（如扫码）→ 启动一次 session → session 完成 → onCompleted →
/// 回到 trigger 等下一个 SN → 直到 trigger 返回 nil 或外部 stop()。
///
/// 不做 CLI 实现；trigger 由调用方提供（SwiftUI ViewModel 等可基于
/// `CheckedContinuation` 把扫码事件转成 async 返回）。
///
/// ```swift
/// let loop = TestLoop(executor: executor) {
///     await viewModel.waitForBarcode()
/// } onCompleted: { record in
///     await store.save(record)
/// }
/// await loop.start()
/// // ...
/// await loop.stop()
/// ```
public actor TestLoop {
    /// 触发器：返回 SN 启动下一轮；返回 nil 退出循环
    public typealias TriggerFunction = @Sendable () async -> String?
    /// 每次 session 完成的回调（在内部 task 内）
    public typealias CompletedHandler = @Sendable (TestRecord) async -> Void

    /// loop 当前状态
    public enum State: Sendable, Equatable {
        case idle
        /// 在等 trigger 提供下一个 SN
        case awaitingTrigger
        /// 正在跑 session
        case running(serialNumber: String?)
        /// trigger 返回 nil 或被 stop()，已退出
        case stopped
    }

    private let executor: TestExecutor
    private let trigger: TriggerFunction
    private let onCompleted: CompletedHandler

    private var task: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<State>.Continuation] = [:]
    private var emittedStates: [State] = [.idle]
    private(set) public var currentState: State = .idle
    private(set) public var completedCount: Int = 0

    public init(
        executor: TestExecutor,
        trigger: @escaping TriggerFunction,
        onCompleted: @escaping CompletedHandler = { _ in }
    ) {
        self.executor = executor
        self.trigger = trigger
        self.onCompleted = onCompleted
    }

    /// 启动 loop。重复调用空操作。
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// 取消 loop（中断当前等待 trigger 或正在跑的 session）
    public func stop() async {
        task?.cancel()
        await executor.cancel()
    }

    /// 等待 loop 退出
    public func wait() async {
        await task?.value
    }

    /// 订阅状态流。新订阅会先收到至订阅时刻的全部状态历史，loop 结束后立即 finish。
    public func states() -> AsyncStream<State> {
        let id = UUID()
        var continuation: AsyncStream<State>.Continuation!
        let stream = AsyncStream<State> { c in continuation = c }
        for s in emittedStates { continuation.yield(s) }
        if currentState == .stopped {
            continuation.finish()
            return stream
        }
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.detach(id) }
        }
        return stream
    }

    // MARK: - 私有

    private func detach(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func setState(_ s: State) {
        currentState = s
        emittedStates.append(s)
        for c in continuations.values { c.yield(s) }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            setState(.awaitingTrigger)
            let sn = await trigger()
            if Task.isCancelled || sn == nil { break }
            setState(.running(serialNumber: sn))
            let session = await executor.startSession(serialNumber: sn)
            let record = await session.record()
            completedCount += 1
            await onCompleted(record)
        }
        setState(.stopped)
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }
}
