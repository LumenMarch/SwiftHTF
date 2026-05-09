# SwiftHTF

[![CI](https://github.com/HunterFirefly/SwiftHTF/actions/workflows/ci.yml/badge.svg)](https://github.com/HunterFirefly/SwiftHTF/actions/workflows/ci.yml)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2012%2B-blue.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

一个现代 Swift 硬件测试框架，灵感来自 [OpenHTF](https://github.com/google/openhtf)。声明式编写产线 / Bring-up / 实验室测试计划，运行在 `actor` 隔离的执行器中，通过 `AsyncStream` 观测事件，并以 JSON / CSV 形式输出测试记录。

[English](README.md)

## 特性

- **声明式测试计划** —— 用 `@resultBuilder` DSL 组合 `Phase`，原生支持 `if` / `for` / `#available` 分支。
- **严格并发** —— 基于 Swift `actor` 构建并启用 `StrictConcurrency`：执行器状态串行化，phase 代码运行在 `@MainActor`，Plug 隔离方式由你决定。
- **重试 / 超时 / 验证器** —— 直接声明 `lowerLimit` / `upperLimit` / `unit`，或挂载自定义 `Validator`。
- **类型化测量** —— `ctx.measure("vcc", 3.3, unit: "V")` 通过 `AnyCodableValue` 记录任意 JSON 兼容值。
- **可插拔硬件 (`Plug`)** —— 支持无参 `init()` 或工厂闭包注册；`setup` / `tearDown` 自动按顺序执行。
- **事件流** —— 通过 `executor.events()` 订阅 `testStarted` / `phaseCompleted` / `log` / `testCompleted`。
- **输出回调** —— 内置 `ConsoleOutput` / `JSONOutput` / `CSVOutput`，可实现 `OutputCallback` 自定义。
- **Codable 记录** —— `TestRecord` / `PhaseRecord` / `Measurement` 完整 JSON 往返。

## 系统要求

- Swift 5.9+
- macOS 12+

## 安装

在你的 `Package.swift` 中添加依赖：

```swift
dependencies: [
    .package(url: "https://github.com/HunterFirefly/SwiftHTF.git", branch: "main")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: ["SwiftHTF"]
    )
]
```

## 快速上手

```swift
import SwiftHTF

// 1. 定义一个 Plug
actor PowerSupply: PlugProtocol {
    private var voltage: Double = 0
    init() {}
    func setOutput(_ v: Double) async { voltage = v }
    func readVoltage() async -> Double { voltage }
    func setup() async throws { /* 建立连接 */ }
    func tearDown() async { voltage = 0 }
}

// 2. 构建测试计划
@MainActor
func makePlan() -> TestPlan {
    TestPlan(name: "DemoBoard") {
        Phase(name: "PowerOn") { ctx in
            let psu = ctx.getPlug(PowerSupply.self)
            await psu.setOutput(3.3)
            return .continue
        }

        Phase(name: "VccCheck", lowerLimit: "3.0", upperLimit: "3.6", unit: "V") { ctx in
            let psu = ctx.getPlug(PowerSupply.self)
            let v = await psu.readVoltage()
            ctx.setValue("VccCheck", String(format: "%.3f", v))
            ctx.measure("vcc", v, unit: "V")
            return .continue
        }
    }
}

// 3. 运行
@MainActor
func run() async {
    let plan = makePlan()
    let executor = TestExecutor(
        plan: plan,
        outputCallbacks: [ConsoleOutput()]
    )
    await executor.register(PowerSupply.self)

    // 可选：订阅事件流
    let listener = Task { [executor] in
        for await event in await executor.events() {
            if case .phaseCompleted(let r) = event {
                print("phase \(r.name) -> \(r.outcome.rawValue)")
            }
        }
    }

    let record = await executor.execute(serialNumber: "SN-0001")
    listener.cancel()
    print("结果: \(record.outcome.rawValue)")
}
```

## 概念

### `TestPlan` 与 `Phase`

`TestPlan` 是一个有名字的 `Phase` 序列，可选 `setup` / `teardown`。`@TestPlanBuilder` 让你自由混用循环和条件：

```swift
TestPlan(name: "Smoke") {
    Phase(name: "Connect") { _ in .continue }
    if config.includeBootTest {
        Phase(name: "Boot") { _ in .continue }
    }
    for sensor in sensors {
        Phase(name: "Read_\(sensor.id)") { _ in .continue }
    }
}
```

每个 phase 返回 `PhaseResult`：

| 返回值             | 含义                                     |
|--------------------|------------------------------------------|
| `.continue`        | 通过；进入下一个 phase                   |
| `.failAndContinue` | 标记失败；视 `continueOnFail` 决定继续   |
| `.retry`           | 重新执行（最多 `retryCount` 次）         |
| `.skip`            | 跳过                                     |
| `.stop`            | 立即终止整个测试                         |

### Plug

`PlugProtocol` 抽象任意硬件适配器，实现可以自由选择隔离方式（`actor` / `@MainActor` / 非 isolated 都行）：

```swift
actor PowerSupply: PlugProtocol {
    init() {}
    func setup() async throws { /* 连接硬件 */ }
    func tearDown() async { /* 断开 */ }
}

// 注册：
await executor.register(PowerSupply.self)
// 或带工厂闭包：
await executor.register(PowerSupply.self) { PowerSupply(port: "/dev/tty.usbserial-1") }
```

`PlugManager` 在 `@MainActor` 上构造实例（一次），phase 运行前调用 `setup()`，结束（含失败路径）保证 `tearDown()` 执行。

### 验证器与限值

Phase 可以直接声明 `lowerLimit` / `upperLimit`（字符串，支持 `0x...` 十六进制）与 `unit`，框架自动包成 `RangeValidator`。需要字符串 / 正则 / 非空校验时，附加一组自定义 `Validator`。

### 事件流

`executor.events()` 返回 `AsyncStream<TestEvent>`。该方法 actor 隔离，因此在 `execute()` 之前建立的订阅不会丢事件。取消消费任务或跳出 for-await 即自动解除订阅。

```swift
for await event in await executor.events() {
    switch event {
    case .testStarted(let name, let sn): print("start \(name) sn=\(sn ?? "-")")
    case .phaseCompleted(let r):         print("phase \(r.name) \(r.outcome.rawValue)")
    case .log(let msg):                  print("log: \(msg)")
    case .testCompleted(let r):          print("done \(r.outcome.rawValue)")
    }
}
```

### 输出回调

实现 `OutputCallback.save(record:)` 即可对接任意输出。内置：

- `ConsoleOutput` —— 控制台摘要
- `JSONOutput(directory:)` —— 每条记录一个 ISO8601 命名的 JSON 文件
- `CSVOutput(directory:)` —— 每条记录一个 CSV，每行一个 phase

## Demo

```bash
swift run SwiftHTFDemo
```

JSON / CSV 输出落在 `$TMPDIR/SwiftHTFDemo/`。

## 开发

```bash
swift build
swift test
```

## 许可证

[MIT](LICENSE) © 2026 HunterFirefly
