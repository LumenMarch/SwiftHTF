@testable import SwiftHTF
import XCTest

/// `Phase.withArgs(...)` + `Phase.withPlug(_:replacedWith:)` 测试。
final class PhaseParameterizationTests: XCTestCase {
    // MARK: - withArgs 基本读取

    func testWithArgsExposedViaCtxArgs() async {
        let base = Phase(name: "VccCheck") { @MainActor ctx in
            let v = ctx.args.double("voltage") ?? 0
            ctx.measure("vcc", v, unit: "V")
            return .continue
        }
        let plan = TestPlan(name: "p") {
            base.withArgs(["voltage": .double(3.3)])
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.phases[0].measurements["vcc"]?.value.asDouble, 3.3)
        XCTAssertEqual(record.phases[0].arguments["voltage"]?.asDouble, 3.3)
    }

    // MARK: - 多 withArgs 累积合并

    func testWithArgsAccumulatesAndOverrides() {
        let base = Phase(name: "Soak") { @MainActor _ in .continue }
        let phase = base
            .withArgs(["a": .int(1), "b": .int(2)])
            .withArgs(["b": .int(99), "c": .int(3)])
        XCTAssertEqual(phase.arguments["a"]?.asInt, 1)
        XCTAssertEqual(phase.arguments["b"]?.asInt, 99) // 后者覆盖
        XCTAssertEqual(phase.arguments["c"]?.asInt, 3)
    }

    // MARK: - 自动 name 后缀

    func testAutoNameSuffixWithoutExplicit() {
        let base = Phase(name: "VccCheck") { @MainActor _ in .continue }
        let p = base.withArgs(["voltage": .double(3.3), "channel": .int(1)])
        XCTAssertEqual(p.definition.name, "VccCheck[channel=1,voltage=3.3]")
    }

    func testExplicitNameSuffixOverridesAuto() {
        let base = Phase(name: "VccCheck") { @MainActor _ in .continue }
        let p = base.withArgs(["voltage": .double(3.3)], nameSuffix: "_3V3")
        XCTAssertEqual(p.definition.name, "VccCheck_3V3")
    }

    // MARK: - 同 base 参数化 fork 多变体

    func testParameterizedForkProducesIndependentPhases() async {
        let base = Phase(
            name: "VccCheck",
            measurements: [.named("vcc", unit: "V")]
        ) { @MainActor ctx in
            let v = ctx.args.double("voltage") ?? 0
            ctx.measure("vcc", v, unit: "V")
            return .continue
        }
        let plan = TestPlan(name: "multi") {
            for v in [3.0, 3.3, 3.6] {
                base.withArgs(["voltage": .double(v)], nameSuffix: "_\(v)V")
            }
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.phases.count, 3)
        XCTAssertEqual(record.phases[0].name, "VccCheck_3.0V")
        XCTAssertEqual(record.phases[1].name, "VccCheck_3.3V")
        XCTAssertEqual(record.phases[2].name, "VccCheck_3.6V")
        XCTAssertEqual(record.phases[0].arguments["voltage"]?.asDouble, 3.0)
        XCTAssertEqual(record.phases[1].arguments["voltage"]?.asDouble, 3.3)
        XCTAssertEqual(record.phases[2].arguments["voltage"]?.asDouble, 3.6)
    }

    // MARK: - PhaseRecord.arguments JSON 往返

