import XCTest
@testable import SwiftHTF

@MainActor
final class PlugDependencyTests: XCTestCase {

    // MARK: - 测试用 plug

    /// 记录 setup 顺序到全局 actor，便于断言
    actor SetupRecorder {
        static let shared = SetupRecorder()
        var order: [String] = []
        func record(_ name: String) { order.append(name) }
        func snapshot() -> [String] { order }
        func reset() { order = [] }
    }

    // 基础 plug
    final class CorePlug: PlugProtocol, @unchecked Sendable {
        init() {}
        func setup(resolver: PlugResolver) async throws {
            await SetupRecorder.shared.record("Core")
        }
    }

    // 依赖 Core
    final class MidPlug: PlugProtocol, @unchecked Sendable {
        var coreSeen: Bool = false
        init() {}
        static var dependencies: [any PlugProtocol.Type] { [CorePlug.self] }
        func setup(resolver: PlugResolver) async throws {
            coreSeen = await resolver.get(CorePlug.self) != nil
            await SetupRecorder.shared.record("Mid")
        }
    }

    // 同时依赖 Core 和 Mid
    final class TopPlug: PlugProtocol, @unchecked Sendable {
        var midRefSet: Bool = false
        init() {}
        static var dependencies: [any PlugProtocol.Type] { [CorePlug.self, MidPlug.self] }
        func setup(resolver: PlugResolver) async throws {
            midRefSet = await resolver.get(MidPlug.self) != nil
            await SetupRecorder.shared.record("Top")
        }
    }

    // 循环：A→B→A
    final class CycleA: PlugProtocol, @unchecked Sendable {
        init() {}
        static var dependencies: [any PlugProtocol.Type] { [CycleB.self] }
    }

    final class CycleB: PlugProtocol, @unchecked Sendable {
        init() {}
        static var dependencies: [any PlugProtocol.Type] { [CycleA.self] }
    }

    // 缺失依赖
    final class NeedsMissing: PlugProtocol, @unchecked Sendable {
        init() {}
        static var dependencies: [any PlugProtocol.Type] { [Missing.self] }
    }

    final class Missing: PlugProtocol, @unchecked Sendable {
        init() {}
    }

    // 无依赖（旧路径）
    final class StandalonePlug: PlugProtocol, @unchecked Sendable {
        init() {}
        func setup(resolver: PlugResolver) async throws {
            await SetupRecorder.shared.record("Standalone")
        }
    }

    override func setUp() async throws {
        await SetupRecorder.shared.reset()
    }

    // MARK: - 用例

    func testNoDependenciesUnchanged() async {
        let plan = TestPlan(name: "no_dep") {
            Phase(name: "p") { _ in .continue }
        }
        let exec = TestExecutor(plan: plan)
        await exec.register(StandalonePlug.self)
        let record = await exec.execute()
        XCTAssertEqual(record.outcome, .pass)
        let order = await SetupRecorder.shared.snapshot()
        XCTAssertEqual(order, ["Standalone"])
    }

    func testSingleDependencySetupOrder() async {
        let plan = TestPlan(name: "single") {
            Phase(name: "p") { _ in .continue }
        }
        let exec = TestExecutor(plan: plan)
        await exec.register(MidPlug.self)
        await exec.register(CorePlug.self)
        let record = await exec.execute()
        XCTAssertEqual(record.outcome, .pass)
        let order = await SetupRecorder.shared.snapshot()
        XCTAssertEqual(order, ["Core", "Mid"], "依赖应先于被依赖者 setup")
    }

    func testMultipleDependenciesSetupOrder() async {
        let plan = TestPlan(name: "multi") {
            Phase(name: "p") { _ in .continue }
        }
        let exec = TestExecutor(plan: plan)
        await exec.register(TopPlug.self)
        await exec.register(MidPlug.self)
        await exec.register(CorePlug.self)
        let record = await exec.execute()
        XCTAssertEqual(record.outcome, .pass)
        let order = await SetupRecorder.shared.snapshot()
        XCTAssertEqual(order, ["Core", "Mid", "Top"])
    }

    func testResolverGetsExpectedInstance() async {
        // phase 内拿 TopPlug，验证它在 setup 时确实拿到了 MidPlug 引用
        actor MidRefBox { var v: Bool = false; func set(_ x: Bool) { v = x }; func get() -> Bool { v } }
        let box = MidRefBox()
        let plan = TestPlan(name: "verify_ref") {
            Phase(name: "check") { @MainActor ctx in
                let top = ctx.getPlug(TopPlug.self)
                await box.set(top.midRefSet)
                return .continue
            }
        }
        let exec = TestExecutor(plan: plan)
        await exec.register(TopPlug.self)
        await exec.register(MidPlug.self)
        await exec.register(CorePlug.self)
        _ = await exec.execute()
        let midRef = await box.get()
        XCTAssertTrue(midRef, "TopPlug.setup 应拿到 MidPlug 实例")
    }

    func testCyclicDependencyFailsWithError() async {
        let plan = TestPlan(name: "cycle") {
            Phase(name: "p") { _ in .continue }
        }
        let exec = TestExecutor(plan: plan)
        await exec.register(CycleA.self)
        await exec.register(CycleB.self)
        let record = await exec.execute()
        XCTAssertEqual(record.outcome, .error, "循环依赖应导致 plug setup 失败 → record.error")
    }

    func testUnregisteredDependencyFailsWithError() async {
        let plan = TestPlan(name: "missing") {
            Phase(name: "p") { _ in .continue }
        }
        let exec = TestExecutor(plan: plan)
        await exec.register(NeedsMissing.self)
        // 不注册 Missing
        let record = await exec.execute()
        XCTAssertEqual(record.outcome, .error)
    }
}
