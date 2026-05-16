@testable import SwiftHTF
import XCTest

/// `OutputFilenameTemplate` 渲染 + `JSONOutput / CSVOutput` 自定义模板落盘。
final class OutputFilenameTemplateTests: XCTestCase {
    // MARK: - 单纯渲染

    func testRendersKnownTokens() {
        var record = TestRecord(planName: "MyPlan", serialNumber: "SN-9001")
        record.outcome = .pass
        let tpl = OutputFilenameTemplate("{dut_id}.{start_time_millis}.{outcome}.json")
        let rendered = tpl.render(record: record)
        XCTAssertTrue(rendered.hasPrefix("SN-9001."), rendered)
        XCTAssertTrue(rendered.hasSuffix(".PASS.json"), rendered)
        // 中间是 milliseconds：仅校验全数字
        let mid = rendered.dropFirst("SN-9001.".count).dropLast(".PASS.json".count)
        XCTAssertTrue(mid.allSatisfy(\.isNumber))
    }

    func testFallsBackToNoSNWhenSerialMissing() {
        let record = TestRecord(planName: "p", serialNumber: nil)
        let tpl = OutputFilenameTemplate("{serial}.json")
        XCTAssertEqual(tpl.render(record: record), "noSN.json")
    }

    func testUnknownTokenStaysLiteral() {
        let record = TestRecord(planName: "p", serialNumber: "X")
        let tpl = OutputFilenameTemplate("{plan}_{unknown}.dat")
        XCTAssertEqual(tpl.render(record: record), "p_{unknown}.dat")
    }

    func testLegacyTemplateMatchesOldDefault() {
        let record = TestRecord(planName: "Plan", serialNumber: "SN")
        let tpl = OutputFilenameTemplate.legacy(ext: "json")
        let rendered = tpl.render(record: record)
        XCTAssertTrue(rendered.hasPrefix("Plan_SN_"), rendered)
        XCTAssertTrue(rendered.hasSuffix(".json"), rendered)
    }

    // MARK: - JSONOutput 写入磁盘走自定义模板

    func testJSONOutputWritesWithCustomTemplate() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifthtf-tpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tpl = OutputFilenameTemplate("{dut_id}.json")
        let output = JSONOutput(directory: dir, filenameTemplate: tpl)
        let plan = TestPlan(name: "tpl") {
            Phase(name: "p") { _ in .continue }
        }
        _ = await TestExecutor(plan: plan, outputCallbacks: [output]).execute(serialNumber: "DUT-42")

        let written = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(written, ["DUT-42.json"])
    }

    // MARK: - CSVOutput 同等

    func testCSVOutputWritesWithCustomTemplate() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifthtf-tpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tpl = OutputFilenameTemplate("{dut_id}.csv")
        let output = CSVOutput(directory: dir, filenameTemplate: tpl)
        let plan = TestPlan(name: "tpl") {
            Phase(name: "p") { _ in .continue }
        }
        _ = await TestExecutor(plan: plan, outputCallbacks: [output]).execute(serialNumber: "DUT-7")

        let written = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(written, ["DUT-7.csv"])
    }
}
