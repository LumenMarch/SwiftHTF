@testable import SwiftHTF
import XCTest

final class TestDiagnoserTests: XCTestCase {
    // MARK: - 触发时机

    func testDiagnoserRunsOnPass() async {
        let diagnoser = ClosureTestDiagnoser("pass-noop") { _ in
            [Diagnosis(code: "ALWAYS", severity: .info, message: "ran")]
        }
        let plan = TestPlan(name: "pass", diagnosers: [diagnoser]) {
            Phase(name: "p") { _ in .continue }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.diagnoses.count, 1)
        XCTAssertEqual(record.diagnoses[0].code, "ALWAYS")
    }

    func testDiagnoserRunsOnFail() async {
        let diagnoser = ClosureTestDiagnoser("fail-detector") { record in
            guard record.outcome == .fail else { return [] }
            return [Diagnosis(code: "RUN_FAILED", severity: .error, message: "outcome=\(record.outcome.rawValue)")]
        }
        let plan = TestPlan(name: "fail", diagnosers: [diagnoser]) {
            Phase(name: "boom") { _ in .failAndContinue }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .fail)
        XCTAssertEqual(record.diagnoses.count, 1)
        XCTAssertEqual(record.diagnoses[0].code, "RUN_FAILED")
    }

    func testDiagnoserSelfSkipsOnPass() async {
        // diagnoser 自己看 outcome 决定是否 emit；这里 pass 不 emit
        let diagnoser = ClosureTestDiagnoser("only-on-fail") { record in
            guard record.outcome == .fail else { return [] }
            return [Diagnosis(code: "X", message: "x")]
        }
        let plan = TestPlan(name: "skip", diagnosers: [diagnoser]) {
            Phase(name: "ok") { _ in .continue }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertTrue(record.diagnoses.isEmpty)
    }

    // MARK: - 多 diagnoser 顺序

    func testMultipleDiagnosersAppendInOrder() async {
        let d1 = ClosureTestDiagnoser("d1") { _ in [Diagnosis(code: "D1", message: "1")] }
        let d2 = ClosureTestDiagnoser("d2") { _ in [Diagnosis(code: "D2", message: "2")] }
        let d3 = ClosureTestDiagnoser("d3") { _ in
            [Diagnosis(code: "D3a", message: "3a"), Diagnosis(code: "D3b", message: "3b")]
        }
        let plan = TestPlan(name: "ord", diagnosers: [d1, d2, d3]) {
            Phase(name: "p") { _ in .continue }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.diagnoses.map(\.code), ["D1", "D2", "D3a", "D3b"])
    }

    // MARK: - 读 record 全貌

    func testDiagnoserSeesAllPhaseRecords() async {
        let diagnoser = ClosureTestDiagnoser("aggregate") { record in
            let marginal = record.phases.filter { $0.outcome == .marginalPass }.count
            if marginal > 0 {
                let d = Diagnosis(
                    code: "MARGINAL_COUNT",
                    severity: .warning,
                    message: "\(marginal)",
                    details: ["count": .int(Int64(marginal))]
                )
                return [d]
            }
            return []
        }
        let plan = TestPlan(name: "agg", diagnosers: [diagnoser]) {
            Phase(name: "m1", measurements: [.named("v").marginalRange(3.0, 3.6).inRange(2.5, 4.0)]) { ctx in
                ctx.measure("v", 2.9)
                return .continue
            }
            Phase(name: "m2", measurements: [.named("v").marginalRange(3.0, 3.6).inRange(2.5, 4.0)]) { ctx in
                ctx.measure("v", 3.7)
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, TestOutcome.marginalPass)
        XCTAssertEqual(record.diagnoses.count, 1)
        XCTAssertEqual(record.diagnoses[0].code, "MARGINAL_COUNT")
        XCTAssertEqual(record.diagnoses[0].details["count"]?.asInt, 2)
    }

    // MARK: - Codable

    func testTestRecordCodableIncludesDiagnoses() async throws {
        let diagnoser = ClosureTestDiagnoser("codec") { _ in
            [Diagnosis(code: "CODEC", severity: .info, message: "msg")]
        }
        let plan = TestPlan(name: "codec", diagnosers: [diagnoser]) {
            Phase(name: "p") { _ in .continue }
        }
        let record = await TestExecutor(plan: plan).execute()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TestRecord.self, from: data)
        XCTAssertEqual(decoded.diagnoses.count, 1)
        XCTAssertEqual(decoded.diagnoses[0].code, "CODEC")
    }

    func testLegacyJSONWithoutDiagnosesDecodes() throws {
        let legacy = Data("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "planName": "legacy",
          "startTime": "2026-01-01T00:00:00Z",
          "outcome": "PASS",
          "phases": [],
          "metadata": {}
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(TestRecord.self, from: legacy)
        XCTAssertTrue(record.diagnoses.isEmpty)
    }

    // MARK: - 与 PhaseDiagnoser 共存

    func testTestAndPhaseDiagnosersBothFire() async {
        let phaseD = ClosureDiagnoser("phase-d") { _, _ in
            [Diagnosis(code: "PHASE", message: "p")]
        }
        let testD = ClosureTestDiagnoser("test-d") { _ in
            [Diagnosis(code: "TEST", message: "t")]
        }
        let plan = TestPlan(name: "both", diagnosers: [testD]) {
            Phase(name: "boom", diagnosers: [phaseD]) { _ in .failAndContinue }
        }
        let record = await TestExecutor(plan: plan).execute()
        // phase-level：在 PhaseRecord.diagnoses
        XCTAssertEqual(record.phases[0].diagnoses.map(\.code), ["PHASE"])
        // test-level：在 TestRecord.diagnoses
        XCTAssertEqual(record.diagnoses.map(\.code), ["TEST"])
    }
}
