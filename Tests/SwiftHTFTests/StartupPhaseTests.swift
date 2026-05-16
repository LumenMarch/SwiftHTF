@testable import SwiftHTF
import XCTest

/// `TestPlan.startup` 启动门控 phase（OpenHTF `test_start` 等价物）的行为契约。
///
/// 覆盖：
/// - startup 改写 `ctx.serialNumber` → 回填进 `record.serialNumber`
/// - `.stop` → `.aborted`，主体不跑，teardown 仍跑
/// - 抛异常 → `record.outcome = .fail`（PhaseRecord.outcome=.error），主体不跑
/// - `.failAndContinue` → `record.outcome = .fail`，主体不跑
/// - `runIf=false` → 当作无 startup，主体放行，不写 SkipRecord、不发 `serialNumberResolved`
/// - 无 startup → 现状不变（兼容性）
/// - PhaseRecord.groupPath = `["__startup__"]`
/// - 事件流含 `serialNumberResolved` 且携带最终 serial
final class StartupPhaseTests: XCTestCase {
    func testStartupRewritesSerialNumber() async {
        let plan = TestPlan(
            name: "scan_sn",
            startup: Phase(name: "ScanSN") { @MainActor ctx in
                ctx.serialNumber = "SN-FROM-STARTUP"
                return .continue
            }
        ) {
            Phase(name: "main") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute(serialNumber: "SN-INITIAL")
        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.serialNumber, "SN-FROM-STARTUP")
        XCTAssertEqual(record.phases.count, 2)
        XCTAssertEqual(record.phases[0].name, "ScanSN")
        XCTAssertEqual(record.phases[0].groupPath, TestSession.startupGroupPath)
        XCTAssertEqual(record.phases[1].name, "main")
        XCTAssertEqual(record.phases[1].groupPath, [])
    }

    func testStartupStopAbortsAndSkipsMainButRunsTeardown() async {
        let teardownRan = Counter()
        let plan = TestPlan(
            name: "scan_cancel",
            startup: Phase(name: "ScanSN") { _ in .stop },
            teardown: [
                Phase(name: "td") { @MainActor _ in
                    teardownRan.bump()
                    return .continue
                },
            ]
        ) {
            Phase(name: "main") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .aborted)
        // 主体不跑：只剩 startup + teardown
        XCTAssertEqual(record.phases.map(\.name), ["ScanSN", "td"])
        XCTAssertEqual(teardownRan.value, 1)
    }

    func testStartupThrowingMakesRecordFailAndSkipsMain() async {
        struct ScanError: Error {}
        let plan = TestPlan(
            name: "scan_throws",
            startup: Phase(name: "ScanSN") { _ in throw ScanError() }
        ) {
            Phase(name: "main") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .fail)
        XCTAssertEqual(record.phases.count, 1)
        XCTAssertEqual(record.phases[0].name, "ScanSN")
        XCTAssertEqual(record.phases[0].outcome, .error)
    }

    func testStartupFailAndContinueMakesRecordFail() async {
        let plan = TestPlan(
            name: "scan_fail",
            startup: Phase(name: "ScanSN") { _ in .failAndContinue }
        ) {
            Phase(name: "main") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .fail)
        XCTAssertEqual(record.phases.count, 1)
        XCTAssertEqual(record.phases[0].outcome, .fail)
    }

    func testStartupRunIfFalseSkipsStartupEntirely() async {
        let plan = TestPlan(
            name: "scan_gated",
            startup: Phase(
                name: "ScanSN",
                runIf: { _ in false }
            ) { _ in .continue }
        ) {
            Phase(name: "main") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)

        // 订阅事件，确认不发 serialNumberResolved
        let events = Events()
        let stream = await executor.events()
        let listener = Task {
            for await ev in stream {
                if case let .serialNumberResolved(sn) = ev {
                    await events.markResolved(sn)
                }
                if case .testCompleted = ev { return }
            }
        }

        let record = await executor.execute()
        _ = await listener.value

        XCTAssertEqual(record.outcome, .pass)
        // runIf=false → 不写 SkipRecord，主体单独跑
        XCTAssertEqual(record.phases.count, 1)
        XCTAssertEqual(record.phases[0].name, "main")
        let resolved = await events.resolvedCalled
        XCTAssertFalse(resolved, "runIf=false 时不应发 serialNumberResolved 事件")
    }

    func testNoStartupKeepsExistingBehavior() async {
        let plan = TestPlan(name: "no_startup") {
            Phase(name: "main") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute(serialNumber: "SN-A")
        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.serialNumber, "SN-A")
        XCTAssertEqual(record.phases.count, 1)
        XCTAssertEqual(record.phases[0].name, "main")
    }

    func testSerialNumberResolvedEventCarriesFinalSerial() async {
        let plan = TestPlan(
            name: "scan_emit",
            startup: Phase(name: "ScanSN") { @MainActor ctx in
                ctx.serialNumber = "SN-NEW"
                return .continue
            }
        ) {
            Phase(name: "main") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let events = Events()
        let stream = await executor.events()
        let listener = Task {
            for await ev in stream {
                if case let .serialNumberResolved(sn) = ev {
                    await events.markResolved(sn)
                }
                if case .testCompleted = ev { return }
            }
        }
        _ = await executor.execute(serialNumber: "SN-OLD")
        _ = await listener.value

        let resolved = await events.resolvedCalled
        let resolvedSN = await events.resolvedSN
        XCTAssertTrue(resolved)
        XCTAssertEqual(resolvedSN, "SN-NEW")
    }
}

// MARK: - 测试辅助

private final class Counter: @unchecked Sendable {
    private var n: Int = 0
    private let lock = NSLock()
    func bump() {
        lock.lock(); defer { lock.unlock() }
        n += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return n
    }
}

/// actor 化的事件断言收集器
private actor Events {
    private(set) var resolvedCalled: Bool = false
    private(set) var resolvedSN: String?
    func markResolved(_ sn: String?) {
        resolvedCalled = true
        resolvedSN = sn
    }
}
