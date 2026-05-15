@testable import SwiftHTF
import XCTest

final class JSONSchemaExportTests: XCTestCase {
    /// 把 schema 解码成 [String: Any] 方便断言
    private func decodeSchema(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("schema not a JSON object")
            return [:]
        }
        return obj
    }

    /// 从 schema 中按 property 名取 dict（含 force-cast-free 解包）
    private func property(_ name: String, in schema: [String: Any]) throws -> [String: Any] {
        let props = try XCTUnwrap(schema["properties"] as? [String: Any])
        return try XCTUnwrap(props[name] as? [String: Any])
    }

    func testHeaderFields() throws {
        let plan = TestPlan(name: "MyPlan") {
            Phase(name: "p") { _ in .continue }
        }
        let schema = try decodeSchema(plan.exportSchema())
        XCTAssertEqual(schema["$schema"] as? String, "http://json-schema.org/draft-07/schema#")
        XCTAssertEqual(schema["title"] as? String, "MyPlan")
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertNotNil(schema["x-swifthtf-version"])
        XCTAssertNotNil(schema["properties"])
    }

    func testInRangeInclusiveMaps() throws {
        let plan = TestPlan(name: "p") {
            Phase(
                name: "k",
                measurements: [.named("vcc", unit: "V").inRange(3.0, 3.6)]
            ) { _ in .continue }
        }
        let schema = try decodeSchema(plan.exportSchema())
        let props = try XCTUnwrap(schema["properties"] as? [String: Any])
        let vcc = try XCTUnwrap(props["vcc"] as? [String: Any])
        XCTAssertEqual(vcc["type"] as? String, "number")
        XCTAssertEqual(vcc["minimum"] as? Double, 3.0)
        XCTAssertEqual(vcc["maximum"] as? Double, 3.6)
        XCTAssertEqual(vcc["x-swifthtf-unit"] as? String, "V")
    }

    func testInRangeExclusiveMaps() throws {
        let plan = TestPlan(name: "p") {
            Phase(
                name: "k",
                measurements: [.named("v").inRange(0, 1, inclusive: false)]
            ) { _ in .continue }
        }
        let schema = try decodeSchema(plan.exportSchema())
        let v = try property("v", in: schema)
        XCTAssertEqual(v["exclusiveMinimum"] as? Double, 0)
        XCTAssertEqual(v["exclusiveMaximum"] as? Double, 1)
        XCTAssertNil(v["minimum"], "exclusive 时不应同时写 minimum")
    }

    func testEqualsMapsToConst() throws {
        let plan = TestPlan(name: "p") {
            Phase(
                name: "k",
                measurements: [.named("model").equals("XK-1")]
            ) { _ in .continue }
        }
        let schema = try decodeSchema(plan.exportSchema())
        let m = try property("model", in: schema)
        XCTAssertEqual(m["const"] as? String, "XK-1")
    }

    func testRegexMapsToPattern() throws {
        let plan = TestPlan(name: "p") {
            Phase(
                name: "k",
                measurements: [.named("sn").matchesRegex("^SN-[0-9]{4}$")]
            ) { _ in .continue }
        }
        let schema = try decodeSchema(plan.exportSchema())
        let sn = try property("sn", in: schema)
        XCTAssertEqual(sn["type"] as? String, "string")
        XCTAssertEqual(sn["pattern"] as? String, "^SN-[0-9]{4}$")
    }

    func testWithinPercentMapsToBounds() throws {
        let plan = TestPlan(name: "p") {
            Phase(
                name: "k",
                measurements: [.named("f").withinPercent(of: 100, percent: 5)]
            ) { _ in .continue }
        }
        let schema = try decodeSchema(plan.exportSchema())
        let f = try property("f", in: schema)
        XCTAssertEqual(f["minimum"] as? Double, 95)
        XCTAssertEqual(f["maximum"] as? Double, 105)
    }

    func testOneOfMapsToEnum() throws {
        let plan = TestPlan(name: "p") {
            Phase(
                name: "k",
                measurements: [.named("color").oneOf(["R", "G", "B"])]
            ) { _ in .continue }
        }
        let schema = try decodeSchema(plan.exportSchema())
        let c = try property("color", in: schema)
        XCTAssertEqual(c["enum"] as? [String], ["R", "G", "B"])
    }

    func testLengthEqualsWritesBothLengthAndItems() throws {
        let plan = TestPlan(name: "p") {
            Phase(
                name: "k",
                measurements: [.named("tag").lengthEquals(4)]
            ) { _ in .continue }
        }
        let schema = try decodeSchema(plan.exportSchema())
        let t = try property("tag", in: schema)
        XCTAssertEqual(t["minLength"] as? Int, 4)
        XCTAssertEqual(t["maxLength"] as? Int, 4)
        XCTAssertEqual(t["minItems"] as? Int, 4)
        XCTAssertEqual(t["maxItems"] as? Int, 4)
    }

    func testUnmappedValidatorsAppearInExtension() throws {
        let plan = TestPlan(name: "p") {
            Phase(
                name: "k",
                measurements: [
                    .named("v")
                        .inRange(0, 10)
                        .marginalRange(2, 8)
                        .notEmpty(),
                ]
            ) { _ in .continue }
        }
        let schema = try decodeSchema(plan.exportSchema())
        let v = try property("v", in: schema)
        let ext = try XCTUnwrap(v["x-swifthtf-validators"] as? [String])
        XCTAssertTrue(ext.contains { $0.starts(with: "marginal_range") })
        XCTAssertTrue(ext.contains("not_empty"))
        // inRange 仍写到标准字段
        XCTAssertEqual(v["minimum"] as? Double, 0)
    }

    func testOptionalFlagWritten() throws {
        let plan = TestPlan(name: "p") {
            Phase(
                name: "k",
                measurements: [.named("v").inRange(0, 1).optional()]
            ) { _ in .continue }
        }
        let schema = try decodeSchema(plan.exportSchema())
        let v = try property("v", in: schema)
        XCTAssertEqual(v["x-swifthtf-optional"] as? Bool, true)
    }

    // MARK: - Series

    func testSeriesSpecMaps() throws {
        let plan = TestPlan(name: "p") {
            Phase(
                name: "iv",
                series: [
                    .named("curve", description: "IV sweep")
                        .dimension("V", unit: "V")
                        .value("I", unit: "A")
                        .lengthInRange(10, 100),
                ]
            ) { _ in .continue }
        }
        let schema = try decodeSchema(plan.exportSchema())
        let curve = try property("curve", in: schema)
        XCTAssertEqual(curve["type"] as? String, "array")
        XCTAssertEqual(curve["minItems"] as? Int, 10)
        XCTAssertEqual(curve["maxItems"] as? Int, 100)
        XCTAssertEqual(curve["description"] as? String, "IV sweep")
        let meta = try XCTUnwrap(curve["x-swifthtf-series"] as? [String: Any])
        let dims = try XCTUnwrap(meta["dimensions"] as? [[String: Any]])
        XCTAssertEqual(dims.first?["name"] as? String, "V")
        XCTAssertEqual(dims.first?["unit"] as? String, "V")
        let value = try XCTUnwrap(meta["value"] as? [String: Any])
        XCTAssertEqual(value["name"] as? String, "I")
    }

    // MARK: - 嵌套结构遍历

    func testGroupAndSubtestNodesContribute() throws {
        let plan = TestPlan(name: "p") {
            Group("setup") {
                Phase(name: "init", measurements: [.named("init_v").inRange(0, 1)]) { _ in .continue }
            }
            Subtest("main") {
                Phase(name: "core", measurements: [.named("core_v").inRange(2, 3)]) { _ in .continue }
            }
            Phase(name: "top", measurements: [.named("top_v").inRange(4, 5)]) { _ in .continue }
        }
        let schema = try decodeSchema(plan.exportSchema())
        let props = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(props["init_v"], "group 内 phase")
        XCTAssertNotNil(props["core_v"], "subtest 内 phase")
        XCTAssertNotNil(props["top_v"], "顶层 phase")
    }
}
