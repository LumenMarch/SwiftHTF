@testable import SwiftHTF
import XCTest

final class TestPlanBuilderTests: XCTestCase {
    func testSinglePhase() {
        let plan = TestPlan(name: "x") {
            Phase(name: "a") { _ in .continue }
        }
        XCTAssertEqual(plan.nodes.compactMap(\.asPhase).count, 1)
        XCTAssertEqual(plan.nodes.compactMap(\.asPhase)[0].definition.name, "a")
    }

    func testMultiplePhases() {
        let plan = TestPlan(name: "x") {
            Phase(name: "a") { _ in .continue }
            Phase(name: "b") { _ in .continue }
            Phase(name: "c") { _ in .continue }
        }
        XCTAssertEqual(plan.nodes.compactMap(\.asPhase).map(\.definition.name), ["a", "b", "c"])
    }

    func testOptionalPhase() {
        let include = false
        let plan = TestPlan(name: "x") {
            Phase(name: "a") { _ in .continue }
            if include {
                Phase(name: "b") { _ in .continue }
            }
            Phase(name: "c") { _ in .continue }
        }
        XCTAssertEqual(plan.nodes.compactMap(\.asPhase).map(\.definition.name), ["a", "c"])
    }

    func testEitherPhase() {
        let useFast = true
        let plan = TestPlan(name: "x") {
            if useFast {
                Phase(name: "fast") { _ in .continue }
            } else {
                Phase(name: "slow") { _ in .continue }
            }
        }
        XCTAssertEqual(plan.nodes.compactMap(\.asPhase).map(\.definition.name), ["fast"])
    }

    func testForLoop() {
        let names = ["a", "b", "c"]
        let plan = TestPlan(name: "x") {
            for name in names {
                Phase(name: name) { _ in .continue }
            }
        }
        XCTAssertEqual(plan.nodes.compactMap(\.asPhase).map(\.definition.name), names)
    }

    func testArrayExpression() {
        let extras: [Phase] = [
            Phase(name: "x") { _ in .continue },
            Phase(name: "y") { _ in .continue },
        ]
        let plan = TestPlan(name: "p") {
            Phase(name: "a") { _ in .continue }
            extras
        }
        XCTAssertEqual(plan.nodes.compactMap(\.asPhase).map(\.definition.name), ["a", "x", "y"])
    }

    func testSetupTeardown() {
        let plan = TestPlan(
            name: "p",
            setup: [Phase(name: "init") { _ in .continue }],
            teardown: [Phase(name: "cleanup") { _ in .continue }]
        ) {
            Phase(name: "main") { _ in .continue }
        }
        XCTAssertEqual(plan.setupNodes.compactMap(\.asPhase).map(\.definition.name), ["init"])
        XCTAssertEqual(plan.teardownNodes.compactMap(\.asPhase).map(\.definition.name), ["cleanup"])
        XCTAssertEqual(plan.nodes.compactMap(\.asPhase).map(\.definition.name), ["main"])
    }
}
