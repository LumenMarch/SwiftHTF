import Foundation

/// 阶段执行器
///
/// 负责单个 Phase 的运行：超时包装、retry / measurement-repeat 双计数器循环、
/// harvest 单点 measurement 与多维 series（按 spec 跑 validator 写回三态 outcome），
/// 收集 attachments / phaseLogs，并在终态 fail/.error 时跑 diagnosers。
/// 返回的 `PhaseRecord` 由 `TestSession` 串入 `TestRecord.phases`。
@MainActor
public final class PhaseExecutor {
    /// 把 phase 内 `ctx.log(...)` 与执行流追踪日志转成纯文本广播给上层（session 事件流）。
    /// 返回前缀已格式化为 `[LEVEL] message`。
    public typealias LogEmitter = @Sendable (String) -> Void

    private let context: TestContext
    private let emitLog: LogEmitter?

    init(context: TestContext, emitLog: LogEmitter? = nil) {
        self.context = context
        self.emitLog = emitLog
    }

    /// 执行单个阶段。
    ///
    /// 在原子 `executeAttempt` 之外包一层 measurement-repeat：
    /// 当 phase 闭包返回 `.continue` 但 measurement 验证失败导致 outcome 升级为 `.fail` 时，
    /// 若 `repeatOnMeasurementFail` 配额未用尽则重跑（清空 ctx.measurements / attachments 由
    /// harvest 自身完成）。`retryCount` 与 measurement-repeat 是独立计数器，不互相消耗。
    func execute(phase: Phase) async -> PhaseRecord {
        let maxMeasurementRepeats = phase.repeatOnMeasurementFail
        var measurementRepeatsUsed = 0

        while true {
            let record = await executeAttempt(phase: phase)
            let measurementCausedFail = record.outcome == .fail
                && (record.measurements.values.contains { $0.outcome == .fail }
                    || record.traces.values.contains { $0.outcome == .fail })
            if measurementCausedFail, measurementRepeatsUsed < maxMeasurementRepeats {
                measurementRepeatsUsed += 1
                log("[\(phase.definition.name)] ---> Repeat (measurement fail \(measurementRepeatsUsed)/\(maxMeasurementRepeats))")
                continue
            }
            // 终态：outcome 已定。fail/error 时跑 diagnosers。
            if record.outcome == .fail || record.outcome == .error,
               !phase.diagnosers.isEmpty
            {
                return await runDiagnosers(record: record, phase: phase)
            }
            return record
        }
    }

    /// 跑 phase.diagnosers 并合并副作用（measurement / attachment / trace / logs）进 record。
    /// diagnoser 写的 measurement / trace 不再跑 spec validation —— 视为辅助调试信息。
    private func runDiagnosers(record: PhaseRecord, phase: Phase) async -> PhaseRecord {
        var r = record
        // 暂时重启 logEmitter，让 diagnoser 内的 ctx.log 也能广播到事件流
        let stringEmitter = emitLog
        context.logEmitter = { entry in
            stringEmitter?("[\(entry.level.rawValue)] \(entry.message)")
        }
        for diagnoser in phase.diagnosers {
            let diagnoses = await diagnoser.diagnose(record: r, context: context)
            r.diagnoses.append(contentsOf: diagnoses)
            // diagnoser 副作用：合并新写入的 ctx.measurements / ctx.series / ctx.attachments / ctx.phaseLogs
            for (name, m) in context.measurements {
                r.measurements[name] = m
            }
            for (name, s) in context.series {
                r.traces[name] = s
            }
            r.attachments.append(contentsOf: context.attachments)
            r.logs.append(contentsOf: context.phaseLogs)
            context.measurements = [:]
            context.series = [:]
            context.attachments = []
            context.phaseLogs = []
            for d in diagnoses {
                log("[\(phase.definition.name)] ---> Diagnosis (\(d.severity.rawValue)) \(d.code): \(d.message)")
            }
        }
        context.logEmitter = nil
        return r
    }

