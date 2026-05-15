@testable import SwiftHTF
import XCTest

final class TestMetadataTests: XCTestCase {
    // MARK: - SessionMetadata 合并

    func testMergingOverridesNonNilFields() {
        let base = SessionMetadata(
            stationInfo: StationInfo(stationId: "STN-1", stationName: "焊接 A"),
            dutInfo: DUTInfo(partNumber: "PN-100"),
            codeInfo: CodeInfo(version: "1.0", gitCommit: "abc"),
            operatorName: "alice"
        )
        let override = SessionMetadata(
            stationInfo: StationInfo(stationId: "STN-2"),
            operatorName: "bob"
        )
        let merged = base.merging(override)
        XCTAssertEqual(merged.stationInfo?.stationId, "STN-2", "整字段替换")
        XCTAssertNil(merged.stationInfo?.stationName, "整字段替换不做 deep merge")
        XCTAssertEqual(merged.dutInfo?.partNumber, "PN-100", "未覆盖的字段保留")
        XCTAssertEqual(merged.codeInfo?.gitCommit, "abc")
        XCTAssertEqual(merged.operatorName, "bob")
    }

    func testMergingWithNilReturnsBase() {
        let base = SessionMetadata(operatorName: "alice")
        let merged = base.merging(nil)
        XCTAssertEqual(merged.operatorName, "alice")
    }

    // MARK: - Executor 注入

    func testExecutorDefaultMetadataAppearsInRecord() async {
        let defaults = SessionMetadata(
            stationInfo: StationInfo(stationId: "STN-PROD-1", location: "SH-3F"),
            codeInfo: CodeInfo(version: "1.2.3", gitCommit: "deadbeef"),
            operatorName: "alice"
        )
        let plan = TestPlan(name: "p") {
            Phase(name: "p1") { _ in .continue }
        }
        let record = await TestExecutor(plan: plan, defaultMetadata: defaults).execute()
        XCTAssertEqual(record.stationInfo?.stationId, "STN-PROD-1")
        XCTAssertEqual(record.stationInfo?.location, "SH-3F")
        XCTAssertEqual(record.codeInfo?.version, "1.2.3")
        XCTAssertEqual(record.operatorName, "alice")
    }

    func testPerSessionMetadataOverridesDefault() async {
        let defaults = SessionMetadata(
            stationInfo: StationInfo(stationId: "STN-A"),
            operatorName: "alice"
        )
        let plan = TestPlan(name: "p") {
            Phase(name: "p1") { _ in .continue }
        }
        let executor = TestExecutor(plan: plan, defaultMetadata: defaults)
        let r1 = await executor.execute(
            serialNumber: "SN-1",
            metadata: SessionMetadata(operatorName: "bob")
        )
        XCTAssertEqual(r1.stationInfo?.stationId, "STN-A", "未覆盖字段继承")
        XCTAssertEqual(r1.operatorName, "bob", "per-session 覆盖 default")
    }

    func testDUTInfoAttributesPersist() async {
        let dut = DUTInfo(
            partNumber: "PN-X",
            attributes: ["lot": .string("L001"), "wafer": .int(7)]
        )
        let plan = TestPlan(name: "p") { Phase(name: "p1") { _ in .continue } }
        let record = await TestExecutor(plan: plan).execute(
            metadata: SessionMetadata(dutInfo: dut)
        )
        XCTAssertEqual(record.dutInfo?.partNumber, "PN-X")
        XCTAssertEqual(record.dutInfo?.attributes["lot"]?.asString, "L001")
        XCTAssertEqual(record.dutInfo?.attributes["wafer"]?.asInt, 7)
    }

    // MARK: - Codable 兼容旧 JSON

    func testRoundTripWithAllMetadata() throws {
        var record = TestRecord(planName: "p", serialNumber: "SN-1")
        record.stationInfo = StationInfo(stationId: "STN-1", hostName: "tester-01.local")
        record.dutInfo = DUTInfo(partNumber: "PN-1", deviceType: "module")
        record.codeInfo = CodeInfo(version: "1.0", gitCommit: "abc123")
        record.operatorName = "alice"
        record.outcome = .pass
        record.endTime = Date()

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let data = try enc.encode(record)
        let decoded = try dec.decode(TestRecord.self, from: data)

        XCTAssertEqual(decoded.stationInfo?.stationId, "STN-1")
        XCTAssertEqual(decoded.stationInfo?.hostName, "tester-01.local")
        XCTAssertEqual(decoded.dutInfo?.deviceType, "module")
        XCTAssertEqual(decoded.codeInfo?.gitCommit, "abc123")
        XCTAssertEqual(decoded.operatorName, "alice")
    }

    func testDecodesOldJSONWithoutMetadataFields() throws {
        // 模拟 v0.1.x 风格的 JSON：无 stationInfo / dutInfo / codeInfo / operatorName
        let oldJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "planName": "legacy",
          "startTime": 1715760000,
          "outcome": "PASS",
          "phases": [],
          "subtests": [],
          "diagnoses": [],
          "metadata": {}
        }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let r = try dec.decode(TestRecord.self, from: Data(oldJSON.utf8))
        XCTAssertEqual(r.planName, "legacy")
        XCTAssertNil(r.stationInfo)
        XCTAssertNil(r.dutInfo)
        XCTAssertNil(r.codeInfo)
        XCTAssertNil(r.operatorName)
    }

    // MARK: - HistoryQuery 过滤

    func testHistoryQueryFiltersByStationAndOperator() async throws {
        let store = InMemoryHistoryStore()
        func record(
            sn: String, station: String, operatorName: String
        ) -> TestRecord {
            var r = TestRecord(planName: "p", serialNumber: sn)
            r.stationInfo = StationInfo(stationId: station)
            r.operatorName = operatorName
            r.outcome = .pass
            r.endTime = Date()
            return r
        }
        try await store.save(record(sn: "S1", station: "STN-A", operatorName: "alice"))
        try await store.save(record(sn: "S2", station: "STN-A", operatorName: "bob"))
        try await store.save(record(sn: "S3", station: "STN-B", operatorName: "alice"))

        let byStation = try await store.list(HistoryQuery(stationId: "STN-A"))
        XCTAssertEqual(byStation.count, 2)
        XCTAssertTrue(byStation.allSatisfy { $0.stationInfo?.stationId == "STN-A" })

        let byOp = try await store.list(HistoryQuery(operatorName: "alice"))
        XCTAssertEqual(byOp.count, 2)

        let both = try await store.list(
            HistoryQuery(stationId: "STN-A", operatorName: "alice")
        )
        XCTAssertEqual(both.count, 1)
        XCTAssertEqual(both.first?.serialNumber, "S1")
    }

    func testHistoryQueryEmptyFiltersAllowAll() async throws {
        let store = InMemoryHistoryStore()
        var r = TestRecord(planName: "p", serialNumber: "S1")
        r.outcome = .pass
        r.endTime = Date()
        try await store.save(r)
        let all = try await store.list(.all)
        XCTAssertEqual(all.count, 1)
    }
}
