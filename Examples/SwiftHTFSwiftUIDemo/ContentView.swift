import SwiftHTF
import SwiftHTFUI
import SwiftUI

struct ContentView: View {
    @StateObject private var model = DemoModel()

    var body: some View {
        RunnerScene(
            runner: model.runner,
            prompts: model.prompts,
            plug: model.promptPlug
        )
        .task { await model.boot() }
    }
}

private struct RunnerScene: View {
    @ObservedObject var runner: TestRunnerViewModel
    @ObservedObject var prompts: PromptCoordinator
    let plug: PromptPlug

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                phaseList
            }
            .frame(minWidth: 360)

            VStack(alignment: .leading, spacing: 0) {
                Text("日志").font(.headline).padding([.top, .horizontal])
                Divider()
                logView
            }
            .frame(minWidth: 320)
        }
        .task { await prompts.attach(to: plug) }
        .sheet(item: $prompts.current) { req in
            PromptSheetView(request: req) { resp in
                prompts.resolve(req.id, response: resp)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(runner.planName ?? "DemoBoard").font(.title2.bold())
                Spacer()
                if let outcome = runner.outcome {
                    OutcomeBadge(outcome: outcome)
                }
            }
            HStack(spacing: 12) {
                Button(runner.isRunning ? "运行中…" : "开始测试") { runner.start() }
                    .disabled(runner.isRunning)
                    .keyboardShortcut(.defaultAction)
                Button("取消") { runner.cancel() }
                    .disabled(!runner.isRunning)
                Button("清空") { runner.reset() }
                    .disabled(runner.isRunning)
                Spacer()
                if let sn = runner.serialNumber {
                    Text("SN: \(sn)").foregroundColor(.secondary).font(.callout)
                }
            }
        }
        .padding()
    }

    private var phaseList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(runner.phases) { phase in
                    PhaseRow(phase: phase)
                }
                if runner.phases.isEmpty {
                    Text("尚未运行").foregroundColor(.secondary).padding()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var logView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(runner.logLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - 子视图

private struct OutcomeBadge: View {
    let outcome: TestOutcome
    var body: some View {
        Text(outcome.rawValue)
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.18))
            .foregroundColor(color)
            .cornerRadius(6)
    }

    private var color: Color {
        switch outcome {
        case .pass: .green
        case .marginalPass: .yellow
        case .fail, .error, .timeout, .aborted: .red
        }
    }
}

private struct PhaseRow: View {
    let phase: PhaseRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(symbol).foregroundColor(color)
                if !phase.groupPath.isEmpty {
                    Text(phase.groupPath.joined(separator: " / ") + " /")
                        .foregroundColor(.secondary).font(.caption)
                }
                Text(phase.name).font(.body.bold())
                Spacer()
                Text(String(format: "%.2fs", phase.duration))
                    .foregroundColor(.secondary).font(.caption)
            }
            if let msg = phase.errorMessage {
                Text(msg).font(.caption).foregroundColor(.red)
            }
            ForEach(phase.measurements.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                MeasurementRow(name: entry.key, measurement: entry.value)
            }
            ForEach(phase.traces.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                TraceRow(name: entry.key, trace: entry.value)
            }
            ForEach(Array(phase.attachments.enumerated()), id: \.offset) { _, a in
                AttachmentRow(attachment: a)
            }
            ForEach(phase.diagnoses) { d in
                DiagnosisRow(diagnosis: d)
            }
        }
        .padding(8)
        .padding(.leading, CGFloat(phase.groupPath.count) * 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06))
        .cornerRadius(6)
    }

    private var symbol: String {
        switch phase.outcome {
        case .pass: "✓"
        case .marginalPass: "≈"
        case .fail: "✗"
        case .skip: "⏭"
        case .error: "⚠"
        case .timeout: "⏱"
        }
    }

    private var color: Color {
        switch phase.outcome {
        case .pass: .green
        case .marginalPass: .yellow
        case .fail, .error, .timeout: .red
        case .skip: .gray
        }
    }
}

private struct DiagnosisRow: View {
    let diagnosis: Diagnosis

