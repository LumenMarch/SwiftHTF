@testable import SwiftHTF
import XCTest

final class RunIfTests: XCTestCase {
    // MARK: - Phase runIf

    func testPhaseRunIfFalseSkipsAndKeepsPass() async {
        let plan = TestPlan(name: "phase_skip") {
            Phase(name: "skipped", runIf: { _ in false }) { _ in
                XCTFail("execute 不应被调用")
                return .continue
            }
            Phase(name: "after") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()

        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.phases.count, 2)
        XCTAssertEqual(record.phases[0].name, "skipped")
        XCTAssertEqual(record.phases[0].outcome, .skip)
        XCTAssertEqual(record.phases[0].errorMessage, "runIf=false")
        XCTAssertEqual(record.phases[1].name, "after")
        XCTAssertEqual(record.phases[1].outcome, .pass)
    }

    func testPhaseRunIfTrueRunsNormally() async {
        let plan = TestPlan(name: "phase_run") {
            Phase(name: "p", runIf: { _ in true }) { _ in .continue }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases.first?.outcome, .pass)
    }

    func testPhaseRunIfReadsConfig() async {
        let cfg = TestConfig(values: ["feature.enabled": .bool(false)])
        let plan = TestPlan(name: "via_cfg") {
            Phase(
                name: "feature",
                runIf: { @MainActor ctx in ctx.config.bool("feature.enabled") ?? false }
            ) { _ in
                XCTFail("config 关闭应跳过")
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan, config: cfg).execute()
        XCTAssertEqual(record.phases.first?.outcome, .skip)
    }

    func testPhaseRunIfReadsPriorPhaseDecision() async {
        // 跨 phase 的决定通过外部 actor 传递（ctx.measurements 在 harvest 后清空，
        // 不能跨 phase 读取；要持久化跨 phase 数据，用 actor / plug / config）
        actor Mode { var value: String?; func set(_ v: String) {
            value = v
        }; func get() -> String? {
            value
        } }
        let mode = Mode()
        let plan = TestPlan(name: "from_prior") {
            Phase(name: "decide") { @MainActor _ in
                await mode.set("fast")
                return .continue
            }
            Phase(
                name: "extra",
                runIf: { @MainActor _ in await mode.get() == "full" }
            ) { _ in
                XCTFail("mode != full 不应执行")
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases.last?.outcome, .skip)
    }

    // MARK: - Group runIf

    func testGroupRunIfFalseSkipsEntireGroup() async {
        let plan = TestPlan(name: "group_skip") {
            Group("disabled", runIf: { _ in false }) {
                Phase(name: "inner") { _ in
                    XCTFail("group 跳过时 children 不应跑")
                    return .continue
                }
            } setup: {
                Phase(name: "inner_setup") { _ in
                    XCTFail("group 跳过时 setup 不应跑")
                    return .continue
                }
            } teardown: {
                Phase(name: "inner_teardown") { _ in
                    XCTFail("group 跳过时 teardown 不应跑")
                    return .continue
                }
            }
            Phase(name: "after") { _ in .continue }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        // 两条记录：合成的 group skip + after
        XCTAssertEqual(record.phases.count, 2)
        XCTAssertEqual(record.phases[0].name, "disabled")
        XCTAssertEqual(record.phases[0].outcome, .skip)
        XCTAssertEqual(record.phases[0].groupPath, [])
        XCTAssertEqual(record.phases[1].name, "after")
        XCTAssertEqual(record.phases[1].outcome, .pass)
    }

    func testGroupRunIfTrueRunsAllChildren() async {
        let plan = TestPlan(name: "group_run") {
            Group("enabled", runIf: { _ in true }) {
                Phase(name: "c1") { _ in .continue }
                Phase(name: "c2") { _ in .continue }
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases.map(\.name), ["c1", "c2"])
        XCTAssertEqual(record.outcome, .pass)
    }

    func testNestedGroupRunIfSkipsOnlyInner() async {
        let plan = TestPlan(name: "nested_skip") {
            Group("outer") {
                Phase(name: "p1") { _ in .continue }
                Group("inner", runIf: { _ in false }) {
                    Phase(name: "deep") { _ in
                        XCTFail("inner 跳过时 deep 不应跑")
                        return .continue
                    }
                }
                Phase(name: "p2") { _ in .continue }
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        let names = record.phases.map(\.name)
        XCTAssertEqual(names, ["p1", "inner", "p2"])
        XCTAssertEqual(record.phases[1].outcome, .skip)
        XCTAssertEqual(record.phases[1].groupPath, ["outer"], "skip 记录的 path 应是父层")
    }

    func testGroupRunIfSeesParentScope() async {
        // group runIf 闭包通过捕获外部 actor 读到上一个 phase 的决定
        actor Mode { var value: String?; func set(_ v: String) {
            value = v
        }; func get() -> String? {
            value
        } }
        let mode = Mode()
        let plan = TestPlan(name: "group_predicate") {
            Phase(name: "decide") { @MainActor _ in
                await mode.set("fast")
                return .continue
            }
            Group(
                "extras",
                runIf: { @MainActor _ in await mode.get() == "full" }
            ) {
                Phase(name: "long_test") { _ in
                    XCTFail("mode=fast 时 group 应跳过")
                    return .continue
                }
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        XCTAssertTrue(record.phases.contains { $0.name == "extras" && $0.outcome == .skip })
    }
}
