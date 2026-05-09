@testable import SwiftHTF
import XCTest

/// Per-phase logger 测试
final class PhaseLoggerTests: XCTestCase {
    func testCtxLogIsRecordedOnPhase() async {
        let plan = TestPlan(name: "logs") {
            Phase(name: "p") { @MainActor ctx in
                ctx.logInfo("step 1")
                ctx.logWarning("watch out")
                ctx.logError("boom")
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .pass)
        let logs = record.phases.first?.logs ?? []
        XCTAssertEqual(logs.count, 3)
        XCTAssertEqual(logs.map(\.level), [.info, .warning, .error])
        XCTAssertEqual(logs.map(\.message), ["step 1", "watch out", "boom"])
    }

    func testLogsAreEmittedOnEventStream() async {
        let plan = TestPlan(name: "events") {
            Phase(name: "p") { @MainActor ctx in
                ctx.logInfo("hello")
                ctx.logError("oops")
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)

        actor Sink {
            var msgs: [String] = []
            func add(_ m: String) {
                msgs.append(m)
            }

            func snapshot() -> [String] {
                msgs
            }
        }
        let sink = Sink()

        let listener = Task {
            for await event in await executor.events() {
                if case let .log(m) = event { await sink.add(m) }
                if case .testCompleted = event { return }
            }
        }
        _ = await executor.execute()
        await listener.value

        let lines = await sink.snapshot()
        XCTAssertTrue(lines.contains(where: { $0.contains("[INFO] hello") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("[ERROR] oops") }))
    }

    func testLogsAreClearedBetweenPhases() async {
        let plan = TestPlan(name: "isolated") {
            Phase(name: "a") { @MainActor ctx in
                ctx.logInfo("from-a")
                return .continue
            }
            Phase(name: "b") { @MainActor ctx in
                ctx.logInfo("from-b")
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.phases.count, 2)
        XCTAssertEqual(record.phases[0].logs.map(\.message), ["from-a"])
        XCTAssertEqual(record.phases[1].logs.map(\.message), ["from-b"])
    }

    func testRetryReplacesLogs() async {
        // retry：每次 attempt 起始重置 ctx.phaseLogs；最终 record.logs 仅含最后一次 attempt
        actor Counter { var n = 0; func incr() -> Int {
            n += 1; return n
        } }
        let counter = Counter()
        let plan = TestPlan(name: "retry") {
            Phase(name: "p", retryCount: 1) { @MainActor ctx in
                let attempt = await counter.incr()
                ctx.logInfo("attempt-\(attempt)")
                if attempt == 1 {
                    return .retry
                }
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .pass)
        let msgs = record.phases.first?.logs.map(\.message) ?? []
        XCTAssertEqual(msgs, ["attempt-2"], "retry 重置了 phaseLogs，仅保留最后一次 attempt 的日志")
    }

    func testLogEntryJSONRoundTrip() throws {
        var rec = PhaseRecord(name: "p")
        rec.logs.append(LogEntry(level: .info, message: "hello"))
        rec.logs.append(LogEntry(level: .warning, message: "uh"))
        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(PhaseRecord.self, from: data)
        XCTAssertEqual(decoded.logs.count, 2)
        XCTAssertEqual(decoded.logs[0].level, .info)
        XCTAssertEqual(decoded.logs[1].message, "uh")
    }

    func testDiagnoserLogsAreMergedAfterFail() async {
        let diag = ClosureDiagnoser("tail") { @MainActor _, ctx in
            ctx.logWarning("diag-warn")
            return [Diagnosis(code: "D-1", severity: .warning, message: "diagnoser ran")]
        }

        let plan = TestPlan(name: "diag-logs") {
            Phase(
                name: "p",
                diagnosers: [diag]
            ) { @MainActor ctx in
                ctx.logInfo("phase-info")
                return .failAndContinue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        let logs: [LogEntry] = record.phases.first?.logs ?? []
        XCTAssertEqual(logs.count, 2)
        XCTAssertEqual(logs.map(\.message), ["phase-info", "diag-warn"])
    }

    func testLogLevelOrdering() {
        XCTAssertLessThan(LogLevel.debug, LogLevel.info)
        XCTAssertLessThan(LogLevel.info, LogLevel.warning)
        XCTAssertLessThan(LogLevel.warning, LogLevel.error)
    }
}
