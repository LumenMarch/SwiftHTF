import Foundation

// MARK: - TestSession 主流程阶段拆解

//
// runInternal 自身行数 / 复杂度受 SwiftLint 阈值限制（fileLength 600 / functionBody 100 /
// cyclomaticComplexity 15）。把"启动校验 / plug setup / 主体跑 nodes / outcome 收尾 /
// test 级 diagnoser"这些独立片段抽到本扩展文件，actor 主文件只剩流程编排。

extension TestSession {
    /// 跑启动期 Schema 校验；若 fatal，把 record 标 .error 并完成 session，返回填好的 record。
    /// 非 fatal 时返回 nil，让 runInternal 继续。
    func runStartupValidation(record: inout TestRecord) async -> TestRecord? {
        let validation = SessionStartupValidator.validate(config: config)
        for warning in validation.warningLogs {
            emit(.log(warning))
        }
        guard let reason = validation.failureReason else { return nil }
        emit(.log(reason))
        record.outcome = .error
        record.endTime = Date()
        await notifyOutputs(record)
        emit(.testCompleted(record))
        finishStreams()
        return record
    }

    /// 跑 plug 集中 setup；失败时把 record 标 .error 并 finish session，返回 nil。
    func setupPlugs(record: inout TestRecord) async -> [String: any PlugProtocol]? {
        do {
            return try await plugManager.setupAll()
        } catch {
            emit(.log("Plug setup failed: \(error.localizedDescription)"))
            record.outcome = .error
            record.endTime = Date()
            await notifyOutputs(record)
            emit(.testCompleted(record))
            finishStreams()
            return nil
        }
    }

    /// 跑 plan.startup phase（OpenHTF `test_start` 等价物）。跑在 plug setUp 之后、setupNodes 之前。
    ///
    /// 返回是否应**跳过** `plan.setupNodes` / `plan.nodes` 主体：
    /// - 无 startup → 返回 false，主体照跑
    /// - `runIf` 返回 false → 当作未声明 startup（不写 SkipRecord，不发 serialNumberResolved 事件），
    ///   返回 false
    /// - startup 成功（pass / marginalPass）→ 发 `serialNumberResolved(ctx.serialNumber)`，返回 false
    /// - startup `.stop` → `record.outcome = .aborted`，发事件，返回 true
    /// - startup `.fail / .error / .timeout` → record 同步对应 outcome，发事件，返回 true
    ///
    /// 无论返回 true / false，PhaseRecord 都已写入 `record.phases`，`groupPath = ["__startup__"]`。
    /// teardownNodes / plug tearDownAll 在 runInternal 末尾照跑，本函数不负责。
    func runStartupPhase(into record: inout TestRecord, context: TestContext) async -> Bool {
        guard let startup = plan.startup else { return false }

        if let runIf = startup.runIf, await runIf(context) == false {
            // 与"未声明 startup"等价：不入 record.phases、不发事件、主体放行
            return false
        }

        var phaseRecord = await runPhase(startup, context: context)
        phaseRecord.groupPath = TestSession.startupGroupPath
        record.phases.append(phaseRecord)
        emit(.phaseCompleted(phaseRecord))

        // 同步 startup 内可能改写的 serialNumber 到 record（让 serialNumberResolved 事件携带正确值）
        let resolvedSN = await MainActor.run { context.serialNumber }
        record.serialNumber = resolvedSN
        emit(.serialNumberResolved(resolvedSN))

        if phaseRecord.stopRequested {
            record.outcome = .aborted
            return true
        }
        if phaseRecord.isFailing {
            // 与业务 phase 聚合一致：.fail/.error → record .fail；.timeout 单独升级
            record.outcome = phaseRecord.outcome == .timeout ? .timeout : .fail
            return true
        }
        return false
    }