    var body: some View {
        HStack(spacing: 6) {
            Text("🩺").font(.caption)
            Text("[\(diagnosis.severity.rawValue)]").font(.caption2.bold()).foregroundColor(severityColor)
            Text(diagnosis.code).font(.caption.bold())
            Text(diagnosis.message).font(.caption).foregroundColor(.secondary)
            Spacer()
        }
        .padding(.leading, 16)
    }

    private var severityColor: Color {
        switch diagnosis.severity {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        case .critical: .purple
        }
    }
}

private struct AttachmentRow: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: 6) {
            Text("📎").font(.caption)
            Text(attachment.name).font(.caption.bold())
            Text(attachment.mimeType).foregroundColor(.secondary).font(.caption)
            Text(formatBytes(attachment.size))
                .foregroundColor(.secondary).font(.caption)
            Spacer()
        }
        .padding(.leading, 16)
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        let kb = Double(n) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.2f MB", kb / 1024)
    }
}

private struct TraceRow: View {
    let name: String
    let trace: SeriesMeasurement

    var body: some View {
        HStack(spacing: 6) {
            Text("∿").foregroundColor(color)
            Text(name).font(.caption.bold())
            Text("(\(layoutLabel))").foregroundColor(.secondary).font(.caption2)
            Text("\(trace.samples.count) samples").font(.caption)
            if !trace.validatorMessages.isEmpty {
                Text(trace.validatorMessages.joined(separator: "; "))
                    .font(.caption2).foregroundColor(color).lineLimit(2)
            }
            Spacer()
        }
        .padding(.leading, 16)
    }

    private var layoutLabel: String {
        let dims = trace.dimensions.map { d -> String in
            if let u = d.unit { return "\(d.name)/\(u)" }
            return d.name
        }
        let val: String = {
            if let u = trace.value.unit { return "\(trace.value.name)/\(u)" }
            return trace.value.name
        }()
        return (dims + [val]).joined(separator: ", ")
    }

    private var color: Color {
        switch trace.outcome {
        case .pass: .green
        case .marginalPass: .yellow
        case .skip: .gray
        case .fail, .error, .timeout: .red
        }
    }
}

private struct MeasurementRow: View {
    let name: String
    let measurement: SwiftHTF.Measurement

    var body: some View {
        HStack(spacing: 6) {
            Text(symbol).foregroundColor(color)
            Text(name).font(.caption.bold())
            Text("=").foregroundColor(.secondary).font(.caption)
            Text(measurement.value.displayString).font(.caption)
            if let unit = measurement.unit {
                Text(unit).foregroundColor(.secondary).font(.caption)
            }
            if !measurement.validatorMessages.isEmpty {
                Text(measurement.validatorMessages.joined(separator: "; "))
                    .font(.caption2).foregroundColor(color)
            }
            Spacer()
        }
        .padding(.leading, 16)
    }

    private var symbol: String {
        switch measurement.outcome {
        case .pass: "✓"
        case .marginalPass: "≈"
        case .skip: "⏭"
        case .fail, .error, .timeout: "✗"
        }
    }

    private var color: Color {
        switch measurement.outcome {
        case .pass: .green
        case .marginalPass: .yellow
        case .skip: .gray
        case .fail, .error, .timeout: .red
        }
    }
}

// MARK: - 模型

@MainActor
final class DemoModel: ObservableObject {
    let runner: TestRunnerViewModel
    let prompts: PromptCoordinator
    let promptPlug: PromptPlug
    private let executor: TestExecutor
    private var booted = false

    init() {
        let plug = PromptPlug()
        let plan = makeDemoPlan()
        let exec = TestExecutor(plan: plan, outputCallbacks: [ConsoleOutput()])
        executor = exec
        promptPlug = plug
        runner = TestRunnerViewModel(executor: exec)
        prompts = PromptCoordinator()
    }

    func boot() async {
        guard !booted else { return }
        booted = true
        let plug = promptPlug
        await executor.register(MockPowerSupply.self)
        await executor.register(PromptPlug.self, factory: { @MainActor in plug })
    }
}
