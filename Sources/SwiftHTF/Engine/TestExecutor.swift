import Foundation

/// 测试执行事件
public enum TestEvent: Sendable {
    case testStarted(planName: String, serialNumber: String?)
    case phaseCompleted(PhaseRecord)
    case log(String)
    case testCompleted(TestRecord)
}

/// 测试执行器
///
/// actor 模型保证内部状态串行访问。事件通过 `events()` 返回的 `AsyncStream` 推送，
/// 取代原 onLog/onPhaseComplete 闭包参数。
public actor TestExecutor {
    private let plan: TestPlan
    private let plugManager: PlugManager
    private let outputCallbacks: [OutputCallback]
    private let config: TestConfig

    public private(set) var isRunning: Bool = false
    private var currentTask: Task<TestRecord, Never>?
    private var continuations: [UUID: AsyncStream<TestEvent>.Continuation] = [:]

    /// 初始化
    /// - Parameters:
    ///   - plan: 测试计划
    ///   - config: 测试配置（phase 内通过 ctx.config 访问）
    ///   - outputCallbacks: 输出回调
    public init(
        plan: TestPlan,
        config: TestConfig = TestConfig(),
        outputCallbacks: [OutputCallback] = []
    ) {
        self.plan = plan
        self.config = config
        self.plugManager = PlugManager()
        self.outputCallbacks = outputCallbacks
    }

    /// 注册 Plug 类型（无参 init）
    public func register<T: PlugProtocol>(_ type: T.Type) async {
        await plugManager.register(type)
    }

    /// 注册 Plug 类型（工厂闭包，用于需要构造器参数的场景）
    public func register<T: PlugProtocol>(
        _ type: T.Type,
        factory: @escaping @MainActor @Sendable () -> T
    ) async {
        await plugManager.register(type, factory: factory)
    }

    /// 订阅事件流
    ///
    /// 调用方应在 Task 中迭代 stream。订阅可以在 `execute()` 之前或之后建立；
    /// 订阅终止（终止 task / break out of for-await）会自动从执行器移除。
    ///
    /// 由 actor 隔离 — 返回前 attach 已完成，调用方紧接着的 `execute()` 不会丢事件。
    public func events() -> AsyncStream<TestEvent> {
        let id = UUID()
        var continuation: AsyncStream<TestEvent>.Continuation!
        let stream = AsyncStream<TestEvent> { c in
            continuation = c
        }
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.detach(id) }
        }
        return stream
    }

    private func detach(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emit(_ event: TestEvent) {
        for c in continuations.values { c.yield(event) }
    }

    /// 执行测试
    public func execute(serialNumber: String? = nil) async -> TestRecord {
        guard !isRunning else {
            var record = TestRecord(planName: plan.name, serialNumber: serialNumber)
            record.outcome = .error
            record.endTime = Date()
            return record
        }

        let task = Task<TestRecord, Never> {
            await self.runInternal(serialNumber: serialNumber)
        }
        currentTask = task
        isRunning = true

        let record = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        isRunning = false
        currentTask = nil
        return record
    }

    /// 取消测试 — 通过 Task.cancel() 让结构化并发传播到内部 await 点
    public func cancel() {
        currentTask?.cancel()
    }

    private func runInternal(serialNumber: String?) async -> TestRecord {
        var record = TestRecord(planName: plan.name, serialNumber: serialNumber)
        emit(.testStarted(planName: plan.name, serialNumber: serialNumber))

        let resolvedPlugs: [String: any PlugProtocol]
        do {
            resolvedPlugs = try await plugManager.setupAll()
        } catch {
            emit(.log("Plug setup failed: \(error.localizedDescription)"))
            record.outcome = .error
            record.endTime = Date()
            await notifyOutputs(record)
            emit(.testCompleted(record))
            return record
        }

        let cfg = config
        let context = await MainActor.run {
            TestContext(serialNumber: serialNumber, resolvedPlugs: resolvedPlugs, config: cfg)
        }

        // setup phases
        if let setupPhases = plan.setup {
            for phase in setupPhases {
                if Task.isCancelled { break }
                let phaseRecord = await runPhase(phase, context: context)
                record.phases.append(phaseRecord)
                emit(.phaseCompleted(phaseRecord))
                if phaseRecord.outcome == .fail || phaseRecord.outcome == .error {
                    record.outcome = .fail
                    await runTeardown(record: &record, context: context)
                    await plugManager.tearDownAll()
                    await syncContextBack(into: &record, context: context)
                    record.endTime = Date()
                    await notifyOutputs(record)
                    emit(.testCompleted(record))
                    return record
                }
            }
        }

        // 主 phases
        for phase in plan.phases {
            if Task.isCancelled { break }
            let phaseRecord = await runPhase(phase, context: context)
            record.phases.append(phaseRecord)
            emit(.phaseCompleted(phaseRecord))
            if phaseRecord.outcome == .fail || phaseRecord.outcome == .error {
                record.outcome = .fail
                if !plan.continueOnFail { break }
            }
        }

        if Task.isCancelled {
            record.outcome = .aborted
        }

        await runTeardown(record: &record, context: context)
        await plugManager.tearDownAll()
        await syncContextBack(into: &record, context: context)
        record.endTime = Date()
        await notifyOutputs(record)
        emit(.testCompleted(record))
        return record
    }

    /// 把 phase 期间在 ctx 上发生的可变状态（如 ctx.serialNumber = 扫码值）回灌到 record。
    private func syncContextBack(into record: inout TestRecord, context: TestContext) async {
        let sn = await MainActor.run { context.serialNumber }
        record.serialNumber = sn
    }

    private func runTeardown(record: inout TestRecord, context: TestContext) async {
        guard let teardownPhases = plan.teardown else { return }
        for phase in teardownPhases {
            let phaseRecord = await runPhase(phase, context: context)
            record.phases.append(phaseRecord)
            emit(.phaseCompleted(phaseRecord))
        }
    }

    private nonisolated func runPhase(_ phase: Phase, context: TestContext) async -> PhaseRecord {
        let logEmitter: PhaseExecutor.LogEmitter = { [weak self] msg in
            guard let self else { return }
            Task { await self.emit(.log(msg)) }
        }
        let executor = await MainActor.run {
            PhaseExecutor(context: context, emitLog: logEmitter)
        }
        return await executor.execute(phase: phase)
    }

    private func notifyOutputs(_ record: TestRecord) async {
        for callback in outputCallbacks {
            await callback.save(record: record)
        }
    }
}

/// 测试计划
public struct TestPlan: Sendable {
    public let name: String
    public let phases: [Phase]
    public let setup: [Phase]?
    public let teardown: [Phase]?
    public let continueOnFail: Bool

    public init(
        name: String,
        phases: [Phase],
        setup: [Phase]? = nil,
        teardown: [Phase]? = nil,
        continueOnFail: Bool = false
    ) {
        self.name = name
        self.phases = phases
        self.setup = setup
        self.teardown = teardown
        self.continueOnFail = continueOnFail
    }
}

/// 测试错误
public enum TestError: LocalizedError {
    case timeout(String)
    case noRespond(String)
    case unknown(String)
    case validationFailed(String)
    case maxRetriesExceeded

    public var errorDescription: String? {
        switch self {
        case .timeout(let s): return s
        case .noRespond(let s): return s
        case .unknown(let s): return s
        case .validationFailed(let s): return s
        case .maxRetriesExceeded: return "Max retries exceeded"
        }
    }
}
