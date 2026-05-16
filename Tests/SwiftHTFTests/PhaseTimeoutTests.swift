@testable import SwiftHTF
import XCTest

/// Phase 级 timeout：`.timeout(_:)` 修饰符 + `PhaseOutcomeType.timeout` 终态聚合。
final class PhaseTimeoutTests: XCTestCase {
    // MARK: - 修饰符等价

    func testTimeoutModifierEqualsInitParam() {
        let base = Phase(name: "p", timeout: nil) { _ in .continue }
        let decorated = base.timeout(0.5)
        XCTAssertEqual(decorated.definition.timeout, 0.5)
        XCTAssertEqual(decorated.definition.name, "p")
    }

    // MARK: - 超时 → outcome=.timeout

    func testPhaseTimesOutAndRecordsTimeoutOutcome() async {
        let plan = TestPlan(name: "to-basic") {
            Phase(name: "slow") { @MainActor _ in
                try await Task.sleep(nanoseconds: 300_000_000) // 300ms
                return .continue
            }
            .timeout(0.05)
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases[0].outcome, .timeout)
        // 全是 timeout（无 .fail/.error）→ record.outcome=.timeout
        XCTAssertEqual(record.outcome, .timeout)
    }

    // MARK: - timeout 仍消耗 retry 配额

    func testTimeoutHonorsRetry() async {
        let counter = AttemptCounter()
        let plan = TestPlan(name: "to-retry") {
            Phase(name: "flaky", retryCount: 1) { @MainActor _ in
                let n = await counter.tick()
                if n == 0 {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                return .continue
            }
            .timeout(0.05)
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.phases[0].outcome, .pass)
        let n = await counter.value
        XCTAssertEqual(n, 2, "首次超时后应消耗 1 次 retry 再跑一次")
    }

    // MARK: - timeout 与显式 fail 同时存在 → record .fail（混合优先 fail）

    func testMixedTimeoutAndFailRecordIsFail() async {
        let plan = TestPlan(name: "to-mixed", continueOnFail: true) {
            Phase(name: "fast-fail") { _ in .failAndContinue }
            Phase(name: "slow") { @MainActor _ in
                try await Task.sleep(nanoseconds: 200_000_000)
                return .continue
            }
            .timeout(0.05)
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .fail, "混合 .fail + .timeout 应优先 .fail，给出更明确失败信号")
        XCTAssertEqual(record.phases.count, 2)
        XCTAssertEqual(record.phases[1].outcome, .timeout)
    }

    // MARK: - timeout 不会被 failureExceptions 拐入 .fail

    func testTimeoutNotClassifiedAsFailureException() async {
        // 即便把 TestError 加进 failureExceptions，TestError.timeout 仍归 .timeout。
        let plan = TestPlan(name: "to-classify") {
            Phase(name: "slow", failureExceptions: [TestError.self]) { @MainActor _ in
                try await Task.sleep(nanoseconds: 200_000_000)
                return .continue
            }
            .timeout(0.05)
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases[0].outcome, .timeout)
    }

    // MARK: - macOS 13 Duration 重载

    func testTimeoutDurationOverload() async throws {
        guard #available(macOS 13, *) else {
            throw XCTSkip("Duration overload requires macOS 13")
        }
        let plan = TestPlan(name: "to-duration") {
            Phase(name: "slow") { @MainActor _ in
                try await Task.sleep(for: .milliseconds(200))
                return .continue
            }
            .timeout(.milliseconds(50))
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases[0].outcome, .timeout)
    }

    // MARK: - PhaseRecord Codable 仍能编解 .timeout

    func testPhaseRecordEncodesTimeoutOutcome() async throws {
        let plan = TestPlan(name: "to-codable") {
            Phase(name: "slow") { @MainActor _ in
                try await Task.sleep(nanoseconds: 200_000_000)
                return .continue
            }
            .timeout(0.05)
        }
        let record = await TestExecutor(plan: plan).execute()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TestRecord.self, from: data)
        XCTAssertEqual(decoded.outcome, .timeout)
        XCTAssertEqual(decoded.phases[0].outcome, .timeout)
    }
}

private actor AttemptCounter {
    private(set) var value: Int = 0
    func tick() -> Int {
        let n = value
        value += 1
        return n
    }
}
