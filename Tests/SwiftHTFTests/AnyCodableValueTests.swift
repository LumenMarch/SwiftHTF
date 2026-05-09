@testable import SwiftHTF
import XCTest

final class AnyCodableValueTests: XCTestCase {
    func testRoundTripBool() throws {
        try assertRoundTrip(.bool(true))
        try assertRoundTrip(.bool(false))
    }

    func testRoundTripInt() throws {
        try assertRoundTrip(.int(42))
        try assertRoundTrip(.int(-1))
    }

    func testRoundTripDouble() throws {
        try assertRoundTrip(.double(3.14))
    }

    func testRoundTripString() throws {
        try assertRoundTrip(.string("hello"))
        try assertRoundTrip(.string(""))
    }

    func testRoundTripArray() throws {
        try assertRoundTrip(.array([.int(1), .string("two"), .bool(false)]))
    }

    func testRoundTripObject() throws {
        try assertRoundTrip(.object(["a": .int(1), "b": .string("x")]))
    }

    func testRoundTripNull() throws {
        try assertRoundTrip(.null)
    }

    // MARK: - 类型化访问器

    func testAsBool() {
        XCTAssertEqual(AnyCodableValue.bool(true).asBool, true)
        XCTAssertNil(AnyCodableValue.int(1).asBool)
    }

    func testAsInt() {
        XCTAssertEqual(AnyCodableValue.int(42).asInt, 42)
        XCTAssertEqual(AnyCodableValue.double(7.0).asInt, 7) // 整数 double 也算
        XCTAssertNil(AnyCodableValue.double(3.14).asInt)
        XCTAssertNil(AnyCodableValue.string("3").asInt)
    }

    func testAsDouble() {
        XCTAssertEqual(AnyCodableValue.double(3.14).asDouble, 3.14)
        XCTAssertEqual(AnyCodableValue.int(7).asDouble, 7.0)
        XCTAssertNil(AnyCodableValue.bool(true).asDouble)
    }

    func testAsString() {
        XCTAssertEqual(AnyCodableValue.string("x").asString, "x")
        XCTAssertNil(AnyCodableValue.int(1).asString)
    }

    // MARK: - From Encodable

    func testFromBool() {
        XCTAssertEqual(AnyCodableValue.from(true), .bool(true))
    }

    func testFromInt() {
        XCTAssertEqual(AnyCodableValue.from(42), .int(42))
    }

    func testFromDouble() {
        XCTAssertEqual(AnyCodableValue.from(3.14), .double(3.14))
    }

    func testFromString() {
        XCTAssertEqual(AnyCodableValue.from("hello"), .string("hello"))
    }

    func testFromCustomEncodable() {
        struct Pair: Encodable { let x: Int; let y: String }
        let p = Pair(x: 1, y: "a")
        let coded = AnyCodableValue.from(p)
        if case let .object(dict) = coded {
            XCTAssertEqual(dict["x"], .int(1))
            XCTAssertEqual(dict["y"], .string("a"))
        } else {
            XCTFail("期望 object 类型")
        }
    }

    // MARK: - displayString

    func testDisplayString() {
        XCTAssertEqual(AnyCodableValue.bool(true).displayString, "true")
        XCTAssertEqual(AnyCodableValue.int(42).displayString, "42")
        XCTAssertEqual(AnyCodableValue.string("hi").displayString, "hi")
        XCTAssertEqual(AnyCodableValue.null.displayString, "")
    }

    // MARK: - Helper

    private func assertRoundTrip(_ value: AnyCodableValue) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(value, decoded)
    }
}
