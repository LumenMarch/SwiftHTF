import Foundation

/// 一次测试会话的运行体。一个 TestExecutor 可派生多个并发 TestSession（多 DUT）。
///
/// session 持有自己的 plug 实例（每 session 独立 setup / tearDown）、自己的事件流、
/// 自己的取消句柄。`record()` 等待 session 完成；`events()` 订阅细粒度事件。
public actor TestSession {
    public nonisolated let id: UUID = .init()
    /// startup phase 在 `PhaseRecord.groupPath` 里使用的固定前缀；消费者可据此区分启动门控阶段
    /// 与业务 phase（业务 phase 顶层 groupPath 为空数组 / 含业务 Group 名）。
    public nonisolated static let startupGroupPath: [String] = ["__startup__"]
    // 以下 5 个原是 private，因 `TestSessionStages` 在独立文件 extension 中复用而放宽到 internal。
    // module 内可访问，对包外仍不可见，与 private actor state 的隔离安全等价。
    let plan: TestPlan
    let config: TestConfig
    let plugManager: PlugManager
    private let outputCallbacks: [OutputCallback]
    private let initialSerialNumber: String?
    private let metadata: SessionMetadata

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
        serialNumber: String?,
        metadata: SessionMetadata = SessionMetadata()
    ) {
        self.plan = plan
        self.config = config
        self.plugManager = plugManager
        self.outputCallbacks = outputCallbacks
        initialSerialNumber = serialNumber
        self.metadata = metadata
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
        for e in emittedEvents {
            continuation.yield(e)
        }
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
            return await runInternal()
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

    func emit(_ event: TestEvent) {
        emittedEvents.append(event)
        for c in continuations.values {
            c.yield(event)
        }
    }

    func finishStreams() {
        streamFinished = true
        for c in continuations.values {
            c.finish()
        }
        continuations.removeAll()
    }

    // MARK: - 主流程

    private func runInternal() async -> TestRecord {
        var record = TestRecord(planName: plan.name, serialNumber: initialSerialNumber)
        record.stationInfo = metadata.stationInfo
        record.dutInfo = metadata.dutInfo
        record.codeInfo = metadata.codeInfo
        record.operatorName = metadata.operatorName
        emit(.testStarted(planName: plan.name, serialNumber: initialSerialNumber))

        if let earlyRecord = await runStartupValidation(record: &record) {
            return earlyRecord
        }

        guard let resolvedPlugs = await setupPlugs(record: &record) else {
            return record
        }

        let cfg = config
        let serial = initialSerialNumber
        let context = await MainActor.run {
            TestContext(serialNumber: serial, resolvedPlugs: resolvedPlugs, config: cfg)
        }

        let startupExited = await runStartupPhase(into: &record, context: context)
        var setupExited = false
        if !startupExited {
            setupExited = await runSetupNodes(into: &record, context: context)
        }
        if !startupExited, !setupExited {
            await runMainNodes(into: &record, context: context)
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

        finalizeOutcome(into: &record)
        await runTestDiagnosers(into: &record)

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

    struct GroupOutcome {
        var failed: Bool = false
        var aborted: Bool = false
        /// phase 闭包返回 `.stop` 或检测到致命错误，要求向外冒泡终止整测试。
        /// 与 `aborted`（Task 取消 / unrecoverable）区分，避免 Subtest 隔离失败时误判为取消。
        var stopped: Bool = false
        /// 至少一个子节点的 phase 终态为 `.timeout`。冒泡到 record 收尾决定是否
        /// 标 `TestOutcome.timeout`（仅当 record 因 timeout 失败而非 fail/error 时）。
        var timedOut: Bool = false
    }

    func runNodes(
        _ nodes: [PhaseNode],
        groupPath: [String],
        continueOnFail: Bool,
        into record: inout TestRecord,
        context: TestContext
    ) async -> GroupOutcome {
        var outcome = GroupOutcome()
        for node in nodes {
            if Task.isCancelled { outcome.aborted = true; return outcome }
            let shouldTerminate: Bool
            switch node {
            case let .phase(phase):
                let step = await runPhaseAsChild(
                    phase: phase, groupPath: groupPath, into: &record, context: context
                )
                shouldTerminate = applyPhaseStep(step, continueOnFail: continueOnFail, into: &outcome)
            case let .group(g):
                let nested = await runGroup(g, parentPath: groupPath, into: &record, context: context)
                shouldTerminate = mergeNestedOutcome(nested, into: &outcome, continueOnFail: continueOnFail)
            case let .subtest(s):
                let nested = await runSubtest(s, parentPath: groupPath, into: &record, context: context)
                shouldTerminate = mergeSubtestOutcome(nested, into: &outcome)
            case let .checkpoint(cp):
                // 检查本作用域内是否已 outcome.failed（嵌套 group 失败算，嵌套 subtest 失败被隔离不算）
                let didFail = outcome.failed
                let cpRecord = makeCheckpointRecord(cp, groupPath: groupPath, didFail: didFail)
                record.phases.append(cpRecord)
                emit(.phaseCompleted(cpRecord))
                shouldTerminate = didFail
            case let .dynamic(d):
                let generated = await generateDynamic(d, groupPath: groupPath, into: &record, context: context)
                if generated.isEmpty {
                    shouldTerminate = false
                } else {
                    let nested = await runNodes(
                        generated, groupPath: groupPath, continueOnFail: continueOnFail,
                        into: &record, context: context
                    )
                    shouldTerminate = mergeNestedOutcome(nested, into: &outcome, continueOnFail: continueOnFail)
                }
            }
            if shouldTerminate { return outcome }
        }
        return outcome
    }

    /// 一次 phase 子节点的执行摘要：用于让外层 runNodes 决定是否短路。
    fileprivate struct PhaseStep {
        var failed: Bool = false
        var stopped: Bool = false
        /// phase 终态是否为 `.timeout`。冒泡到 record 聚合层决定 TestOutcome 细分。
        var timedOut: Bool = false
    }

    /// 在 runNodes 内跑一个 phase（不修改 outcome 本身，只返回摘要供 caller 决策）。
    private func runPhaseAsChild(
        phase: Phase,
        groupPath: [String],
        into record: inout TestRecord,
        context: TestContext
    ) async -> PhaseStep {
        if let runIf = phase.runIf, await runIf(context) == false {
            let skipRecord = makeSkipRecord(
                name: phase.definition.name, groupPath: groupPath, reason: "runIf=false"
            )
            record.phases.append(skipRecord)
            emit(.phaseCompleted(skipRecord))
            return PhaseStep()
        }
        var phaseRecord = await runPhase(phase, context: context)
        phaseRecord.groupPath = groupPath
        record.phases.append(phaseRecord)
        emit(.phaseCompleted(phaseRecord))
        if phaseRecord.stopRequested {
            // .stop 优先冒泡，不被 continueOnFail 吞，也让 subtest 隔离不影响传播
            return PhaseStep(failed: false, stopped: true, timedOut: false)
        }
        return PhaseStep(
            failed: phaseRecord.isFailing,
            stopped: false,
            timedOut: phaseRecord.outcome == .timeout
        )
    }

    /// 把 PhaseStep 合并进 GroupOutcome；返回是否立即终止 caller 的循环。
    private func applyPhaseStep(
        _ step: PhaseStep,
        continueOnFail: Bool,
        into outcome: inout GroupOutcome
    ) -> Bool {
        if step.stopped { outcome.stopped = true; return true }
        if step.timedOut { outcome.timedOut = true }
        if step.failed {
            outcome.failed = true
            return !continueOnFail
        }
        return false
    }

    /// 合并嵌套 Group 的结果到外层 outcome。
    /// - Returns: true 表示需要立即终止外层节点序列。
    private func mergeNestedOutcome(
        _ nested: GroupOutcome,
        into outcome: inout GroupOutcome,
        continueOnFail: Bool
    ) -> Bool {
        if nested.timedOut { outcome.timedOut = true }
        if nested.failed {
            outcome.failed = true
            if !continueOnFail { return true }
        }
        if nested.aborted { outcome.aborted = true; return true }
        if nested.stopped { outcome.stopped = true; return true }
        return false
    }

    /// 合并嵌套 Subtest 的结果到外层 outcome。**不**传播 failed（隔离单元）。
    /// - Returns: true 表示需要立即终止外层节点序列。
    private func mergeSubtestOutcome(
        _ nested: GroupOutcome,
        into outcome: inout GroupOutcome
    ) -> Bool {
        if nested.aborted { outcome.aborted = true; return true }
        if nested.stopped { outcome.stopped = true; return true }
        return false
    }

    private func makeSkipRecord(name: String, groupPath: [String], reason: String) -> PhaseRecord {
        var r = PhaseRecord(name: name)
        r.groupPath = groupPath
        r.outcome = .skip
        r.errorMessage = reason
        r.endTime = r.startTime
        return r
    }

    private func makeCheckpointRecord(_ cp: Checkpoint, groupPath: [String], didFail: Bool) -> PhaseRecord {
        var r = PhaseRecord(name: cp.name)
        r.groupPath = groupPath
        r.outcome = didFail ? .fail : .pass
        r.endTime = r.startTime
        if didFail {
            r.errorMessage = "Checkpoint failed: prior phase(s) failed in scope"
        }
        return r
    }

    nonisolated func runPhase(_ phase: Phase, context: TestContext) async -> PhaseRecord {
        let logEmitter: PhaseExecutor.LogEmitter = { [weak self] msg in
            guard let self else { return }
            Task { await self.emit(.log(msg)) }
        }
        let executor = await MainActor.run {
            PhaseExecutor(context: context, emitLog: logEmitter)
        }
        return await executor.execute(phase: phase)
    }

    func notifyOutputs(_ record: TestRecord) async {
        for callback in outputCallbacks {
            await callback.save(record: record)
        }
    }
}

// MARK: - Group 执行

extension TestSession {
    private func runGroup(
        _ g: Group,
        parentPath: [String],
        into record: inout TestRecord,
        context: TestContext
    ) async -> GroupOutcome {
        if let runIf = g.runIf, await runIf(context) == false {
            let skipRecord = makeSkipRecord(name: g.name, groupPath: parentPath, reason: "runIf=false")
            record.phases.append(skipRecord)
            emit(.phaseCompleted(skipRecord))
            return GroupOutcome()
        }

        let path = parentPath + [g.name]

        let setupOut = await runNodes(
            g.setup, groupPath: path, continueOnFail: false,
            into: &record, context: context
        )
        if let early = await handleGroupSetupEarlyExit(setupOut, g: g, path: path, into: &record, context: context) {
            return early
        }

        var groupOutcome = GroupOutcome()
        let childOut = await runNodes(
            g.children, groupPath: path, continueOnFail: g.continueOnFail,
            into: &record, context: context
        )
        groupOutcome.failed = childOut.failed
        groupOutcome.aborted = childOut.aborted
        groupOutcome.stopped = childOut.stopped

        _ = await runNodes(
            g.teardown, groupPath: path, continueOnFail: true,
            into: &record, context: context
        )
        return groupOutcome
    }

    /// Setup 阶段非正常终止时的早退处理：aborted / stopped / failed 三种。
    /// - Returns: 非 nil 表示外层应直接返回该结果（teardown 已按需跑过）。
    private func handleGroupSetupEarlyExit(
        _ setupOut: GroupOutcome,
        g: Group,
        path: [String],
        into record: inout TestRecord,
        context: TestContext
    ) async -> GroupOutcome? {
        if setupOut.aborted { return GroupOutcome(failed: false, aborted: true) }
        if setupOut.stopped {
            // setup 中冒出 .stop：仍跑 teardown，但整测试要终止
            _ = await runNodes(
                g.teardown, groupPath: path, continueOnFail: true,
                into: &record, context: context
            )
            return GroupOutcome(failed: false, aborted: false, stopped: true)
        }
        if setupOut.failed {
            _ = await runNodes(
                g.teardown, groupPath: path, continueOnFail: true,
                into: &record, context: context
            )
            return GroupOutcome(failed: true)
        }
        return nil
    }
}

// MARK: - Subtest 执行

extension TestSession {
    /// runSubtest 主循环每次迭代的中间状态。
    struct SubtestState {
        var phaseIDs: [UUID] = []
        var subtestFailed: Bool = false
        var failureReason: String?
        var aborted: Bool = false
        var stopped: Bool = false
    }

    /// 跑一个 Subtest：内部 phase / group 失败 → 短路剩余节点；subtest fail 不污染外层。
    ///
    /// 终态归约：
    /// - 任一 phase outcome=.fail/.error → subtest .fail（reason 取该 phase 名 + 错误信息）
    /// - 任一 phase subtestFailRequested=true → subtest .fail（reason 标 failSubtest）
    /// - 嵌套 Group 失败 → subtest .fail（reason 取 Group 名）
    /// - 嵌套 Subtest 失败 → **不** 让外层 subtest 失败（独立隔离）
    /// - Task.isCancelled → subtest .error 并冒泡 aborted=true
    /// - 内部 .stop → subtest 终态按已收集情况判定，并冒泡 stopped=true
    private func runSubtest(
        _ s: Subtest,
        parentPath: [String],
        into record: inout TestRecord,
        context: TestContext
    ) async -> GroupOutcome {
        let startTime = Date()
        if let runIf = s.runIf, await runIf(context) == false {
            record.subtests.append(SubtestRecord(
                id: s.id, name: s.name, outcome: .skip,
                startTime: startTime, endTime: Date(),
                phaseIDs: [], failureReason: "runIf=false"
            ))
            return GroupOutcome()
        }

        let path = parentPath + [s.name]
        var state = SubtestState()

        for node in s.nodes {
            if Task.isCancelled { state.aborted = true; break }
            if state.subtestFailed || state.stopped { break }
            await handleSubtestNode(node, path: path, state: &state, into: &record, context: context)
        }

        let outcome: SubtestOutcome = state.aborted
            ? .error
            : (state.subtestFailed ? .fail : .pass)
        record.subtests.append(SubtestRecord(
            id: s.id, name: s.name, outcome: outcome,
            startTime: startTime, endTime: Date(),
            phaseIDs: state.phaseIDs, failureReason: state.failureReason
        ))
        return GroupOutcome(failed: false, aborted: state.aborted, stopped: state.stopped)
    }

    /// 派发一个 subtest 子节点（phase / group / subtest）。
    private func handleSubtestNode(
        _ node: PhaseNode,
        path: [String],
        state: inout SubtestState,
        into record: inout TestRecord,
        context: TestContext
    ) async {
        switch node {
        case let .phase(phase):
            await handleSubtestPhase(phase, path: path, state: &state, into: &record, context: context)
        case let .group(g):
            let nested = await runGroup(g, parentPath: path, into: &record, context: context)
            if nested.aborted { state.aborted = true; return }
            if nested.stopped { state.stopped = true; return }
            if nested.failed {
                state.subtestFailed = true
                state.failureReason = "Group \(g.name) failed"
            }
        case let .subtest(inner):
            let nested = await runSubtest(inner, parentPath: path, into: &record, context: context)
            // 嵌套 subtest 是独立隔离单元，其失败不传染本 subtest
            if nested.aborted { state.aborted = true; return }
            if nested.stopped { state.stopped = true; return }
        case let .checkpoint(cp):
            // subtest 内的 checkpoint 看本 subtest 的 subtestFailed；不冒泡（与 Subtest 隔离一致）
            let didFail = state.subtestFailed
            let cpRecord = makeCheckpointRecord(cp, groupPath: path, didFail: didFail)
            record.phases.append(cpRecord)
            state.phaseIDs.append(cpRecord.id)
            emit(.phaseCompleted(cpRecord))
        // 失败时不需额外动作：state.subtestFailed 已为 true，下一轮 loop 自动 break
        case let .dynamic(d):
            let generated = await generateDynamicInSubtest(d, path: path, state: &state, into: &record, context: context)
            for child in generated {
                if Task.isCancelled { state.aborted = true; return }
                if state.subtestFailed || state.stopped { return }
                await handleSubtestNode(child, path: path, state: &state, into: &record, context: context)
            }
        }
    }

    /// 在 subtest 内跑一个 phase；含 runIf 跳过 / stopRequested / failSubtest / fail/error 判定。
    private func handleSubtestPhase(
        _ phase: Phase,
        path: [String],
        state: inout SubtestState,
        into record: inout TestRecord,
        context: TestContext
    ) async {
        if let runIf = phase.runIf, await runIf(context) == false {
            let skipRecord = makeSkipRecord(
                name: phase.definition.name, groupPath: path, reason: "runIf=false"
            )
            record.phases.append(skipRecord)
            state.phaseIDs.append(skipRecord.id)
            emit(.phaseCompleted(skipRecord))
            return
        }
        var phaseRecord = await runPhase(phase, context: context)
        phaseRecord.groupPath = path
        record.phases.append(phaseRecord)
        state.phaseIDs.append(phaseRecord.id)
        emit(.phaseCompleted(phaseRecord))
        applyPhaseRecordToSubtestState(phaseRecord, state: &state)
    }

    /// 根据 phase 终态更新 subtest 中间状态。`.stop` / `.failSubtest` / `.fail` / `.error` 各自映射。
    private func applyPhaseRecordToSubtestState(_ phaseRecord: PhaseRecord, state: inout SubtestState) {
        if phaseRecord.stopRequested {
            // .stop 在 subtest 内：subtest 算 fail（phase outcome=.error），但 stopped 冒泡，外层立即终止
            state.stopped = true
            state.subtestFailed = true
            state.failureReason = "\(phaseRecord.name): STOP"
            return
        }
        if phaseRecord.subtestFailRequested {
            state.subtestFailed = true
            state.failureReason = "\(phaseRecord.name): failSubtest"
            return
        }
        if phaseRecord.isFailing {
            state.subtestFailed = true
            let msg = phaseRecord.errorMessage ?? phaseRecord.outcome.rawValue
            state.failureReason = "\(phaseRecord.name): \(msg)"
        }
    }
}
