@testable import SwiftHTF
import XCTest

/// `ConfigSchema` / `ConfigDeclaration` / TestExecutor 启动期校验 测试。
final class ConfigSchemaTests: XCTestCase {
    // MARK: - 基础 API

    func testDeclarationLookupAndIsDeclared() {
        let schema = ConfigSchema([
            .optional("vcc.lower", default: .double(3.0), type: .double),
            .required("vcc.upper", type: .double, description: "Upper limit"),
        ])
        XCTAssertEqual(schema.declaration("vcc.lower")?.defaultValue?.asDouble, 3.0)
        XCTAssertEqual(schema.declaration("vcc.upper")?.description, "Upper limit")
        XCTAssertTrue(schema.isDeclared("vcc.lower"))
        XCTAssertFalse(schema.isDeclared("missing.key"))
    }

    func testDefaultsConfigContainsOnlyDefaults() {
        let schema = ConfigSchema([
            .optional("a", default: .int(1)),
            .optional("b", default: nil),
            .required("c"),
        ])
        let defaults = schema.defaultsConfig()
        XCTAssertEqual(defaults.values.count, 1)
        XCTAssertEqual(defaults.int("a"), 1)
    }

    func testRequiredKeysMissingDetection() {
        let schema = ConfigSchema([
            .required("a"),
            .required("b"),
            .optional("c", default: .int(3)),
        ])
        let cfg = TestConfig(values: ["a": .int(1)])
        let missing = schema.requiredKeysMissing(in: cfg)
        XCTAssertEqual(missing, ["b"])
    }

    func testUndeclaredKeysDetection() {
        let schema = ConfigSchema([
            .optional("known"),
        ])
        let cfg = TestConfig(values: [
            "known": .int(1),
            "extra": .string("?"),
            "another": .bool(true),
        ])
        XCTAssertEqual(schema.undeclaredKeys(in: cfg), ["another", "extra"])
    }

    // MARK: - Executor 应用 defaults + 校验 required

    func testExecutorAppliesDefaultsFromSchema() async {
        let schema = ConfigSchema([
            .optional("vcc.lower", default: .double(3.0), type: .double),
        ])
        let plan = TestPlan(name: "p") {
            Phase(name: "read") { @MainActor ctx in
                ctx.measure("v", ctx.config.double("vcc.lower") ?? -1)
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan, config: TestConfig(), configSchema: schema)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.phases[0].measurements["v"]?.value.asDouble, 3.0)
    }

    func testUserConfigOverridesSchemaDefault() async {
        let schema = ConfigSchema([
            .optional("vcc.lower", default: .double(3.0)),
        ])
        let user = TestConfig(values: ["vcc.lower": .double(2.8)])
        let plan = TestPlan(name: "p") {
            Phase(name: "read") { @MainActor ctx in
                ctx.measure("v", ctx.config.double("vcc.lower") ?? -1)
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan, config: user, configSchema: schema)
        let record = await executor.execute()
        XCTAssertEqual(record.phases[0].measurements["v"]?.value.asDouble, 2.8)
    }

    func testMissingRequiredKeyMarksRecordAsError() async {
        let schema = ConfigSchema([.required("must.have")])
        let plan = TestPlan(name: "p") {
            Phase(name: "noop") { @MainActor _ in .continue }
        }
        let executor = TestExecutor(plan: plan, configSchema: schema)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .error)
        // 不应执行任何 phase
        XCTAssertTrue(record.phases.isEmpty)
    }

    // MARK: - 严格度模式

