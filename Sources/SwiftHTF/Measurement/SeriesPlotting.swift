import Foundation

/// 把 `SeriesMeasurement` 转成画图友好的数据形态。
///
/// **不引第三方依赖**（包括 SwiftUI `Charts`）—— 仅暴露纯数值数组，让用户在
/// SwiftUI / AppKit / 其它图库里自由组装。例如：
///
/// ```swift
/// // SwiftUI Charts (macOS 13+ / iOS 16+)
/// import Charts
/// let pts = series.xyPoints()
/// Chart(pts, id: \.0) { LineMark(x: .value("V", $0.0), y: .value("I", $0.1)) }
/// ```
public extension SeriesMeasurement {
    /// 按维度名取该列所有值（dimensions + value 列联合查找；找不到返回 nil）。
    func column(_ name: String) -> [AnyCodableValue]? {
        let layout = columnLayout
        guard let idx = layout.firstIndex(where: { $0.name == name }) else { return nil }
        return samples.compactMap { row in
            row.count > idx ? row[idx] : nil
        }
    }

    /// 把指定列转成 `Double` 数组；非数字项被丢弃。
    func doubles(_ name: String) -> [Double] {
        column(name)?.compactMap(\.asDouble) ?? []
    }

    /// 取 (x, y) 数值对：分别从 `xDim` 与 `yDim` 列读数。
    /// 任一列非数字 / 行长度不够 → 该行被丢弃。
    /// 维度名不存在 → 返回空数组（不报错，便于在 SwiftUI body 里安全使用）。
    func points(xDim: String, yDim: String) -> [(x: Double, y: Double)] {
        let layout = columnLayout
        guard let xi = layout.firstIndex(where: { $0.name == xDim }),
              let yi = layout.firstIndex(where: { $0.name == yDim })
        else { return [] }
        return samples.compactMap { row in
            guard row.count > max(xi, yi),
                  let x = row[xi].asDouble,
                  let y = row[yi].asDouble else { return nil }
            return (x: x, y: y)
        }
    }

    /// 便利：第一个 dimension（X 轴）vs value 列（Y 轴）。最常用一对。
    /// 没有 dimension 时返回空数组。
    func xyPoints() -> [(x: Double, y: Double)] {
        guard let firstDim = dimensions.first else { return [] }
        return points(xDim: firstDim.name, yDim: value.name)
    }

    /// 取 3 维 (x, y, z)：dim0 / dim1 / value，常用于热力图 / 等高线。
    func xyzPoints() -> [(x: Double, y: Double, z: Double)] {
        guard dimensions.count >= 2 else { return [] }
        let xi = 0
        let yi = 1
        let zi = dimensions.count // value 列在最后
        return samples.compactMap { row in
            guard row.count > zi,
                  let x = row[xi].asDouble,
                  let y = row[yi].asDouble,
                  let z = row[zi].asDouble else { return nil }
            return (x: x, y: y, z: z)
        }
    }

    /// 数据边界：返回每列的 (min, max)；空采样返回空数组。
    /// 顺序与 `columnLayout` 一致（dimensions + value）。
    func bounds() -> [(min: Double, max: Double)] {
        let layout = columnLayout
        return (0 ..< layout.count).map { idx in
            let values = samples.compactMap { row in
                row.count > idx ? row[idx].asDouble : nil
            }
            guard let lo = values.min(), let hi = values.max() else {
                return (min: 0, max: 0)
            }
            return (min: lo, max: hi)
        }
    }
}
