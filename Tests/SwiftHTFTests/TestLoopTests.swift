@testable import SwiftHTF
import XCTest

final class TestLoopTests: XCTestCase {
    private func simplePlan() -> TestPlan {
        TestPlan(name: "Loop") {
            Phase(name: "p") { @MainActor _ in .continue }
        }
    }

    func testTriggerSequenceProducesRecords() async {
        // trigger 返回有限序列，跑完应自然停止
        actor SerialFeed {
            var queue: [String] = ["A", "B", "C"]
            func next() -> String? {
                guard !queue.isEmpty else { return nil }
                return queue.removeFirst()
            }
        }
        let feed = SerialFeed()

        actor RecordSink {
            var records: [TestRecord] = []
            func add(_ r: TestRecord) {
                records.append(r)
            }

            func snapshot() -> [TestRecord] {
                records
            }
        }
        let sink = RecordSink()

        let executor = TestExecutor(plan: simplePlan())
        let loop = TestLoop(
            executor: executor,
            trigger: { await feed.next() },
            onCompleted: { await sink.add($0) }
        )
        await loop.start()
        await loop.wait()

        let recs = await sink.snapshot()
        XCTAssertEqual(recs.count, 3)
        XCTAssertEqual(recs.map(\.serialNumber), ["A", "B", "C"])
        let count = await loop.completedCount
        XCTAssertEqual(count, 3)
        let state = await loop.currentState
        XCTAssertEqual(state, .stopped)
    }

    func testStopMidTriggerExits() async {
        // trigger 永远等；stop 应中断
        let executor = TestExecutor(plan: simplePlan())
        let loop = TestLoop(
            executor: executor,
            trigger: {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
        )
        await loop.start()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await loop.stop()
        await loop.wait()
        let state = await loop.currentState
        XCTAssertEqual(state, .stopped)
    }

    func testStateStreamReplaysHistory() async {
        actor Feed { var i = 0; func next() -> String? {
            i += 1; return i <= 1 ? "X" : nil
        } }
        let feed = Feed()
        let executor = TestExecutor(plan: simplePlan())
        let loop = TestLoop(executor: executor, trigger: { await feed.next() })

        await loop.start()
        await loop.wait() // 已 stop

        // 订阅在 loop 完成之后，应能拿到完整历史
        var seen: [TestLoop.State] = []
        for await s in await loop.states() {
            seen.append(s)
        }
        XCTAssertTrue(seen.contains(.idle))
        XCTAssertTrue(seen.contains(.awaitingTrigger))
        XCTAssertTrue(seen.contains(where: {
            if case let .running(sn) = $0 { return sn == "X" }
            return false
        }))
        XCTAssertEqual(seen.last, .stopped)
    }

    func testOnCompletedReceivesEachRecord() async {
        actor Feed { var i = 0; func next() -> String? {
            i += 1; return i <= 2 ? "S\(i)" : nil
        } }
        let feed = Feed()
        actor Counter { var n = 0; var sns: [String?] = []; func add(_ r: TestRecord) {
            n += 1; sns.append(r.serialNumber)
        } }
        let counter = Counter()

        let executor = TestExecutor(plan: simplePlan())
        let loop = TestLoop(
            executor: executor,
            trigger: { await feed.next() },
            onCompleted: { await counter.add($0) }
        )
        await loop.start()
        await loop.wait()

        let n = await counter.n
        let sns = await counter.sns
        XCTAssertEqual(n, 2)
        XCTAssertEqual(sns, ["S1", "S2"])
    }

    func testStartIsIdempotent() async {
        actor Feed { var i = 0; func next() -> String? {
            i += 1; return i == 1 ? "Z" : nil
        } }
        let feed = Feed()
        let executor = TestExecutor(plan: simplePlan())
        let loop = TestLoop(executor: executor, trigger: { await feed.next() })
        await loop.start()
        await loop.start()
        await loop.start()
        await loop.wait()
        let n = await loop.completedCount
        XCTAssertEqual(n, 1, "重复 start 不应启动多个内部 task")
    }
}
