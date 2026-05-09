# SwiftHTF

[![CI](https://github.com/HunterFirefly/SwiftHTF/actions/workflows/ci.yml/badge.svg)](https://github.com/HunterFirefly/SwiftHTF/actions/workflows/ci.yml)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2012%2B-blue.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A modern Swift hardware-test framework inspired by [OpenHTF](https://github.com/google/openhtf). Build manufacturing / bring-up / bench test plans declaratively, run them as `actor`-isolated sessions, observe events as `AsyncStream`, and emit JSON / CSV records. Ships with `SwiftHTFUI` for drop-in SwiftUI integration.

[简体中文](README.zh-CN.md)

## Features

- **Declarative test plans** — compose `Phase`s with a `@resultBuilder` DSL, including `if` / `for` / availability branches.
- **Nested PhaseGroup** — `Group(name) { ... } setup: { ... } teardown: { ... }` sits alongside `Phase` and nests freely; `continueOnFail` is local to each group.
- **Declarative measurements** — pre-declare `MeasurementSpec` on a phase, chain validators (`inRange` / `equals` / `matchesRegex` / `withinPercent` / `notEmpty` / `marginalRange` / `custom`); outcomes are written back to `Measurement.outcome`.
- **Three-state outcome** — `pass` / `marginalPass` / `fail` / `error` / `skip`, with proper "in-spec but near limit" semantics.
- **Runtime gating with `runIf`** — both `Phase` and `Group` accept a `runIf` closure that reads `ctx.config` / collected state to decide whether to execute.
- **Measurement repeat** — `repeatOnMeasurementFail` is independent of `retryCount` (which handles thrown exceptions / explicit `.retry`); the two counters never consume each other.
- **Diagnostics** — `PhaseDiagnoser` runs at terminal `.fail` / `.error`, can read the record and write `ctx.attach` / `ctx.measure` for debugging breadcrumbs; `Diagnosis` carries severity / fault code / arbitrary details.
- **Failure routing** — `failureExceptions` whitelist: thrown matching types map to `.fail` (test failure), others stay `.error` (program error).
- **Attachments** — `ctx.attach(name:data:mimeType:)` / `attachFromFile(_:)`; auto base64 in JSON, summary in Console / CSV.
- **`TestConfig`** — JSON loader, `ctx.config.string(...) / double(...) / value(_, as:)` inside phases. Zero external dependencies.
- **Pluggable hardware (`Plug`)** — register with `init()` or a factory; declare `dependencies` and `PlugManager` topologically sorts setup, injecting ready plugs via `setup(resolver:)`.
- **Operator interaction (`PromptPlug`)** — `await prompt.requestConfirm(...) / requestText(...) / requestChoice(...)` suspends inside a phase; UI subscribes via `events()` and replies with `resolve(...)`. Designed for SwiftUI sheets.
- **Multi-DUT concurrency (`TestSession`)** — one `TestExecutor` spawns multiple concurrent sessions; each owns its own plug instances and event stream. `executor.events()` is the aggregated stream.
- **Strict concurrency** — Swift `actor` + `StrictConcurrency`, phase code is `@MainActor`, plug isolation is your call.
- **Event stream** — `AsyncStream<TestEvent>`: `testStarted` / `phaseCompleted` / `log` / `testCompleted`.
- **Output sinks** — `ConsoleOutput` / `JSONOutput` / `CSVOutput` built in; implement `OutputCallback` for anything else.
- **Codable records** — `TestRecord` / `PhaseRecord` / `Measurement` / `Attachment` / `Diagnosis` round-trip JSON.
- **`SwiftHTFUI`** — ready-made `TestRunnerViewModel` / `PromptCoordinator` / `PromptSheetView` for SwiftUI.

## Requirements

- Swift 5.9+
- macOS 12+

## Installation

Add SwiftHTF to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/HunterFirefly/SwiftHTF.git", branch: "main")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            "SwiftHTF",
            // For SwiftUI integration:
            .product(name: "SwiftHTFUI", package: "SwiftHTF")
        ]
    )
]
```

## Quick start

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
        // Operator confirmation
        Phase(name: "OperatorReady") { @MainActor ctx in
            let prompt = ctx.getPlug(PromptPlug.self)
            return await prompt.requestConfirm("Fixture in place?") ? .continue : .stop
        }

        // Nested Group + declarative measurement + diagnoser
        Group("PowerRail") {
            Phase(name: "PowerOn") { @MainActor ctx in
                await ctx.getPlug(PowerSupply.self).setOutput(3.3)
                return .continue
            }
            Phase(
                name: "VccCheck",
                measurements: [
                    .named("vcc", unit: "V")
                        .inRange(vccLower, vccUpper)        // hard limits
                        .marginalRange(3.2, 3.4)            // warning band
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

## Concepts

### TestPlan / Phase / PhaseGroup

A `TestPlan` is a tree of `PhaseNode`s — leaves are `Phase`, branches are `Group`. `@TestPlanBuilder` lets you mix Phase / Group / loops / conditionals naturally:

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

Execution semantics:
- A node sequence runs in order; on failure the local `continueOnFail` decides whether siblings continue.
- `Group` runs strictly: `setup` → `children` → `teardown`. `teardown` always runs, even after a setup failure.
- `PhaseRecord.groupPath` records the ancestor chain so UI can render hierarchy.

Each phase closure returns a `PhaseResult`:

| Result            | Meaning                                              |
|-------------------|------------------------------------------------------|
| `.continue`       | Pass; run the next phase                             |
| `.failAndContinue`| Mark phase fail; honor `continueOnFail`              |
| `.retry`          | Run the same phase again (up to `retryCount`)        |
| `.skip`           | Skip without running                                 |
| `.stop`           | Abort the whole test                                 |

### Declarative measurements & three-state outcome

Pre-declare a `MeasurementSpec` on the phase; `harvest` runs validators against `ctx.measure(...)` writes:

```swift
Phase(
    name: "VccCheck",
    measurements: [
        .named("vcc", unit: "V", description: "Main rail")
            .inRange(3.0, 3.6)
            .marginalRange(3.1, 3.5)         // outside [3.1, 3.5] → marginalPass
            .withinPercent(of: 3.3, percent: 5)
    ]
) { @MainActor ctx in
    ctx.measure("vcc", 3.07, unit: "V")
    return .continue
}
```

Aggregation precedence: fail > marginal > pass.
- Any measurement `fail` → phase `.fail`, record `.fail`.
- Otherwise any marginal → phase `.marginalPass`; if every phase passes and at least one is marginal → record `.marginalPass`.
- `Measurement.outcome` / `validatorMessages` write back to `PhaseRecord.measurements[name]` for output / UI to colour.

Undeclared measurements may still be written (treated as auxiliary; no aggregation effect).

### Phase advanced fields

```swift
Phase(
    name: "VccCheck",
    timeout: 5,                          // seconds
    retryCount: 2,                       // retries on exception / explicit .retry
    measurements: [.named("vcc").inRange(3.0, 3.6)],
    runIf: { @MainActor ctx in           // runtime gate — false → outcome=.skip
        ctx.config.bool("vcc.enabled") ?? true
    },
    repeatOnMeasurementFail: 3,          // re-read on measurement failure
    diagnosers: [                        // run at terminal .fail / .error
        ClosureDiagnoser("trace") { record, ctx in [...] }
    ],
    failureExceptions: [DUTRefusedToBoot.self]   // whitelisted → .fail; others → .error
) { ... }
```

`runIf` also works on `Group` — when false, a synthetic `outcome=.skip` PhaseRecord is written and setup / children / teardown are entirely skipped.

### Attachments

```swift
Phase(name: "Diag") { @MainActor ctx in
    ctx.attach("trace.log", data: Data("...".utf8), mimeType: "text/plain")
    try ctx.attachFromFile(URL(fileURLWithPath: "/tmp/scope.png"))   // mime inferred
    return .continue
}
```

`PhaseRecord.attachments: [Attachment]` is persisted; JSON output uses `Data`'s default base64; Console shows `📎 name (mime, size)`; CSV gains an `attachments_count` column.

### Configuration (`TestConfig`)

```swift
let cfg = try TestConfig.load(from: URL(fileURLWithPath: "config.json"))
let executor = TestExecutor(plan: plan, config: cfg)

