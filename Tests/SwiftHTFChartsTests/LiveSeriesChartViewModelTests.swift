import SwiftHTF
@testable import SwiftHTFCharts
import XCTest

/// 验证 `LiveSeriesChartViewModel` 对事件流的滚动聚合行为。
@MainActor
final class LiveSeriesChartViewModelTests: XCTestCase {
    func testHandleAppendsTracesFromPhaseCompleted() {
        let vm = LiveSeriesChartViewModel()
        var record = PhaseRecord(name: "Sweep")
        record.traces["iv"] = SeriesMeasurement(
            name: "iv",
            dimensions: [SwiftHTF.Dimension(name: "V", unit: "V")],
            value: SwiftHTF.Dimension(name: "I", unit: "A"),
            samples: [[.double(0), .double(0)], [.double(1), .double(0.5)]]
        )

        vm.handle(.phaseCompleted(record))

        XCTAssertEqual(vm.activeTraces.count, 1)
        XCTAssertEqual(vm.activeTraces[0].name, "iv")
        XCTAssertEqual(vm.activeTraces[0].samples.count, 2)
    }

    func testSamePhaseAndTraceNameOverwritesInPlace() {
        let vm = LiveSeriesChartViewModel()
        var first = PhaseRecord(name: "Sweep")
        first.traces["iv"] = SeriesMeasurement(
            name: "iv",
            dimensions: [SwiftHTF.Dimension(name: "V", unit: "V")],
            value: SwiftHTF.Dimension(name: "I", unit: "A"),
            samples: [[.double(0), .double(0)]]
        )
        var second = PhaseRecord(name: "Sweep")
        second.traces["iv"] = SeriesMeasurement(
            name: "iv",
            dimensions: [SwiftHTF.Dimension(name: "V", unit: "V")],
            value: SwiftHTF.Dimension(name: "I", unit: "A"),
            samples: [[.double(0), .double(0)], [.double(1), .double(0.5)]]
        )

        vm.handle(.phaseCompleted(first))
        vm.handle(.phaseCompleted(second))

        XCTAssertEqual(vm.activeTraces.count, 1)
        XCTAssertEqual(vm.activeTraces[0].samples.count, 2)
    }

    func testDifferentTraceNamesAccumulate() {
        let vm = LiveSeriesChartViewModel()
        var record = PhaseRecord(name: "Sweep")
        record.traces["iv"] = SeriesMeasurement(
            name: "iv",
            dimensions: [SwiftHTF.Dimension(name: "V")],
            value: SwiftHTF.Dimension(name: "I")
        )
        record.traces["temp"] = SeriesMeasurement(
            name: "temp",
            dimensions: [SwiftHTF.Dimension(name: "t", unit: "s")],
            value: SwiftHTF.Dimension(name: "T", unit: "C")
        )
        vm.handle(.phaseCompleted(record))
        XCTAssertEqual(vm.activeTraces.count, 2)
    }

    func testTestStartedSetsPlanName() {
        let vm = LiveSeriesChartViewModel()
        vm.handle(.testStarted(planName: "Smoke", serialNumber: "SN1"))
        XCTAssertEqual(vm.planName, "Smoke")
    }

    func testTestCompletedSetsOutcome() {
        let vm = LiveSeriesChartViewModel()
        var record = TestRecord(planName: "Smoke", serialNumber: "SN1")
        record.outcome = .pass
        vm.handle(.testCompleted(record))
        XCTAssertEqual(vm.outcome, .pass)
    }

    func testClearResetsState() {
        let vm = LiveSeriesChartViewModel()
        var record = PhaseRecord(name: "Sweep")
        record.traces["iv"] = SeriesMeasurement(
            name: "iv",
            dimensions: [SwiftHTF.Dimension(name: "V")],
            value: SwiftHTF.Dimension(name: "I"),
            samples: [[.double(0), .double(0)]]
        )
        vm.handle(.phaseCompleted(record))
        vm.handle(.testStarted(planName: "X", serialNumber: nil))
        vm.clear()
        XCTAssertTrue(vm.activeTraces.isEmpty)
        XCTAssertNil(vm.planName)
    }

    func testLogEventIsIgnored() {
        let vm = LiveSeriesChartViewModel()
        vm.handle(.log("hello"))
        XCTAssertTrue(vm.activeTraces.isEmpty)
        XCTAssertNil(vm.planName)
    }
}
