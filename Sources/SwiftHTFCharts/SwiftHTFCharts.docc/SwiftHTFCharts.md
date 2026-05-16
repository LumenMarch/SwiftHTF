# ``SwiftHTFCharts``

把 SwiftHTF 的 `SeriesMeasurement` 一行渲染成 SwiftUI 折线图。

## Overview

SwiftHTFCharts 是 SwiftHTF 之上的可选 UI 模块（macOS 13+ / iOS 16+，依赖 Apple `Charts`）。
独立 product —— 不引此模块的用户零额外依赖。

主要能力：

- **终态绘图**：`SeriesChart(trace: trace)` 直接读 `PhaseRecord.traces` 出图，
  自动按 dimension 数推断 layout（1D 单线 / 2D 多线分色 / 0D 用 index 当 X）
- **实时绘图**：`LiveSeriesChartViewModel` 订阅 `TestSession` 事件流，
  按 `(phaseName, traceName)` 滚动覆盖 `@Published var activeTraces`
- **规格带**：`.specRange(2.8...3.6)` 在图上画上下限虚线 RuleMark
- **轴覆写**：`.xAxisLabel(_:)` / `.yAxisLabel(_:)` 覆盖自动推断

## Topics

### 视图组件

- ``SeriesChart``
- ``SeriesChartLayout``

### 实时绑定

- ``LiveSeriesChartViewModel``
