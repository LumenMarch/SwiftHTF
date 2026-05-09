import Foundation

/// 操作员交互请求种类
public enum PromptKind: Sendable {
    case confirm(message: String)
    case text(message: String, placeholder: String?)
    case choice(message: String, options: [String])
}

/// 一次操作员交互请求
public struct PromptRequest: Sendable, Identifiable {
    public let id: UUID
    public let kind: PromptKind
    public let createdAt: Date

    public init(id: UUID = UUID(), kind: PromptKind, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
    }
}

/// 操作员对一次请求的响应
public enum PromptResponse: Sendable {
    case confirm(Bool)
    case text(String)
    case choice(Int)
    case cancelled
}

/// 操作员交互 Plug
///
/// 用法（phase 中）：
/// ```swift
/// let prompt = ctx.getPlug(PromptPlug.self)
/// guard await prompt.requestConfirm("放好治具？") else { return .stop }
/// let sn = await prompt.requestText("请扫码", placeholder: "SN")
/// ```
///
/// 用法（SwiftUI 中）：
/// ```swift
/// .task {
///     for await req in await prompt.events() {
///         current = req // 触发 sheet
///     }
/// }
/// ```
/// UI 响应后调用 `prompt.resolve(id: req.id, response: .confirm(true))`。
///
/// 隔离：`@MainActor`，便于 SwiftUI 视图直接持有并订阅；phase 闭包默认也是
/// `@MainActor`，调用 `await prompt.requestConfirm(...)` 不跨 actor 边界。
@MainActor
public final class PromptPlug: PlugProtocol {
    private var pendingRequests: [PromptRequest] = []
    private var continuations: [UUID: CheckedContinuation<PromptResponse, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<PromptRequest>.Continuation] = [:]

    public nonisolated init() {}

    public nonisolated func setup() async throws {}

    public nonisolated func tearDown() async {
        await cancelAll()
    }

    private func cancelAll() {
        for cont in continuations.values {
            cont.resume(returning: .cancelled)
        }
        continuations.removeAll()
        pendingRequests.removeAll()
        for sub in subscribers.values {
            sub.finish()
        }
        subscribers.removeAll()
    }

    // MARK: - 订阅 / 解析（UI 侧）

    /// 订阅请求流。新订阅会立刻收到所有尚未应答的 pending 请求。
    public func events() -> AsyncStream<PromptRequest> {
        let id = UUID()
        var continuation: AsyncStream<PromptRequest>.Continuation!
        let stream = AsyncStream<PromptRequest> { c in
            continuation = c
        }
        subscribers[id] = continuation
        for req in pendingRequests {
            continuation.yield(req)
        }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.detach(id)
            }
        }
        return stream
    }

    private func detach(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    /// 应答某次请求；类型与请求不匹配时由调用方 phase 内的高阶 API 处理。
    public func resolve(id: UUID, response: PromptResponse) {
        guard let cont = continuations.removeValue(forKey: id) else { return }
        pendingRequests.removeAll { $0.id == id }
        cont.resume(returning: response)
    }

    /// 取消某次请求（phase 内 await 会收到 `.cancelled`）。
    public func cancel(id: UUID) {
        resolve(id: id, response: .cancelled)
    }

    /// 当前未应答的请求快照（用于诊断 / UI 重建）
    public var pending: [PromptRequest] {
        pendingRequests
    }

    // MARK: - 高阶 API（phase 侧）

    /// 请求确认（是 / 否）。被取消或类型不匹配时返回 `false`。
    public func requestConfirm(_ message: String) async -> Bool {
        let response = await request(kind: .confirm(message: message))
        if case let .confirm(b) = response { return b }
        return false
    }

    /// 请求文本输入。被取消或类型不匹配时返回空字符串。
    public func requestText(_ message: String, placeholder: String? = nil) async -> String {
        let response = await request(kind: .text(message: message, placeholder: placeholder))
        if case let .text(s) = response { return s }
        return ""
    }

    /// 请求多选。被取消或类型不匹配时返回 `-1`。
    public func requestChoice(_ message: String, options: [String]) async -> Int {
        let response = await request(kind: .choice(message: message, options: options))
        if case let .choice(i) = response { return i }
        return -1
    }

    /// 底层请求接口：返回原始 `PromptResponse`。
    public func request(kind: PromptKind) async -> PromptResponse {
        let req = PromptRequest(kind: kind)
        pendingRequests.append(req)
        for sub in subscribers.values {
            sub.yield(req)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<PromptResponse, Never>) in
                continuations[req.id] = cont
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancel(id: req.id)
            }
        }
    }
}
