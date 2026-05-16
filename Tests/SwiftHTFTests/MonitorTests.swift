@testable import SwiftHTF
import XCTest

/// `MonitorSpec` + `Phase.monitor(...)` / `.monitorBackground(...)` 测试。
///
/// 周期参数刻意取较短（30~50ms），单测期望保留宽松的下界以避免 CI 抖动。
final class MonitorTests: XCTestCase {
    // MARK: - 基本周期采样

    func testMonitorCollectsSamplesIntoTrace() async {
        let counter = SharedCounter()
        let plan = TestPlan(name: "monitor-basic") {
            Phase(name: "soak") { @MainActor _ in
                try await Task.sleep(nanoseconds: 250_000_000) // 250ms
                return .continue
            }
            .monitor("ticks", unit: "n", every: 0.05) { @MainActor _ in
                await counter.next()
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        let trace = record.phases[0].traces["ticks"]
        XCTAssertNotNil(trace)
        // 250ms / 50ms ≈ 5；放宽至 [2, 10] 容忍调度抖动
        XCTAssertGreaterThanOrEqual(trace?.samples.count ?? 0, 2)
        XCTAssertLessThanOrEqual(trace?.samples.count ?? 999, 10)
        XCTAssertEqual(trace?.dimensions.first?.name, "t")
        XCTAssertEqual(trace?.dimensions.first?.unit, "s")
        XCTAssertEqual(trace?.value.name, "ticks")
        XCTAssertEqual(trace?.value.unit, "n")
        // 第一列 elapsed 单调非降
        if let samples = trace?.samples {
            let elapseds = samples.compactMap { $0.first?.asDouble }
            XCTAssertEqual(elapseds, elapseds.sorted())
        }
    }

    // MARK: - 同名 series spec 验证器自动作用

    func testMonitorRespectsSeriesSpecValidator() async {
        let counter = SharedCounter()
        let plan = TestPlan(name: "monitor-spec") {
            Phase(
                name: "soak",
                series: [
                    .named("ticks")
                        .dimension("t", unit: "s")
                        .value("ticks", unit: "n")
                        .lengthAtLeast(100), // 远超实际能采到的量
                ]
            ) { @MainActor _ in
                try await Task.sleep(nanoseconds: 100_000_000)
                return .continue
            }
            .monitor("ticks", unit: "n", every: 0.05) { @MainActor _ in
                await counter.next()
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .fail)
        XCTAssertEqual(record.phases[0].traces["ticks"]?.outcome, .fail)
    }

    // MARK: - 错误阈值停止

    func testMonitorStopsAfterErrorThreshold() async {
        let plan = TestPlan(name: "monitor-errors") {
            Phase(name: "soak") { @MainActor _ in
                try await Task.sleep(nanoseconds: 300_000_000)
                return .continue
            }
            .monitor(
                "broken",
                every: 0.02,
                errorThreshold: 3
            ) { @MainActor _ in
                throw MonitorTestError.boom
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass, "monitor 错误不应影响 phase outcome")
        XCTAssertNil(record.phases[0].traces["broken"], "全部抛错时不应有 sample 落点")
        // 至少 3 条 warning + 1 条停止通告
        let warnings = record.phases[0].logs.filter { $0.level == .warning }
        XCTAssertGreaterThanOrEqual(warnings.count, 3)
        XCTAssertTrue(warnings.contains { $0.message.contains("stopped after") })
    }

    // MARK: - Phase throw 时 monitor 也回收

    func testMonitorStopsWhenPhaseThrows() async {
        let counter = SharedCounter()
        let plan = TestPlan(name: "monitor-throw") {
            Phase(name: "boom") { @MainActor _ in
                try await Task.sleep(nanoseconds: 80_000_000)
                throw MonitorTestError.boom
            }
            .monitor("ticks", every: 0.02) { @MainActor _ in
                await counter.next()
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .fail)
        XCTAssertEqual(record.phases[0].outcome, .error)
        let before = await counter.value
        // 等一小段时间，确认 cancel 后采样不再增长（drainTimeout 收尾 + cancel 生效）
        try? await Task.sleep(nanoseconds: 100_000_000)
        let after = await counter.value
        XCTAssertEqual(before, after, "phase throw 后 monitor 应已停止采样")
    }

    // MARK: - retry 重置 monitor traces

    func testMonitorResetsBetweenAttempts() async {
        let counter = SharedCounter()
        let plan = TestPlan(name: "monitor-retry") {
            Phase(name: "flaky", retryCount: 1) { @MainActor ctx in
                try await Task.sleep(nanoseconds: 60_000_000)
                let n = ctx.state.int("attempt") ?? 0
                ctx.state.set("attempt", n + 1)
                if n == 0 { return .retry }
                return .continue
            }
            .monitor("ticks", every: 0.02) { @MainActor _ in
                await counter.next()
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        let trace = record.phases[0].traces["ticks"]
        XCTAssertNotNil(trace)
        // 第一列 elapsed 单调非降并从接近 0 起步：说明最后一次 attempt 重置了 startedAt
        if let first = trace?.samples.first?.first?.asDouble {
            XCTAssertLessThan(first, 0.04, "最后一次 attempt 的首条采样应靠近 0s")
        }
    }

    // MARK: - background sampler

    func testBackgroundMonitorRuns() async {
        let plan = TestPlan(name: "monitor-bg") {
            Phase(name: "soak") { @MainActor _ in
                try await Task.sleep(nanoseconds: 150_000_000)
                return .continue
            }
            .monitorBackground("bg", every: 0.03) {
                await BgSource.shared.next()
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        let trace = record.phases[0].traces["bg"]
        XCTAssertNotNil(trace)
        XCTAssertGreaterThanOrEqual(trace?.samples.count ?? 0, 2)
    }

    // MARK: - macOS 13 Duration 重载

    func testDurationOverloadCollectsSamples() async throws {
        guard #available(macOS 13, *) else {
            throw XCTSkip("Duration overload requires macOS 13")
        }
        let counter = SharedCounter()
        let plan = TestPlan(name: "monitor-duration") {
            Phase(name: "soak") { @MainActor _ in
                try await Task.sleep(for: .milliseconds(200))
                return .continue
            }
            .monitor("ticks", unit: "n", every: .milliseconds(40)) { @MainActor _ in
                await counter.next()
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        let trace = record.phases[0].traces["ticks"]
        XCTAssertNotNil(trace)
        XCTAssertGreaterThanOrEqual(trace?.samples.count ?? 0, 2)
    }

    /// macOS 13+ Clock 路径：sample 闭包人为慢一点，仍应在固定 grid 上 tick，
    /// 累计漂移远小于"相对睡眠"路径。
    func testClockPathIsDriftFree() async throws {
        guard #available(macOS 13, *) else {
            throw XCTSkip("Clock drift assertion only valid on macOS 13+")
        }
        let plan = TestPlan(name: "monitor-drift") {
            Phase(name: "soak") { @MainActor _ in
                try await Task.sleep(for: .milliseconds(500))
                return .continue
            }
            .monitor("v", every: .milliseconds(50)) { @MainActor _ in
                // sample 自己睡 10ms，相对睡眠路径上会累积 ~10ms × N 的漂移
                try await Task.sleep(for: .milliseconds(10))
                return 1.0
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        let elapseds = record.phases[0].traces["v"]?.samples.compactMap { $0.first?.asDouble } ?? []
        XCTAssertGreaterThanOrEqual(elapseds.count, 5)
        // 第 5 个采样的 elapsed 应当接近 4 × 0.050s = 0.20s（首样在 sample 完成后写入，所以 ≈ period * (index)）
        // 容忍 100ms 调度抖动 —— 重点是验证整体不会因 sample 耗时累计漂移过大。
        if elapseds.count >= 5 {
            XCTAssertLessThan(elapseds[4], 0.40, "Clock 路径应避免显著累计漂移")
        }
    }

    // MARK: - 多 monitor 互不阻塞

    func testMultipleMonitorsIndependent() async {
        let a = SharedCounter()
        let b = SharedCounter()
        let plan = TestPlan(name: "monitor-multi") {
            Phase(name: "soak") { @MainActor _ in
                try await Task.sleep(nanoseconds: 200_000_000)
                return .continue
            }
            .monitor("a", every: 0.03) { @MainActor _ in await a.next() }
            .monitor("b", every: 0.05) { @MainActor _ in await b.next() }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        let aCount = record.phases[0].traces["a"]?.samples.count ?? 0
        let bCount = record.phases[0].traces["b"]?.samples.count ?? 0
        XCTAssertGreaterThanOrEqual(aCount, 2)
        XCTAssertGreaterThanOrEqual(bCount, 2)
        XCTAssertGreaterThan(aCount, bCount, "周期 30ms 的 monitor 应快于 50ms 的")
    }
}

// MARK: - Test helpers

private enum MonitorTestError: Error { case boom }

/// 递增计数器，作为采样源。actor 化以允许 MainActor / 后台 sampler 均可 await。
private actor SharedCounter {
    private var n: Double = 0
    var value: Double {
        n
    }

    func next() -> Double {
        n += 1
        return n
    }
}

/// 后台采样源：actor 化的共享单例，模拟典型的 `await psu.readVoltage()` 调用。
private actor BgSource {
    static let shared = BgSource()
    private var n: Double = 0
    func next() -> Double {
        n += 1
        return n
    }
}
