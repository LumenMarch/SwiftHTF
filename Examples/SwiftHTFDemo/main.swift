import Foundation
import SwiftHTF

// MARK: - 模拟硬件 Plug

//
// 用 actor 实现 — 比 @MainActor class 更适合通用框架，状态串行化由 actor 自动保证

actor MockPowerSupply: PlugProtocol {
    private var voltage: Double = 0

    init() {}

    func setOutput(_ volts: Double) async {
        voltage = volts
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func readVoltage() async -> Double {
        voltage + Double.random(in: -0.05 ... 0.05)
    }

    func setup() async throws {
        print("[PowerSupply] setup")
    }

    func tearDown() async {
        print("[PowerSupply] tearDown")
        voltage = 0
    }
}

// MARK: - 测试计划（result builder）

@MainActor
func makePlan(config: TestConfig) -> TestPlan {
    let vccLower = config.double("vcc.lower") ?? 3.0
    let vccUpper = config.double("vcc.upper") ?? 3.6
    let vccTarget = config.double("vcc.target") ?? 3.3
    let vccPercent = config.double("vcc.percent") ?? 10.0

    return TestPlan(
        name: config.string("plan.name") ?? "DemoBoard",
        teardown: [
            Phase(name: "PowerOff") { @MainActor ctx in
                let psu = ctx.getPlug(MockPowerSupply.self)
                await psu.setOutput(0)
                return .continue
            },
        ]
    ) {
        Phase(name: "OperatorReady") { @MainActor ctx in
            let prompt = ctx.getPlug(PromptPlug.self)
            let ok = await prompt.requestConfirm(
                ctx.config.string("prompts.ready") ?? "放好治具并按确认？"
            )
            ctx.measure("operator_ready", ok)
            return ok ? .continue : .stop
        }

        Phase(name: "ScanSerial") { @MainActor ctx in
            let prompt = ctx.getPlug(PromptPlug.self)
            let sn = await prompt.requestText("请扫码 / 输入 SN", placeholder: "SN-...")
            ctx.serialNumber = sn
            ctx.measure("scanned_sn", sn)
            return .continue
        }

        Group(
            "PowerRail",
            runIf: { @MainActor ctx in ctx.config.bool("powerRail.enabled") ?? true }
        ) {
            Phase(name: "PowerOn") { @MainActor ctx in
                let psu = ctx.getPlug(MockPowerSupply.self)
                await psu.setOutput(vccTarget)
                return .continue
            }
            Phase(
                name: "VccCheck",
                measurements: [
                    .named("vcc", unit: "V", description: "主电源电压")
                        .inRange(vccLower, vccUpper)
                        .marginalRange(
                            config.double("vcc.marginalLower") ?? 3.2,
                            config.double("vcc.marginalUpper") ?? 3.4
                        )
                        .withinPercent(of: vccTarget, percent: vccPercent),
                ],
                diagnosers: [
                    ClosureDiagnoser("vcc-overshoot") { @MainActor record, ctx in
                        guard let v = record.measurements["vcc"]?.value.asDouble else { return [] }
                        let dump = "[diag] vcc=\(v) target=\(vccTarget) lower=\(vccLower) upper=\(vccUpper)"
                        ctx.attach("vcc-trace.log", data: Data(dump.utf8), mimeType: "text/plain")
                        return [
                            Diagnosis(
                                code: v > vccUpper ? "VCC_OVERSHOOT" : "VCC_UNDERSHOOT",
                                severity: .error,
                                message: "vcc \(v) 超出 [\(vccLower), \(vccUpper)]",
                                details: ["vcc": .double(v), "target": .double(vccTarget)]
                            ),
                        ]
                    },
                ]
            ) { @MainActor ctx in
                let psu = ctx.getPlug(MockPowerSupply.self)
                let v = await psu.readVoltage()
                ctx.measure("vcc", v, unit: "V")
                return .continue
            }
            Phase(name: "DiagnosticSnapshot") { @MainActor ctx in
                let log = """
                [diag] vcc=3.30V ok
                [diag] current=120mA ok
                [diag] temp=42.1C ok
                """
                ctx.attach("diag.log", data: Data(log.utf8), mimeType: "text/plain")
                return .continue
            }
        }

        Phase(name: "FlakyTest", retryCount: 3) { @MainActor _ in
            return Bool.random() ? .continue : .retry
        }
    }
}

// MARK: - 入口

/// 持有跨 actor 的 PromptPlug 引用。CLI demo 用它模拟 SwiftUI 的 `@State`：
/// SwiftUI 端做法是在 `View` 里 `let prompt = PromptPlug()`，然后注册时用相同实例的 factory。
private final class PromptHolder: @unchecked Sendable {
    private var value: PromptPlug?
    private let lock = NSLock()
    func set(_ p: PromptPlug) {
        lock.lock(); defer { lock.unlock() }; value = p
    }

    func get() -> PromptPlug? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

@MainActor
func run() async {
    // 内嵌一份 demo 用的 config（实际项目中会用 TestConfig.load(from: url)）
    // 配置说明：
    // - "powerRail.enabled" = false 让 PowerRail 整 group 通过 runIf 跳过（合成 SKIP 记录）。
    // - vcc.marginalLower / vcc.marginalUpper 收紧到 [3.30, 3.31] 等窄带可看到 MARGINAL_PASS 路径。
    let cfgJSON = #"""
    {
        "plan.name": "DemoBoard",
        "vcc.target": 3.3,
        "vcc.lower": 3.0,
        "vcc.upper": 3.6,
        "vcc.marginalLower": 3.2,
        "vcc.marginalUpper": 3.4,
        "vcc.percent": 10,
        "powerRail.enabled": true,
        "prompts.ready": "放好治具并按确认（来自 config）"
    }
    """#
    let config = (try? TestConfig.load(from: Data(cfgJSON.utf8), format: .json)) ?? TestConfig()
    let plan = makePlan(config: config)

    let outputDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SwiftHTFDemo")
    let executor = TestExecutor(
        plan: plan,
        config: config,
        outputCallbacks: [
            ConsoleOutput(),
            JSONOutput(
                directory: outputDir,
                filenameTemplate: OutputFilenameTemplate("{plan}_{serial}_{start_time_iso}.json")
            ),
            CSVOutput(
                directory: outputDir,
                filenameTemplate: OutputFilenameTemplate("{plan}_{serial}_{start_time_iso}.csv")
            ),
        ]
    )

    await executor.register(MockPowerSupply.self)

    let promptHolder = PromptHolder()
    await executor.register(PromptPlug.self, factory: { @MainActor in
        let p = PromptPlug()
        promptHolder.set(p)
        return p
    })

    // 事件流监听
    let listener = Task { [executor] in
        for await event in await executor.events() {
            switch event {
            case let .testStarted(name, sn):
                print("[event] testStarted plan=\(name) sn=\(sn ?? "-")")
            case let .serialNumberResolved(sn):
                print("[event] serialNumberResolved sn=\(sn ?? "-")")
            case let .phaseCompleted(r):
                print("[event] phase \(r.name) -> \(r.outcome.rawValue) (\(String(format: "%.2f", r.duration))s)")
            case let .log(msg):
                print("[event] log: \(msg)")
            case let .testCompleted(r):
                print("[event] testCompleted -> \(r.outcome.rawValue)")
            }
        }
    }

    // PromptPlug 监听：等 plug 实例化后订阅，自动应答（CLI 模拟 SwiftUI 弹窗）。
    // SwiftUI 真实场景里换成在 View 中 `for await req in plug.events()` 触发 sheet。
    let promptListener = Task { @MainActor in
        var plug: PromptPlug?
        for _ in 0 ..< 200 {
            if let p = promptHolder.get() { plug = p; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let plug else { return }
        for await req in plug.events() {
            switch req.kind {
            case let .confirm(msg):
                print("[prompt] confirm: \(msg) -> auto YES")
                plug.resolve(id: req.id, response: .confirm(true))
            case let .text(msg, _):
                print("[prompt] text: \(msg) -> auto SN-DEMO-0001")
                plug.resolve(id: req.id, response: .text("SN-DEMO-0001"))
            case let .choice(msg, opts):
                print("[prompt] choice: \(msg) options=\(opts) -> auto 0")
                plug.resolve(id: req.id, response: .choice(0))
            }
        }
    }

    let record = await executor.execute()
    listener.cancel()
    promptListener.cancel()

    print("\n输出目录: \(outputDir.path)")
    print("最终结果: \(record.outcome.rawValue)")
}

await run()
