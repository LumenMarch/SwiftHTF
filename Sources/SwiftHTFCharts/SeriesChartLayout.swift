import Foundation
import SwiftHTF

/// `SeriesChart` 内部用的点投影 + 轴标签工具。
///
/// 拆出来便于单元测试在不依赖 SwiftUI / Charts 的情况下验证 1D / 2D / 0D 三种 layout 的转换正确性。
public enum SeriesChartLayout {
    /// 投影后的图表点。`series` 仅在 2D layout 下有值（用于 LineMark 分组）。
    public struct Point: Identifiable, Equatable {
        public let id: Int
        public let x: Double
        public let y: Double
        public let series: String?
    }

    /// 把 `SeriesMeasurement` 的 `samples` 转成图表点列表。
    ///
    /// - 1D（`dimensions.count == 1`）：x = dim[0], y = value，series = nil
    /// - 2D（`dimensions.count >= 2`）：x = dim[0], y = value，series = dim[1].displayString
    ///   （第三维及以上忽略；如有需求可后续追加 facet）
    /// - 0D（`dimensions.isEmpty`）：x = sample index, y = value，series = nil
    /// - 任何采样里取不出数值 → 跳过该样本（不抛错，便于实时增量场景）
    public static func points(from trace: SeriesMeasurement) -> [Point] {
        let layout = trace.dimensions.count
        var result: [Point] = []
        result.reserveCapacity(trace.samples.count)
        for (idx, row) in trace.samples.enumerated() {
            guard !row.isEmpty else { continue }
            let valueColumn = row.count - 1
            guard let yValue = row[valueColumn].asDouble else { continue }
            switch layout {
            case 0:
                result.append(Point(id: idx, x: Double(idx), y: yValue, series: nil))
            case 1:
                guard row.count >= 2, let xValue = row[0].asDouble else { continue }
                result.append(Point(id: idx, x: xValue, y: yValue, series: nil))
            default:
                guard row.count >= 3, let xValue = row[0].asDouble else { continue }
                let seriesLabel = row[1].displayString
                result.append(Point(id: idx, x: xValue, y: yValue, series: seriesLabel))
            }
        }
        return result
    }

    /// 拼装一个维度的轴 label：`"name (unit)"` 或 `"name"`。
    public static func axisLabel(for dimension: SwiftHTF.Dimension) -> String {
        if let unit = dimension.unit, !unit.isEmpty {
            return "\(dimension.name) (\(unit))"
        }
        return dimension.name
    }
}
