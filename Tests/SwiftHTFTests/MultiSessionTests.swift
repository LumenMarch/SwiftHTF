import XCTest
@testable import SwiftHTF

final class MultiSessionTests: XCTestCase {

    /// 简单 plug：每次 setup 计数
    actor SetupCounter {
        static let shared = SetupCounter()
        var setupCount = 0
        var tearDownCount = 0
        var maxConcurrent = 0
        var currentLive = 0
        func reset() { setupCount = 0; tearDownCount = 0; maxConcurrent = 0; currentLive = 0 }
        func didSetup() {
            setupCount += 1
            currentLive += 1
            if currentLive > maxConcurrent { maxConcurrent = currentLive }
        }
        func didTearDown() {
            tearDownCount += 1
            currentLive -= 1
        }
        func snapshot() -> (Int, Int, Int) { (setupCount, tearDownCount, maxConcurrent) }
    }

    final class CountingPlug: PlugProtocol, @unchecked Sendable {
        init() {}
        func setup() async throws {
            await SetupCounter.shared.didSetup()
        }
        func tearDown() async {
            await SetupCounter.shared.didTearDown()
        }
    }

    override func setUp() async throws {
        await SetupCounter.shared.reset()
    }

    func testTwoConcurrentSessionsEachHaveOwnPlugInstance() async throws {
        let plan = TestPlan(name: "concurrent") {
            Phase(name: "p") { _ in
                try await Task.sleep(nanoseconds: 50_000_000)
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        await executor.register(CountingPlug.self)

        async let s1 = executor.startSession(serialNumber: "DUT-1")
        async let s2 = executor.startSession(serialNumber: "DUT-2")
        let session1 = await s1
        let session2 = await s2

        async let r1 = session1.record()
        async let r2 = session2.record()
        let rec1 = await r1
        let rec2 = await r2

        XCTAssertEqual(rec1.outcome, .pass)
        XCTAssertEqual(rec2.outcome, .pass)
        XCTAssertEqual(rec1.serialNumber, "DUT-1")
        XCTAssertEqual(rec2.serialNumber, "DUT-2")

        let (setupCnt, tearDownCnt, maxConc) = await SetupCounter.shared.snapshot()
        XCTAssertEqual(setupCnt, 2, "两个 session 各自调用 setup 一次")
        XCTAssertEqual(tearDownCnt, 2)
        XCTAssertEqual(maxConc, 2, "两个 plug 实例应同时存在过")
    }

    func testIndependentEventStreams() async throws {
        let plan = TestPlan(name: "events") {
            Phase(name: "x") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)

        let session1 = await executor.startSession(serialNumber: "A")
        let session2 = await executor.startSession(serialNumber: "B")

        var sn1: String?
        var sn2: String?
        for await event in await session1.events() {
            if case .testStarted(_, let sn) = event { sn1 = sn }
        }
        for await event in await session2.events() {
            if case .testStarted(_, let sn) = event { sn2 = sn }
        }

        _ = await session1.record()
        _ = await session2.record()

        XCTAssertEqual(sn1, "A")
        XCTAssertEqual(sn2, "B")
    }

    func testExecuteIsBackwardCompatible() async {
        // 旧 API：execute(serialNumber:) 仍然可用
        let plan = TestPlan(name: "legacy") {
            Phase(name: "p") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute(serialNumber: "SN-OLD")
        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.serialNumber, "SN-OLD")
    }

    func testCancelAllSessions() async {
        let plan = TestPlan(name: "long") {
            Phase(name: "wait") { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let s1 = await executor.startSession(serialNumber: "A")
        let s2 = await executor.startSession(serialNumber: "B")

        try? await Task.sleep(nanoseconds: 100_000_000)
        await executor.cancel()

        let r1 = await s1.record()
        let r2 = await s2.record()
        XCTAssertTrue(r1.outcome == .aborted || r1.outcome == .fail || r1.outcome == .error)
        XCTAssertTrue(r2.outcome == .aborted || r2.outcome == .fail || r2.outcome == .error)
    }

    func testAggregateEventsAcrossSessions() async {
        let plan = TestPlan(name: "agg") {
            Phase(name: "x") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)

        actor Collector {
            var sns: Set<String> = []
            func add(_ s: String?) { if let s { sns.insert(s) } }
            func snapshot() -> Set<String> { sns }
        }
        let c = Collector()

        let listener = Task {
            for await event in await executor.events() {
                if case .testStarted(_, let sn) = event { await c.add(sn) }
            }
        }

        async let s1 = executor.startSession(serialNumber: "AA")
        async let s2 = executor.startSession(serialNumber: "BB")
        let session1 = await s1
        let session2 = await s2
        _ = await session1.record()
        _ = await session2.record()

        try? await Task.sleep(nanoseconds: 100_000_000)
        listener.cancel()

        let sns = await c.snapshot()
        XCTAssertTrue(sns.contains("AA"))
        XCTAssertTrue(sns.contains("BB"))
    }
}
