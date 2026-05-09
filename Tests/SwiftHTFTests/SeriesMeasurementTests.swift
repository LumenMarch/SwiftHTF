import XCTest
@testable import SwiftHTF

final class SeriesMeasurementTests: XCTestCase {

    // MARK: - 数据模型 / JSON 往返

    func testSeriesMeasurementJSONRoundTrip() throws {
        let m = SeriesMeasurement(
            name: "iv",
            description: "IV sweep",
            dimensions: [Dimension(name: "V", unit: "V")],
            value: Dimension(name: "I", unit: "A"),
            samples: [
                [.double(0.0), .double(0.001)],
                [.double(1.0), .double(0.012)],
                [.double(2.0), .double(0.025)],
            ],
            outcome: .pass,
            validatorMessages: []
        )
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(SeriesMeasurement.self, from: data)
        XCTAssertEqual(decoded.name, "iv")
        XCTAssertEqual(decoded.dimensions.first?.name, "V")
        XCTAssertEqual(decoded.value.name, "I")
        XCTAssertEqual(decoded.samples.count, 3)
        XCTAssertEqual(decoded.samples[1][0].asDouble, 1.0)
        XCTAssertEqual(decoded.samples[1][1].asDouble, 0.012)
    }

    func testColumnLayout() {
        let m = SeriesMeasurement(
            name: "x",
            dimensions: [
                Dimension(name: "A", unit: "u1"),
                Dimension(name: "B", unit: "u2"),
            ],
            value: Dimension(name: "Y", unit: "v")
        )
        XCTAssertEqual(m.columnLayout.map(\.name), ["A", "B", "Y"])
    }

    // MARK: - 端到端 phase 集成

