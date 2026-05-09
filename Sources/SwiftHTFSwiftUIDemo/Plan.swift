import Foundation
import SwiftHTF

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
    func setup() async throws {}
    func tearDown() async { voltage = 0 }
}

@MainActor
func makeDemoPlan() -> TestPlan {
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
        Phase(name: "OperatorReady") { @MainActor ctx in
            let prompt = ctx.getPlug(PromptPlug.self)
            let ok = await prompt.requestConfirm("放好治具，按确认开始测试")
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

        Group("PowerRail") {
            Phase(name: "PowerOn") { @MainActor ctx in
                let psu = ctx.getPlug(MockPowerSupply.self)
                await psu.setOutput(3.3)
                return .continue
            }
            Phase(
                name: "VccCheck",
                measurements: [
                    .named("vcc", unit: "V", description: "主电源")
                        .inRange(3.0, 3.6)
                        .withinPercent(of: 3.3, percent: 10)
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
            Phase(
                name: "VRampSweep",
                series: [
                    .named("v_ramp")
                        .dimension("V_set", unit: "V")
                        .value("V_meas", unit: "V")
                        .lengthAtLeast(5)
                        .each { sample in
                            guard let want = sample[0].asDouble,
                                  let got = sample[1].asDouble else { return .pass }
                            let err = abs(got - want)
                            if err > 0.2 { return .fail("err=\(err)V") }
                            if err > 0.1 { return .marginal("err=\(err)V") }
                            return .pass
                        }
                ]
            ) { @MainActor ctx in
                let psu = ctx.getPlug(MockPowerSupply.self)
                await ctx.recordSeries("v_ramp") { rec in
                    for v in stride(from: 0.0, through: 3.3, by: 0.5) {
                        await psu.setOutput(v)
                        let measured = await psu.readVoltage()
                        rec.append(v, measured)
                    }
                }
                return .continue
            }
        }

        Phase(name: "Mode") { @MainActor ctx in
            let prompt = ctx.getPlug(PromptPlug.self)
            let idx = await prompt.requestChoice("选择测试档位", options: ["快速", "标准", "完整"])
            ctx.measure("mode_index", idx)
            return .continue
        }
    }
}
