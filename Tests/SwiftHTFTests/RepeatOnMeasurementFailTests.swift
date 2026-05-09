@testable import SwiftHTF
import XCTest

@MainActor
final class RepeatOnMeasurementFailTests: XCTestCase {
    /// 计数器辅助
    private actor Counter {
        var count = 0
        func increment() -> Int {
            count += 1; return count
        }

        func value() -> Int {
            count
        }
    }

    func testRepeatsAndEventuallyPasses() async {
        let counter = Counter()
        let plan = TestPlan(name: "mfail_pass") {
            Phase(
                name: "vcc",
                measurements: [.named("vcc", unit: "V").inRange(3.0, 3.6)],
                repeatOnMeasurementFail: 3
            ) { @MainActor ctx in
                let n = await counter.increment()
                // 前两次写超限值；第三次写合法值
                let v = n < 3 ? 5.0 : 3.3
                ctx.measure("vcc", v, unit: "V")
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        let attempts = await counter.value()
        XCTAssertEqual(attempts, 3, "前两次失败 → 重跑两次 → 第三次通过")
        XCTAssertEqual(record.outcome, .pass)
        let phase = record.phases.first
        XCTAssertEqual(phase?.outcome, .pass)
        XCTAssertEqual(phase?.measurements["vcc"]?.outcome, .pass)
    }

    func testQuotaExhaustedKeepsFail() async {
        let counter = Counter()
        let plan = TestPlan(name: "mfail_exhaust") {
            Phase(
                name: "vcc",
                measurements: [.named("vcc", unit: "V").inRange(3.0, 3.6)],
                repeatOnMeasurementFail: 2
            ) { @MainActor ctx in
                _ = await counter.increment()
                ctx.measure("vcc", 9.9, unit: "V") // 永远超限
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        let attempts = await counter.value()
        XCTAssertEqual(attempts, 3, "1 次首跑 + 2 次重跑 = 3")
        XCTAssertEqual(record.outcome, .fail)
        XCTAssertEqual(record.phases.first?.outcome, .fail)
        XCTAssertEqual(record.phases.first?.measurements["vcc"]?.outcome, .fail)
    }

    func testZeroQuotaMeansSingleAttempt() async {
        let counter = Counter()
        let plan = TestPlan(name: "no_repeat") {
            Phase(
                name: "vcc",
                measurements: [.named("vcc", unit: "V").inRange(3.0, 3.6)],
                repeatOnMeasurementFail: 0
            ) { @MainActor ctx in
                _ = await counter.increment()
                ctx.measure("vcc", 9.9)
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        let attempts = await counter.value()
        XCTAssertEqual(attempts, 1, "默认 0 配额：measurement fail 立即终止")
        XCTAssertEqual(record.outcome, .fail)
    }

    func testMeasurementRepeatIndependentFromRetryCount() async {
        // phase 内：第一次 throw（消耗 retryCount），第二次写超限（消耗 measurement-repeat），
        // 第三次写合法值通过。两套计数器互不干扰。
        struct E: Error {}
        let counter = Counter()
        let plan = TestPlan(name: "mixed") {
            Phase(
                name: "vcc",
                retryCount: 1,
                measurements: [.named("vcc", unit: "V").inRange(3.0, 3.6)],
                repeatOnMeasurementFail: 2
            ) { @MainActor ctx in
                let n = await counter.increment()
                if n == 1 { throw E() }
                let v = n == 2 ? 9.9 : 3.3
                ctx.measure("vcc", v, unit: "V")
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        let attempts = await counter.value()
        XCTAssertEqual(attempts, 3, "1 throw → retryCount 消耗 1；2 measurement fail → repeat 消耗 1；3 pass")
        XCTAssertEqual(record.outcome, .pass)
    }

    func testCtxMeasurementsClearedBetweenRepeats() async {
        let counter = Counter()
        let plan = TestPlan(name: "clear") {
            Phase(
                name: "vcc",
                measurements: [.named("vcc", unit: "V").inRange(3.0, 3.6)],
                repeatOnMeasurementFail: 1
            ) { @MainActor ctx in
                let n = await counter.increment()
                // 第一次：写一个超限的 vcc + 一个 attachment
                // 重跑前：harvest 已清 ctx.measurements / ctx.attachments，所以这一段读出来应该是空
                XCTAssertTrue(ctx.measurements.isEmpty, "进 phase 时 ctx.measurements 必须为空")
                XCTAssertTrue(ctx.attachments.isEmpty, "进 phase 时 ctx.attachments 必须为空")
                if n == 1 {
                    ctx.measure("vcc", 9.9, unit: "V")
                    ctx.attach("trace", data: Data([0x01]), mimeType: "application/octet-stream")
                } else {
                    ctx.measure("vcc", 3.3, unit: "V")
                }
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        // 第二次跑没附件，最终 record 不应保留旧的 trace
        XCTAssertEqual(record.phases.first?.attachments.count, 0)
    }

    func testPhaseFailViaThrowDoesNotTriggerMeasurementRepeat() async {
        struct E: Error {}
        let counter = Counter()
        let plan = TestPlan(name: "exception") {
            Phase(
                name: "vcc",
                retryCount: 0,
                measurements: [.named("vcc", unit: "V").inRange(3.0, 3.6)],
                repeatOnMeasurementFail: 5
            ) { _ in
                _ = await counter.increment()
                throw E()
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        let attempts = await counter.value()
        XCTAssertEqual(attempts, 1, "throw 走 retryCount 路径，不应触发 measurement-repeat")
        XCTAssertEqual(record.outcome, .fail)
        XCTAssertEqual(record.phases.first?.outcome, .error)
    }
}
