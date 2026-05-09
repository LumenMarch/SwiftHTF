import XCTest
@testable import SwiftHTF

final class FailureExceptionsTests: XCTestCase {

    private struct DUTRefusedToBoot: Error {}
    private struct UnexpectedCrash: Error {}

    func testWhitelistedExceptionMappedToFail() async {
        let plan = TestPlan(name: "fail_exc") {
            Phase(
                name: "boot",
                failureExceptions: [DUTRefusedToBoot.self]
            ) { _ in throw DUTRefusedToBoot() }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases.first?.outcome, .fail, "白名单异常应映射为 .fail")
        XCTAssertEqual(record.outcome, .fail)
    }

    func testNonWhitelistedExceptionStaysError() async {
        let plan = TestPlan(name: "err_exc") {
            Phase(
                name: "boot",
                failureExceptions: [DUTRefusedToBoot.self]
            ) { _ in throw UnexpectedCrash() }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases.first?.outcome, .error, "白名单外异常仍是 .error")
    }

    func testEmptyWhitelistKeepsLegacyErrorBehavior() async {
        struct E: Error {}
        let plan = TestPlan(name: "legacy") {
            Phase(name: "boom") { _ in throw E() }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases.first?.outcome, .error)
    }

    func testRetryStillTriggeredBeforeFailMapping() async {
        actor Counter { var n = 0; func inc() -> Int { n += 1; return n } }
        let counter = Counter()
        let plan = TestPlan(name: "retry_then_fail") {
            Phase(
                name: "boot",
                retryCount: 2,
                failureExceptions: [DUTRefusedToBoot.self]
            ) { _ in
                _ = await counter.inc()
                throw DUTRefusedToBoot()
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        let attempts = await counter.n
        XCTAssertEqual(attempts, 3, "1 + retryCount=2 = 3 次")
        XCTAssertEqual(record.phases.first?.outcome, .fail, "用尽 retry 后按白名单分流为 .fail")
    }

    func testExactTypeMatchOnly() async {
        // 父类型 / 协议匹配应算外（精确类型）
        struct Specific: Error {}
        struct Different: Error {}
        let plan = TestPlan(name: "exact") {
            Phase(
                name: "x",
                failureExceptions: [Specific.self]
            ) { _ in throw Different() }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases.first?.outcome, .error)
    }

    func testMultipleWhitelistedTypes() async {
        struct A: Error {}
        struct B: Error {}
        let plan = TestPlan(name: "multi", continueOnFail: true) {
            Phase(name: "p1", failureExceptions: [A.self, B.self]) { _ in throw A() }
            Phase(name: "p2", failureExceptions: [A.self, B.self]) { _ in throw B() }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases.map(\.outcome), [.fail, .fail])
    }
}
