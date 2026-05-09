@testable import SwiftHTF
import XCTest

final class HistoryStoreTests: XCTestCase {
    // MARK: - 帮手

    private func makeRecord(
        plan: String = "P",
        sn: String? = "SN-1",
        outcome: TestOutcome = .pass,
        startOffset: TimeInterval = 0
    ) -> TestRecord {
        var r = TestRecord(planName: plan, serialNumber: sn)
        r.outcome = outcome
        // 用反射不能改 let startTime；构造一个新 record 调整 endTime 即可
        r.endTime = r.startTime.addingTimeInterval(0.1 + startOffset)
        return r
    }

    // MARK: - InMemoryHistoryStore

    func testInMemorySaveAndLoad() async throws {
        let store = InMemoryHistoryStore()
        let r = makeRecord()
        try await store.save(r)
        let loaded = try await store.load(id: r.id)
        XCTAssertEqual(loaded?.id, r.id)
        XCTAssertEqual(loaded?.planName, "P")
    }

    func testInMemoryListByQuery() async throws {
        let store = InMemoryHistoryStore()
        try await store.save(makeRecord(plan: "A", sn: "SN-1", outcome: .pass))
        try await store.save(makeRecord(plan: "A", sn: "SN-2", outcome: .fail))
        try await store.save(makeRecord(plan: "B", sn: "SN-1", outcome: .pass))

        let allA = try await store.list(HistoryQuery(planName: "A"))
        XCTAssertEqual(allA.count, 2)

        let sn1 = try await store.list(HistoryQuery(serialNumber: "SN-1"))
        XCTAssertEqual(sn1.count, 2)

        let fails = try await store.list(HistoryQuery(outcomes: [.fail]))
        XCTAssertEqual(fails.count, 1)
        XCTAssertEqual(fails.first?.serialNumber, "SN-2")
    }

    func testInMemoryDeleteAndClear() async throws {
        let store = InMemoryHistoryStore()
        let r = makeRecord()
        try await store.save(r)
        try await store.delete(id: r.id)
        let loaded = try await store.load(id: r.id)
        XCTAssertNil(loaded)

        try await store.save(makeRecord())
        try await store.save(makeRecord(sn: "SN-2"))
        try await store.clear()
        let all = try await store.list(.all)
        XCTAssertEqual(all.count, 0)
    }

    func testInMemoryLimit() async throws {
        let store = InMemoryHistoryStore()
        for _ in 0 ..< 5 {
            try await store.save(makeRecord())
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let limited = try await store.list(HistoryQuery(limit: 2))
        XCTAssertEqual(limited.count, 2)
    }

    func testInMemorySortDescending() async throws {
        let store = InMemoryHistoryStore()
        var records: [TestRecord] = []
        for _ in 0 ..< 3 {
            let r = makeRecord()
            records.append(r)
            try await store.save(r)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let desc = try await store.list(HistoryQuery(sortDescending: true))
        XCTAssertEqual(desc.first?.id, records.last?.id)
        let asc = try await store.list(HistoryQuery(sortDescending: false))
        XCTAssertEqual(asc.first?.id, records.first?.id)
    }

    // MARK: - JSONFileHistoryStore

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftHTF-history-test-" + UUID().uuidString)
    }

    func testJSONFileRoundTrip() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try JSONFileHistoryStore(directory: dir)
        var r = makeRecord(plan: "Demo", sn: "ABC")
        var phase = PhaseRecord(name: "p")
        phase.outcome = .pass
        phase.measurements["v"] = Measurement(name: "v", value: .double(3.3), unit: "V")
        phase.logs.append(LogEntry(level: .info, message: "ok"))
        r.phases = [phase]

        try await store.save(r)
        let loaded = try await store.load(id: r.id)
        XCTAssertEqual(loaded?.serialNumber, "ABC")
        XCTAssertEqual(loaded?.phases.first?.measurements["v"]?.value.asDouble, 3.3)
        XCTAssertEqual(loaded?.phases.first?.logs.first?.message, "ok")
    }

    func testJSONFileListAndDelete() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try JSONFileHistoryStore(directory: dir)
        let r1 = makeRecord(sn: "A")
        let r2 = makeRecord(sn: "B", outcome: .fail)
        let r3 = makeRecord(sn: "B", outcome: .pass)
        try await store.save(r1); try await store.save(r2); try await store.save(r3)

        let all = try await store.list(.all)
        XCTAssertEqual(all.count, 3)
        let bs = try await store.list(HistoryQuery(serialNumber: "B"))
        XCTAssertEqual(bs.count, 2)
        let fails = try await store.list(HistoryQuery(outcomes: [.fail]))
        XCTAssertEqual(fails.count, 1)
        XCTAssertEqual(fails.first?.id, r2.id)

        try await store.delete(id: r2.id)
        let afterDel = try await store.list(.all)
        XCTAssertEqual(afterDel.count, 2)
    }

    func testJSONFileClear() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try JSONFileHistoryStore(directory: dir)
        try await store.save(makeRecord())
        try await store.save(makeRecord(sn: "B"))
        try await store.clear()
        let all = try await store.list(.all)
        XCTAssertEqual(all.count, 0)
    }

    func testJSONFileSinceUntilFilters() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try JSONFileHistoryStore(directory: dir)
        let cutoff = Date()
        try await store.save(makeRecord())
        try? await Task.sleep(nanoseconds: 30_000_000)
        try await store.save(makeRecord())

        let after = try await store.list(HistoryQuery(since: cutoff.addingTimeInterval(0.01)))
        XCTAssertEqual(after.count, 1, "since 之后只应有第二条")
    }

    // MARK: - 集成 TestExecutor 自动入库

    func testHistoryOutputCallbackAutoSavesRecords() async throws {
        let store = InMemoryHistoryStore()
        let callback = HistoryOutputCallback(store: store)
        let plan = TestPlan(name: "auto") {
            Phase(name: "p") { @MainActor _ in .continue }
        }
        let executor = TestExecutor(plan: plan, outputCallbacks: [callback])
        _ = await executor.execute(serialNumber: "SN-X")
        _ = await executor.execute(serialNumber: "SN-Y")

        let all = try await store.list(.all)
        XCTAssertEqual(all.count, 2)
        let xs = try await store.list(HistoryQuery(serialNumber: "SN-X"))
        XCTAssertEqual(xs.count, 1)
        XCTAssertEqual(xs.first?.outcome, .pass)
    }
}
