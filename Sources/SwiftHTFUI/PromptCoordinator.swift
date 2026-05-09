import Foundation
import Combine
import SwiftHTF

/// 把 `PromptPlug.events()` 转成 SwiftUI 友好的 `@Published` 状态。
///
/// 用法：
/// ```swift
/// @StateObject private var prompts = PromptCoordinator()
///
/// var body: some View {
///     ContentView()
///         .task { await prompts.attach(to: promptPlug) }
///         .sheet(item: $prompts.current) { req in
///             PromptSheetView(request: req) { resp in
///                 prompts.resolve(req.id, response: resp)
///             }
///         }
/// }
/// ```
@MainActor
public final class PromptCoordinator: ObservableObject {
    @Published public var current: PromptRequest?

    private weak var plug: PromptPlug?
    private var listener: Task<Void, Never>?
    private var detached: Bool = true

    public init() {}

    /// 绑定到一个 PromptPlug 实例并开始消费请求。
    /// 同一时刻只展示一个请求；下一条等当前 resolve 后才显示。
    public func attach(to plug: PromptPlug) async {
        detach()
        self.plug = plug
        self.detached = false
        let stream = plug.events()
        listener = Task { @MainActor [weak self] in
            for await req in stream {
                guard let self else { return }
                // detach 后即便仍有缓冲事件，也不再写 current
                if self.detached { continue }
                // 简单策略：若当前已有 prompt，覆盖之
                self.current = req
            }
        }
    }

    /// 停止订阅。
    public func detach() {
        detached = true
        listener?.cancel()
        listener = nil
        current = nil
        plug = nil
    }

    /// 应答当前 prompt。
    public func resolve(_ id: UUID, response: PromptResponse) {
        plug?.resolve(id: id, response: response)
        if current?.id == id {
            current = nil
        }
    }

    /// 取消当前 prompt（phase 内会收到 .cancelled）。
    public func cancel(_ id: UUID) {
        plug?.cancel(id: id)
        if current?.id == id {
            current = nil
        }
    }

    deinit {
        listener?.cancel()
    }
}
