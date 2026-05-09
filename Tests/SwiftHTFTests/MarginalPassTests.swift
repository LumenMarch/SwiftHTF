import XCTest
@testable import SwiftHTF

final class MarginalPassTests: XCTestCase {

    // MARK: - MarginalRangeValidator 单元

    func testMarginalRangeInside() {
        let v = MarginalRangeValidator(lower: 3.1, upper: 3.5)
        XCTAssertEqual(v.validate(.double(3.3)), .pass)
        XCTAssertEqual(v.validate(.double(3.1)), .pass)
        XCTAssertEqual(v.validate(.double(3.5)), .pass)
    }

    func testMarginalRangeOutsideTriggersMarginal() {
        let v = MarginalRangeValidator(lower: 3.1, upper: 3.5)
        if case .marginal = v.validate(.double(3.05)) {} else { XCTFail("接近下限应 marginal") }
        if case .marginal = v.validate(.double(3.55)) {} else { XCTFail("接近上限应 marginal") }
    }

    func testMarginalRangeNonNumericIsPass() {
        let v = MarginalRangeValidator(lower: 0, upper: 1)
        XCTAssertEqual(v.validate(.string("x")), .pass, "非数字交给其他 validator，不强加 fail/marginal")
    }

    // MARK: - spec verdict 三态聚合

    func testSpecVerdictPass() {
        let spec = MeasurementSpec.named("v")
            .inRange(3.0, 3.6)
            .marginalRange(3.1, 3.5)
        let (verdict, msgs) = spec.run(on: .double(3.3))
        if case .pass = verdict {} else { XCTFail("expected pass, got \(verdict)") }
        XCTAssertTrue(msgs.isEmpty)
    }

    func testSpecVerdictMarginal() {
        let spec = MeasurementSpec.named("v")
            .inRange(3.0, 3.6)
            .marginalRange(3.1, 3.5)
        let (verdict, msgs) = spec.run(on: .double(3.05))
        if case .marginal = verdict {} else { XCTFail("expected marginal") }
        XCTAssertEqual(msgs.count, 1)
    }

    func testSpecVerdictFailHasPrecedenceOverMarginal() {
        let spec = MeasurementSpec.named("v")
            .inRange(3.0, 3.6)
            .marginalRange(3.1, 3.5)
        let (verdict, _) = spec.run(on: .double(2.5)) // 同时违反 hard 与 marginal
        if case .fail = verdict {} else { XCTFail("fail 应优先于 marginal") }
    }

    // MARK: - harvest 升级

    func testPhaseUpgradesToMarginalPass() async {
        let plan = TestPlan(name: "marginal_phase") {
            Phase(
                name: "vcc",
                measurements: [
                    .named("vcc", unit: "V")
                        .inRange(3.0, 3.6)
                        .marginalRange(3.1, 3.5)
                ]
            ) { @MainActor ctx in
                ctx.measure("vcc", 3.05, unit: "V")
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        let phase = record.phases.first
        XCTAssertEqual(phase?.outcome, .marginalPass)
        XCTAssertEqual(phase?.measurements["vcc"]?.outcome, .marginalPass)
    }

    func testRecordUpgradesToMarginalPass() async {
        let plan = TestPlan(name: "marginal_record") {
            Phase(
                name: "vcc",
                measurements: [
                    .named("vcc", unit: "V")
                        .inRange(3.0, 3.6)
                        .marginalRange(3.1, 3.5)
                ]
            ) { @MainActor ctx in
                ctx.measure("vcc", 3.05, unit: "V")
                return .continue
            }
            Phase(name: "after") { _ in .continue }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .marginalPass)
    }

    func testFailDominatesMarginalAtRecordLevel() async {
        let plan = TestPlan(name: "fail_wins", continueOnFail: true) {
            Phase(
                name: "marg",
                measurements: [.named("v").inRange(0, 10).marginalRange(2, 8)]
            ) { @MainActor ctx in
                ctx.measure("v", 1.0)
                return .continue
            }
            Phase(
                name: "bad",
                measurements: [.named("v").inRange(0, 10)]
            ) { @MainActor ctx in
                ctx.measure("v", 99.0)
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .fail, "含 fail 的整体 outcome 应是 fail，不是 marginalPass")
    }

    func testNoMarginalKeepsPass() async {
        let plan = TestPlan(name: "all_good") {
            Phase(
                name: "vcc",
                measurements: [
                    .named("vcc").inRange(3.0, 3.6).marginalRange(3.1, 3.5)
                ]
            ) { @MainActor ctx in
                ctx.measure("vcc", 3.3)
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
    }

    // MARK: - Codable 往返

    func testRecordCodableRoundtripPreservesMarginalPass() async throws {
        let plan = TestPlan(name: "codable") {
            Phase(
                name: "v",
                measurements: [.named("v").inRange(0, 10).marginalRange(2, 8)]
            ) { @MainActor ctx in
                ctx.measure("v", 1.0)
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TestRecord.self, from: data)
        XCTAssertEqual(decoded.outcome, .marginalPass)
        XCTAssertEqual(decoded.phases.first?.outcome, .marginalPass)
        XCTAssertEqual(decoded.phases.first?.measurements["v"]?.outcome, .marginalPass)
    }
}
