import SwiftHTF
@testable import SwiftHTFCharts
import XCTest

/// 验证 `SeriesChartLayout.points(from:)` 在 0D / 1D / 2D 上的投影。
final class SeriesChartLayoutTests: XCTestCase {
    func testOneDimensionalLayoutTakesFirstColumnAsX() {
        let trace = SeriesMeasurement(
            name: "iv",
            dimensions: [SwiftHTF.Dimension(name: "V", unit: "V")],
            value: SwiftHTF.Dimension(name: "I", unit: "A"),
            samples: [
                [.double(0.0), .double(0.0)],
                [.double(1.0), .double(0.5)],
                [.double(2.0), .double(1.1)],
            ]
        )
        let pts = SeriesChartLayout.points(from: trace)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[0].x, 0.0)
        XCTAssertEqual(pts[0].y, 0.0)
        XCTAssertEqual(pts[2].x, 2.0)
        XCTAssertEqual(pts[2].y, 1.1)
        XCTAssertNil(pts[0].series)
    }

    func testTwoDimensionalLayoutGroupsBySecondColumn() {
        let trace = SeriesMeasurement(
            name: "iv_vs_temp",
            dimensions: [SwiftHTF.Dimension(name: "V", unit: "V"), SwiftHTF.Dimension(name: "T", unit: "C")],
            value: SwiftHTF.Dimension(name: "I", unit: "A"),
            samples: [
                [.double(1.0), .double(25), .double(0.5)],
                [.double(2.0), .double(25), .double(1.1)],
                [.double(1.0), .double(85), .double(0.7)],
                [.double(2.0), .double(85), .double(1.4)],
            ]
        )
        let pts = SeriesChartLayout.points(from: trace)
        XCTAssertEqual(pts.count, 4)
        XCTAssertEqual(pts[0].series, "25.0")
        XCTAssertEqual(pts[2].series, "85.0")
    }

    func testZeroDimensionalLayoutUsesIndexAsX() {
        let trace = SeriesMeasurement(
            name: "raw",
            dimensions: [],
            value: SwiftHTF.Dimension(name: "v", unit: "V"),
            samples: [[.double(0.1)], [.double(0.2)], [.double(0.15)]]
        )
        let pts = SeriesChartLayout.points(from: trace)
        XCTAssertEqual(pts.map(\.x), [0, 1, 2])
        XCTAssertEqual(pts.map(\.y), [0.1, 0.2, 0.15])
    }

    func testSamplesWithNonNumericValuesAreSkipped() {
        let trace = SeriesMeasurement(
            name: "iv",
            dimensions: [SwiftHTF.Dimension(name: "V", unit: "V")],
            value: SwiftHTF.Dimension(name: "I", unit: "A"),
            samples: [
                [.double(0.0), .double(0.0)],
                [.double(1.0), .string("N/A")],
                [.double(2.0), .double(1.1)],
            ]
        )
        let pts = SeriesChartLayout.points(from: trace)
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(pts.map(\.x), [0.0, 2.0])
    }

    func testAxisLabelIncludesUnitWhenPresent() {
        XCTAssertEqual(
            SeriesChartLayout.axisLabel(for: SwiftHTF.Dimension(name: "V", unit: "V")),
            "V (V)"
        )
        XCTAssertEqual(
            SeriesChartLayout.axisLabel(for: SwiftHTF.Dimension(name: "index", unit: nil)),
            "index"
        )
        XCTAssertEqual(
            SeriesChartLayout.axisLabel(for: SwiftHTF.Dimension(name: "x", unit: "")),
            "x"
        )
    }

    func testEmptySamplesProduceEmptyPoints() {
        let trace = SeriesMeasurement(
            name: "empty",
            dimensions: [SwiftHTF.Dimension(name: "x")],
            value: SwiftHTF.Dimension(name: "y")
        )
        XCTAssertTrue(SeriesChartLayout.points(from: trace).isEmpty)
    }
}
