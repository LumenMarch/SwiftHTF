# SwiftHTF

[![CI](https://github.com/LumenMarch/SwiftHTF/actions/workflows/ci.yml/badge.svg)](https://github.com/LumenMarch/SwiftHTF/actions/workflows/ci.yml)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2012%2B-blue.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A modern Swift hardware-test framework inspired by [OpenHTF](https://github.com/google/openhtf). Build manufacturing / bring-up / bench test plans declaratively, run them as `actor`-isolated sessions, observe events as `AsyncStream`, and emit JSON / CSV records. Ships with `SwiftHTFUI` for drop-in SwiftUI integration.

[简体中文](README.zh-CN.md)

## Features

- **Declarative test plans** — compose `Phase`s with a `@resultBuilder` DSL, including `if` / `for` / availability branches.
- **Startup phase (OpenHTF `test_start` equivalent)** — `TestPlan(name:, startup: Phase(...)) { ... }` runs a single gating phase *after* plug `setUp()` but *before* `setupNodes`. Typical use: scan barcode via `PromptPlug`, write `ctx.serialNumber`, then let the main flow proceed. Returning `.stop` aborts the whole test (`outcome = .aborted`) while still running `teardownNodes` / plug tearDown. A `serialNumberResolved(String?)` event fires once startup finishes so SwiftUI can refresh titles before `testCompleted`.
- **Nested PhaseGroup** — `Group(name) { ... } setup: { ... } teardown: { ... }` sits alongside `Phase` and nests freely; `continueOnFail` is local to each group.
- **Subtest (isolated-failure unit)** — `Subtest("name") { ... }` sits alongside `Phase` / `Group`. Any phase fail / error / `.failSubtest` short-circuits the remaining nodes, but **does not propagate** to `TestRecord.outcome`. A separate `SubtestRecord` (with `phaseIDs` back-references) is emitted for UI / sinks.
- **Checkpoint (sequence merge point)** — `Checkpoint("name")` sits alongside `Phase` / `Group` / `Subtest`. When reached, scans the local scope's phase outcomes; if any `.fail` / `.error` is found, writes a `PhaseRecord(outcome: .fail)` and short-circuits the remaining siblings (ignores `continueOnFail`). Useful for "collect data first, then decide whether to run expensive stress tests" patterns. Scope is local: top-level checkpoint sees only top-level phases, group/subtest checkpoints see only their own scope.
- **Declarative measurements** — pre-declare `MeasurementSpec` on a phase, chain validators (`inRange` / `equals` / `matchesRegex` / `withinPercent` / `notEmpty` / `marginalRange` / `custom`); outcomes are written back to `Measurement.outcome`.
- **Multi-dimensional measurements (`SeriesMeasurement`)** — `ctx.recordSeries("iv") { rec in ... }` incrementally captures IV / sweep / temperature curves; `SeriesMeasurementSpec` supports `lengthAtLeast` / `each` / `custom` validators.
- **Three-state outcome** — `pass` / `marginalPass` / `fail` / `error` / `skip`, with proper "in-spec but near limit" semantics.
- **Runtime gating with `runIf`** — both `Phase` and `Group` accept a `runIf` closure that reads `ctx.config` / collected state to decide whether to execute.
- **Measurement repeat** — `repeatOnMeasurementFail` is independent of `retryCount` (which handles thrown exceptions / explicit `.retry`); the two counters never consume each other.
- **Diagnostics** — `PhaseDiagnoser` runs at terminal `.fail` / `.error`, can read the record and write `ctx.attach` / `ctx.measure` / `ctx.log` for debugging breadcrumbs; `TestDiagnoser` runs once at test wrap-up (outcome already determined, before tear-down) for whole-record post-processing — useful for cross-phase aggregation, multi-rail degradation detection, etc. `Diagnosis` carries severity / fault code / arbitrary details.
- **Failure routing** — `failureExceptions` whitelist: thrown matching types map to `.fail` (test failure), others stay `.error` (program error).
- **Attachments** — `ctx.attach(name:data:mimeType:)` / `attachFromFile(_:)`; auto base64 in JSON, summary in Console / CSV.
- **Per-phase logger** — `ctx.logInfo / logWarning / logError(...)` writes to `PhaseRecord.logs: [LogEntry]` and broadcasts to the event stream in real time; on retry only the last attempt's logs survive.
- **`TestConfig` multi-source loading** — JSON / YAML files (auto-detected by extension), environment variables (`TestConfig.from(environment:prefix:)`), command-line `--key value` / `--key=value` (`TestConfig.from(arguments:)`), chained via `.merging(_:)` for OpenHTF-style priority (defaults < file < env < CLI). Inside phases: `ctx.config.string(...) / double(...) / value(_, as:)`. Depends on Yams for YAML.
- **Phase-shared state** — `ctx.state` is a session-level mutable dict (mirrors `TestConfig` API: `string` / `int` / `double` / `bool` / `value(_:as:)` + `set(_:_:)`). Pass intermediate values between phases without inventing a custom plug; not persisted to `TestRecord` (use `measure` for that).
- **Pluggable hardware (`Plug`)** — register with `init()` or a factory; declare `dependencies` and `PlugManager` topologically sorts setup, injecting ready plugs via `setup(resolver:)`.
- **Plug placeholders (`bind` / `swap`)** — `executor.swap(RealPSU.self, with: MockPSU.self)` swaps a real plug with a mock; phase code keeps `ctx.getPlug(RealPSU.self)` unchanged.
- **Operator interaction (`PromptPlug`)** — `await prompt.requestConfirm(..., timeout: 30) / requestText(...) / requestChoice(...)` suspends inside a phase with optional per-call timeout; UI subscribes via `events()` and replies with `resolve(...)`. `resolutions()` stream notifies the UI when any request resolves (user answer / cancel / timeout) so SwiftUI sheets auto-dismiss. Designed for SwiftUI sheets.
- **Multi-DUT concurrency (`TestSession`)** — one `TestExecutor` spawns multiple concurrent sessions; each owns its own plug instances and event stream. `executor.events()` is the aggregated stream.
- **History persistence (`HistoryStore`)** — `InMemoryHistoryStore` / `JSONFileHistoryStore`; query by SN / planName / outcome / time window / limit. `HistoryOutputCallback` plugs in as an `OutputCallback` for automatic ingest.
- **Continuous trigger loop (`TestLoop`)** — factory pattern: `trigger` returns a serial number to start one session, then waits again on completion; `states()` exposes a state stream for SwiftUI.
- **Strict concurrency** — Swift `actor` + `StrictConcurrency`, phase code is `@MainActor`, plug isolation is your call.
- **Event stream** — `AsyncStream<TestEvent>`: `testStarted` / `serialNumberResolved` / `phaseCompleted` / `log` / `testCompleted`.
- **Output sinks** — `ConsoleOutput` / `JSONOutput` / `CSVOutput` / `HistoryOutputCallback` built in; implement `OutputCallback` for anything else.
- **Codable records** — `TestRecord` / `PhaseRecord` / `Measurement` / `SeriesMeasurement` / `Attachment` / `Diagnosis` / `LogEntry` round-trip JSON.
- **`SwiftHTFUI`** — ready-made `TestRunnerViewModel` / `PromptCoordinator` / `PromptSheetView` for SwiftUI.

## Requirements

- Swift 5.9+
- macOS 12+

## Installation

Add SwiftHTF to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/LumenMarch/SwiftHTF.git", from: "0.3.0")
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

        // Nested Group + declarative measurement + diagnoser + per-phase log
        Group("PowerRail") {
            Phase(name: "PowerOn") { @MainActor ctx in
                ctx.logInfo("Powering on at 3.3V")
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
| `.failSubtest`    | Mark phase fail and short-circuit enclosing Subtest (equivalent to `.failAndContinue` when not in a Subtest) |

### Startup phase (OpenHTF `test_start` equivalent)

Plans often need to gate the whole run on something — scan a barcode to learn the DUT's serial number, confirm a fixture is in place, or refuse to proceed if a license check fails. Put that logic in `TestPlan.startup`:

```swift
TestPlan(
    name: "DemoBoard",
    startup: Phase(name: "ScanSN") { @MainActor ctx in
        let prompt = ctx.getPlug(PromptPlug.self)
        guard let sn = await prompt.requestText("Scan DUT SN", timeout: 60)
        else { return .stop }                              // operator cancelled
        ctx.serialNumber = sn                              // back-fill record.serialNumber
        return .continue
    }
) {
    Phase(name: "PowerOn") { _ in .continue }
    Group("RFTests") { ... }
} teardown: [
    Phase(name: "PowerOff") { _ in .continue }
]
```

Lifecycle position: plug `setUp()` → **startup** → `setupNodes` → `nodes` → `teardownNodes` → plug `tearDown()`.

Outcome mapping (PhaseRecord vs TestRecord):

| Startup `PhaseResult`   | `PhaseRecord.outcome` | `TestRecord.outcome` | Main body runs? | Teardown runs? |
|-------------------------|-----------------------|----------------------|-----------------|----------------|
| `.continue`             | `.pass`               | (unchanged)          | yes             | yes            |
| `.stop`                 | `.pass`*              | `.aborted`           | no              | yes            |
| `.failAndContinue`      | `.fail`               | `.fail`              | no              | yes            |
| thrown (non-whitelist)  | `.error`              | `.fail`              | no              | yes            |
| timed out               | `.timeout`            | `.timeout`           | no              | yes            |
| `runIf` returns `false` | (no record written)   | (unchanged)          | yes             | yes            |

\* `.stop` is a control-flow signal, not a failure — the `PhaseRecord` keeps its computed outcome (typically `.pass`) and `stopRequested = true` triggers the `.aborted` mapping.

Other notes:
- Startup `PhaseRecord` is appended to `record.phases` with `groupPath = TestSession.startupGroupPath` (`["__startup__"]`) so UI / sinks can tell startup apart from business phases.
- Plug `tearDown()` always runs (regardless of startup outcome).
- A `TestEvent.serialNumberResolved(ctx.serialNumber)` is broadcast immediately after startup completes (unless skipped by `runIf`). `SwiftHTFUI.TestRunnerViewModel` already wires this so the title refreshes the moment the operator finishes scanning, well before `testCompleted`.
- Startup inherits the full `Phase` feature set: `timeout`, `retryCount`, `measurements`, `series`, `diagnosers`, `failureExceptions`, `runIf`, `repeatOnMeasurementFail`.

### Subtest (isolated-failure unit)

A `Subtest` is a sibling node to `Phase` / `Group` that **isolates failure**: any inner phase / group failure short-circuits the remaining nodes but does **not** propagate to `TestRecord.outcome`. Subtest results are emitted as `SubtestRecord` entries on `TestRecord.subtests`, with `phaseIDs` cross-referencing `TestRecord.phases`.

```swift
TestPlan(name: "Board") {
    Phase(name: "Connect") { _ in .continue }

    Subtest("PowerTests") {
        Phase(name: "VccCheck") { _ in .continue }
        Phase(name: "VddCheck") { _ in .failAndContinue }   // short-circuits this Subtest
        Phase(name: "VbatCheck") { _ in .continue }         // not run
    }

    Phase(name: "Cleanup") { _ in .continue }   // still runs — Subtest failure is isolated
}
```

Semantics:

- Phase `.fail` / `.error` / `.failSubtest`, or nested `Group` failure → short-circuit remaining nodes in the Subtest.
- Subtest failure does **not** set `TestRecord.outcome = .fail`. The outer test continues; inspect `record.subtests` to aggregate.
- Nested `Subtest` failures do **not** propagate to the enclosing Subtest either — each Subtest is its own isolation boundary.
- `.stop` still propagates across Subtest boundaries to abort the whole test.
- `Subtest` accepts `runIf`; false → `SubtestRecord.outcome = .skip` and zero phases recorded.

`SubtestRecord`:

| Field          | Meaning                                                               |
|----------------|-----------------------------------------------------------------------|
| `id`           | Stable UUID across encode / decode                                    |
| `name`         | As declared                                                           |
| `outcome`      | `.pass` / `.fail` / `.error` / `.skip`                                |
| `phaseIDs`     | `PhaseRecord.id`s of phases run inside this Subtest, in order         |
| `failureReason`| Which inner node triggered the short-circuit (`"VddCheck: FAIL"`)     |
| `startTime` / `endTime` / `duration` | Subtest-level timing                            |

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

### Multi-dimensional measurements (`SeriesMeasurement`)

Declare the trace's dimensions then incrementally append samples in the phase; `harvest` runs all series validators:

```swift
Phase(
    name: "VRampSweep",
    series: [
        .named("v_ramp")
            .dimension("V_set", unit: "V")
            .value("V_meas", unit: "V")
            .lengthAtLeast(5)
            .each { sample in                         // closure runs per row
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

`SeriesMeasurement` lives alongside single-point `Measurement` in `PhaseRecord.traces: [String: SeriesMeasurement]`; series outcomes feed the same phase aggregation, and `repeatOnMeasurementFail` triggers on series failure too.

### Phase advanced fields

```swift
Phase(
    name: "VccCheck",
    timeout: 5,                          // seconds
    retryCount: 2,                       // retries on exception / explicit .retry
    measurements: [.named("vcc").inRange(3.0, 3.6)],
    series: [.named("v_ramp").dimension("V").value("I").lengthAtLeast(5)],
    runIf: { @MainActor ctx in           // runtime gate — false → outcome=.skip
        ctx.config.bool("vcc.enabled") ?? true
    },
    repeatOnMeasurementFail: 3,          // re-read on measurement / series failure
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

### Per-phase logger

Inside a phase write logs via `ctx.logXxx`; entries are appended to `PhaseRecord.logs` in order and broadcast to the session event stream live:

```swift
Phase(name: "BringUp") { @MainActor ctx in
    ctx.logInfo("Booting BSP")
    do {
        try await bsp.boot()
    } catch {
        ctx.logError("boot failed: \(error.localizedDescription)")
        throw error
    }
    return .continue
}
```

- `LogEntry { timestamp, level, message }`, `LogLevel` is `debug/info/warning/error`
- Each retry attempt resets the buffer; only the last attempt's logs survive in `record.logs`
- Logs written from a `PhaseDiagnoser` are merged into `record.logs` as well

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

### Plug placeholders (mock injection)

Real plugs in production, mocks in CI — phase code stays the same:

```swift
class RealPSU: PlugProtocol {
    required init() {}
    func setOutput(_ v: Double) {}
    func readVoltage() -> Double { /* real readout */ 3.3 }
    func setup() async throws {}
    func tearDown() async {}
}
final class MockPSU: RealPSU {
    override func readVoltage() -> Double { 1.5 }   // simulated
}

let executor = TestExecutor(plan: plan)
await executor.register(RealPSU.self)
await executor.swap(RealPSU.self, with: MockPSU.self)   // swap for tests

// Phase code unchanged:
ctx.getPlug(RealPSU.self).readVoltage()   // actually returns the MockPSU instance
```

API:
- `bind(Abstract.self, to: Concrete.self)` — alias an abstract type to an already-registered concrete one
- `swap(A.self, with: B.self)` — `unregister(A) + register(B) + bind(A, to: B)` in one call
- `swap(_, with:, factory:)` — supply a factory closure for the mock instance

Aliases also participate in dependency topological sort: a plug that declares `dependencies = [Abstract.self]` resolves to the concrete instance after the alias is in place.

### PromptPlug & SwiftUI integration

Inside a phase, suspend until the operator answers (with optional per-call timeout):

```swift
Phase(name: "ScanSerial") { @MainActor ctx in
    let prompt = ctx.getPlug(PromptPlug.self)
    // Without timeout: wait forever
    let sn = await prompt.requestText("Scan SN", placeholder: "SN-...")
    ctx.serialNumber = sn

    // With 30 s timeout: empty string on timeout (same as cancel)
    let opOK = await prompt.requestConfirm("Fixture ready?", timeout: 30)
    if !opOK { return .stop }
    return .continue
}
```

`timeout: TimeInterval? = nil` is available on all three high-level APIs. To distinguish operator cancel from timeout, use the lower-level `request(kind:timeout:) -> PromptResponse`:

```swift
let response = await prompt.request(kind: .confirm(message: "OK?"), timeout: 5)
switch response {
case .confirm(let b):  ...
case .cancelled:       ctx.logWarning("operator cancelled")
case .timedOut:        ctx.logWarning("no response after 5 s")
case .text, .choice:   break // shape mismatch
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

// Single DUT:
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

### History persistence (`HistoryStore`)

Persist records to disk and query past results across processes:

```swift
let store = try JSONFileHistoryStore(directory: URL(fileURLWithPath: "/var/log/htf"))
let executor = TestExecutor(
    plan: plan,
    outputCallbacks: [HistoryOutputCallback(store: store)]   // auto-ingest each record
)

// later:
let recent = try await store.list(HistoryQuery(serialNumber: "SN-1", limit: 10))
let fails = try await store.list(HistoryQuery(outcomes: [.fail], since: Date().addingTimeInterval(-86400)))
```

API:
- `save(_:)` / `load(id:)` / `list(_:)` / `delete(id:)` / `clear()`
- `HistoryQuery`: `serialNumber` / `planName` / `outcomes` / `since` / `until` / `limit` / `sortDescending`
- Built-in implementations: `InMemoryHistoryStore` (actor, for tests) and `JSONFileHistoryStore` (actor, one JSON file per record, `secondsSince1970` encoding to preserve millisecond precision)

### Continuous trigger loop (`TestLoop`)

Factory continuous-test pattern: scan barcode → start a session → wait for completion → back to scan:

```swift
let loop = TestLoop(
    executor: executor,
    trigger: { await viewModel.waitForBarcode() },   // returns SN, nil to stop
    onCompleted: { record in
        try? await store.save(record)
    }
)
await loop.start()
// ...
await loop.stop()
```

`states()` exposes the state stream (`idle` / `awaitingTrigger` / `running(sn)` / `stopped`) with replay buffer to drive SwiftUI; `completedCount` reflects sessions completed.

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
- `CSVOutput(directory:)` — one CSV per record, one row per phase (columns: name, outcome, duration_s, measurements_count, traces_count, attachments_count, diagnoses_count, error)
- `HistoryOutputCallback(store:)` — wraps any `HistoryStore` for automatic ingest

## Demos

```bash
# Programmatic demo (auto-answers prompts, outputs to $TMPDIR/SwiftHTFDemo/)
swift run SwiftHTFDemo

# SwiftUI window (operator answers prompts, phase grid + live log)
swift run SwiftHTFSwiftUIDemo
```

## Development

```bash
swift build
swift test          # 185 tests
```

## License

[MIT](LICENSE) © 2026 LumenMarch
