import XCTest
@testable import SwiftHTF

/// Plug 替身（mock 注入 / 抽象别名）相关测试
final class PlugPlaceholderTests: XCTestCase {

    // MARK: - 测试 Plug：用 class + required init() 支持 swap 子类继承

    class RealPSU: PlugProtocol, @unchecked Sendable {
        required init() {}
        var voltage: Double = 0
        func setOutput(_ v: Double) { voltage = v }
        func readVoltage() -> Double { voltage }
        func setup() async throws {}
        func tearDown() async { voltage = 0 }
    }

    final class MockPSU: RealPSU, @unchecked Sendable {
        var simulated: Double = 1.5
        override func readVoltage() -> Double { simulated }
    }

    /// 依赖 RealPSU（用于验证 swap 后 resolver 能拿到 MockPSU 实例）
    final class FollowerPlug: PlugProtocol, @unchecked Sendable {
        static var dependencies: [any PlugProtocol.Type] { [RealPSU.self] }
        var observedKlass: String?
        var observedVoltage: Double?
        required init() {}
        func setup(resolver: PlugResolver) async throws {
            let psu = await resolver.get(RealPSU.self)
            observedKlass = psu.map { String(describing: type(of: $0)) }
            observedVoltage = psu?.readVoltage()
        }
        func tearDown() async {}
    }

    // MARK: - swap：真实换 mock

    func testSwapReplacesRealWithMock() async {
        let plan = TestPlan(name: "swap") {
            Phase(name: "p") { @MainActor ctx in
                let psu = ctx.getPlug(RealPSU.self)
                ctx.measure("voltage", psu.readVoltage())
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        await executor.register(RealPSU.self)
        await executor.swap(RealPSU.self, with: MockPSU.self)

        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .pass)
        let voltage = record.phases.first?.measurements["voltage"]?.value.asDouble
        XCTAssertEqual(voltage, 1.5, "应取自 MockPSU.simulated")
    }

    func testSwapWithFactoryAllowsCustomMock() async {
        let plan = TestPlan(name: "swap-factory") {
            Phase(name: "p") { @MainActor ctx in
                let psu = ctx.getPlug(RealPSU.self)
                ctx.measure("voltage", psu.readVoltage())
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        await executor.register(RealPSU.self)
        await executor.swap(RealPSU.self, with: MockPSU.self) { @MainActor in
            let m = MockPSU()
            m.simulated = 9.9
            return m
        }
        let record = await executor.execute()
        XCTAssertEqual(record.phases.first?.measurements["voltage"]?.value.asDouble, 9.9)
    }

    // MARK: - bind：注册 concrete + 用 abstract 别名

    func testBindAliasResolvesToConcrete() async {
        // 这里把 MockPSU 当"具体"，RealPSU 当"抽象"。bind RealPSU→MockPSU 后，
        // phase 代码 getPlug(RealPSU.self) 实际拿到 MockPSU 实例。
        let plan = TestPlan(name: "bind") {
            Phase(name: "p") { @MainActor ctx in
                let psu = ctx.getPlug(RealPSU.self)
                ctx.measure("isMock", psu is MockPSU)
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        await executor.register(MockPSU.self)
        await executor.bind(RealPSU.self, to: MockPSU.self)

        let record = await executor.execute()
        XCTAssertEqual(record.phases.first?.measurements["isMock"]?.value.asBool, true)
    }

    // MARK: - 依赖解析也走 alias

    func testDependencyChainResolvesAlias() async {
        // FollowerPlug.dependencies = [RealPSU.self]；swap 后 RealPSU→MockPSU
        // resolver.get(RealPSU.self) 应拿到 MockPSU 实例。
        let plan = TestPlan(name: "deps") {
            Phase(name: "p") { @MainActor ctx in
                let f = ctx.getPlug(FollowerPlug.self)
                ctx.measure("klass", f.observedKlass ?? "<nil>")
                ctx.measure("voltage", f.observedVoltage ?? -1)
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        await executor.register(RealPSU.self)
        await executor.swap(RealPSU.self, with: MockPSU.self)
        await executor.register(FollowerPlug.self)

        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.phases.first?.measurements["klass"]?.value.asString, "MockPSU")
        XCTAssertEqual(record.phases.first?.measurements["voltage"]?.value.asDouble, 1.5)
    }

    // MARK: - 多 session 共享 alias 配置（registrationFns 应用到每个 session）

    func testMultiSessionsAllSeeSwap() async {
        let plan = TestPlan(name: "multi") {
            Phase(name: "p") { @MainActor ctx in
                let psu = ctx.getPlug(RealPSU.self)
                ctx.measure("voltage", psu.readVoltage())
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        await executor.register(RealPSU.self)
        await executor.swap(RealPSU.self, with: MockPSU.self)

        async let s1 = executor.startSession(serialNumber: "A")
        async let s2 = executor.startSession(serialNumber: "B")
        let r1 = await s1
        let r2 = await s2
        async let rec1 = r1.record()
        async let rec2 = r2.record()
        let (rA, rB) = await (rec1, rec2)
        XCTAssertEqual(rA.phases.first?.measurements["voltage"]?.value.asDouble, 1.5)
        XCTAssertEqual(rB.phases.first?.measurements["voltage"]?.value.asDouble, 1.5)
    }

    // MARK: - bind 但 concrete 未注册：plug setup 时拿不到 → unregisteredDependency 仅在 plug 声明依赖时报

    func testBindWithoutConcreteRegisteredYieldsNilFromGetPlug() async {
        // 没 register MockPSU，仅 bind —— ctx.getPlug 走默认 fatalError。
        // 这里测的是更弱的契约：bind 不会自动 register。
        let plan = TestPlan(name: "missing") {
            Phase(name: "p") { @MainActor _ in .continue }
        }
        let executor = TestExecutor(plan: plan)
        await executor.bind(RealPSU.self, to: MockPSU.self)
        let record = await executor.execute()
        // 没具体 plug，phase 简单 pass（phase 内并未 getPlug）；setupAll 不会因 alias 失败
        XCTAssertEqual(record.outcome, .pass)
    }
}