    /// 跑 plan.setupNodes；返回是否应跳过 plan.nodes 主体（aborted / stopped / setup 失败 → true）。
    func runSetupNodes(into record: inout TestRecord, context: TestContext) async -> Bool {
        guard !plan.setupNodes.isEmpty else { return false }
        let outcome = await runNodes(
            plan.setupNodes,
            groupPath: [],
            continueOnFail: false,
            into: &record,
            context: context
        )
        var earlyExit = false
        if outcome.failed { record.outcome = .fail; earlyExit = true }
        if outcome.aborted { record.outcome = .aborted; earlyExit = true }
        if outcome.stopped { earlyExit = true }
        return earlyExit
    }

    /// 跑 plan.nodes 主体；处理 fail / aborted / timeout 升级。
    func runMainNodes(into record: inout TestRecord, context: TestContext) async {
        let outcome = await runNodes(
            plan.nodes,
            groupPath: [],
            continueOnFail: plan.continueOnFail,
            into: &record,
            context: context
        )
        if outcome.failed { record.outcome = .fail }
        if outcome.aborted { record.outcome = .aborted }
        // 失败 phase 全是 timeout（无 fail/error）→ 升级 TestOutcome.timeout，给上游更明确信号
        if record.outcome == .fail, outcome.timedOut,
           !record.phases.contains(where: { $0.outcome == .fail || $0.outcome == .error })
        {
            record.outcome = .timeout
        }
    }

    /// teardown 完成后做最终 outcome 调整：marginalPass 升级 + cancel 优先级覆盖。
    func finalizeOutcome(into record: inout TestRecord) {
        if record.outcome == .pass,
           record.phases.contains(where: { $0.outcome == .marginalPass })
        {
            record.outcome = .marginalPass
        }
        // 取消比失败信息更明确：运行期间被 cancel，无条件覆盖为 .aborted
        if Task.isCancelled {
            record.outcome = .aborted
        }
    }

    /// 跑 test-level diagnosers，按 trigger 过滤。outcome 已定后调用。
    func runTestDiagnosers(into record: inout TestRecord) async {
        for diagnoser in plan.diagnosers {
            let shouldRun = switch diagnoser.trigger {
            case .always: true
            case .onlyOnFail: record.outcome.isFailing
            }
            if shouldRun {
                let diagnoses = await diagnoser.diagnose(record: record)
                record.diagnoses.append(contentsOf: diagnoses)
            }
        }
    }

    // MARK: - DynamicPhases helper（顶层 / subtest 内共用）

    /// 顶层 runNodes 内的 dynamic 节点：调闭包拿 [PhaseNode]；抛错时占位 .error
    /// PhaseRecord 并返回空数组（由调用方决定是否继续）。
    func generateDynamic(
        _ d: DynamicPhases,
        groupPath: [String],
        into record: inout TestRecord,
        context: TestContext
    ) async -> [PhaseNode] {
        do {
            return try await d.generate(context)
        } catch {
            let placeholder = makeDynamicErrorRecord(name: d.name, groupPath: groupPath, error: error)
            record.phases.append(placeholder)
            emit(.phaseCompleted(placeholder))
            return []
        }
    }

    /// subtest 内的 dynamic 节点：抛错时占位写入 PhaseRecord 同时挂到 subtest phaseIDs；
    /// 返回生成的节点供调用方递归执行。
    func generateDynamicInSubtest(
        _ d: DynamicPhases,
        path: [String],
        state: inout SubtestState,
        into record: inout TestRecord,
        context: TestContext
    ) async -> [PhaseNode] {
        do {
            return try await d.generate(context)
        } catch {
            let placeholder = makeDynamicErrorRecord(name: d.name, groupPath: path, error: error)
            record.phases.append(placeholder)
            state.phaseIDs.append(placeholder.id)
            emit(.phaseCompleted(placeholder))
            return []
        }
    }

    /// DynamicPhases 闭包抛错时写入的占位 PhaseRecord。
    func makeDynamicErrorRecord(
        name: String, groupPath: [String], error: Error
    ) -> PhaseRecord {
        var r = PhaseRecord(name: name)
        r.groupPath = groupPath
        r.outcome = .error
        r.errorMessage = "DynamicPhases generator threw: \(error.localizedDescription)"
        r.endTime = r.startTime
        return r
    }
}
