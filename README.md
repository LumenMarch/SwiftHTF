# SwiftHTF

[![CI](https://github.com/HunterFirefly/SwiftHTF/actions/workflows/ci.yml/badge.svg)](https://github.com/HunterFirefly/SwiftHTF/actions/workflows/ci.yml)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2012%2B-blue.svg)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A modern Swift hardware-test framework inspired by [OpenHTF](https://github.com/google/openhtf). Build manufacturing / bring-up / bench test plans declaratively, run them as `actor`-isolated sessions, observe events as `AsyncStream`, and emit JSON / CSV records.

[简体中文](README.zh-CN.md)

## Features

- **Declarative test plans** — compose `Phase`s with a `@resultBuilder` DSL, including `if` / `for` / availability branches.
- **Strict concurrency** — built on Swift `actor`s with `StrictConcurrency` enabled; engine state is serialized, phase code runs on `@MainActor`, plugs are isolated however you need.
- **Phases with retry, timeout, validators** — declare `lowerLimit` / `upperLimit` / `unit` inline, or attach custom `Validator`s.
- **Typed measurements** — `ctx.measure("vcc", 3.3, unit: "V")` records JSON-codable values via `AnyCodableValue`.
- **Pluggable hardware (`Plug`)** — register types with `init()` or a factory closure; `setup` / `tearDown` run automatically with strict ordering.
- **Event stream** — subscribe to `testStarted` / `phaseCompleted` / `log` / `testCompleted` via `executor.events()`.
- **Output sinks** — ship with `ConsoleOutput`, `JSONOutput`, `CSVOutput`; implement `OutputCallback` to add your own.
- **Codable records** — `TestRecord` / `PhaseRecord` / `Measurement` round-trip through JSON.

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
        dependencies: ["SwiftHTF"]
    )
]
```

## Quick start

```swift
import SwiftHTF

// 1. Define a hardware plug
actor PowerSupply: PlugProtocol {
    private var voltage: Double = 0
    init() {}
    func setOutput(_ v: Double) async { voltage = v }
    func readVoltage() async -> Double { voltage }
    func setup() async throws { /* connect */ }
    func tearDown() async { voltage = 0 }
}

// 2. Build a test plan
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

// 3. Run it
@MainActor
func run() async {
    let plan = makePlan()
    let executor = TestExecutor(
        plan: plan,
        outputCallbacks: [ConsoleOutput()]
    )
    await executor.register(PowerSupply.self)

    // Optional: subscribe to events
    let listener = Task { [executor] in
        for await event in await executor.events() {
            if case .phaseCompleted(let r) = event {
                print("phase \(r.name) -> \(r.outcome.rawValue)")
            }
        }
    }

    let record = await executor.execute(serialNumber: "SN-0001")
    listener.cancel()
    print("Outcome: \(record.outcome.rawValue)")
}
```

## Concepts

### `TestPlan` & `Phase`

A `TestPlan` is a named sequence of `Phase`s, with optional `setup` / `teardown` arrays. Phases are built with the `@TestPlanBuilder` result builder, so you can mix loops and conditionals naturally:

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

Each phase returns a `PhaseResult`:

| Result            | Meaning                                       |
|-------------------|-----------------------------------------------|
| `.continue`       | Pass; run the next phase                      |
| `.failAndContinue`| Mark phase fail; honor `continueOnFail`       |
| `.retry`          | Run the same phase again (up to `retryCount`) |
| `.skip`           | Skip without running                          |
| `.stop`           | Abort the whole test                          |

### Plugs

`PlugProtocol` describes any hardware adapter. Implementations choose their own actor isolation — `actor`, `@MainActor`, or non-isolated all work:

```swift
actor PowerSupply: PlugProtocol {
    init() {}
    func setup() async throws { /* connect */ }
    func tearDown() async { /* disconnect */ }
}

// In your test entry:
await executor.register(PowerSupply.self)
// or with a factory:
await executor.register(PowerSupply.self) { PowerSupply(port: "/dev/tty.usbserial-1") }
```

`PlugManager` constructs each instance once on `@MainActor`, calls `setup()` before phases run, and guarantees `tearDown()` runs after — including on failure paths.

### Validators & limits

Phases can attach `lowerLimit` / `upperLimit` (string, supports `0x...` hex) and `unit`. The framework wraps them in a `RangeValidator` automatically. For string / regex / non-empty checks, attach a `Validator` array.

### Event stream

`executor.events()` returns an `AsyncStream<TestEvent>`. The call is `actor`-isolated, so subscriptions established before `execute()` receive every event. Cancel the consuming task or break out of the loop to detach.

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

### Output callbacks

Implement `OutputCallback.save(record:)` for arbitrary sinks. Built-ins:

- `ConsoleOutput` — pretty-printed summary
- `JSONOutput(directory:)` — one ISO8601-named JSON file per record
- `CSVOutput(directory:)` — one CSV per record, one row per phase

## Demo

```bash
swift run SwiftHTFDemo
```

Output JSON / CSV files land in `$TMPDIR/SwiftHTFDemo/`.

## Development

```bash
swift build
swift test
```

## License

[MIT](LICENSE) © 2026 HunterFirefly