    private func executeAttempt(phase: Phase) async -> PhaseRecord {
        var phaseRecord = PhaseRecord(name: phase.definition.name)
        log("[\(phase.definition.name)] ---> Start")

        // 注入 series spec，供 ctx.recordSeries 默认从中读取维度
        context.seriesSpecs = Dictionary(
            uniqueKeysWithValues: phase.series.map { ($0.name, $0) }
        )

        // 注入参数化运行时态：args（withArgs 声明）+ plug 重定向（withPlug 声明）。
        // 在 attempt 之间 / harvest 末尾会被清空。
        context.arguments = phase.arguments
        context.plugOverrides = phase.plugOverrides

        // 注入 phase logger emitter，让 ctx.log 既写 phaseLogs 又广播到事件流
        let stringEmitter = emitLog
        context.logEmitter = { entry in
            stringEmitter?("[\(entry.level.rawValue)] \(entry.message)")
        }

        var lastError: Error?
        var attempts = 0
        let maxAttempts = phase.definition.retryCount + 1

        while attempts < maxAttempts {
            attempts += 1
            // 每次 attempt 起始重置 ctx 的 phase 局部状态（measurements/series/attachments
            // 由 harvest 末尾清空；logs 用 retry 维度重置以反映最后一次 attempt 的实际日志）
            context.phaseLogs = []

            // 启动 monitor 后台任务（与 Phase 主体生命周期对齐：本次 attempt 起始挂起，
            // attempt 结束前回收）。每次 attempt 重启，确保 retry / repeat 不串行采样。
            let monitorHandles = MonitorScheduler.start(phase: phase, context: context)

            do {
                let result = try await executeWithTimeout(phase: phase, context: context)
                await MonitorScheduler.stop(monitorHandles)

                switch result {
                case .continue:
                    phaseRecord.endTime = Date()
                    phaseRecord.outcome = .pass
                    log("[\(phase.definition.name)] ---> Continue")
                    return harvest(phaseRecord, phase: phase)

                case .failAndContinue:
                    phaseRecord.endTime = Date()
                    phaseRecord.outcome = .fail
                    log("[\(phase.definition.name)] ---> FAIL (continue)")
                    return harvest(phaseRecord, phase: phase)

                case .retry:
                    if attempts < maxAttempts {
                        log("[\(phase.definition.name)] ---> Repeat")
                        continue
                    }
                    phaseRecord.endTime = Date()
                    phaseRecord.outcome = .error
                    phaseRecord.errorMessage = TestError.maxRetriesExceeded.errorDescription
                    log("[\(phase.definition.name)] ---> ERROR: Max retries exceeded")
                    return harvest(phaseRecord, phase: phase)

                case .skip:
                    phaseRecord.endTime = Date()
                    phaseRecord.outcome = .skip
                    log("[\(phase.definition.name)] ---> SKIP")
                    return harvest(phaseRecord, phase: phase)

                case .stop:
                    phaseRecord.endTime = Date()
                    phaseRecord.outcome = .error
                    phaseRecord.stopRequested = true
                    log("[\(phase.definition.name)] ---> STOP")
                    return harvest(phaseRecord, phase: phase)

                case .failSubtest:
                    // 在 Subtest 内：TestSession.runSubtest 检测 subtestFailRequested 短路
                    // 不在 Subtest 内：等价 .failAndContinue（phase 标 .fail，subtestFailRequested 留着但无副作用）
                    phaseRecord.endTime = Date()
                    phaseRecord.outcome = .fail
                    phaseRecord.subtestFailRequested = true
                    log("[\(phase.definition.name)] ---> FAIL_SUBTEST")
                    return harvest(phaseRecord, phase: phase)
                }

            } catch {
                lastError = error
                await MonitorScheduler.stop(monitorHandles)

                if attempts < maxAttempts {
                    log("[\(phase.definition.name)] ---> Retry \(attempts): \(error.localizedDescription)")
                    continue
                }

                phaseRecord.endTime = Date()
                let outcome: PhaseOutcomeType = isFailureException(error, phase: phase) ? .fail : .error
                phaseRecord.outcome = outcome
                phaseRecord.errorMessage = error.localizedDescription
                let label = outcome == .fail ? "FAIL" : "ERROR"
                log("[\(phase.definition.name)] ---> \(label): \(error.localizedDescription)")
                return harvest(phaseRecord, phase: phase)
            }
        }

        // 不应到达
        phaseRecord.endTime = Date()
        phaseRecord.outcome = .error
        phaseRecord.errorMessage = (lastError ?? TestError.unknown("Unknown error")).localizedDescription
        return harvest(phaseRecord, phase: phase)
    }

    /// phase.failureExceptions 与抛出 error 的精确类型匹配？
    private nonisolated func isFailureException(_ error: Error, phase: Phase) -> Bool {
        let errorType = type(of: error)
        let errorId = ObjectIdentifier(errorType)
        return phase.failureExceptions.contains { ObjectIdentifier($0) == errorId }
    }

    /// harvest 聚合 verdict
    private struct HarvestVerdict {
        var anyFailed: Bool = false
        var anyMarginal: Bool = false
        var failureMessages: [String] = []
        var marginalMessages: [String] = []
    }

    /// 将 ctx.measurements / ctx.series 收集到 phaseRecord，按 spec 跑 validator，写回各自
    /// outcome/validatorMessages；任一 measurement 或 trace fail 时把 phase 从 .pass 升级为 .fail；
    /// 任一 marginal 时升级为 .marginalPass。最后清空 ctx 给下个 phase 使用。
    private func harvest(_ record: PhaseRecord, phase: Phase) -> PhaseRecord {
        var r = record
        var verdict = HarvestVerdict()
        r.measurements = collectMeasurements(phase: phase, verdict: &verdict)
        r.traces = collectSeries(phase: phase, verdict: &verdict)

        r.attachments = context.attachments
        r.logs = context.phaseLogs
        r.arguments = context.arguments
        context.measurements = [:]
        context.series = [:]
        context.attachments = []
        context.phaseLogs = []
        context.arguments = [:]
        context.plugOverrides = [:]
        context.logEmitter = nil

        // 仅当 phase 当前还是 pass 时升级（不覆盖 .skip/.error/.fail）
        if r.outcome == .pass {
            if verdict.anyFailed {
                r.outcome = .fail
                if r.errorMessage == nil {
                    r.errorMessage = verdict.failureMessages.joined(separator: "; ")
                }
                log("[\(phase.definition.name)] ---> FAIL (measurement): \(verdict.failureMessages.joined(separator: "; "))")
            } else if verdict.anyMarginal {
                r.outcome = .marginalPass
                log("[\(phase.definition.name)] ---> MARGINAL: \(verdict.marginalMessages.joined(separator: "; "))")
            }
        }
        return r
    }

