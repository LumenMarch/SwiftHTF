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

    /// 执行单个阶段
    /// - Parameter phase: 阶段定义
    /// - Returns: 阶段记录
    func execute(phase: Phase) async -> PhaseRecord {
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
        for (name, m) in context.measurements {
            var updated = m
            if let spec = specsByName[name] {
                let (ok, messages) = spec.run(on: m.value)
                updated.outcome = ok ? .pass : .fail
                updated.validatorMessages = messages
                if !ok {
                    anyMeasurementFailed = true
                    failureMessages.append(contentsOf: messages.map { "[\(name)] \($0)" })
                }
            }
            collected[name] = updated
        }
        r.measurements = collected
        context.measurements = [:]

        // 仅当 phase 当前还是 pass 时升级为 fail（不要覆盖已存在的 .skip/.error/.fail）
        if anyMeasurementFailed && r.outcome == .pass {
            r.outcome = .fail
            if r.errorMessage == nil {
                r.errorMessage = failureMessages.joined(separator: "; ")
            }
            log("[\(phase.definition.name)] ---> FAIL (measurement): \(failureMessages.joined(separator: "; "))")
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
