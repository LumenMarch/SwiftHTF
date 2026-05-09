import XCTest
@testable import SwiftHTF

final class TestConfigTests: XCTestCase {

    // MARK: - 加载

    func testLoadFromValidJSON() throws {
        let json = #"""
        {
            "vcc.lower": 3.0,
            "vcc.upper": 3.6,
            "operator": "alice",
            "modes": ["fast", "full"],
            "retry_limit": 3,
            "enabled": true
        }
        """#
        let cfg = try TestConfig.load(from: Data(json.utf8))
        XCTAssertEqual(cfg.double("vcc.lower"), 3.0)
        XCTAssertEqual(cfg.double("vcc.upper"), 3.6)
        XCTAssertEqual(cfg.string("operator"), "alice")
        XCTAssertEqual(cfg.int("retry_limit"), 3)
        XCTAssertEqual(cfg.bool("enabled"), true)
    }

    func testLoadRejectsNonObjectTopLevel() {
        let json = #"[1, 2, 3]"#
        XCTAssertThrowsError(try TestConfig.load(from: Data(json.utf8)))
    }

    func testLoadFromFileURL() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg_\(UUID().uuidString).json")
        try Data(#"{"x": 42}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let cfg = try TestConfig.load(from: url)
        XCTAssertEqual(cfg.int("x"), 42)
    }

    // MARK: - 取值

    func testSubscriptReturnsRawValue() {
        let cfg = TestConfig(values: ["x": .int(7)])
        XCTAssertEqual(cfg["x"], .int(7))
        XCTAssertNil(cfg["missing"])
    }

    func testContains() {
        let cfg = TestConfig(values: ["a": .bool(false)])
        XCTAssertTrue(cfg.contains("a"))
        XCTAssertFalse(cfg.contains("b"))
    }

    func testValueDecodableStruct() throws {
        struct Limits: Decodable, Equatable { let lower: Double; let upper: Double }
        let json = #"""
        { "vcc": { "lower": 3.0, "upper": 3.6 } }
        """#
        let cfg = try TestConfig.load(from: Data(json.utf8))
        let lim = cfg.value("vcc", as: Limits.self)
        XCTAssertEqual(lim, Limits(lower: 3.0, upper: 3.6))
    }

    func testArrayWithTransform() throws {
        let json = #"""
        { "modes": ["fast", "full"], "scores": [1, 2, 3] }
        """#
        let cfg = try TestConfig.load(from: Data(json.utf8))
        XCTAssertEqual(cfg.array("modes", as: { $0.asString }), ["fast", "full"])
        XCTAssertEqual(cfg.array("scores", as: { $0.asInt }), [1, 2, 3])
        XCTAssertNil(cfg.array("missing", as: { $0.asString }))
    }

    // MARK: - 与 TestExecutor 集成

    func testCtxConfigVisibleInsidePhase() async {
        let cfg = TestConfig(values: ["greeting": .string("hello"), "lower": .double(1.5)])
        let plan = TestPlan(name: "cfg") {
            Phase(name: "read") { @MainActor ctx in
                ctx.measure("greeting", ctx.config.string("greeting") ?? "")
                ctx.measure("lower", ctx.config.double("lower") ?? 0.0)
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan, config: cfg)
        let record = await executor.execute()
        let phase = record.phases.first
        XCTAssertEqual(phase?.measurements["greeting"]?.value.asString, "hello")
        XCTAssertEqual(phase?.measurements["lower"]?.value.asDouble, 1.5)
    }

    func testDefaultConfigIsEmpty() async {
        let plan = TestPlan(name: "empty") {
            Phase(name: "read") { @MainActor ctx in
                XCTAssertFalse(ctx.config.contains("anything"))
                XCTAssertNil(ctx.config.string("anything"))
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        _ = await executor.execute()
    }
}
