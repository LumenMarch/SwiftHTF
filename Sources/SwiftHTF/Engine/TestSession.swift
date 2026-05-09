import Foundation

/// 一次测试会话的运行体。一个 TestExecutor 可派生多个并发 TestSession（多 DUT）。
///
/// session 持有自己的 plug 实例（每 session 独立 setup / tearDown）、自己的事件流、
/// 自己的取消句柄。`record()` 等待 session 完成；`events()` 订阅细粒度事件。
public actor TestSession {
    public nonisolated let id: UUID = UUID()
    private let plan: TestPlan
    private let config: TestConfig
    private let plugManager: PlugManager
    private let outputCallbacks: [OutputCallback]
    private let initialSerialNumber: String?

    private var runner: Task<TestRecord, Never>?
    private var continuations: [UUID: AsyncStream<TestEvent>.Continuation] = [:]
    private var hasStarted: Bool = false
    /// 已发出的事件历史。新订阅会被补发；保证 startSession 内立刻 start session 后，
    /// 调用方再 events() 也能拿到 testStarted。
    private var emittedEvents: [TestEvent] = []
    private var streamFinished: Bool = false

    init(
        plan: TestPlan,
        config: TestConfig,
        plugManager: PlugManager,
        outputCallbacks: [OutputCallback],
        serialNumber: String?
    ) {
        self.plan = plan
        self.config = config
        self.plugManager = plugManager
        self.outputCallbacks = outputCallbacks
        self.initialSerialNumber = serialNumber
    }

    // MARK: - 公开 API

    /// 订阅事件流。
    ///
    /// 新订阅会先收到至订阅时刻为止已 emit 的全部事件（补发），保证
    /// 即便 startSession 内已立刻 start 了 session，调用方紧接着的
    /// events() 也不会丢失 `.testStarted`。已 finish 的 session 仍能
    /// 通过 events() 拿到完整历史，stream 立即结束。
    public func events() -> AsyncStream<TestEvent> {
        let id = UUID()
        var continuation: AsyncStream<TestEvent>.Continuation!
        let stream = AsyncStream<TestEvent> { c in continuation = c }
        // 先补发历史
        for e in emittedEvents { continuation.yield(e) }
        if streamFinished {
            continuation.finish()
            return stream
        }
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.detach(id)
            }
        }
        return stream
    }

    /// 启动 session（异步执行，立刻返回）
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        runner = Task<TestRecord, Never> { [weak self] in
            guard let self else {
                return TestRecord(planName: "", serialNumber: nil)
            }
            return await self.runInternal()
        }
    }

    /// 取消 session
    public func cancel() {
        runner?.cancel()
    }

    /// 等待最终 record
    public func record() async -> TestRecord {
        guard let runner else {
            // 未启动：返回空 record
            var r = TestRecord(planName: plan.name, serialNumber: initialSerialNumber)
            r.outcome = .error
            r.endTime = Date()
            return r
        }
        return await runner.value
    }

    private func detach(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emit(_ event: TestEvent) {
        emittedEvents.append(event)
        for c in continuations.values { c.yield(event) }
    }

    private func finishStreams() {
        streamFinished = true
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }

    // MARK: - 主流程

    private func runInternal() async -> TestRecord {
        var record = TestRecord(planName: plan.name, serialNumber: initialSerialNumber)
        emit(.testStarted(planName: plan.name, serialNumber: initialSerialNumber))

        let resolvedPlugs: [String: any PlugProtocol]
        do {
            resolvedPlugs = try await plugManager.setupAll()
        } catch {
            emit(.log("Plug setup failed: \(error.localizedDescription)"))
            record.outcome = .error
            record.endTime = Date()
            await notifyOutputs(record)
            emit(.testCompleted(record))
            finishStreams()
            return record
        }

        let cfg = config
        let serial = initialSerialNumber
        let context = await MainActor.run {
            TestContext(serialNumber: serial, resolvedPlugs: resolvedPlugs, config: cfg)
        }

        // 顶层 setup（plan.setupNodes）
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

        if !plan.teardownNodes.isEmpty {
            _ = await runNodes(
                plan.teardownNodes,
                groupPath: [],
                continueOnFail: true,
                into: &record,
                context: context
            )
        }

        if record.outcome == .pass
            && record.phases.contains(where: { $0.outcome == .marginalPass })
        {
            record.outcome = .marginalPass
        }

        if Task.isCancelled && record.outcome != .fail {
            record.outcome = .aborted
        }

        await plugManager.tearDownAll()
        await syncContextBack(into: &record, context: context)
        record.endTime = Date()
        await notifyOutputs(record)
        emit(.testCompleted(record))
        finishStreams()
        return record
    }

    private func syncContextBack(into record: inout TestRecord, context: TestContext) async {
        let sn = await MainActor.run { context.serialNumber }
        record.serialNumber = sn
    }

    private struct GroupOutcome {
        var failed: Bool = false
        var aborted: Bool = false
    }

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

    private func runGroup(
        _ g: Group,
        parentPath: [String],
        into record: inout TestRecord,
        context: TestContext
    ) async -> GroupOutcome {
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
