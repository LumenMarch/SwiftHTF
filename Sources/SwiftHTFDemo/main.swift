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
        voltage + Double.random(in: -0.05...0.05)
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
func makePlan() -> TestPlan {
    TestPlan(
        name: "DemoBoard",
        teardown: [
            Phase(name: "PowerOff") { @MainActor ctx in
                let psu = ctx.getPlug(MockPowerSupply.self)
                await psu.setOutput(0)
                return .continue
            }
        ]
    ) {
        Phase(name: "PowerOn") { @MainActor ctx in
            let psu = ctx.getPlug(MockPowerSupply.self)
            await psu.setOutput(3.3)
            return .continue
        }

        Phase(name: "VccCheck", lowerLimit: "3.0", upperLimit: "3.6", unit: "V") { @MainActor ctx in
            let psu = ctx.getPlug(MockPowerSupply.self)
            let v = await psu.readVoltage()
            ctx.setValue("VccCheck", String(format: "%.3f", v))
            ctx.measure("vcc", v, unit: "V")
            return .continue
        }

        Phase(name: "FlakyTest", retryCount: 3) { @MainActor _ in
            return Bool.random() ? .continue : .retry
        }
    }
}

// MARK: - 入口

@MainActor
func run() async {
    let plan = makePlan()

    let outputDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SwiftHTFDemo")
    let executor = TestExecutor(
        plan: plan,
        outputCallbacks: [
            ConsoleOutput(),
            JSONOutput(directory: outputDir),
            CSVOutput(directory: outputDir)
        ]
    )

    await executor.register(MockPowerSupply.self)

    let listener = Task { [executor] in
        for await event in await executor.events() {
            switch event {
            case .testStarted(let name, let sn):
                print("[event] testStarted plan=\(name) sn=\(sn ?? "-")")
            case .phaseCompleted(let r):
                print("[event] phase \(r.name) -> \(r.outcome.rawValue) (\(String(format: "%.2f", r.duration))s)")
            case .log(let msg):
                print("[event] log: \(msg)")
            case .testCompleted(let r):
                print("[event] testCompleted -> \(r.outcome.rawValue)")
            }
        }
    }

    let record = await executor.execute(serialNumber: "SN-DEMO-0001")
    listener.cancel()

    print("\n输出目录: \(outputDir.path)")
    print("最终结果: \(record.outcome.rawValue)")
}

await run()
