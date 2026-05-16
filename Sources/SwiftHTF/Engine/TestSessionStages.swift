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
}
