# SwiftHTF

[![CI](https://github.com/LumenMarch/SwiftHTF/actions/workflows/ci.yml/badge.svg)](https://github.com/LumenMarch/SwiftHTF/actions/workflows/ci.yml)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2012%2B-blue.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

一个现代 Swift 硬件测试框架，灵感来自 [OpenHTF](https://github.com/google/openhtf)。声明式编写产线 / Bring-up / 实验室测试计划，运行在 `actor` 隔离的执行器中，通过 `AsyncStream` 观测事件，并以 JSON / CSV 形式输出测试记录。配套 `SwiftHTFUI` 库可直接接入 SwiftUI。

[English](README.md)

## 特性

- **声明式测试计划** —— 用 `@resultBuilder` DSL 组合 `Phase`，原生支持 `if` / `for` / `#available` 分支。
- **启动门控 Phase（OpenHTF `test_start` 等价物）** —— `TestPlan(name:, startup: Phase(...)) { ... }` 注册一个跑在 plug `setUp()` 之后、`setupNodes` 之前的单一门控 phase。典型用例：用 `PromptPlug` 扫码拿 DUT SN，写回 `ctx.serialNumber` 才放行业务流程。返回 `.stop` 整测试 `outcome=.aborted`（teardown 仍跑）；startup 完成后立刻广播一次 `serialNumberResolved(String?)` 事件，SwiftUI 可在 `testCompleted` 之前刷新标题里的 SN。
- **嵌套 PhaseGroup** —— `Group(name) { ... } setup: { ... } teardown: { ... }` 与 Phase 同级，可任意层级嵌套；group 内 `continueOnFail` 局部生效。
- **Subtest（可隔离失败单元）** —— `Subtest("name") { ... }` 与 Phase / Group 同级。内部任一 phase 失败 / error / `.failSubtest` 短路剩余节点，但**不传播**到 `TestRecord.outcome`；单独写入 `SubtestRecord`（含 `phaseIDs` 反向引用），供 UI / 输出 sink 单独渲染。
- **Checkpoint（流程汇合点）** —— `Checkpoint("name")` 与 Phase / Group / Subtest 同级。到达时扫描本作用域已收集的 phase outcomes，若有任一 `.fail` / `.error` 则写入 `PhaseRecord(outcome: .fail)` 并短路剩余兄弟节点（无视 `continueOnFail`）。适合"先把诊断 phase 都跑完拿数据，再决定是否进入耗时的压力测试"模式。作用域是本地的：顶层 checkpoint 只看顶层 phases，group / subtest 内的 checkpoint 只看本作用域。
- **声明式 Measurement** —— 在 phase 上预声明 `MeasurementSpec`，链式追加 validator (`inRange` / `equals` / `matchesRegex` / `withinPercent` / `notEmpty` / `marginalRange` / `custom`)，运行后写回 `Measurement.outcome`。
- **多维 Measurement (`SeriesMeasurement`)** —— `ctx.recordSeries("iv") { rec in ... }` 增量收集 IV / 扫频 / 扫温曲线；`SeriesMeasurementSpec` 支持 `lengthAtLeast` / `each` / `custom` 等校验。
- **三态 outcome** —— `pass` / `marginalPass` / `fail` / `error` / `skip`，支持靠近边界但仍合格的"放行但需关注"语义。
- **运行时条件门 `runIf`** —— Phase 与 Group 都可挂 `runIf` 闭包，访问当前 `ctx.config` / 已收集的状态决定是否执行。
- **测量重跑** —— `repeatOnMeasurementFail`（measurement 失败重跑）与 `retryCount`（异常 / 显式 retry）独立计数，互不消耗。
- **故障诊断** —— `PhaseDiagnoser` 在 phase fail/.error 终态触发，可读 record + 写 `ctx.attach` / `ctx.measure` / `ctx.log` 留下调试线索；`TestDiagnoser` 在测试收尾时（outcome 已定、tearDown 之前）跑一次，对整个 `TestRecord` 做后处理 —— 适合跨 phase 汇总、多电源弱信号合成故障码等场景。`Diagnosis` 带 severity / 故障码 / 任意 details。
- **异常分流** —— `failureExceptions` 白名单：抛指定类型→`.fail`（业务失败），其他→`.error`（程序错误）。
- **附件 `attach`** —— phase 内 `ctx.attach(name:data:mimeType:)` / `attachFromFile(_:)`，自动 base64 进 JSON、Console / CSV 摘要。
- **Phase 局部日志** —— `ctx.logInfo / logWarning / logError(...)` 写入 `PhaseRecord.logs: [LogEntry]` 同时实时广播到事件流；retry 时仅保留最后一次 attempt 的日志。
- **配置 `TestConfig` 多源加载** —— JSON / YAML 文件（按扩展名自动识别）、环境变量（`TestConfig.from(environment:prefix:)`）、命令行 `--key value` / `--key=value`（`TestConfig.from(arguments:)`），用 `.merging(_:)` 链式合并（OpenHTF 风格优先级：defaults < file < env < CLI）。phase 内 `ctx.config.string(...) / double(...) / value(_, as:)` 读取；YAML 依赖 Yams。
- **Phase 间共享状态 `ctx.state`** —— session 级可变字典，API 镜像 `TestConfig`（`string` / `int` / `double` / `bool` / `value(_:as:)` + `set(_:_:)`）；phase 间传中间值用，不进 `TestRecord`（要持久化用 `measure`）。
- **可插拔硬件 (`Plug`)** —— 支持 `init()` 或工厂闭包注册；声明 `dependencies` 后 `PlugManager` 自动拓扑排序，`setup(resolver:)` 注入已就绪的依赖。
- **Plug 替身 (`bind` / `swap`)** —— `executor.swap(RealPSU.self, with: MockPSU.self)` 把真实 plug 整组替换为 mock；phase 代码 `ctx.getPlug(RealPSU.self)` 不变。
- **操作员交互 (`PromptPlug`)** —— phase 内 `await prompt.requestConfirm(..., timeout: 30) / requestText(...) / requestChoice(...)` 挂起；可选单次超时；UI 端用 `events()` 订阅、`resolve(...)` 应答，再通过 `resolutions()` 信号流自动撤回 SwiftUI sheet（用户回应 / cancel / timeout 任一原因都会通知）。
- **多 DUT 并发 (`TestSession`)** —— 一个 `TestExecutor` 可派生多个 session 同时运行，各自独立 plug 实例 + 独立事件流；`executor.events()` 是聚合流。
- **历史持久化 (`HistoryStore`)** —— `InMemoryHistoryStore` / `JSONFileHistoryStore`，按 SN / planName / outcome / 时间窗口 / limit 查询；`HistoryOutputCallback` 可作为 `OutputCallback` 自动入库。
- **连续触发循环 (`TestLoop`)** —— 工厂模式：`trigger` 闭包返回 SN 启动一次 session，结束后回到 trigger 等下一轮；`states()` 状态流方便 SwiftUI 驱动 UI。
- **严格并发** —— Swift `actor` + `StrictConcurrency`，phase 代码 `@MainActor`，Plug 隔离方式由你决定。
- **事件流** —— `AsyncStream<TestEvent>`：`testStarted` / `serialNumberResolved` / `phaseCompleted` / `log` / `testCompleted`。
- **输出回调** —— 内置 `ConsoleOutput` / `JSONOutput` / `CSVOutput` / `HistoryOutputCallback`，可实现 `OutputCallback` 自定义。
- **Codable 记录** —— `TestRecord` / `PhaseRecord` / `Measurement` / `SeriesMeasurement` / `Attachment` / `Diagnosis` / `LogEntry` 完整 JSON 往返。
- **`SwiftHTFUI` 库** —— 现成的 `TestRunnerViewModel` / `PromptCoordinator` / `PromptSheetView`，直接接入 SwiftUI。

## 系统要求

- Swift 5.9+
- macOS 12+

## 安装

在你的 `Package.swift` 中添加依赖：

```swift
dependencies: [
    .package(url: "https://github.com/LumenMarch/SwiftHTF.git", from: "0.3.0")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            "SwiftHTF",
            // SwiftUI 端再加：
            .product(name: "SwiftHTFUI", package: "SwiftHTF")
        ]
    )
]
```

## 快速上手

```swift
import SwiftHTF

actor PowerSupply: PlugProtocol {
    private var voltage: Double = 0
    init() {}
    func setOutput(_ v: Double) async { voltage = v }
    func readVoltage() async -> Double { voltage + Double.random(in: -0.05...0.05) }
    func setup() async throws {}
    func tearDown() async { voltage = 0 }
}

@MainActor
func makePlan(config: TestConfig) -> TestPlan {
    let vccLower = config.double("vcc.lower") ?? 3.0
    let vccUpper = config.double("vcc.upper") ?? 3.6

    return TestPlan(name: "DemoBoard") {
        // 操作员确认
        Phase(name: "OperatorReady") { @MainActor ctx in
            let prompt = ctx.getPlug(PromptPlug.self)
            return await prompt.requestConfirm("放好治具？") ? .continue : .stop
        }

        // 嵌套 Group + 声明式 measurement + diagnoser + per-phase log
        Group("PowerRail") {
            Phase(name: "PowerOn") { @MainActor ctx in
                ctx.logInfo("开机至 3.3V")
                await ctx.getPlug(PowerSupply.self).setOutput(3.3)
                return .continue
            }
            Phase(
                name: "VccCheck",
                measurements: [
                    .named("vcc", unit: "V")
                        .inRange(vccLower, vccUpper)        // 硬限值
                        .marginalRange(3.2, 3.4)            // 警告带
                        .withinPercent(of: 3.3, percent: 10)
                ],
                diagnosers: [
                    ClosureDiagnoser("vcc-overshoot") { @MainActor record, ctx in
                        guard let v = record.measurements["vcc"]?.value.asDouble,
                              v > vccUpper else { return [] }
                        ctx.attach("trace.log", data: Data("v=\(v)".utf8), mimeType: "text/plain")
                        return [Diagnosis(code: "VCC_OVERSHOOT", message: "vcc=\(v)")]
                    }
                ]
            ) { @MainActor ctx in
                let v = await ctx.getPlug(PowerSupply.self).readVoltage()
                ctx.measure("vcc", v, unit: "V")
                return .continue
            }
        }
    }
}

@MainActor
func run() async {
    let cfg = TestConfig(values: [
        "vcc.lower": .double(3.0), "vcc.upper": .double(3.6)
    ])
    let executor = TestExecutor(
        plan: makePlan(config: cfg),
        config: cfg,
        outputCallbacks: [ConsoleOutput()]
    )
    await executor.register(PowerSupply.self)
    await executor.register(PromptPlug.self)

    let record = await executor.execute(serialNumber: "SN-0001")
    print("Outcome: \(record.outcome.rawValue)")
}
```

## 概念

### TestPlan / Phase / PhaseGroup

`TestPlan` 是一棵 `PhaseNode` 树，叶子是 `Phase`，分支是 `Group`。`@TestPlanBuilder` 让你自由混用 Phase / Group / 循环 / 条件：

```swift
TestPlan(name: "Smoke") {
    Phase(name: "Connect") { _ in .continue }

    Group("RFTests", continueOnFail: true) {
        for band in [.low, .mid, .high] {
            Phase(name: "RF_\(band)") { _ in .continue }
        }
    } setup: {
        Phase(name: "Cal") { _ in .continue }
    } teardown: {
        Phase(name: "RF_Off") { _ in .continue }
    }

    if config.includeBootTest {
        Phase(name: "Boot") { _ in .continue }
    }
}
```

执行语义：
- 一组节点按顺序跑；遇 fail 看局部 `continueOnFail` 决定是否继续兄弟。
- Group：`setup` → `children` → `teardown` 严格串行；`teardown` 必跑（即使 setup 失败也跑）。
- `PhaseRecord.groupPath` 记录祖先链，便于 UI 渲染层级。

每个 Phase 闭包返回 `PhaseResult`：

| 返回值             | 含义                                     |
|--------------------|------------------------------------------|
| `.continue`        | 通过；进入下一个 phase                   |
| `.failAndContinue` | 标记失败；视 `continueOnFail` 决定继续   |
| `.retry`           | 重新执行（最多 `retryCount` 次）         |
| `.skip`            | 跳过                                     |
| `.stop`            | 立即终止整个测试                         |
| `.failSubtest`     | 标记 phase 失败并短路所在 Subtest（不在 Subtest 内时等价 `.failAndContinue`） |

### 启动门控 Phase（OpenHTF `test_start` 等价物）

很多 plan 需要在主体开跑前先做一道闸：扫码拿 DUT SN、确认治具就位、license 校验等。这类逻辑放在 `TestPlan.startup`：

```swift
TestPlan(
    name: "DemoBoard",
    startup: Phase(name: "ScanSN") { @MainActor ctx in
        let prompt = ctx.getPlug(PromptPlug.self)
        guard let sn = await prompt.requestText("Scan DUT SN", timeout: 60)
        else { return .stop }                              // 操作员取消
        ctx.serialNumber = sn                              // 回填 record.serialNumber
        return .continue
    }
) {
    Phase(name: "PowerOn") { _ in .continue }
    Group("RFTests") { ... }
} teardown: [
    Phase(name: "PowerOff") { _ in .continue }
]
```

生命周期位置：plug `setUp()` → **startup** → `setupNodes` → `nodes` → `teardownNodes` → plug `tearDown()`。

返回值映射（PhaseRecord ↔ TestRecord）：

| Startup 返回值          | `PhaseRecord.outcome` | `TestRecord.outcome` | 跑主体？ | 跑 teardown？ |
|-------------------------|-----------------------|----------------------|----------|---------------|
| `.continue`             | `.pass`               | （不变）             | 是       | 是            |
| `.stop`                 | `.pass`*              | `.aborted`           | 否       | 是            |
| `.failAndContinue`      | `.fail`               | `.fail`              | 否       | 是            |
| 抛非白名单异常          | `.error`              | `.fail`              | 否       | 是            |
| 超时                    | `.timeout`            | `.timeout`           | 否       | 是            |
| `runIf` 返回 `false`    | （不写 PhaseRecord）  | （不变）             | 是       | 是            |

\* `.stop` 是控制流信号，不是失败 —— `PhaseRecord` 保留其计算出的 outcome（通常 `.pass`），由 `stopRequested = true` 触发 `.aborted` 映射。

其他要点：
- Startup `PhaseRecord` 仍写入 `record.phases`，`groupPath = TestSession.startupGroupPath`（即 `["__startup__"]`），UI / sink 可据此区分启动门控阶段与业务 phase。
- Plug `tearDown()` 总会跑（无论 startup outcome 如何）。
- Startup 跑完后立刻广播一次 `TestEvent.serialNumberResolved(ctx.serialNumber)`（`runIf` 跳过时不发）；`SwiftHTFUI.TestRunnerViewModel` 已对接该事件，操作员扫码完成的瞬间 UI 标题里的 SN 就会刷新，不必等 `testCompleted`。
- Startup 继承完整 `Phase` 字段：`timeout` / `retryCount` / `measurements` / `series` / `diagnosers` / `failureExceptions` / `runIf` / `repeatOnMeasurementFail`。

### Subtest（可隔离失败单元）

`Subtest` 与 `Phase` / `Group` 平级的节点，**隔离失败**：内部 phase / group 失败时短路剩余节点，但**不传播**到 `TestRecord.outcome`。结果以 `SubtestRecord` 写入 `TestRecord.subtests`，通过 `phaseIDs` 反查 `TestRecord.phases`。

```swift
TestPlan(name: "Board") {
    Phase(name: "Connect") { _ in .continue }

    Subtest("PowerTests") {
        Phase(name: "VccCheck") { _ in .continue }
        Phase(name: "VddCheck") { _ in .failAndContinue }   // 短路本 Subtest
        Phase(name: "VbatCheck") { _ in .continue }         // 不会跑
    }

    Phase(name: "Cleanup") { _ in .continue }   // 仍会跑 —— Subtest 失败被隔离
}
```

语义：

- phase 返回 `.fail` / `.error` / `.failSubtest`，或嵌套 `Group` 失败 → 短路 Subtest 剩余节点
- Subtest 失败**不**让 `TestRecord.outcome = .fail`；外层测试继续；通过 `record.subtests` 聚合判定
- 嵌套 Subtest 之间互相隔离，内层 fail 不传染外层
- `.stop` 仍跨 Subtest 边界冒泡，终止整测试
- `Subtest` 支持 `runIf`；false 时 `SubtestRecord.outcome = .skip`、`phaseIDs=[]`

`SubtestRecord` 字段：

| 字段             | 含义                                                              |
|------------------|-------------------------------------------------------------------|
| `id`             | 稳定 UUID，编解码后保留                                            |
| `name`           | 声明时的名字                                                       |
| `outcome`        | `.pass` / `.fail` / `.error` / `.skip`                            |
| `phaseIDs`       | 本 Subtest 内 phase 在 `TestRecord.phases` 里的 id（按执行顺序）   |
| `failureReason`  | 哪个节点触发了短路（如 `"VddCheck: FAIL"`）                        |
| `startTime` / `endTime` / `duration` | Subtest 级时序                              |

### 声明式 Measurement & 三态 outcome

在 Phase 上预声明 `MeasurementSpec`，phase 内 `ctx.measure(...)` 写入后 `harvest` 自动跑 validator：

```swift
Phase(
    name: "VccCheck",
    measurements: [
        .named("vcc", unit: "V", description: "主电源")
            .inRange(3.0, 3.6)
            .marginalRange(3.1, 3.5)         // [3.1, 3.5] 外 → marginalPass
            .withinPercent(of: 3.3, percent: 5)
    ]
) { @MainActor ctx in
    ctx.measure("vcc", 3.07, unit: "V")
    return .continue
}
```

聚合规则（按优先级）：fail > marginal > pass。
- 任一 measurement `fail` → phase `.fail`，record `.fail`。
- 否则任一 marginal → phase `.marginalPass`，record 全过且至少一个 marginal → record `.marginalPass`。
- `Measurement.outcome` / `validatorMessages` 写回 `PhaseRecord.measurements[name]`，输出层据此着色。

未声明的 measurement 仍允许写入（视为辅助信息，不参与聚合）。

### 多维 Measurement（SeriesMeasurement）

声明 trace 维度后，phase 内 `ctx.recordSeries` 用闭包增量收集 IV / 扫频 / 扫温曲线，harvest 跑全量 validator：

```swift
Phase(
    name: "VRampSweep",
    series: [
        .named("v_ramp")
            .dimension("V_set", unit: "V")
            .value("V_meas", unit: "V")
            .lengthAtLeast(5)
            .each { sample in                         // 每个采样跑闭包
                guard let want = sample[0].asDouble,
                      let got = sample[1].asDouble else { return .pass }
                let err = abs(got - want)
                if err > 0.2 { return .fail("err=\(err)V") }
                if err > 0.1 { return .marginal("err=\(err)V") }
                return .pass
            }
    ]
) { @MainActor ctx in
    let psu = ctx.getPlug(PowerSupply.self)
    await ctx.recordSeries("v_ramp") { rec in
        for v in stride(from: 0.0, through: 3.3, by: 0.5) {
            await psu.setOutput(v)
            rec.append(v, await psu.readVoltage())
        }
    }
    return .continue
}
```

`SeriesMeasurement` 与单点 `Measurement` 平行存放在 `PhaseRecord.traces: [String: SeriesMeasurement]`；同样参与 phase outcome 聚合，`repeatOnMeasurementFail` 也对 series fail 生效。

### Phase 高级字段

```swift
Phase(
    name: "VccCheck",
    timeout: 5,                          // 超时（秒）
    retryCount: 2,                       // 异常 / 显式 .retry 的重试次数
    measurements: [.named("vcc").inRange(3.0, 3.6)],
    series: [.named("v_ramp").dimension("V").value("I").lengthAtLeast(5)],
    runIf: { @MainActor ctx in           // 运行时条件门 — false 时 outcome=.skip
        ctx.config.bool("vcc.enabled") ?? true
    },
    repeatOnMeasurementFail: 3,          // measurement / series 失败时再读 N 次
    diagnosers: [                        // fail / .error 终态时跑
        ClosureDiagnoser("trace") { record, ctx in [...] }
    ],
    failureExceptions: [DUTRefusedToBoot.self]   // 白名单异常 → .fail；其他 → .error
) { ... }
```

`runIf` 可挂在 Group 上 —— false 时合成一条 `outcome=.skip` 的 PhaseRecord，setup/children/teardown 全不跑。

### 附件（Attachments）

```swift
Phase(name: "Diag") { @MainActor ctx in
    ctx.attach("trace.log", data: Data("...".utf8), mimeType: "text/plain")
    try ctx.attachFromFile(URL(fileURLWithPath: "/tmp/scope.png"))   // 按扩展名推 mime
    return .continue
}
```

`PhaseRecord.attachments: [Attachment]` 持久化；JSON 输出时 `Data` 默认 base64；Console 显示 `📎 name (mime, size)`；CSV 加 `attachments_count` 列。

### Phase 局部日志

phase 闭包内通过 `ctx.logXxx` 写日志，按写入顺序进入 `PhaseRecord.logs`，并实时广播到 session 事件流：

```swift
Phase(name: "BringUp") { @MainActor ctx in
    ctx.logInfo("启动 BSP")
    do {
        try await bsp.boot()
    } catch {
        ctx.logError("boot failed: \(error.localizedDescription)")
        throw error
    }
    return .continue
}
```

- `LogEntry { timestamp, level, message }`，`LogLevel` 为 `debug/info/warning/error`
- retry 时每次 attempt 起始重置，`record.logs` 仅含最后一次 attempt
- diagnoser 内 `ctx.log` 也合并进 `record.logs`

### 配置（TestConfig）

```swift
let cfg = try TestConfig.load(from: URL(fileURLWithPath: "config.json"))
let executor = TestExecutor(plan: plan, config: cfg)

// phase 内：
let lower = ctx.config.double("vcc.lower") ?? 3.0
struct Limits: Decodable { let lower: Double; let upper: Double }
let lim = ctx.config.value("vcc", as: Limits.self)
```

内部为 `[String: AnyCodableValue]`；零外部依赖；JSON 加载顶层必须是对象。

### Plug 依赖注入

```swift
final class CorePlug: PlugProtocol { init() {} }

final class MidPlug: PlugProtocol {
    init() {}
    static var dependencies: [any PlugProtocol.Type] { [CorePlug.self] }
    func setup(resolver: PlugResolver) async throws {
        let core = await resolver.get(CorePlug.self)!
        // 初始化时已能拿到 core 引用
    }
}
```

`PlugManager.setupAll` 拓扑排序构造 plug，依赖先于被依赖者 setup；循环依赖 / 缺失依赖会抛 `PlugManagerError`，TestExecutor 把它转为 `record.outcome=.error`。

### Plug 替身（mock 注入）

部署用真实 plug，CI 用 mock —— phase 代码不变：

```swift
class RealPSU: PlugProtocol {
    required init() {}
    func setOutput(_ v: Double) {}
    func readVoltage() -> Double { /* 真实读数 */ 3.3 }
    func setup() async throws {}
    func tearDown() async {}
}
final class MockPSU: RealPSU {
    override func readVoltage() -> Double { 1.5 }   // 仿真
}

let executor = TestExecutor(plan: plan)
await executor.register(RealPSU.self)
await executor.swap(RealPSU.self, with: MockPSU.self)   // 测试时整组替换

// phase 代码不动：
ctx.getPlug(RealPSU.self).readVoltage()   // 实际拿到 MockPSU 实例
```

API：
- `bind(Abstract.self, to: Concrete.self)` —— 抽象别名到已注册的具体类型
- `swap(A.self, with: B.self)` —— `unregister(A) + register(B) + bind(A, to: B)` 一站式
- `swap(_, with:, factory:)` —— 自定义 mock 实例的工厂闭包

依赖链上 alias 也参与拓扑排序：plug 声明 `dependencies = [Abstract.self]`，alias 后 resolver 拿到具体实现。

### PromptPlug & SwiftUI 集成

phase 内挂起等待操作员（可选超时）：

```swift
Phase(name: "ScanSerial") { @MainActor ctx in
    let prompt = ctx.getPlug(PromptPlug.self)
    // 不传 timeout：永久等
    let sn = await prompt.requestText("请扫码", placeholder: "SN-...")
    ctx.serialNumber = sn

    // 带 30s 超时：超时映射为默认值（false / "" / -1），与 cancel 一致
    let opOK = await prompt.requestConfirm("治具就位？", timeout: 30)
    if !opOK { return .stop }
    return .continue
}
```

三个高阶 API 都带可选 `timeout: TimeInterval? = nil`。要区分"操作员取消"与"超时未应答"，用底层 `request(kind:timeout:) -> PromptResponse`：

```swift
let response = await prompt.request(kind: .confirm(message: "OK?"), timeout: 5)
switch response {
case .confirm(let b):  ...
case .cancelled:       ctx.logWarning("操作员取消")
case .timedOut:        ctx.logWarning("5 秒内未应答")
case .text, .choice:   break // 类型不匹配
}
```

UI 端用 `SwiftHTFUI` 现成视图模型与 sheet：

```swift
import SwiftUI
import SwiftHTF
import SwiftHTFUI

struct ContentView: View {
    @StateObject private var runner: TestRunnerViewModel
    @StateObject private var prompts = PromptCoordinator()
    private let plug = PromptPlug()

    init() {
        let exec = TestExecutor(plan: makePlan())
        self._runner = StateObject(wrappedValue: TestRunnerViewModel(executor: exec))
    }

    var body: some View {
        VStack {
            Button("开始测试") { runner.start() }
                .disabled(runner.isRunning)
            List(runner.phases) { phase in
                Text("\(phase.name) → \(phase.outcome.rawValue)")
            }
        }
        .task { await prompts.attach(to: plug) }
        .sheet(item: $prompts.current) { req in
            PromptSheetView(request: req) { resp in
                prompts.resolve(req.id, response: resp)
            }
        }
    }
}
```

`TestRunnerViewModel` 暴露 `phases` / `logLines` / `outcome` / `isRunning` / `record` / `serialNumber` 等 `@Published` 属性，订阅 `session.events()`，多 session 模式不会混流。

### 多 DUT 并发

`TestExecutor` 是一个 plan / config / plug 注册的容器；可派生多个并发 `TestSession`：

```swift
let executor = TestExecutor(plan: plan, config: cfg)
await executor.register(PowerSupply.self)

// 单 DUT：
let record = await executor.execute(serialNumber: "SN-1")

// 多 DUT 并发：
async let s1 = executor.startSession(serialNumber: "DUT-1")
async let s2 = executor.startSession(serialNumber: "DUT-2")
let session1 = await s1
let session2 = await s2
async let r1 = session1.record()
async let r2 = session2.record()
let (rec1, rec2) = await (r1, r2)
```

每个 session 持有独立的 plug 实例（factory 重新构造，独立 setup/tearDown）。`executor.events()` 是聚合流；要区分多 session 改订阅 `session.events()`。

### 历史持久化（HistoryStore）

把 record 落到磁盘，跨进程查询既往结果：

```swift
let store = try JSONFileHistoryStore(directory: URL(fileURLWithPath: "/var/log/htf"))
let executor = TestExecutor(
    plan: plan,
    outputCallbacks: [HistoryOutputCallback(store: store)]   // 每次完成自动入库
)

// 之后查询：
let recent = try await store.list(HistoryQuery(serialNumber: "SN-1", limit: 10))
let fails = try await store.list(HistoryQuery(outcomes: [.fail], since: Date().addingTimeInterval(-86400)))
```

API：
- `save(_:)` / `load(id:)` / `list(_:)` / `delete(id:)` / `clear()`
- `HistoryQuery`：`serialNumber` / `planName` / `outcomes` / `since` / `until` / `limit` / `sortDescending`
- 内置实现：`InMemoryHistoryStore`（actor，测试用） / `JSONFileHistoryStore`（actor，每条 record 一个 JSON 文件，secondsSince1970 编码保留毫秒精度）

### 连续触发循环（TestLoop）

工厂连续测试模式：扫码 → 启动 session → 等结束 → 回到扫码：

```swift
let loop = TestLoop(
    executor: executor,
    trigger: { await viewModel.waitForBarcode() },   // 返回 SN，nil 表示停止
    onCompleted: { record in
        try? await store.save(record)
    }
)
await loop.start()
// ...
await loop.stop()
```

`states()` 状态流（`idle` / `awaitingTrigger` / `running(sn)` / `stopped`）补发历史，方便 SwiftUI 驱动 UI；`completedCount` 反映已完成的 session 数。

### 事件流

```swift
for await event in await executor.events() {
    switch event {
    case .testStarted(let name, let sn): ...
    case .phaseCompleted(let r):         ...
    case .log(let msg):                  ...
    case .testCompleted(let r):          ...
    }
}
```

`session.events()` 带 replay buffer —— 新订阅会被补发已 emit 的全部历史事件，因此即使 `startSession` 内部立刻 start session，调用方再 events() 也不会丢 `.testStarted`。

### 输出回调

实现 `OutputCallback.save(record:)` 即可对接任意输出。内置：

- `ConsoleOutput` —— 控制台摘要（含 measurement / 附件 / 故障码）
- `JSONOutput(directory:)` —— 每条记录一个 ISO8601 命名的 JSON 文件
- `CSVOutput(directory:)` —— 每条记录一个 CSV，每行一个 phase（列：name, outcome, duration_s, measurements_count, traces_count, attachments_count, diagnoses_count, error）
- `HistoryOutputCallback(store:)` —— 包装任意 `HistoryStore`，每次记录完成自动入库

## Demo

```bash
# 程序化运行的演示（自动应答 prompt，输出落 $TMPDIR/SwiftHTFDemo/）
swift run SwiftHTFDemo

# SwiftUI 主窗口（手动应答 prompt，phase 表格 + live log）
swift run SwiftHTFSwiftUIDemo
```

## 开发

```bash
swift build
swift test          # 185 用例
```

## 许可证

[MIT](LICENSE) © 2026 LumenMarch
