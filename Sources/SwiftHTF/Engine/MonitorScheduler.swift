import Foundation

/// `Phase.monitor(...)` / `monitorBackground(...)` 声明的周期采样调度器。
///
/// 与 `PhaseExecutor` 分离以保持后者职责单一；运行时所有调度状态都在
/// 一次性的 `Handle` 数组里，本类型不持久状态。
///
/// 生命周期：`PhaseExecutor` 在每次 attempt 起始调 `start(...)`，phase 主体
/// 退出（return/throw/cancel）后调 `stop(...)` 回收任务（含 drainTimeout 收尾）。
@MainActor
enum MonitorScheduler {
    /// 单个 monitor 的运行句柄：Task + 它声明的 drainTimeout。
    struct Handle {
        let task: Task<Void, Never>
        let drainTimeout: TimeInterval
    }

    /// 为 phase 中每个 `MonitorSpec` 起一个独立 Task，互不阻塞。
    /// 任务循环直到收到 cancel 或 errorThreshold 达成。
    static func start(phase: Phase, context: TestContext) -> [Handle] {
        guard !phase.monitors.isEmpty else { return [] }
        let startedAt = Date()
        return phase.monitors.map { spec in
            let task = Task {
                await Self.runMonitor(spec: spec, context: context, startedAt: startedAt)
            }
            return Handle(task: task, drainTimeout: spec.drainTimeout)
        }
    }

    /// Phase 主体结束后回收所有 monitor：
    /// 1) 发 cancel 信号给每个 monitor Task
    /// 2) 对每个任务最多再等 `drainTimeout` 让它完成飞行中的采样
    /// 3) 超时则脱离等待（飞行中的采样写回因 ctx.series 已被 harvest 清空而无效）
    static func stop(_ handles: [Handle]) async {
        guard !handles.isEmpty else { return }
        for h in handles {
            h.task.cancel()
        }
        await withTaskGroup(of: Void.self) { group in
            for h in handles {
                group.addTask {
                    await withTaskGroup(of: Void.self) { inner in
                        inner.addTask { await h.task.value }
                        inner.addTask {
                            let ns = UInt64(max(0, h.drainTimeout) * 1_000_000_000)
                            try? await Task.sleep(nanoseconds: ns)
                        }
                        _ = await inner.next()
                        inner.cancelAll()
                    }
                }
            }
        }
    }

    /// monitor 循环主体：周期采样、错误计数、cancel 退出。
    ///
    /// macOS 13+：`SuspendingClock` + 绝对 deadline 累加，sample 耗时不影响下次 tick 时刻
    /// （长跑无累计漂移）。macOS 12：fallback 到 `Task.sleep(nanoseconds:)`，相对睡眠。
    ///
    /// 两路径共享：`elapsed` 始终走 `Date()` 墙钟，trace 的 `t` 列含义与平台无关。
    nonisolated static func runMonitor(
        spec: MonitorSpec,
        context: TestContext,
        startedAt: Date
    ) async {
        if #available(macOS 13, *) {
            await runMonitorClock(spec: spec, context: context, startedAt: startedAt)
        } else {
            await runMonitorLegacy(spec: spec, context: context, startedAt: startedAt)
        }
    }

    /// macOS 13+ 路径：SuspendingClock 绝对时刻 grid。
    @available(macOS 13, *)
    private nonisolated static func runMonitorClock(
        spec: MonitorSpec,
        context: TestContext,
        startedAt: Date
    ) async {
        var errorCount = 0
        let clock = SuspendingClock()
        let periodDuration: Duration = .nanoseconds(Int(max(0, spec.period) * 1_000_000_000))
        var deadline = clock.now + periodDuration
        while !Task.isCancelled {
            await pumpOnce(spec: spec, context: context, startedAt: startedAt, errorCount: &errorCount)
            if errorCount >= spec.errorThreshold { return }
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
            deadline += periodDuration
        }
    }

    /// macOS 12 路径：`Task.sleep(nanoseconds:)` 相对睡眠。
    private nonisolated static func runMonitorLegacy(
        spec: MonitorSpec,
        context: TestContext,
        startedAt: Date
    ) async {
        var errorCount = 0
        let periodNanos = UInt64(max(0, spec.period) * 1_000_000_000)
        while !Task.isCancelled {
            await pumpOnce(spec: spec, context: context, startedAt: startedAt, errorCount: &errorCount)
            if errorCount >= spec.errorThreshold { return }
            do {
                try await Task.sleep(nanoseconds: periodNanos)
            } catch {
                return
            }
        }
    }

    /// 单次"采样 + 写入 / 错误计数"原子动作，两条调度路径共用。
    /// `errorCount` 由调用方持有；达 `errorThreshold` 后由外层退出循环。
    private nonisolated static func pumpOnce(
        spec: MonitorSpec,
        context: TestContext,
        startedAt: Date,
        errorCount: inout Int
    ) async {
        do {
            let value: Double = switch spec.sampler {
            case let .mainActor(fn):
                try await fn(context)
            case let .background(fn):
                try await fn()
            }
            if Task.isCancelled { return }
            let elapsed = Date().timeIntervalSince(startedAt)
            await MainActor.run {
                Self.appendSample(
                    name: spec.name, unit: spec.unit,
                    elapsed: elapsed, value: value, context: context
                )
            }
        } catch is CancellationError {
            return
        } catch {
            errorCount += 1
            let capturedErrorCount = errorCount
            let capturedMessage = error.localizedDescription
            await MainActor.run {
                context.logWarning(
                    "[monitor:\(spec.name)] sample error "
                        + "(\(capturedErrorCount)/\(spec.errorThreshold)): \(capturedMessage)"
                )
            }
            if errorCount >= spec.errorThreshold {
                await MainActor.run {
                    context.logWarning(
                        "[monitor:\(spec.name)] stopped after \(capturedErrorCount) consecutive errors"
                    )
                }
            }
        }
    }

    /// 把一行 `[elapsed_s, value]` 追加到 ctx.series[name]；不存在则懒初始化。
    /// 维度恒定为 `(t, s)` + `(name, unit)`。若用户在 phase.series 上声明了同名
    /// spec，验证器会在 harvest 时跑在累计的采样上。
    @MainActor
    private static func appendSample(
        name: String, unit: String?,
        elapsed: TimeInterval, value: Double,
        context: TestContext
    ) {
        if context.series[name] == nil {
            context.series[name] = SeriesMeasurement(
                name: name,
                description: nil,
                dimensions: [Dimension(name: "t", unit: "s")],
                value: Dimension(name: name, unit: unit),
                samples: []
            )
        }
        context.series[name]?.samples.append([.double(elapsed), .double(value)])
    }
}
