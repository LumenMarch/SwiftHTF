import XCTest
@testable import SwiftHTF

final class MeasurementValidatorTests: XCTestCase {

    // MARK: - 内置 validator 单元

    func testInRangeInclusive() {
        let v = InRangeValidator(lower: 3.0, upper: 3.6, inclusive: true)
        XCTAssertEqual(v.validate(.double(3.0)), .pass)
        XCTAssertEqual(v.validate(.double(3.6)), .pass)
        XCTAssertEqual(v.validate(.double(3.3)), .pass)
        if case .pass = v.validate(.double(2.9)) { XCTFail() }
        if case .pass = v.validate(.double(3.7)) { XCTFail() }
    }

    func testInRangeExclusive() {
        let v = InRangeValidator(lower: 3.0, upper: 3.6, inclusive: false)
        if case .pass = v.validate(.double(3.0)) { XCTFail("端点应不通过") }
        if case .pass = v.validate(.double(3.6)) { XCTFail("端点应不通过") }
        XCTAssertEqual(v.validate(.double(3.3)), .pass)
    }

    func testInRangeRejectsNonNumeric() {
        let v = InRangeValidator(lower: 0, upper: 1)
        if case .pass = v.validate(.string("x")) { XCTFail() }
        if case .pass = v.validate(.null) { XCTFail() }
    }

    func testEqualsValidator() {
        let v = EqualsValueValidator(expected: .string("OK"))
        XCTAssertEqual(v.validate(.string("OK")), .pass)
        if case .pass = v.validate(.string("NG")) { XCTFail() }

        let vi = EqualsValueValidator(expected: .int(42))
        XCTAssertEqual(vi.validate(.int(42)), .pass)
        if case .pass = vi.validate(.int(43)) { XCTFail() }
    }

    func testRegexValidator() {
        let v = RegexMeasurementValidator(pattern: "^SN-[0-9]{4}$")
        XCTAssertEqual(v.validate(.string("SN-1234")), .pass)
        if case .pass = v.validate(.string("SN-12")) { XCTFail() }
        if case .pass = v.validate(.int(1234)) { XCTFail("非字符串应不通过") }
    }

    func testWithinPercent() {
        let v = WithinPercentValidator(target: 100, percent: 5)
        XCTAssertEqual(v.validate(.double(95)), .pass)
        XCTAssertEqual(v.validate(.double(105)), .pass)
        if case .pass = v.validate(.double(94.9)) { XCTFail() }
        if case .pass = v.validate(.double(105.1)) { XCTFail() }
    }

    func testNotEmpty() {
        let v = NotEmptyMeasurementValidator()
        XCTAssertEqual(v.validate(.string("x")), .pass)
        if case .pass = v.validate(.string("")) { XCTFail() }
        if case .pass = v.validate(.string("  \n")) { XCTFail() }
        if case .pass = v.validate(.array([])) { XCTFail() }
        XCTAssertEqual(v.validate(.array([.int(1)])), .pass)
        if case .pass = v.validate(.null) { XCTFail() }
    }

    func testCustomValidator() {
        let v = CustomMeasurementValidator(label: "even") { value in
            guard let n = value.asInt else { return .fail("not int") }
            return n % 2 == 0 ? .pass : .fail("\(n) is odd")
        }
        XCTAssertEqual(v.validate(.int(4)), .pass)
        if case .pass = v.validate(.int(5)) { XCTFail() }
    }

    // MARK: - Builder 链 + spec.run

    func testBuilderChainAggregates() {
        let spec = MeasurementSpec.named("vcc", unit: "V")
            .inRange(3.0, 3.6)
            .withinPercent(of: 3.3, percent: 10)
        XCTAssertEqual(spec.validators.count, 2)
        let (v1, msgs) = spec.run(on: .double(3.3))
        if case .pass = v1 {} else { XCTFail("expected pass") }
        XCTAssertTrue(msgs.isEmpty)

        let (v2, msgs2) = spec.run(on: .double(2.5))
        if case .fail = v2 {} else { XCTFail("expected fail") }
        XCTAssertEqual(msgs2.count, 2, "两个 validator 都应报错")
    }