    func testRecordSeriesAndHarvestPasses() async throws {
        let plan = TestPlan(name: "iv-pass") {
            Phase(
                name: "sweep",
                series: [
                    .named("iv")
                        .dimension("V", unit: "V")
                        .value("I", unit: "A")
                        .lengthAtLeast(3)
                ]
            ) { @MainActor ctx in
                await ctx.recordSeries("iv") { rec in
                    rec.append(0.0, 0.001)
                    rec.append(1.0, 0.012)
                    rec.append(2.0, 0.025)
                }
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute(serialNumber: "SN-1")
        XCTAssertEqual(record.outcome, .pass)
        let phaseRec = record.phases.first
        XCTAssertNotNil(phaseRec)
        XCTAssertEqual(phaseRec?.outcome, .pass)
        let trace = phaseRec?.traces["iv"]
        XCTAssertNotNil(trace)
        XCTAssertEqual(trace?.samples.count, 3)
        XCTAssertEqual(trace?.dimensions.first?.unit, "V")
        XCTAssertEqual(trace?.value.unit, "A")
        XCTAssertEqual(trace?.outcome, .pass)
    }

    func testEachValidatorFailsPhase() async throws {
        let plan = TestPlan(name: "iv-overcurrent") {
            Phase(
                name: "sweep",
                series: [
                    .named("iv")
                        .dimension("V", unit: "V")
                        .value("I", unit: "A")
                        .each { sample in
                            let i = sample[1].asDouble ?? 0
                            return i < 0.1 ? .pass : .fail("over current \(i)")
                        }
                ]
            ) { @MainActor ctx in
                await ctx.recordSeries("iv") { rec in
                    rec.append(0.0, 0.001)
                    rec.append(1.0, 0.05)
                    rec.append(2.0, 0.5)  // 触发 fail
                }
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute(serialNumber: "SN-2")
        XCTAssertEqual(record.outcome, .fail)
        let trace = record.phases.first?.traces["iv"]
        XCTAssertEqual(trace?.outcome, .fail)
        XCTAssertFalse(trace?.validatorMessages.isEmpty ?? true)
        XCTAssertTrue(
            trace?.validatorMessages.first?.contains("over current") ?? false,
            "应该带有 each label"
        )
    }

    func testEachValidatorMarginalPropagatesToPhase() async throws {
        let plan = TestPlan(name: "iv-marginal") {
            Phase(
                name: "sweep",
                series: [
                    .named("iv")
                        .dimension("V", unit: "V")
                        .value("I", unit: "A")
                        .each { sample in
                            let i = sample[1].asDouble ?? 0
                            if i > 0.04 {
                                return .marginal("接近上限")
                            }
                            return .pass
                        }
                ]
            ) { @MainActor ctx in
                await ctx.recordSeries("iv") { rec in
                    rec.append(0.0, 0.001)
                    rec.append(1.0, 0.045)  // 触发 marginal
                }
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute(serialNumber: "SN-3")
        XCTAssertEqual(record.outcome, .marginalPass)
        XCTAssertEqual(record.phases.first?.outcome, .marginalPass)
        XCTAssertEqual(record.phases.first?.traces["iv"]?.outcome, .marginalPass)
    }

    func testLengthAtLeastFails() async throws {
        let plan = TestPlan(name: "too-short") {
            Phase(
                name: "sweep",
                series: [
                    .named("iv")
                        .dimension("V", unit: "V")
                        .value("I", unit: "A")
                        .lengthAtLeast(5)
                ]
            ) { @MainActor ctx in
                await ctx.recordSeries("iv") { rec in
                    rec.append(0.0, 0.001)
                    rec.append(1.0, 0.002)
                }
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute(serialNumber: "SN-4")
        XCTAssertEqual(record.outcome, .fail)
        let trace = record.phases.first?.traces["iv"]
        XCTAssertEqual(trace?.outcome, .fail)
    }

    func testRepeatOnMeasurementFailRetriggersForSeries() async throws {
        actor Counter { var n = 0; func incr() -> Int { n += 1; return n } }
        let counter = Counter()
        let plan = TestPlan(name: "retry-series") {
            Phase(
                name: "sweep",
                series: [
                    .named("iv")
                        .dimension("V", unit: "V")
                        .value("I", unit: "A")
                        .lengthAtLeast(2)
                ],
                repeatOnMeasurementFail: 2
            ) { @MainActor ctx in
                let attempt = await counter.incr()
                await ctx.recordSeries("iv") { rec in
                    rec.append(0.0, 0.001)
                    if attempt >= 2 {
                        rec.append(1.0, 0.002)  // 第二次起够长
                    }
                }
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute(serialNumber: "SN-5")
        XCTAssertEqual(record.outcome, .pass, "第二次 attempt 应通过")
        let n = await counter.n
        XCTAssertEqual(n, 2, "应有 1 次重跑")
    }

    func testExplicitDimensionsOverrideSpec() async throws {
        // recordSeries 显式传维度时应优先于 spec
        let plan = TestPlan(name: "override") {
            Phase(
                name: "sweep",
                series: [
                    .named("iv")
                        .dimension("V", unit: "V")
                        .value("I", unit: "A")
                ]
            ) { @MainActor ctx in
                await ctx.recordSeries(
                    "iv",
                    dimensions: [Dimension(name: "Freq", unit: "Hz")],
                    value: Dimension(name: "Gain", unit: "dB")
                ) { rec in
                    rec.append(1000, 20)
                }
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute(serialNumber: "SN-6")
        let trace = record.phases.first?.traces["iv"]
        XCTAssertEqual(trace?.dimensions.first?.name, "Freq")
        XCTAssertEqual(trace?.value.name, "Gain")
    }

    func testNoSpecMatchTraceStillRecorded() async throws {
        // recordSeries 用了 spec 不存在的名字：仍然写入 record，但不跑 validator
        let plan = TestPlan(name: "no-spec") {
            Phase(name: "sweep") { @MainActor ctx in
                await ctx.recordSeries(
                    "ad-hoc",
                    dimensions: [Dimension(name: "x")],
                    value: Dimension(name: "y")
                ) { rec in
                    rec.append(1, 2)
                }
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute(serialNumber: "SN-7")
        XCTAssertEqual(record.outcome, .pass)
        let trace = record.phases.first?.traces["ad-hoc"]
        XCTAssertNotNil(trace)
        XCTAssertEqual(trace?.outcome, .pass)
        XCTAssertTrue(trace?.validatorMessages.isEmpty ?? false)
    }

    func testCustomSeriesValidator() async throws {
        // 自定义全量校验：要求采样按 V 单调递增
        let plan = TestPlan(name: "monotonic") {
            Phase(
                name: "sweep",
                series: [
                    .named("iv")
                        .dimension("V", unit: "V")
                        .value("I", unit: "A")
                        .custom(label: "monotonic_v") { samples, _, _ in
                            var prev = -Double.infinity
                            for row in samples {
                                guard let v = row.first?.asDouble else {
                                    return .fail("非数值")
                                }
                                if v <= prev { return .fail("V 非单调递增 at \(v)") }
                                prev = v
                            }
                            return .pass
                        }
                ]
            ) { @MainActor ctx in
                await ctx.recordSeries("iv") { rec in
                    rec.append(0.0, 0.001)
                    rec.append(2.0, 0.020)
                    rec.append(1.0, 0.010)  // 不单调
                }
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let record = await executor.execute(serialNumber: "SN-8")
        XCTAssertEqual(record.outcome, .fail)
        XCTAssertEqual(record.phases.first?.traces["iv"]?.outcome, .fail)
    }

    func testPhaseRecordTracesJSONRoundTrip() throws {
        var rec = PhaseRecord(name: "p")
        rec.outcome = .pass
        rec.traces["iv"] = SeriesMeasurement(
            name: "iv",
            dimensions: [Dimension(name: "V", unit: "V")],
            value: Dimension(name: "I", unit: "A"),
            samples: [[.double(1), .double(0.01)]],
            outcome: .pass
        )
        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(PhaseRecord.self, from: data)
        XCTAssertEqual(decoded.traces["iv"]?.samples.first?[1].asDouble, 0.01)
    }
}