    func testStrictModeRejectsUndeclaredKeys() async {
        let schema = ConfigSchema([.optional("known")], strictness: .strict)
        let cfg = TestConfig(values: ["unknown": .int(1)])
        let plan = TestPlan(name: "p") {
            Phase(name: "noop") { @MainActor _ in .continue }
        }
        let executor = TestExecutor(plan: plan, config: cfg, configSchema: schema)
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .error)
    }

    func testLaxModeAllowsUndeclaredKeysSilently() async {
        let schema = ConfigSchema([.optional("known")], strictness: .lax)
        let captured = WarningBox()
        let cfg = TestConfig(values: ["unknown": .int(1)])
        let plan = TestPlan(name: "p") {
            Phase(name: "read") { @MainActor ctx in
                _ = ctx.config.int("unknown") // 读未声明 key
                return .continue
            }
        }
        let executor = TestExecutor(
            plan: plan, config: cfg, configSchema: schema,
            undeclaredKeyHandler: { @Sendable in captured.add($0) }
        )
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .pass)
        let warnings = captured.values
        XCTAssertTrue(warnings.isEmpty, "lax 模式不应触发 undeclared key handler")
    }

    func testWarnModeCapturesUndeclaredKeyRead() async {
        let schema = ConfigSchema([.optional("known")], strictness: .warn)
        let captured = WarningBox()
        let cfg = TestConfig(values: ["known": .int(1)])
        let plan = TestPlan(name: "p") {
            Phase(name: "read") { @MainActor ctx in
                _ = ctx.config.int("known") // 已声明，不触发
                _ = ctx.config.int("missing") // 未声明，应触发
                _ = ctx.config.int("missing") // 再读一次也应触发（不去重）
                return .continue
            }
        }
        let executor = TestExecutor(
            plan: plan, config: cfg, configSchema: schema,
            undeclaredKeyHandler: { @Sendable in captured.add($0) }
        )
        let record = await executor.execute()
        XCTAssertEqual(record.outcome, .pass)
        let warnings = captured.values
        XCTAssertEqual(warnings, ["missing", "missing"])
    }

    // MARK: - 与 ctx.config 读时校验

    func testCtxConfigReadTriggersHandlerInWarnMode() async {
        let schema = ConfigSchema([.optional("a"), .optional("b", default: .int(7))])
        let captured = WarningBox()
        let plan = TestPlan(name: "p") {
            Phase(name: "read") { @MainActor ctx in
                ctx.measure("b", ctx.config.int("b") ?? -1)
                _ = ctx.config.string("typo") // 未声明
                return .continue
            }
        }
        let executor = TestExecutor(
            plan: plan, configSchema: schema,
            undeclaredKeyHandler: { @Sendable in captured.add($0) }
        )
        let record = await executor.execute()
        XCTAssertEqual(record.phases[0].measurements["b"]?.value.asInt, 7)
        let warnings = captured.values
        XCTAssertEqual(warnings, ["typo"])
    }

    // MARK: - Schema JSON 导出

    func testExportJSONSchemaContainsPropertiesAndRequired() throws {
        let schema = ConfigSchema([
            .required("vcc.upper", type: .double, description: "Upper limit"),
            .optional("retries", default: .int(3), type: .int),
            .optional("name", default: .string("dut"), type: .string),
        ], strictness: .warn)
        let data = try schema.exportJSONSchema(title: "Board")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["title"] as? String, "Board")
        XCTAssertEqual(json["type"] as? String, "object")
        XCTAssertEqual(json["x-swifthtf-strictness"] as? String, "warn")
        XCTAssertEqual(json["required"] as? [String], ["vcc.upper"])

        let props = try XCTUnwrap(json["properties"] as? [String: [String: Any]])
        XCTAssertEqual(props["vcc.upper"]?["type"] as? String, "number")
        XCTAssertEqual(props["vcc.upper"]?["description"] as? String, "Upper limit")
        XCTAssertEqual(props["retries"]?["type"] as? String, "integer")
        XCTAssertEqual(props["retries"]?["default"] as? Int, 3)
        XCTAssertEqual(props["name"]?["default"] as? String, "dut")
    }

    // MARK: - 与现有 merging 链路兼容

    func testMergingPreservesSchemaReference() {
        let schema = ConfigSchema([.optional("x", default: .int(1))])
        let base = TestConfig(values: ["x": .int(2)], schema: schema)
        let override = TestConfig(values: ["y": .int(3)])
        let merged = base.merging(override)
        // merge 后 schema 引用应保留（base 的 schema）；values 合并
        XCTAssertNotNil(merged.schema)
        XCTAssertEqual(merged.values["x"]?.asInt, 2)
        XCTAssertEqual(merged.values["y"]?.asInt, 3)
    }
}

// MARK: - 测试用线程安全 box

/// `undeclaredKeyHandler` 是同步 @Sendable closure，actor 调用要 Task 跳异步，
/// 测试断言时机不稳。改用 NSLock 包裹普通数组，同步可读。
private final class WarningBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ s: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(s)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
