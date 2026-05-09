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

        // 顶层 setup（旧 API 兼容）
        var earlyExit = false
        if !plan.setupNodes.isEmpty {
            let outcome = await runNodes(
                plan.setupNodes,
                groupPath: [],
                continueOnFail: false,
                into: &record,
                context: context
            )
            if outcome.failed {
                record.outcome = .fail
                earlyExit = true
            }
            if outcome.aborted { record.outcome = .aborted; earlyExit = true }
        }

        if !earlyExit {
            let outcome = await runNodes(
                plan.nodes,
                groupPath: [],
                continueOnFail: plan.continueOnFail,
                into: &record,
                context: context
            )
            if outcome.failed { record.outcome = .fail }
            if outcome.aborted { record.outcome = .aborted }
        }

        // teardown 必跑
        if !plan.teardownNodes.isEmpty {
            _ = await runNodes(
                plan.teardownNodes,
                groupPath: [],
                continueOnFail: true,
                into: &record,
                context: context
            )
        }

        if Task.isCancelled && record.outcome != .fail {
            record.outcome = .aborted
        }

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

    private struct GroupOutcome {
        var failed: Bool = false
        var aborted: Bool = false
    }

    /// 顺序执行节点序列；遇 group 递归。
    private func runNodes(
        _ nodes: [PhaseNode],
        groupPath: [String],
        continueOnFail: Bool,
        into record: inout TestRecord,
        context: TestContext
    ) async -> GroupOutcome {
        var outcome = GroupOutcome()
        for node in nodes {
            if Task.isCancelled { outcome.aborted = true; return outcome }
            switch node {
            case .phase(let phase):
                // runIf 检查
                if let runIf = phase.runIf {
                    let proceed = await runIf(context)
                    if !proceed {
                        let skipRecord = makeSkipRecord(
                            name: phase.definition.name,
                            groupPath: groupPath,
                            reason: "runIf=false"
                        )
                        record.phases.append(skipRecord)
                        emit(.phaseCompleted(skipRecord))
                        continue
                    }
                }
                var phaseRecord = await runPhase(phase, context: context)
                phaseRecord.groupPath = groupPath
                record.phases.append(phaseRecord)
                emit(.phaseCompleted(phaseRecord))
                if phaseRecord.outcome == .fail || phaseRecord.outcome == .error {
                    outcome.failed = true
                    if !continueOnFail { return outcome }
                }
            case .group(let g):
                let nested = await runGroup(g, parentPath: groupPath, into: &record, context: context)
                if nested.failed {
                    outcome.failed = true
                    if !continueOnFail { return outcome }
                }
                if nested.aborted {
                    outcome.aborted = true
                    return outcome
                }
            }
        }
        return outcome
    }

    /// 执行单个 Group：先 runIf 门控，然后 setup → children（按 group.continueOnFail）→ teardown（必跑）
    private func runGroup(
        _ g: Group,
        parentPath: [String],
        into record: inout TestRecord,
        context: TestContext
    ) async -> GroupOutcome {
        // group runIf：false 时合成一条 skip 记录，跳整段
        if let runIf = g.runIf {
            let proceed = await runIf(context)
            if !proceed {
                let skipRecord = makeSkipRecord(name: g.name, groupPath: parentPath, reason: "runIf=false")
                record.phases.append(skipRecord)
                emit(.phaseCompleted(skipRecord))
                return GroupOutcome(failed: false, aborted: false)
            }
        }

        let path = parentPath + [g.name]
        var groupOutcome = GroupOutcome()

        let setupOut = await runNodes(
            g.setup, groupPath: path, continueOnFail: false,
            into: &record, context: context
        )
        if setupOut.aborted { return GroupOutcome(failed: false, aborted: true) }
        if setupOut.failed {
            groupOutcome.failed = true
            // 跳过 children，仍跑 teardown
            _ = await runNodes(
                g.teardown, groupPath: path, continueOnFail: true,
                into: &record, context: context
            )
            return groupOutcome
        }

        let childOut = await runNodes(
            g.children, groupPath: path, continueOnFail: g.continueOnFail,
            into: &record, context: context
        )
        if childOut.failed { groupOutcome.failed = true }
        if childOut.aborted { groupOutcome.aborted = true }

        _ = await runNodes(
            g.teardown, groupPath: path, continueOnFail: true,
            into: &record, context: context
        )

        return groupOutcome
    }

    /// 构造一条合成的 skip 记录（runIf 跳过场景）
    private func makeSkipRecord(name: String, groupPath: [String], reason: String) -> PhaseRecord {
        var r = PhaseRecord(name: name)
        r.groupPath = groupPath
        r.outcome = .skip
        r.errorMessage = reason
        r.endTime = r.startTime
        return r
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
    public let nodes: [PhaseNode]
    public let setupNodes: [PhaseNode]
    public let teardownNodes: [PhaseNode]
    public let continueOnFail: Bool

    /// 旧 API 投影：仅返回顶层 `.phase` 节点。含嵌套 Group 时对其内部不可见。
    public var phases: [Phase] { nodes.compactMap { $0.asPhase } }
    /// 旧 API 投影：仅返回顶层 setup 中的 `.phase` 节点；空时返回 nil（与旧语义一致）。
    public var setup: [Phase]? {
        let phases = setupNodes.compactMap { $0.asPhase }
        return phases.isEmpty ? nil : phases
    }
    public var teardown: [Phase]? {
        let phases = teardownNodes.compactMap { $0.asPhase }
        return phases.isEmpty ? nil : phases
    }

    /// 主初始化：直接用 PhaseNode 构造（含嵌套 Group）
    public init(
        name: String,
        nodes: [PhaseNode],
        setupNodes: [PhaseNode] = [],
        teardownNodes: [PhaseNode] = [],
        continueOnFail: Bool = false
    ) {
        self.name = name
        self.nodes = nodes
        self.setupNodes = setupNodes
        self.teardownNodes = teardownNodes
        self.continueOnFail = continueOnFail
    }

    /// 旧 init 兼容（接受 `[Phase]`，自动包装为 `.phase` 节点）
    public init(
        name: String,
        phases: [Phase],
        setup: [Phase]? = nil,
        teardown: [Phase]? = nil,
        continueOnFail: Bool = false
    ) {
        self.init(
            name: name,
            nodes: phases.map { .phase($0) },
            setupNodes: (setup ?? []).map { .phase($0) },
            teardownNodes: (teardown ?? []).map { .phase($0) },
            continueOnFail: continueOnFail
        )
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
