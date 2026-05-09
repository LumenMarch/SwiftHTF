@testable import SwiftHTF
import XCTest

final class DiagnosticsTests: XCTestCase {
    // MARK: - 触发时机

    func testDiagnoserRunsOnFail() async {
        let plan = TestPlan(name: "fail_diag", continueOnFail: true) {
            Phase(
                name: "bad",
                diagnosers: [
                    ClosureDiagnoser("d1") { _, _ in
                        [Diagnosis(code: "E_BAD", message: "explicit fail")]
                    },
                ]
            ) { _ in .failAndContinue }
        }
        let record = await TestExecutor(plan: plan).execute()
        let phase = record.phases.first
        XCTAssertEqual(phase?.outcome, .fail)
        XCTAssertEqual(phase?.diagnoses.first?.code, "E_BAD")
    }

    func testDiagnoserRunsOnError() async {
        struct E: Error {}
        let plan = TestPlan(name: "err_diag") {
            Phase(
                name: "boom",
                diagnosers: [
                    ClosureDiagnoser("d1") { record, _ in
                        [Diagnosis(code: "E_THROW", message: record.errorMessage ?? "?")]
                    },
                ]
            ) { _ in throw E() }
        }
        let record = await TestExecutor(plan: plan).execute()
        let phase = record.phases.first
        XCTAssertEqual(phase?.outcome, .error)
        XCTAssertEqual(phase?.diagnoses.first?.code, "E_THROW")
    }

    func testDiagnoserSkippedOnPass() async {
        actor Counter { var hit = 0; func inc() {
            hit += 1
        }; func value() -> Int {
            hit
        } }
        let counter = Counter()
        let plan = TestPlan(name: "pass_diag") {
            Phase(
                name: "good",
                diagnosers: [
                    ClosureDiagnoser("d1") { _, _ in
                        await counter.inc()
                        return [Diagnosis(code: "X", message: "x")]
                    },
                ]
            ) { _ in .continue }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases.first?.outcome, .pass)
        XCTAssertTrue(record.phases.first?.diagnoses.isEmpty ?? false)
        let hits = await counter.value()
        XCTAssertEqual(hits, 0, "pass 时 diagnoser 不应被调用")
    }

    func testDiagnoserSkippedOnSkip() async {
        actor Counter { var hit = 0; func inc() {
            hit += 1
        }; func value() -> Int {
            hit
        } }
        let counter = Counter()
        let plan = TestPlan(name: "skip_diag") {
            Phase(
                name: "skipped",
                runIf: { _ in false },
                diagnosers: [
                    ClosureDiagnoser("d1") { _, _ in
                        await counter.inc()
                        return [Diagnosis(code: "X", message: "x")]
                    },
                ]
            ) { _ in .continue }
        }
        _ = await TestExecutor(plan: plan).execute()
        let hits = await counter.value()
        XCTAssertEqual(hits, 0, ".skip 路径不跑 diagnoser")
    }

    // MARK: - 多 diagnoser

    func testMultipleDiagnosersRunInOrder() async {
        let plan = TestPlan(name: "multi", continueOnFail: true) {
            Phase(
                name: "bad",
                diagnosers: [
                    ClosureDiagnoser("a") { _, _ in [Diagnosis(code: "A", message: "a")] },
                    ClosureDiagnoser("b") { _, _ in [Diagnosis(code: "B", message: "b")] },
                    ClosureDiagnoser("c") { _, _ in [Diagnosis(code: "C", message: "c")] },
                ]
            ) { _ in .failAndContinue }
        }
        let record = await TestExecutor(plan: plan).execute()
        let codes = record.phases.first?.diagnoses.map(\.code) ?? []
        XCTAssertEqual(codes, ["A", "B", "C"])
    }

    // MARK: - 副作用：写 attach / measure

    func testDiagnoserAttachAndMeasureFlowToRecord() async {
        let plan = TestPlan(name: "side_effect", continueOnFail: true) {
            Phase(
                name: "bad",
                diagnosers: [
                    ClosureDiagnoser("dump") { @MainActor record, ctx in
                        ctx.attach("trace.log", data: Data("dump".utf8), mimeType: "text/plain")
                        ctx.measure("retry_count", 3)
                        return [
                            Diagnosis(
                                code: "DUMP",
                                severity: .warning,
                                message: "trace dumped",
                                details: ["phase": .string(record.name)]
                            ),
                        ]
                    },
                ]
            ) { _ in .failAndContinue }
        }
        let record = await TestExecutor(plan: plan).execute()
        let phase = record.phases.first
        XCTAssertEqual(phase?.attachments.first?.name, "trace.log")
        XCTAssertEqual(phase?.measurements["retry_count"]?.value.asInt, 3)
        XCTAssertEqual(phase?.diagnoses.first?.severity, .warning)
        XCTAssertEqual(phase?.diagnoses.first?.details["phase"]?.asString, "bad")
    }

    // MARK: - 与 measurement-repeat 配合

    func testDiagnoserRunsAfterMeasurementRepeatExhaustion() async {
        actor Counter { var attempts = 0; var diagHits = 0
            func incAtt() {
                attempts += 1
            }

            func incDiag() {
                diagHits += 1
            }

            func snapshot() -> (Int, Int) {
                (attempts, diagHits)
            }
        }
        let counter = Counter()
        let plan = TestPlan(name: "repeat_then_diag", continueOnFail: true) {
            Phase(
                name: "vcc",
                measurements: [.named("vcc").inRange(0, 1)],
                repeatOnMeasurementFail: 2,
                diagnosers: [
                    ClosureDiagnoser("d") { _, _ in
                        await counter.incDiag()
                        return [Diagnosis(code: "VCC_OOR", message: "out of range")]
                    },
                ]
            ) { @MainActor ctx in
                await counter.incAtt()
                ctx.measure("vcc", 99.0)
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        let (att, diag) = await counter.snapshot()
        XCTAssertEqual(att, 3, "repeat 用尽：1 + 2 = 3 次跑")
        XCTAssertEqual(diag, 1, "diagnoser 仅在终态跑一次")
        XCTAssertEqual(record.phases.first?.diagnoses.first?.code, "VCC_OOR")
    }

    // MARK: - Codable 往返

    func testCodableRoundtrip() async throws {
        let plan = TestPlan(name: "codable", continueOnFail: true) {
            Phase(
                name: "bad",
                diagnosers: [
                    ClosureDiagnoser("x") { _, _ in
                        [
                            Diagnosis(
                                code: "E1",
                                severity: .critical,
                                message: "boom",
                                details: ["k": .int(7)]
                            ),
                        ]
                    },
                ]
            ) { _ in .failAndContinue }
        }
        let record = await TestExecutor(plan: plan).execute()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TestRecord.self, from: data)
        let d = decoded.phases.first?.diagnoses.first
        XCTAssertEqual(d?.code, "E1")
        XCTAssertEqual(d?.severity, .critical)
        XCTAssertEqual(d?.details["k"]?.asInt, 7)
    }
}