    func testArgumentsPersistedThroughJSONRoundTrip() async throws {
        let base = Phase(name: "X") { @MainActor _ in .continue }
        let plan = TestPlan(name: "p") {
            base.withArgs(["k": .string("v"), "n": .int(42)], nameSuffix: "_x")
        }
        let record = await TestExecutor(plan: plan).execute()
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TestRecord.self, from: data)
        XCTAssertEqual(decoded.phases[0].arguments["k"]?.asString, "v")
        XCTAssertEqual(decoded.phases[0].arguments["n"]?.asInt, 42)
    }

    func testOldJSONWithoutArgumentsDecodesAsEmpty() throws {
        // 不含 arguments 字段的旧 PhaseRecord JSON 应反序列化为空 dict
        let id = UUID()
        let start = Date()
        let json = """
        {
            "id": "\(id.uuidString)",
            "name": "Legacy",
            "startTime": \(start.timeIntervalSinceReferenceDate),
            "outcome": "PASS",
            "measurements": {},
            "traces": {},
            "attachments": [],
            "groupPath": [],
            "diagnoses": [],
            "logs": [],
            "subtestFailRequested": false,
            "stopRequested": false
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(PhaseRecord.self, from: data)
        XCTAssertEqual(decoded.arguments, [:])
    }

    // MARK: - Decodable struct 反序列化

    func testArgsValueAsDecodable() async {
        struct Limits: Decodable, Equatable {
            let lo: Double
            let hi: Double
        }
        let base = Phase(
            name: "Range",
            measurements: [.named("captured_hi")]
        ) { @MainActor ctx in
            let lim = ctx.args.value("limits", as: Limits.self) ?? Limits(lo: 0, hi: 0)
            ctx.measure("captured_hi", lim.hi)
            return .continue
        }
        let plan = TestPlan(name: "p") {
            base.withArgs([
                "limits": .object(["lo": .double(3.0), "hi": .double(3.6)]),
            ], nameSuffix: "_a")
        }
        let record = await TestExecutor(plan: plan).execute()
        XCTAssertEqual(record.phases[0].measurements["captured_hi"]?.value.asDouble, 3.6)
    }

    // MARK: - withPlug 重定向

    /// 重新声明（在 PlugPlaceholderTests 文件外不可见，故本地再定义一份用于 isolation）
    class RealPSU: PlugProtocol, @unchecked Sendable {
        required init() {}
        var voltage: Double = 0
        func setOutput(_ v: Double) {
            voltage = v
        }

        func readVoltage() -> Double {
            voltage
        }

        func setup() async throws {}
        func tearDown() async {
            voltage = 0
        }
    }

    final class MockPSU: RealPSU, @unchecked Sendable {
        var simulated: Double = 1.5
        override func readVoltage() -> Double {
            simulated
        }
    }

    func testWithPlugRedirectsOnlyDeclaredPhase() async {
        // 一个 phase 用 mock，另一个 phase 用真值
        let basePhase = Phase(name: "Read") { @MainActor ctx in
            let psu = ctx.getPlug(RealPSU.self)
            ctx.measure("v", psu.readVoltage())
            return .continue
        }
        let plan = TestPlan(name: "mixed") {
            Phase(name: "SetReal") { @MainActor ctx in
                ctx.getPlug(RealPSU.self).setOutput(3.3)
                return .continue
            }
            basePhase.withArgs([:], nameSuffix: "_real") // 沿用 RealPSU
            basePhase
                .withArgs([:], nameSuffix: "_mock")
                .withPlug(RealPSU.self, replacedWith: MockPSU.self)
        }
        let executor = TestExecutor(plan: plan)
        await executor.register(RealPSU.self)
        await executor.register(MockPSU.self)
        let record = await executor.execute()

        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.phases[1].measurements["v"]?.value.asDouble, 3.3,
                       "未声明 withPlug 的 phase 应取 RealPSU 真值")
        XCTAssertEqual(record.phases[2].measurements["v"]?.value.asDouble, 1.5,
                       "声明 withPlug 的 phase 应取 MockPSU 仿真值")
    }

    func testWithPlugDoesNotLeakToSiblings() async {
        // 单一 phase 用 mock，后续 phase 仍应取真值
        let plan = TestPlan(name: "iso") {
            Phase(name: "Set") { @MainActor ctx in
                ctx.getPlug(RealPSU.self).setOutput(3.0)
                return .continue
            }
            Phase(name: "ReadMock") { @MainActor ctx in
                ctx.measure("v", ctx.getPlug(RealPSU.self).readVoltage())
                return .continue
            }
            .withPlug(RealPSU.self, replacedWith: MockPSU.self)
            Phase(name: "ReadReal") { @MainActor ctx in
                ctx.measure("v", ctx.getPlug(RealPSU.self).readVoltage())
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        await executor.register(RealPSU.self)
        await executor.register(MockPSU.self)
        let record = await executor.execute()
        XCTAssertEqual(record.phases[1].measurements["v"]?.value.asDouble, 1.5)
        XCTAssertEqual(record.phases[2].measurements["v"]?.value.asDouble, 3.0)
    }

    // MARK: - Schema 导出

    func testSchemaIncludesArgumentsExtension() throws {
        let base = Phase(
            name: "VccCheck",
            measurements: [.named("vcc", unit: "V").inRange(3.0, 3.6)]
        ) { @MainActor _ in .continue }
        let plan = TestPlan(name: "schema") {
            base.withArgs(["voltage": .double(3.3)], nameSuffix: "_3V3")
            base.withArgs(["voltage": .double(3.6)], nameSuffix: "_3V6")
        }
        let data = try plan.exportSchema()
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let extArgs = json["x-swifthtf-arguments"] as? [[String: Any]]
        XCTAssertNotNil(extArgs)
        XCTAssertEqual(extArgs?.count, 2)
        let names = extArgs?.compactMap { $0["phase"] as? String }
        XCTAssertEqual(names, ["VccCheck_3V3", "VccCheck_3V6"])
    }
}
