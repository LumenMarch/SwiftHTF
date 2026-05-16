@testable import SwiftHTF
import XCTest

/// `DiagnoserTrigger`：.always / .onlyOnFail 控制位，对
/// `PhaseDiagnoser` / `TestDiagnoser` 的过滤效果。
final class DiagnoserTriggerTests: XCTestCase {
    // MARK: - PhaseDiagnoser：默认 .onlyOnFail，pass 不跑

    func testPhaseDiagnoserDefaultOnlyOnFail() async {
        let probe = TriggerProbe()
        let plan = TestPlan(name: "pdef") {
            Phase(
                name: "ok",
                diagnosers: [
                    ClosureDiagnoser("p1") { _, _ in
                        await probe.tick()
                        return []
                    },
                ]
            ) { _ in .continue }
        }
        _ = await TestExecutor(plan: plan).execute()
        let n = await probe.count
        XCTAssertEqual(n, 0, "phase pass 时默认 diagnoser 不应触发")
    }

    func testPhaseDiagnoserAlwaysFiresOnPass() async {
        let probe = TriggerProbe()
        let plan = TestPlan(name: "palw") {
            Phase(
                name: "ok",
                diagnosers: [
                    ClosureDiagnoser("p1", trigger: .always) { _, _ in
                        await probe.tick()
                        return []
                    },
                ]
            ) { _ in .continue }
        }
        _ = await TestExecutor(plan: plan).execute()
        let n = await probe.count
        XCTAssertEqual(n, 1, "trigger=.always 时 pass 也应跑")
    }

    func testPhaseDiagnoserOnlyOnFailFiresOnTimeout() async {
        let probe = TriggerProbe()
        let plan = TestPlan(name: "ptmo") {
            Phase(
                name: "slow",
                diagnosers: [
                    ClosureDiagnoser("p1") { _, _ in
                        await probe.tick()
                        return []
                    },
                ]
            ) { @MainActor _ in
                try await Task.sleep(nanoseconds: 200_000_000)
                return .continue
            }
            .timeout(0.05)
        }
        _ = await TestExecutor(plan: plan).execute()
        let n = await probe.count
        XCTAssertEqual(n, 1, ".timeout 也属于失败族，应触发 .onlyOnFail diagnoser")
    }

    // MARK: - TestDiagnoser：默认 .always

    func testTestDiagnoserDefaultAlwaysFiresOnPass() async {
        let probe = TriggerProbe()
        let diag = ClosureTestDiagnoser("t1") { _ in
            await probe.tick()
            return []
        }
        let plan = TestPlan(name: "tdef", diagnosers: [diag]) {
            Phase(name: "ok") { _ in .continue }
        }
        _ = await TestExecutor(plan: plan).execute()
        let n = await probe.count
        XCTAssertEqual(n, 1, "TestDiagnoser 默认 .always，pass 也跑")
    }

    func testTestDiagnoserOnlyOnFailSkipsPass() async {
        let probe = TriggerProbe()
        let diag = ClosureTestDiagnoser("t1", trigger: .onlyOnFail) { _ in
            await probe.tick()
            return []
        }
        let plan = TestPlan(name: "tof", diagnosers: [diag]) {
            Phase(name: "ok") { _ in .continue }
        }
        _ = await TestExecutor(plan: plan).execute()
        let n = await probe.count
        XCTAssertEqual(n, 0, "trigger=.onlyOnFail 在 pass 终态不应跑")
    }

    func testTestDiagnoserOnlyOnFailFiresOnFail() async {
        let probe = TriggerProbe()
        let diag = ClosureTestDiagnoser("t1", trigger: .onlyOnFail) { _ in
            await probe.tick()
            return []
        }
        let plan = TestPlan(name: "tofF", diagnosers: [diag]) {
            Phase(name: "boom") { _ in .failAndContinue }
        }
        _ = await TestExecutor(plan: plan).execute()
        let n = await probe.count
        XCTAssertEqual(n, 1)
    }
}

private actor TriggerProbe {
    private(set) var count: Int = 0
    func tick() {
        count += 1
    }
}
