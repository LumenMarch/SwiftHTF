import Foundation

/// 阶段执行器
///
/// 负责单个 Phase 的运行：超时包装、重试循环、验证测量值。返回 PhaseRecord 由 TestExecutor 收集。
@MainActor
public final class PhaseExecutor {
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
                && record.measurements.values.contains { $0.outcome == .fail }
            if measurementCausedFail && measurementRepeatsUsed < maxMeasurementRepeats {
                measurementRepeatsUsed += 1
                log("[\(phase.definition.name)] ---> Repeat (measurement fail \(measurementRepeatsUsed)/\(maxMeasurementRepeats))")
                continue
            }
            return record
        }
    }

    private func executeAttempt(phase: Phase) async -> PhaseRecord {
        var phaseRecord = PhaseRecord(name: phase.definition.name)
        log("[\(phase.definition.name)] ---> Start")

        var lastError: Error?
        var attempts = 0
        let maxAttempts = phase.definition.retryCount + 1

        while attempts < maxAttempts {
            attempts += 1

            do {
                let result = try await executeWithTimeout(phase: phase, context: context)

                switch result {
                case .continue:
                    if let value = context.getValue(phase.definition.name) {
                        let validation = validateValue(value, phase: phase)
                        switch validation {
                        case .pass:
                            phaseRecord.endTime = Date()
                            phaseRecord.outcome = .pass
                            phaseRecord.value = value
                            log("[\(phase.definition.name)] ---> \(value)")
                            return harvest(phaseRecord, phase: phase)
                        case .fail(let message):
                            if attempts < maxAttempts {
                                log("[\(phase.definition.name)] ---> Retry \(attempts): \(message)")
                                continue
                            }
                            phaseRecord.endTime = Date()
                            phaseRecord.outcome = .fail
                            phaseRecord.value = value
                            phaseRecord.errorMessage = message
                            log("[\(phase.definition.name)] ---> FAIL: \(message)")
                            return harvest(phaseRecord, phase: phase)
                        }
                    } else {
                        phaseRecord.endTime = Date()
                        phaseRecord.outcome = .pass
                        log("[\(phase.definition.name)] ---> Continue")
                        return harvest(phaseRecord, phase: phase)
                    }

                case .failAndContinue:
                    phaseRecord.endTime = Date()
                    phaseRecord.outcome = .fail
                    phaseRecord.value = context.getValue(phase.definition.name)
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
                    log("[\(phase.definition.name)] ---> STOP")
                    return harvest(phaseRecord, phase: phase)
                }

            } catch {
                lastError = error

                if attempts < maxAttempts {
                    log("[\(phase.definition.name)] ---> Retry \(attempts): \(error.localizedDescription)")
                    continue
                }

                phaseRecord.endTime = Date()
                phaseRecord.outcome = .error
                phaseRecord.errorMessage = error.localizedDescription
                log("[\(phase.definition.name)] ---> ERROR: \(error.localizedDescription)")
                return harvest(phaseRecord, phase: phase)
            }
        }

        // 不应到达
        phaseRecord.endTime = Date()
        phaseRecord.outcome = .error
        phaseRecord.errorMessage = (lastError ?? TestError.unknown("Unknown error")).localizedDescription
        return harvest(phaseRecord, phase: phase)
    }

    /// 将 ctx.measurements 收集到 phaseRecord，按 phase.measurements 中的 spec 跑 validator，
    /// 写回每条 measurement 的 outcome/validatorMessages；任一 measurement fail 时把 phase
    /// 从 .pass 升级为 .fail。最后清空 ctx 给下个 phase 使用。
    private func harvest(_ record: PhaseRecord, phase: Phase) -> PhaseRecord {
        var r = record
        let specsByName: [String: MeasurementSpec] = Dictionary(
            uniqueKeysWithValues: phase.measurements.map { ($0.name, $0) }
        )
        var anyMeasurementFailed = false
        var failureMessages: [String] = []

        var collected: [String: Measurement] = [:]
        var anyMeasurementMarginal = false
        var marginalMessages: [String] = []

        for (name, m) in context.measurements {
            var updated = m
            if let spec = specsByName[name] {
                let (verdict, messages) = spec.run(on: m.value)
                updated.validatorMessages = messages
                switch verdict {
                case .pass:
                    updated.outcome = .pass
                case .marginal:
                    updated.outcome = .marginalPass
                    anyMeasurementMarginal = true
                    marginalMessages.append(contentsOf: messages.map { "[\(name)] \($0)" })
                case .fail:
                    updated.outcome = .fail
                    anyMeasurementFailed = true
                    failureMessages.append(contentsOf: messages.map { "[\(name)] \($0)" })
                }
            }
            collected[name] = updated
        }
        r.measurements = collected
        r.attachments = context.attachments
        context.measurements = [:]
        context.attachments = []

        // 仅当 phase 当前还是 pass 时升级（不覆盖 .skip/.error/.fail）
        if r.outcome == .pass {
            if anyMeasurementFailed {
                r.outcome = .fail
                if r.errorMessage == nil {
                    r.errorMessage = failureMessages.joined(separator: "; ")
                }
                log("[\(phase.definition.name)] ---> FAIL (measurement): \(failureMessages.joined(separator: "; "))")
            } else if anyMeasurementMarginal {
                r.outcome = .marginalPass
                log("[\(phase.definition.name)] ---> MARGINAL: \(marginalMessages.joined(separator: "; "))")
            }
        }
        return r
    }

    private func executeWithTimeout(phase: Phase, context: TestContext) async throws -> PhaseResult {
        if let timeout = phase.definition.timeout {
            return try await withTimeout(timeout) {
                try await phase.definition.execute(context)
            }
        } else {
            return try await phase.definition.execute(context)
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

    private func validateValue(_ value: String, phase: Phase) -> ValidationResult {
        for validator in phase.validators {
            let result = validator.validate(value)
            if case .fail = result {
                return result
            }
        }

        if phase.lowerLimit != nil || phase.upperLimit != nil {
            let validator = RangeValidator(
                lower: phase.lowerLimit.flatMap { RangeValidator.parseNumber($0) },
                upper: phase.upperLimit.flatMap { RangeValidator.parseNumber($0) },
                unit: phase.unit
            )
            return validator.validate(value)
        }

        return .pass
    }

    private func log(_ message: String) {
        emitLog?(message)
    }
}
