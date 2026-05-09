import Foundation

/// SeriesRecorder：在 phase 闭包内由 `TestContext.recordSeries(...)` 提供，
/// 用于增量收集 series 采样行。
///
/// 所有 `append` 重载最终归一为 `[AnyCodableValue]`：
/// - `append(_ row: [any Encodable])`：通用变长版本
/// - `append(_ a, _ b, ...)`：1~5 元便捷版本
/// - `appendCoded(_ row:)`：调用方已经规范化为 `[AnyCodableValue]`
///
/// recorder 不强制 `row.count` 与 `columnLayout.count` 相等 —— spec 验证器
/// 阶段会校验维度。框架本身只负责忠实存储采样原值。
@MainActor
public final class SeriesRecorder {
    public let name: String
    public let columnLayout: [Dimension]
    public private(set) var samples: [[AnyCodableValue]] = []

    init(name: String, columnLayout: [Dimension]) {
        self.name = name
        self.columnLayout = columnLayout
    }

    /// 追加一行采样
    public func append(_ row: [any Encodable]) {
        samples.append(row.map { AnyCodableValue.from($0) })
    }

    /// 追加一行已规范化的采样
    public func appendCoded(_ row: [AnyCodableValue]) {
        samples.append(row)
    }

    /// 1 元（少见，等价于单点 measurement）
    public func append(_ a: any Encodable) {
        append([a])
    }

    /// 2 元便捷（最常见：1 个自变量 + 1 个因变量）
    public func append(_ a: any Encodable, _ b: any Encodable) {
        append([a, b])
    }

    /// 3 元便捷
    public func append(_ a: any Encodable, _ b: any Encodable, _ c: any Encodable) {
        append([a, b, c])
    }

    /// 4 元便捷
    public func append(
        _ a: any Encodable,
        _ b: any Encodable,
        _ c: any Encodable,
        _ d: any Encodable
    ) {
        append([a, b, c, d])
    }

    /// 5 元便捷
    public func append(
        _ a: any Encodable,
        _ b: any Encodable,
        _ c: any Encodable,
        _ d: any Encodable,
        _ e: any Encodable
    ) {
        append([a, b, c, d, e])
    }
}