// inside a phase:
let lower = ctx.config.double("vcc.lower") ?? 3.0
struct Limits: Decodable { let lower: Double; let upper: Double }
let lim = ctx.config.value("vcc", as: Limits.self)
```

Internally `[String: AnyCodableValue]`; zero external dependencies; JSON top-level must be an object.

### Plug dependency injection

```swift
final class CorePlug: PlugProtocol { init() {} }

final class MidPlug: PlugProtocol {
    init() {}
    static var dependencies: [any PlugProtocol.Type] { [CorePlug.self] }
    func setup(resolver: PlugResolver) async throws {
        let core = await resolver.get(CorePlug.self)!
        // core is already initialised
    }
}
```

`PlugManager.setupAll` topologically sorts plugs so dependencies set up before dependents. Cycles or missing dependencies throw `PlugManagerError`, which `TestExecutor` surfaces as `record.outcome=.error`.

### PromptPlug & SwiftUI integration

Inside a phase, suspend until the operator answers:

```swift
Phase(name: "ScanSerial") { @MainActor ctx in
    let prompt = ctx.getPlug(PromptPlug.self)
    let sn = await prompt.requestText("Scan SN", placeholder: "SN-...")
    ctx.serialNumber = sn          // back-fills into the record
    return .continue
}
```

On the UI side, `SwiftHTFUI` ships ready-made view models and a default sheet:

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
            Button("Run") { runner.start() }
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

`TestRunnerViewModel` exposes `phases` / `logLines` / `outcome` / `isRunning` / `record` / `serialNumber` as `@Published` properties; it subscribes to `session.events()`, so multi-session mode never mixes streams.

### Multi-DUT concurrency

`TestExecutor` is a container of plan / config / plug registrations and can spawn multiple concurrent `TestSession`s:

```swift
let executor = TestExecutor(plan: plan, config: cfg)
await executor.register(PowerSupply.self)