    // MARK: - 与 PhaseExecutor 集成（harvest 真的写回 outcome）

    func testHarvestWritesMeasurementOutcomePass() async {
        let plan = TestPlan(name: "harvest_pass") {
            Phase(
                name: "vcc",
                measurements: [
                    .named("vcc", unit: "V").inRange(3.0, 3.6)
                ]
            ) { @MainActor ctx in
                ctx.measure("vcc", 3.32, unit: "V")
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .pass)
        let m = record.phases.first?.measurements["vcc"]
        XCTAssertEqual(m?.outcome, .pass)
        XCTAssertTrue(m?.validatorMessages.isEmpty ?? false)
    }

    func testHarvestWritesMeasurementOutcomeFail() async {
        let plan = TestPlan(name: "harvest_fail") {
            Phase(
                name: "vcc",
                measurements: [
                    .named("vcc", unit: "V").inRange(3.0, 3.6)
                ]
            ) { @MainActor ctx in
                ctx.measure("vcc", 5.0, unit: "V")
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .fail, "measurement 失败应让 phase / record 升级为 fail")
        let phase = record.phases.first
        XCTAssertEqual(phase?.outcome, .fail)
        let m = phase?.measurements["vcc"]
        XCTAssertEqual(m?.outcome, .fail)
        XCTAssertEqual(m?.validatorMessages.count, 1)
    }

    func testUndeclaredMeasurementStaysPass() async {
        let plan = TestPlan(name: "undeclared") {
            Phase(name: "free") { @MainActor ctx in
                // 没有 spec，仍允许写入
                ctx.measure("note", "hello")
                ctx.measure("count", 7)
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .pass)
        let ms = record.phases.first?.measurements
        XCTAssertEqual(ms?["note"]?.outcome, .pass)
        XCTAssertEqual(ms?["count"]?.outcome, .pass)
    }

    func testMeasurementValidationCoexistsWithLegacyStringValidator() async {
        // 旧路径：phase.value 走 lowerLimit/upperLimit
        // 新路径：ctx.measure 走 spec
        let plan = TestPlan(name: "coexist") {
            Phase(
                name: "vcc",
                lowerLimit: "3.0",
                upperLimit: "3.6",
                unit: "V",
                measurements: [
                    .named("rail", unit: "V").inRange(0.0, 1.5)
                ]
            ) { @MainActor ctx in
                ctx.setValue("vcc", "3.3")        // 旧路径 -> pass
                ctx.measure("rail", 0.9, unit: "V") // 新路径 -> pass
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .pass)
        let phase = record.phases.first
        XCTAssertEqual(phase?.value, "3.3")
        XCTAssertEqual(phase?.measurements["rail"]?.outcome, .pass)
    }

    func testFailAndContinueDoesNotGetUpgradedAgain() async {
        // 已经是 .fail 的 phase（来自 .failAndContinue）即便 measurement 也失败也不会出错
        let plan = TestPlan(name: "double_fail", continueOnFail: true) {
            Phase(
                name: "x",
                measurements: [.named("y").inRange(0, 1)]
            ) { @MainActor ctx in
                ctx.measure("y", 99)
                return .failAndContinue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        let phase = record.phases.first
        XCTAssertEqual(phase?.outcome, .fail)
        XCTAssertEqual(phase?.measurements["y"]?.outcome, .fail)
    }

    func testSkippedPhaseKeepsSkipOutcomeEvenWithMeasurement() async {
        // .skip 优先级高于 measurement 失败升级
        let plan = TestPlan(name: "skip_guard") {
            Phase(
                name: "x",
                measurements: [.named("y").inRange(0, 1)]
            ) { @MainActor ctx in
                ctx.measure("y", 99)
                return .skip
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        let phase = record.phases.first
        XCTAssertEqual(phase?.outcome, .skip, ".skip 不应被 measurement fail 覆盖")
        // measurement 自身仍标 fail
        XCTAssertEqual(phase?.measurements["y"]?.outcome, .fail)
    }
}
