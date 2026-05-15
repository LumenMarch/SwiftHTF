@testable import SwiftHTF
import XCTest

final class SeriesPlottingTests: XCTestCase {
    /// 构造一个 IV 曲线 series：dim V (V), value I (A)
    private func makeIVCurve() -> SeriesMeasurement {
        SeriesMeasurement(
            name: "iv",
            dimensions: [Dimension(name: "V", unit: "V")],
            value: Dimension(name: "I", unit: "A"),
            samples: [
                [.double(0.0), .double(0.0)],
                [.double(1.0), .double(0.1)],
                [.double(2.0), .double(0.25)],
                [.double(3.0), .double(0.4)],
            ]
        )
    }

    // MARK: - column / doubles

    func testColumnByDimensionName() {
        let s = makeIVCurve()
        let vs = s.column("V")
        XCTAssertEqual(vs?.map(\.asDouble), [0, 1, 2, 3])
    }

    func testColumnByValueName() {
        let s = makeIVCurve()
        let iCol = s.column("I")
        XCTAssertEqual(iCol?.map(\.asDouble), [0.0, 0.1, 0.25, 0.4])
    }

    func testColumnUnknownReturnsNil() {
        let s = makeIVCurve()
        XCTAssertNil(s.column("nope"))
    }

    func testDoublesDropsNonNumeric() {
        let s = SeriesMeasurement(
            name: "mix",
            dimensions: [Dimension(name: "x")],
            value: Dimension(name: "y"),
            samples: [
                [.double(1), .double(10)],
                [.double(2), .string("oops")], // y 非数字
                [.double(3), .double(30)],
            ]
        )
        XCTAssertEqual(s.doubles("y"), [10, 30])
        XCTAssertEqual(s.doubles("x"), [1, 2, 3])
    }

    // MARK: - points

    func testPointsByName() {
        let s = makeIVCurve()
        let pts = s.points(xDim: "V", yDim: "I")
        XCTAssertEqual(pts.count, 4)
        XCTAssertEqual(pts.map(\.x), [0, 1, 2, 3])
        XCTAssertEqual(pts.map(\.y), [0.0, 0.1, 0.25, 0.4])
    }

    func testPointsUnknownDimReturnsEmpty() {
        let s = makeIVCurve()
        XCTAssertTrue(s.points(xDim: "nope", yDim: "I").isEmpty)
        XCTAssertTrue(s.points(xDim: "V", yDim: "nope").isEmpty)
    }

    func testXyPointsDefaultsToFirstDimAndValue() {
        let s = makeIVCurve()
        let pts = s.xyPoints()
        XCTAssertEqual(pts.count, 4)
        XCTAssertEqual(pts.first?.x, 0)
        XCTAssertEqual(pts.last?.y, 0.4)
    }

    func testXyPointsEmptyWhenNoDimensions() {
        let s = SeriesMeasurement(
            name: "scalar",
            dimensions: [],
            value: Dimension(name: "v"),
            samples: [[.double(1)], [.double(2)]]
        )
        XCTAssertTrue(s.xyPoints().isEmpty)
    }

    func testPointsSkipsRowsWithNonNumeric() {
        let s = SeriesMeasurement(
            name: "iv",
            dimensions: [Dimension(name: "V")],
            value: Dimension(name: "I"),
            samples: [
                [.double(1), .double(0.1)],
                [.string("x"), .double(0.2)], // x 非数字
                [.double(3), .double(0.3)],
            ]
        )
        let pts = s.points(xDim: "V", yDim: "I")
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(pts.map(\.x), [1, 3])
    }

    // MARK: - xyzPoints

    func testXyzPointsForTwoDimensions() {
        let s = SeriesMeasurement(
            name: "heat",
            dimensions: [Dimension(name: "x"), Dimension(name: "y")],
            value: Dimension(name: "z"),
            samples: [
                [.double(0), .double(0), .double(10)],
                [.double(1), .double(0), .double(15)],
                [.double(0), .double(1), .double(20)],
            ]
        )
        let pts = s.xyzPoints()
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[0].z, 10)
        XCTAssertEqual(pts[2].y, 1)
    }

    func testXyzPointsEmptyForOneDimension() {
        let s = makeIVCurve()
        XCTAssertTrue(s.xyzPoints().isEmpty)
    }

    // MARK: - bounds

    func testBoundsReturnsMinMaxPerColumn() {
        let s = makeIVCurve()
        let b = s.bounds()
        XCTAssertEqual(b.count, 2) // V + I
        XCTAssertEqual(b[0].min, 0)
        XCTAssertEqual(b[0].max, 3)
        XCTAssertEqual(b[1].min, 0)
        XCTAssertEqual(b[1].max, 0.4)
    }

    func testBoundsEmptySeries() {
        let s = SeriesMeasurement(
            name: "empty",
            dimensions: [Dimension(name: "x")],
            value: Dimension(name: "y"),
            samples: []
        )
        let b = s.bounds()
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(b[0].min, 0)
        XCTAssertEqual(b[0].max, 0)
    }
}