// Single DUT (backwards compatible):
let record = await executor.execute(serialNumber: "SN-1")

// Multi-DUT in parallel:
async let s1 = executor.startSession(serialNumber: "DUT-1")
async let s2 = executor.startSession(serialNumber: "DUT-2")
let session1 = await s1
let session2 = await s2
async let r1 = session1.record()
async let r2 = session2.record()
let (rec1, rec2) = await (r1, r2)
```

Each session owns its own plug instances (factories are reinvoked, independent setup / tearDown). `executor.events()` is the aggregated stream; subscribe to `session.events()` to discriminate per-DUT.

### Event stream

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

`session.events()` carries a replay buffer — new subscribers receive every previously emitted event, so even if `startSession` already started the session you won't miss `.testStarted`.

### Output sinks

Implement `OutputCallback.save(record:)` for arbitrary destinations. Built-ins:

- `ConsoleOutput` — pretty-printed summary (with measurements, attachments, diagnoses)
- `JSONOutput(directory:)` — one ISO8601-named JSON file per record
- `CSVOutput(directory:)` — one CSV per record, one row per phase (with `attachments_count` / `diagnoses_count` columns)

## Demos

```bash
# CLI demo (auto-answers prompts, outputs to $TMPDIR/SwiftHTFDemo/)
swift run SwiftHTFDemo

# SwiftUI window (operator answers prompts, phase grid + live log)
swift run SwiftHTFSwiftUIDemo
```

## Development

```bash
swift build
swift test          # 160 tests
```

## License

[MIT](LICENSE) © 2026 HunterFirefly
