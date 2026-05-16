import Foundation

/// 全局 abort 总线：把"信号 / 外部触发"扇出到一组已登记的 cancel 回调。
///
/// 典型用法（CLI 入口处）：
/// ```swift
/// TestExecutor.installSIGINTHandler()                   // 装一次 SIGINT 处理器
/// let executor = TestExecutor(plan: ...)
/// let token = await executor.bindToAbortRegistry()      // 把 executor.cancel 登记到总线
/// _ = await executor.execute(serialNumber: "SN-001")
/// await AbortRegistry.shared.unregister(token)          // 退出前注销
/// ```
///
/// 设计取舍：
/// - SwiftHTF 不主动接管 SIGINT —— 嵌入到 SwiftUI app / 宿主进程时不应抢用户的信号表
/// - `installSIGINTHandler()` 是显式 opt-in，多次调用幂等
/// - 注册的 handler 持有强引用；调用方需在 executor 生命周期末尾 `unregister`，
///   或在 handler 内 `[weak self]` 让 self 自然 dealloc
public actor AbortRegistry {
    public static let shared = AbortRegistry()

    private var handlers: [UUID: @Sendable () async -> Void] = [:]

    public init() {}

    /// 注册一个 cancel 回调，返回用于注销的 token。多次调用会累积多条登记。
    public func register(_ handler: @escaping @Sendable () async -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    /// 注销之前的登记；token 未知则空操作。
    public func unregister(_ token: UUID) {
        handlers.removeValue(forKey: token)
    }

    /// 触发所有已登记的 cancel 回调。已登记的 handler 同时并发触发，
    /// 调用方不需要等单个 handler 完成；常见用途是把 SIGINT 转为
    /// 一次广播停所有 executor。
    public func abortAll() async {
        let snapshot = handlers.values
        for h in snapshot {
            Task { await h() }
        }
    }

    /// 总登记条目数；测试可见。
    public var registeredCount: Int {
        handlers.count
    }

    /// 清空所有登记（测试用）。
    public func reset() {
        handlers.removeAll()
    }
}

// MARK: - SIGINT 安装器

public extension TestExecutor {
    /// 把本 executor 的 `cancel()` 登记到 `AbortRegistry.shared`，返回 token 用于注销。
    ///
    /// 通常配合 `installSIGINTHandler()` 一起用 —— Ctrl-C 触发后总线一次性 cancel
    /// 所有登记的 executor。注意：注册产生对 self 的强引用持有期；executor 跑完后
    /// 调 `await AbortRegistry.shared.unregister(token)` 释放。
    func bindToAbortRegistry(_ registry: AbortRegistry = .shared) async -> UUID {
        await registry.register { [weak self] in
            await self?.cancel()
        }
    }

    /// 显式安装一次 SIGINT 处理器：Ctrl-C / `kill -INT` 触发 `AbortRegistry.shared.abortAll()`。
    ///
    /// 多次调用幂等。仅在 darwin 平台有效（依赖 `DispatchSource.makeSignalSource`）。
    /// 由调用方在 CLI 入口处 opt-in；SwiftHTF 不会自动接管信号表。
    ///
    /// - Note: 必须先 `signal(SIGINT, SIG_IGN)` 屏蔽默认 handler，dispatch source
    ///   才能收到信号；本方法已处理该细节。
    static func installSIGINTHandler() {
        AbortSignalInstaller.installOnce()
    }
}

/// SIGINT dispatch source 单例：内部状态由 main thread 拥有（一次性安装），
/// 静态属性 `installed` 通过 NSLock 保护以满足并发安全。
private enum AbortSignalInstaller {
    private nonisolated(unsafe) static var source: DispatchSourceSignal?
    private static let lock = NSLock()

    static func installOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        src.setEventHandler {
            Task {
                await AbortRegistry.shared.abortAll()
            }
        }
        src.resume()
        source = src
    }
}
