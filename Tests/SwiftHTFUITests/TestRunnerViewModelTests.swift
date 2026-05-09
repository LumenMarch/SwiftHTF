import SwiftHTF
@testable import SwiftHTFUI
import XCTest

@MainActor
final class TestRunnerViewModelTests: XCTestCase {
    func testStartCollectsPhasesAndOutcome() async throws {
        let plan = TestPlan(name: "ui_simple") {
            Phase(name: "a") { _ in .continue }
            Phase(name: "b") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let vm = TestRunnerViewModel(executor: executor)

        vm.start()
        try await waitUntil { !vm.isRunning && vm.outcome != nil }

        XCTAssertEqual(vm.outcome, .pass)
        XCTAssertEqual(vm.phases.count, 2)
        XCTAssertEqual(vm.phases.map(\.name), ["a", "b"])
        XCTAssertEqual(vm.planName, "ui_simple")
    }

    func testStartCapturesLogLines() async throws {
        let plan = TestPlan(name: "logs") {
            Phase(name: "x") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let vm = TestRunnerViewModel(executor: executor, logCapacity: 50)

        vm.start()
        try await waitUntil { !vm.isRunning }

        XCTAssertFalse(vm.logLines.isEmpty)
        XCTAssertTrue(vm.logLines.contains { $0.contains("[x]") })
    }

    func testLogCapacityRingBuffer() async throws {
        // 制造大量 log（用 retry 触发多条 log）
        let plan = TestPlan(name: "ring") {
            Phase(name: "spam", retryCount: 5) { _ in .retry }
        }
        let executor = TestExecutor(plan: plan)
        let vm = TestRunnerViewModel(executor: executor, logCapacity: 3)

        vm.start()
        try await waitUntil { !vm.isRunning }

        XCTAssertLessThanOrEqual(vm.logLines.count, 3)
    }

    func testStartIgnoredWhenAlreadyRunning() async throws {
        let plan = TestPlan(name: "long") {
            Phase(name: "wait") { _ in
                try await Task.sleep(nanoseconds: 100_000_000)
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let vm = TestRunnerViewModel(executor: executor)

        vm.start()
        XCTAssertTrue(vm.isRunning)
        // 第二次调用应被忽略
        vm.start()
        try await waitUntil { !vm.isRunning }
        XCTAssertEqual(vm.phases.count, 1, "重入 start 不应导致额外 phase")
    }

    func testResetClearsState() async throws {
        let plan = TestPlan(name: "reset") {
            Phase(name: "x") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let vm = TestRunnerViewModel(executor: executor)

        vm.start()
        try await waitUntil { !vm.isRunning }
        XCTAssertFalse(vm.phases.isEmpty)

        vm.reset()
        XCTAssertTrue(vm.phases.isEmpty)
        XCTAssertNil(vm.outcome)
        XCTAssertNil(vm.record)
    }

    func testSerialNumberPropagatesFromCtx() async throws {
        let plan = TestPlan(name: "scan") {
            Phase(name: "scan") { @MainActor ctx in
                ctx.serialNumber = "SN-VM"
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let vm = TestRunnerViewModel(executor: executor)

        vm.start()
        try await waitUntil { !vm.isRunning && vm.record != nil }

        XCTAssertEqual(vm.serialNumber, "SN-VM")
        XCTAssertEqual(vm.record?.serialNumber, "SN-VM")
    }

    // MARK: - 工具

    private func waitUntil(timeout: TimeInterval = 2.0, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("timeout waiting for predicate")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
