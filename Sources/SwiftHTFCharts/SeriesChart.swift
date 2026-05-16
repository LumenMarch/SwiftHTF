import Foundation
import SwiftHTF
import SwiftUI
#if canImport(Charts)
import Charts
#endif

/// 把 `SeriesMeasurement` 一行渲染成折线图。
///
/// 自动按 `dimensions.count` 推断 layout：
/// - **1D**（如 IV 曲线 `dimensions: [V]`, value: `I`）→ 一条 LineMark，dim[0] 作 X 轴
/// - **2D**（如 `dimensions: [V, temperature]`）→ 多条 LineMark，dim[1] 分组分色
/// - **0D**（无 dimensions，纯采样列表）→ 用 sample index 作 X 轴
///
/// 用法：
/// ```swift
/// SeriesChart(trace: trace)
///     .frame(height: 200)
///     .specRange(2.8...3.6)            // 可选：画 spec 范围带
///     .xAxisLabel("VCC (V)")           // 可选：覆写自动轴 label
/// ```
///
/// 隔离：纯 SwiftUI 视图，可在任意 view body 中使用。要求 macOS 13+ / iOS 16+（Apple Charts）。
@available(macOS 13.0, iOS 16.0, *)
public struct SeriesChart: View {
    private let trace: SeriesMeasurement
    private var specRange: ClosedRange<Double>?
    private var xLabelOverride: String?
    private var yLabelOverride: String?
    private var showLegend: Bool

    public init(trace: SeriesMeasurement) {
        self.trace = trace
        self.specRange = nil
        self.xLabelOverride = nil
        self.yLabelOverride = nil
        self.showLegend = true
    }

    public var body: some View {
        #if canImport(Charts)
        chartBody
        #else
        Text("Charts framework 不可用")
            .foregroundColor(.secondary)
            .font(.caption)
        #endif
    }

    #if canImport(Charts)
    @ViewBuilder
    private var chartBody: some View {
        let points = SeriesChartLayout.points(from: trace)
        Chart {
            ForEach(points) { p in
                LineMark(
                    x: .value(xLabel, p.x),
                    y: .value(yLabel, p.y)
                )
                .foregroundStyle(by: .value("series", p.series ?? defaultSeriesName))
                .interpolationMethod(.monotone)
            }
            if let range = specRange {
                RuleMark(y: .value("lo", range.lowerBound))
                    .foregroundStyle(traceColor.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(y: .value("hi", range.upperBound))
                    .foregroundStyle(traceColor.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXAxisLabel(xLabel)
        .chartYAxisLabel(yLabel)
        .chartLegend(showLegend && trace.dimensions.count >= 2 ? .visible : .hidden)
        .chartForegroundStyleScale(range: [traceColor])
    }

    private var defaultSeriesName: String {
        trace.value.name
    }

    private var traceColor: Color {
        switch trace.outcome {
        case .pass: .green
        case .marginalPass: .yellow
        case .skip: .gray
        case .fail, .error, .timeout: .red
        }
    }
    #endif

    private var xLabel: String {
        if let custom = xLabelOverride { return custom }
        if let first = trace.dimensions.first {
            return SeriesChartLayout.axisLabel(for: first)
        }
        return "index"
    }

    private var yLabel: String {
        if let custom = yLabelOverride { return custom }
        return SeriesChartLayout.axisLabel(for: trace.value)
    }
}

// MARK: - Modifiers

@available(macOS 13.0, iOS 16.0, *)
public extension SeriesChart {
    /// 画一条上下限范围带（虚线 RuleMark）。常用于把 `MeasurementSpec.inRange(lo, hi)` 投影到图上。
    func specRange(_ range: ClosedRange<Double>) -> SeriesChart {
        var copy = self
        copy.specRange = range
        return copy
    }

    /// 覆写 X 轴 label（默认从 `dimensions[0]` 推断）。
    func xAxisLabel(_ text: String) -> SeriesChart {
        var copy = self
        copy.xLabelOverride = text
        return copy
    }

    /// 覆写 Y 轴 label（默认从 `value.name + unit` 推断）。
    func yAxisLabel(_ text: String) -> SeriesChart {
        var copy = self
        copy.yLabelOverride = text
        return copy
    }

    /// 是否显示 legend（默认仅 2D 时显示）。
    func showLegend(_ visible: Bool) -> SeriesChart {
        var copy = self
        copy.showLegend = visible
        return copy
    }
}
