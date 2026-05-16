@testable import SwiftHTF
import XCTest

final class TestExecutorTests: XCTestCase {
    // MARK: - 基础流程

    func testSimplePassPlan() async {
        let plan = TestPlan(name: "simple") {
            Phase(name: "a") { _ in .continue }
            Phase(name: "b") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.phases.count, 2)
        XCTAssertEqual(record.phases.map(\.outcome), [.pass, .pass])
    }

    func testThrowingPhaseFailsTest() async {
        struct E: Error {}
        let plan = TestPlan(name: "fail") {
            Phase(name: "boom") { _ in throw E() }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .fail)
        XCTAssertEqual(record.phases.first?.outcome, .error)
    }

    func testContinueOnFailRunsAllPhases() async {
        let plan = TestPlan(name: "cont", continueOnFail: true) {
            Phase(name: "a") { _ in .failAndContinue }
            Phase(name: "b") { _ in .continue }
            Phase(name: "c") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.phases.count, 3)
        XCTAssertEqual(record.outcome, .fail)
    }

    func testNoContinueOnFailStopsAfterFail() async {
        let plan = TestPlan(name: "stop") {
            Phase(name: "a") { _ in .failAndContinue }
            Phase(name: "b") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.phases.count, 1)
        XCTAssertEqual(record.outcome, .fail)
    }

    // MARK: - Setup / Teardown

    func testSetupFailureSkipsMainPhases() async {
        let setupPhases = [Phase(name: "setup_bad") { _ in .failAndContinue }]
        let plan = TestPlan(
            name: "setup",
            setup: setupPhases,
            teardown: nil
        ) {
            Phase(name: "main") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        // setup 失败应跳过 main
        XCTAssertFalse(record.phases.contains { $0.name == "main" })
        XCTAssertEqual(record.outcome, .fail)
    }

    func testTeardownAlwaysRunsAfterFailure() async {
        struct E: Error {}
        let teardownPhases = [Phase(name: "cleanup") { _ in .continue }]
        let plan = TestPlan(
            name: "td",
            setup: nil,
            teardown: teardownPhases
        ) {
            Phase(name: "main") { _ in throw E() }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertTrue(record.phases.contains { $0.name == "cleanup" })
    }

    // MARK: - 重试

    func testRetrySucceedsEventually() async {
        actor Counter {
            var count = 0
            func increment() -> Int {
                count += 1; return count
            }
        }
        let counter = Counter()
        let plan = TestPlan(name: "retry") {
            Phase(name: "flaky", retryCount: 2) { _ in
                let n = await counter.increment()
                return n < 3 ? .retry : .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.phases.first?.outcome, .pass)
    }

    // MARK: - 取消

    func testCancellation() async {
        let plan = TestPlan(name: "cancel") {
            Phase(name: "long") { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)

        let runTask = Task { await executor.execute() }
        // 给执行器一点启动时间
        try? await Task.sleep(nanoseconds: 100_000_000)
        await executor.cancel()
        let record = await runTask.value

        XCTAssertTrue(record.outcome == .aborted || record.outcome == .fail || record.outcome == .error)
        // 不应阻塞 5 秒
    }

    // MARK: - 事件流

    func testEventStream() async {
        let plan = TestPlan(name: "events") {
            Phase(name: "a") { _ in .continue }
            Phase(name: "b") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)

        actor Collector {
            var events: [String] = []
            func add(_ s: String) {
                events.append(s)
            }

            func snapshot() -> [String] {
                events
            }
        }
        let collector = Collector()

        let stream = await executor.events()
        let listener = Task {
            for await event in stream {
                switch event {
                case .testStarted: await collector.add("testStarted")
                case .serialNumberResolved: break
                case let .phaseCompleted(r): await collector.add("phase:\(r.name)")
                case .testCompleted: await collector.add("testCompleted")
                case .log: break
                }
            }
        }

        _ = await executor.execute()
        // 给监听器消费完
        try? await Task.sleep(nanoseconds: 100_000_000)
        listener.cancel()

        let events = await collector.snapshot()
        XCTAssertTrue(events.contains("testStarted"))
        XCTAssertTrue(events.contains("phase:a"))
        XCTAssertTrue(events.contains("phase:b"))
        XCTAssertTrue(events.contains("testCompleted"))
    }

    // MARK: - 类型化 Measurement

    func testTypedMeasurementsCollected() async {
        let plan = TestPlan(name: "measurements") {
            Phase(name: "vcc") { @MainActor ctx in
                ctx.measure("voltage", 3.3, unit: "V")
                ctx.measure("status", "OK")
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        let phaseRecord = record.phases.first
        XCTAssertEqual(phaseRecord?.measurements["voltage"]?.value.asDouble, 3.3)
        XCTAssertEqual(phaseRecord?.measurements["voltage"]?.unit, "V")
        XCTAssertEqual(phaseRecord?.measurements["status"]?.value.asString, "OK")
    }

    // MARK: - Serial number 回灌

    func testSerialNumberFromCtxIsPersisted() async {
        let plan = TestPlan(name: "scan") {
            Phase(name: "scan_sn") { @MainActor ctx in
                ctx.serialNumber = "SN-FROM-CTX"
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.serialNumber, "SN-FROM-CTX")
    }

    func testCtxSerialNumberOverridesInitialArg() async {
        let plan = TestPlan(name: "override") {
            Phase(name: "rescan") { @MainActor ctx in
                XCTAssertEqual(ctx.serialNumber, "SN-INIT")
                ctx.serialNumber = "SN-RESCANNED"
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute(serialNumber: "SN-INIT")
        XCTAssertEqual(record.serialNumber, "SN-RESCANNED")
    }

    func testSerialNumberStaysNilWhenUnset() async {
        let plan = TestPlan(name: "nil") {
            Phase(name: "noop") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertNil(record.serialNumber)
    }

    // MARK: - Codable record

    func testRecordEncodesToJSON() async throws {
        let plan = TestPlan(name: "json") {
            Phase(name: "x") { @MainActor ctx in
                ctx.measure("x", 42)
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        XCTAssertGreaterThan(data.count, 0)

        // 反向解码确保结构往返一致
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TestRecord.self, from: data)
        XCTAssertEqual(decoded.planName, "json")
        XCTAssertEqual(decoded.outcome, .pass)
        XCTAssertEqual(decoded.phases.count, 1)
    }
}
