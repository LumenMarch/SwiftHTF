@testable import SwiftHTF
import XCTest

final class PhaseStateTests: XCTestCase {
    // MARK: - phase 间传值

    func testStatePassedAcrossPhases() async {
        let plan = TestPlan(name: "pass") {
            Phase(name: "producer") { ctx in
                ctx.state.set("token", "abc")
                ctx.state.set("count", 7)
                return .continue
            }
            Phase(name: "consumer", measurements: [.named("seen_token")]) { ctx in
                let token = ctx.state.string("token") ?? ""
                let count = ctx.state.int("count") ?? 0
                ctx.measure("seen_token", token)
                ctx.measure("seen_count", count)
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        let consumer = record.phases[1]
        XCTAssertEqual(consumer.measurements["seen_token"]?.value.asString, "abc")
        XCTAssertEqual(consumer.measurements["seen_count"]?.value.asInt, 7)
    }

    // MARK: - 类型化访问

    func testStateTypeAccessors() async {
        let plan = TestPlan(name: "types") {
            Phase(name: "write") { ctx in
                ctx.state.set("s", "hello")
                ctx.state.set("i", 42)
                ctx.state.set("d", 3.14)
                ctx.state.set("b", true)
                return .continue
            }
            Phase(name: "read") { ctx in
                XCTAssertEqual(ctx.state.string("s"), "hello")
                XCTAssertEqual(ctx.state.int("i"), 42)
                XCTAssertEqual(ctx.state.double("d"), 3.14)
                XCTAssertEqual(ctx.state.bool("b"), true)
                XCTAssertNil(ctx.state.string("missing"))
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
    }

    // MARK: - Codable 复杂类型

    func testStateCodableRoundTrip() async {
        struct DUTInfo: Codable, Equatable {
            let sn: String
            let firmware: String
            let calCount: Int
        }
        let plan = TestPlan(name: "codec") {
            Phase(name: "write") { ctx in
                ctx.state.set("dut", DUTInfo(sn: "SN-1", firmware: "1.2.3", calCount: 5))
                return .continue
            }
            Phase(name: "read", measurements: [.named("dut_sn"), .named("dut_cal")]) { ctx in
                let info = ctx.state.value("dut", as: DUTInfo.self)
                XCTAssertEqual(info?.sn, "SN-1")
                XCTAssertEqual(info?.firmware, "1.2.3")
                ctx.measure("dut_sn", info?.sn ?? "")
                ctx.measure("dut_cal", info?.calCount ?? 0)
                return .continue
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases[1].measurements["dut_sn"]?.value.asString, "SN-1")
        XCTAssertEqual(record.phases[1].measurements["dut_cal"]?.value.asInt, 5)
    }

    // MARK: - 覆写 / 移除

    func testStateOverwriteAndRemove() async {
        let plan = TestPlan(name: "ovr") {
            Phase(name: "p1") { ctx in
                ctx.state.set("k", 1)
                XCTAssertEqual(ctx.state.int("k"), 1)
                ctx.state.set("k", 2)
                XCTAssertEqual(ctx.state.int("k"), 2)
                XCTAssertTrue(ctx.state.contains("k"))
                ctx.state.remove("k")
                XCTAssertFalse(ctx.state.contains("k"))
                XCTAssertNil(ctx.state.int("k"))
                return .continue
            }
        }
        _ = await TestExecutor(plan: plan).execute()
    }

    // MARK: - runIf 内访问

    func testRunIfReadsState() async {
        let plan = TestPlan(name: "runif") {
            Phase(name: "set_flag") { ctx in
                ctx.state.set("skip_next", true)
                return .continue
            }
            Phase(name: "skipped", runIf: { ctx in ctx.state.bool("skip_next") != true }) { _ in
                .continue
            }
            Phase(name: "ran") { _ in .continue }
        }
        let record = await TestExecutor(plan: plan).execute()
        let skipped = record.phases.first { $0.name == "skipped" }
        XCTAssertEqual(skipped?.outcome, .skip, "runIf 应能读 state")
        XCTAssertTrue(record.phases.contains { $0.name == "ran" })
    }

    // MARK: - 跨 group 可见

    func testStateVisibleAcrossGroups() async {
        let plan = TestPlan(name: "groups") {
            Group("setup") {
                Phase(name: "init") { ctx in
                    ctx.state.set("ready", true)
                    return .continue
                }
            }
            Group("main") {
                Phase(name: "use", measurements: [.named("ready")]) { ctx in
                    ctx.measure("ready", ctx.state.bool("ready") ?? false)
                    return .continue
                }
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        let use = record.phases.first { $0.name == "use" }
        XCTAssertEqual(use?.measurements["ready"]?.value.asBool, true)
    }

    // MARK: - 多 session 隔离

    func testMultiSessionStateIsolated() async {
        let plan = TestPlan(name: "iso") {
            Phase(name: "write_sn") { ctx in
                ctx.state.set("sn", ctx.serialNumber ?? "?")
                return .continue
            }
            Phase(name: "read_sn", measurements: [.named("seen")]) { ctx in
                ctx.measure("seen", ctx.state.string("sn") ?? "")
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        async let s1 = executor.startSession(serialNumber: "DUT-A")
        async let s2 = executor.startSession(serialNumber: "DUT-B")
        let sess1 = await s1
        let sess2 = await s2
        async let r1 = sess1.record()
        async let r2 = sess2.record()
        let (rec1, rec2) = await (r1, r2)

        let seen1 = rec1.phases.first { $0.name == "read_sn" }?.measurements["seen"]?.value.asString
        let seen2 = rec2.phases.first { $0.name == "read_sn" }?.measurements["seen"]?.value.asString
        XCTAssertEqual(seen1, "DUT-A")
        XCTAssertEqual(seen2, "DUT-B")
    }

    // MARK: - subscript

    func testSubscriptReadWrite() async {
        let plan = TestPlan(name: "sub") {
            Phase(name: "p") { ctx in
                ctx.state["raw"] = .string("v")
                XCTAssertEqual(ctx.state["raw"]?.asString, "v")
                ctx.state["raw"] = nil
                XCTAssertNil(ctx.state["raw"])
                return .continue
            }
        }
        _ = await TestExecutor(plan: plan).execute()
    }
}
