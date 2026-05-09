@testable import SwiftHTF
import XCTest

final class PhaseGroupTests: XCTestCase {
    // MARK: - 顺序与路径

    func testGroupRunsSetupChildrenTeardownInOrder() async {
        let plan = TestPlan(name: "order") {
            Group("g1") {
                Phase(name: "c1") { _ in .continue }
                Phase(name: "c2") { _ in .continue }
            } setup: {
                Phase(name: "s1") { _ in .continue }
            } teardown: {
                Phase(name: "t1") { _ in .continue }
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.phases.map(\.name), ["s1", "c1", "c2", "t1"])
        XCTAssertTrue(record.phases.allSatisfy { $0.groupPath == ["g1"] })
        XCTAssertEqual(record.outcome, .pass)
    }

    func testNestedGroupsBuildPath() async {
        let plan = TestPlan(name: "nested") {
            Group("outer") {
                Phase(name: "p1") { _ in .continue }
                Group("inner") {
                    Phase(name: "p2") { _ in .continue }
                }
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.phases.count, 2)
        XCTAssertEqual(record.phases[0].name, "p1")
        XCTAssertEqual(record.phases[0].groupPath, ["outer"])
        XCTAssertEqual(record.phases[1].name, "p2")
        XCTAssertEqual(record.phases[1].groupPath, ["outer", "inner"])
    }

    func testTopLevelPhaseHasEmptyPath() async {
        let plan = TestPlan(name: "flat") {
            Phase(name: "flat") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.phases.first?.groupPath, [])
    }

    // MARK: - 失败语义

    func testGroupSetupFailureSkipsChildrenButRunsTeardown() async {
        let plan = TestPlan(name: "setup_fail") {
            Group("g") {
                Phase(name: "child") { _ in .continue }
            } setup: {
                Phase(name: "bad_setup") { _ in .failAndContinue }
            } teardown: {
                Phase(name: "td") { _ in .continue }
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        let names = record.phases.map(\.name)
        XCTAssertTrue(names.contains("bad_setup"))
        XCTAssertFalse(names.contains("child"), "setup 失败应跳 children")
        XCTAssertTrue(names.contains("td"), "setup 失败仍应跑 teardown")
        XCTAssertEqual(record.outcome, .fail)
    }

    func testGroupChildFailureRunsTeardown() async {
        let plan = TestPlan(name: "child_fail") {
            Group("g") {
                Phase(name: "bad") { _ in .failAndContinue }
                Phase(name: "next") { _ in .continue }
            } teardown: {
                Phase(name: "td") { _ in .continue }
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        let names = record.phases.map(\.name)
        XCTAssertTrue(names.contains("bad"))
        XCTAssertTrue(names.contains("td"), "child fail 仍应跑 teardown")
        XCTAssertEqual(record.outcome, .fail)
    }

    func testGroupContinueOnFailIsLocal() async {
        // group 内 continueOnFail = true，外层 continueOnFail = false
        // → group 内 fail 后兄弟继续，但 group 整体仍标 fail，外层 plan 不再继续后续兄弟
        let plan = TestPlan(name: "scope") {
            Group("g", continueOnFail: true) {
                Phase(name: "c1") { _ in .failAndContinue }
                Phase(name: "c2") { _ in .continue }
            }
            Phase(name: "after_group") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        let names = record.phases.map(\.name)
        XCTAssertTrue(names.contains("c1"))
        XCTAssertTrue(names.contains("c2"), "group.continueOnFail 应让兄弟继续")
        XCTAssertFalse(names.contains("after_group"), "外层 plan.continueOnFail=false → group fail 后中止")
        XCTAssertEqual(record.outcome, .fail)
    }

    func testPlanContinueOnFailRunsAfterGroupFail() async {
        let plan = TestPlan(name: "plan_cont", continueOnFail: true) {
            Group("g") {
                Phase(name: "boom") { _ in .failAndContinue }
            }
            Phase(name: "after_group") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertTrue(record.phases.map(\.name).contains("after_group"))
        XCTAssertEqual(record.outcome, .fail)
    }

    // MARK: - 顶层 setup / teardown 兼容

    func testTopLevelSetupTeardownStillWorks() async {
        let setupPhases = [Phase(name: "init") { _ in .continue }]
        let teardownPhases = [Phase(name: "cleanup") { _ in .continue }]
        let plan = TestPlan(
            name: "compat",
            setup: setupPhases,
            teardown: teardownPhases
        ) {
            Phase(name: "main") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.phases.map(\.name), ["init", "main", "cleanup"])
        XCTAssertEqual(record.outcome, .pass)
    }

    // MARK: - DSL 节点结构

    func testTestPlanNodesContainGroups() {
        let plan = TestPlan(name: "proj") {
            Phase(name: "top1") { _ in .continue }
            Group("g") {
                Phase(name: "inner") { _ in .continue }
            }
            Phase(name: "top2") { _ in .continue }
        }
        XCTAssertEqual(plan.nodes.count, 3)
        XCTAssertEqual(plan.nodes[0].asPhase?.definition.name, "top1")
        XCTAssertNotNil(plan.nodes[1].asGroup)
        XCTAssertEqual(plan.nodes[1].asGroup?.children.count, 1)
        XCTAssertEqual(plan.nodes[2].asPhase?.definition.name, "top2")
    }
}
