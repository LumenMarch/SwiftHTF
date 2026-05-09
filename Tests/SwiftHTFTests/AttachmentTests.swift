@testable import SwiftHTF
import XCTest

final class AttachmentTests: XCTestCase {
    func testAttachInline() async {
        let plan = TestPlan(name: "attach") {
            Phase(name: "snap") { @MainActor ctx in
                ctx.attach("hello", data: Data("hi".utf8), mimeType: "text/plain")
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        let phase = record.phases.first
        XCTAssertEqual(phase?.attachments.count, 1)
        XCTAssertEqual(phase?.attachments.first?.name, "hello")
        XCTAssertEqual(phase?.attachments.first?.mimeType, "text/plain")
        XCTAssertEqual(phase?.attachments.first?.data, Data("hi".utf8))
    }

    func testMultipleAttachmentsKeepOrder() async {
        let plan = TestPlan(name: "multi") {
            Phase(name: "p") { @MainActor ctx in
                ctx.attach("a", data: Data([0x01]), mimeType: "application/octet-stream")
                ctx.attach("b", data: Data([0x02]), mimeType: "application/octet-stream")
                ctx.attach("c", data: Data([0x03]), mimeType: "application/octet-stream")
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.phases.first?.attachments.map(\.name), ["a", "b", "c"])
    }

    func testAttachmentsResetBetweenPhases() async {
        let plan = TestPlan(name: "reset") {
            Phase(name: "first") { @MainActor ctx in
                ctx.attach("x", data: Data([0x01]), mimeType: "text/plain")
                return .continue
            }
            Phase(name: "second") { @MainActor ctx in
                XCTAssertTrue(ctx.attachments.isEmpty, "phase 间 ctx.attachments 应被重置")
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        XCTAssertEqual(record.phases.count, 2)
        XCTAssertEqual(record.phases[0].attachments.count, 1)
        XCTAssertEqual(record.phases[1].attachments.count, 0)
    }

    func testAttachFromFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifthtf_test_\(UUID().uuidString).log")
        try Data("line1\nline2".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = tmp
        let plan = TestPlan(name: "file") {
            Phase(name: "load") { @MainActor ctx in
                try ctx.attachFromFile(url)
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        let a = record.phases.first?.attachments.first
        XCTAssertEqual(a?.name, tmp.lastPathComponent)
        XCTAssertEqual(a?.mimeType, "text/plain")
        XCTAssertEqual(a?.data, Data("line1\nline2".utf8))
    }

    func testAttachFromFileExplicitNameAndMime() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob_\(UUID().uuidString).bin")
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp

        let plan = TestPlan(name: "rename") {
            Phase(name: "load") { @MainActor ctx in
                try ctx.attachFromFile(url, name: "payload", mimeType: "application/x-custom")
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        let a = record.phases.first?.attachments.first
        XCTAssertEqual(a?.name, "payload")
        XCTAssertEqual(a?.mimeType, "application/x-custom")
    }

    func testMimeTypeInference() {
        XCTAssertEqual(Attachment.mimeType(forPathExtension: "png"), "image/png")
        XCTAssertEqual(Attachment.mimeType(forPathExtension: "JPG"), "image/jpeg")
        XCTAssertEqual(Attachment.mimeType(forPathExtension: "txt"), "text/plain")
        XCTAssertEqual(Attachment.mimeType(forPathExtension: "log"), "text/plain")
        XCTAssertEqual(Attachment.mimeType(forPathExtension: "csv"), "text/csv")
        XCTAssertEqual(Attachment.mimeType(forPathExtension: "json"), "application/json")
        XCTAssertEqual(Attachment.mimeType(forPathExtension: "xyz"), "application/octet-stream")
    }

    // MARK: - Codable round-trip

    func testRecordWithAttachmentEncodesAndDecodes() async throws {
        let plan = TestPlan(name: "codable") {
            Phase(name: "p") { @MainActor ctx in
                ctx.attach("hello.txt", data: Data("hi".utf8), mimeType: "text/plain")
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TestRecord.self, from: data)

        let a = decoded.phases.first?.attachments.first
        XCTAssertEqual(a?.name, "hello.txt")
        XCTAssertEqual(a?.mimeType, "text/plain")
        XCTAssertEqual(a?.data, Data("hi".utf8))
    }

    func testJSONUsesBase64ForData() async throws {
        let plan = TestPlan(name: "base64") {
            Phase(name: "p") { @MainActor ctx in
                ctx.attach("blob", data: Data([0xCA, 0xFE]), mimeType: "application/octet-stream")
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let json = String(data: data, encoding: .utf8) ?? ""
        // base64("\xCA\xFE") == "yv4="
        XCTAssertTrue(json.contains("yv4="), "JSON 中应包含 base64 编码的 data")
    }
}