    /// 单点 measurements 收集 + missing-required 处理。
    private func collectMeasurements(
        phase: Phase, verdict: inout HarvestVerdict
    ) -> [String: Measurement] {
        let specsByName: [String: MeasurementSpec] = Dictionary(
            uniqueKeysWithValues: phase.measurements.map { ($0.name, $0) }
        )
        var collected: [String: Measurement] = [:]
        for (name, m) in context.measurements {
            var updated = m
            if let spec = specsByName[name] {
                // transform：保留原值到 rawValue，把转换结果写回 value 再跑 validator
                if let transform = spec.transform {
                    let raw = m.value
                    let mapped = transform(raw)
                    updated.rawValue = raw
                    updated.value = mapped
                }
                let (v, messages) = spec.run(on: updated.value)
                updated.validatorMessages = messages
                applyMeasurementVerdict(name: name, verdict: v, messages: messages,
                                        updated: &updated, agg: &verdict)
            }
            collected[name] = updated
        }
        for spec in phase.measurements
            where collected[spec.name] == nil && !spec.isOptional
        {
            let msg = "missing required measurement"
            collected[spec.name] = Measurement(
                name: spec.name, value: .null, unit: spec.unit,
                outcome: .fail, validatorMessages: [msg]
            )
            verdict.anyFailed = true
            verdict.failureMessages.append("[\(spec.name)] \(msg)")
        }
        return collected
    }

    /// Series traces 收集 + missing-required 处理。
    private func collectSeries(
        phase: Phase, verdict: inout HarvestVerdict
    ) -> [String: SeriesMeasurement] {
        let seriesSpecsByName: [String: SeriesMeasurementSpec] = Dictionary(
            uniqueKeysWithValues: phase.series.map { ($0.name, $0) }
        )
        var collected: [String: SeriesMeasurement] = [:]
        for (name, s) in context.series {
            var updated = s
            if let spec = seriesSpecsByName[name] {
                let (v, messages) = spec.run(on: s.samples)
                updated.validatorMessages = messages
                applySeriesVerdict(name: name, verdict: v, messages: messages,
                                   updated: &updated, agg: &verdict)
            }
            collected[name] = updated
        }
        for spec in phase.series
            where collected[spec.name] == nil && !spec.isOptional
        {
            let msg = "missing required series"
            collected[spec.name] = SeriesMeasurement(
                name: spec.name, description: spec.description,
                dimensions: spec.dimensions,
                value: spec.value ?? Dimension(name: "value"),
                outcome: .fail, validatorMessages: [msg]
            )
            verdict.anyFailed = true
            verdict.failureMessages.append("[\(spec.name)] \(msg)")
        }
        return collected
    }

    private func applyMeasurementVerdict(
        name: String, verdict: MeasurementSpec.Verdict, messages: [String],
        updated: inout Measurement, agg: inout HarvestVerdict
    ) {
        switch verdict {
        case .pass:
            updated.outcome = .pass
        case .marginal:
            updated.outcome = .marginalPass
            agg.anyMarginal = true
            agg.marginalMessages.append(contentsOf: messages.map { "[\(name)] \($0)" })
        case .fail:
            updated.outcome = .fail
            agg.anyFailed = true
            agg.failureMessages.append(contentsOf: messages.map { "[\(name)] \($0)" })
        }
    }

    private func applySeriesVerdict(
        name: String, verdict: MeasurementSpec.Verdict, messages: [String],
        updated: inout SeriesMeasurement, agg: inout HarvestVerdict
    ) {
        switch verdict {
        case .pass:
            updated.outcome = .pass
        case .marginal:
            updated.outcome = .marginalPass
            agg.anyMarginal = true
            agg.marginalMessages.append(contentsOf: messages.map { "[\(name)] \($0)" })
        case .fail:
            updated.outcome = .fail
            agg.anyFailed = true
            agg.failureMessages.append(contentsOf: messages.map { "[\(name)] \($0)" })
        }
    }

    private func executeWithTimeout(phase: Phase, context: TestContext) async throws -> PhaseResult {
        if let timeout = phase.definition.timeout {
            try await withTimeout(timeout) {
                try await phase.definition.execute(context)
            }
        } else {
            try await phase.definition.execute(context)
        }
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TestError.timeout("Timeout after \(seconds)s")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func log(_ message: String) {
        emitLog?(message)
    }
}
