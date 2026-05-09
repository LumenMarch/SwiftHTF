import SwiftUI
import SwiftHTF

/// 默认 prompt sheet 视图。按 `PromptKind` 渲染不同 UI。
///
/// 调用方在 `.sheet(item: $coord.current)` 内构造它，并把响应回传给 `PromptCoordinator`。
public struct PromptSheetView: View {
    public let request: PromptRequest
    public let onResponse: (PromptResponse) -> Void

    public init(request: PromptRequest, onResponse: @escaping (PromptResponse) -> Void) {
        self.request = request
        self.onResponse = onResponse
    }

    public var body: some View {
        VStack(spacing: 0) {
            switch request.kind {
            case .confirm(let message):
                ConfirmContent(message: message, onResponse: onResponse)
            case .text(let message, let placeholder):
                TextContent(message: message, placeholder: placeholder, onResponse: onResponse)
            case .choice(let message, let options):
                ChoiceContent(message: message, options: options, onResponse: onResponse)
            }
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 160)
    }
}

private struct ConfirmContent: View {
    let message: String
    let onResponse: (PromptResponse) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            HStack {
                Spacer()
                Button("否") { onResponse(.confirm(false)) }
                    .keyboardShortcut(.cancelAction)
                Button("是") { onResponse(.confirm(true)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct TextContent: View {
    let message: String
    let placeholder: String?
    let onResponse: (PromptResponse) -> Void
    @State private var input: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message).font(.headline)
            TextField(placeholder ?? "", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onResponse(.text(input)) }
            HStack {
                Spacer()
                Button("取消") { onResponse(.cancelled) }
                    .keyboardShortcut(.cancelAction)
                Button("确定") { onResponse(.text(input)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.isEmpty)
            }
        }
    }
}

private struct ChoiceContent: View {
    let message: String
    let options: [String]
    let onResponse: (PromptResponse) -> Void
    @State private var selected: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message).font(.headline)
            Picker("", selection: $selected) {
                ForEach(Array(options.enumerated()), id: \.offset) { (idx, opt) in
                    Text(opt).tag(idx)
                }
            }
            .pickerStyle(.radioGroup)
            HStack {
                Spacer()
                Button("取消") { onResponse(.cancelled) }
                    .keyboardShortcut(.cancelAction)
                Button("确定") { onResponse(.choice(selected)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
