import Foundation

/// 测试执行事件
public enum TestEvent: Sendable {
    case testStarted(planName: String, serialNumber: String?)
    case phaseCompleted(PhaseRecord)
    case log(String)
    case testCompleted(TestRecord)
}

/// 测试执行器：plan / config / plug 注册的容器，能派生多个并发 `TestSession`。
///
/// 单 DUT 用法（最常见）：直接 `executor.execute(serialNumber:)` 跑一轮。
/// 多 DUT 并发：`executor.startSession(serialNumber:)` 拿到独立 session，可同时跑多个。
///
/// 每个 session 持有自己的 plug 实例（factory 重新构造、独立 setup/tearDown），互不干扰。
/// `events()` 是聚合流：所有 session 的事件汇到这里，方便单 session 简单消费；要区分
/// 多 session 时改订阅 `session.events()`。
public actor TestExecutor {
    private let plan: TestPlan
    private let outputCallbacks: [OutputCallback]
    private let config: TestConfig

    /// 把"register T 类型"打包成可灌入新 PlugManager 的闭包，保留泛型类型信息。
    private var registrationFns: [@Sendable (PlugManager) async -> Void] = []
    private var activeSessions: [UUID: TestSession] = [:]
    private var continuations: [UUID: AsyncStream<TestEvent>.Continuation] = [:]

    public init(
        plan: TestPlan,
        config: TestConfig = TestConfig(),
        outputCallbacks: [OutputCallback] = []
    ) {
        self.plan = plan
        self.config = config
        self.outputCallbacks = outputCallbacks
    }

    // MARK: - Plug 注册

    /// 注册 Plug 类型（无参 init）
    public func register<T: PlugProtocol>(_ type: T.Type) async {
        registrationFns.append { mgr in
            await mgr.register(type)
        }
    }

    /// 注册 Plug 类型（工厂闭包，用于需要构造器参数的场景）
    public func register<T: PlugProtocol>(
        _ type: T.Type,
        factory: @escaping @MainActor @Sendable () -> T
    ) async {
        registrationFns.append { mgr in
            await mgr.register(type, factory: factory)
        }
    }

    /// 把抽象类型别名到已注册的具体类型。phase 代码用 `ctx.getPlug(Abstract.self)`
    /// 时实际拿到 `Concrete` 实例。
    /// `Concrete` 必须已经通过 `register` 登记。
    public func bind<A: PlugProtocol, C: PlugProtocol>(
        _ abstract: A.Type,
        to concrete: C.Type
    ) async {
        registrationFns.append { mgr in
            await mgr.bind(abstract, to: concrete)
        }
    }

    /// 用 `B` 替换 `A` 的注册（mock 注入）。会移除 A 的 factory，注册 B，
    /// 并把 `A` 别名到 `B`，使 `ctx.getPlug(A.self)` 得到 B 实例。
    public func swap<A: PlugProtocol, B: PlugProtocol>(
        _ a: A.Type,
        with b: B.Type
    ) async {
        registrationFns.append { mgr in
            await mgr.swap(a, with: b)
        }
    }

    /// 工厂闭包版 swap
    public func swap<A: PlugProtocol, B: PlugProtocol>(
        _ a: A.Type,
        with b: B.Type,
        factory: @escaping @MainActor @Sendable () -> B
    ) async {
        registrationFns.append { mgr in
            await mgr.swap(a, with: b, factory: factory)
        }
    }

    // MARK: - Session 派生

    /// 创建一个新的测试会话；调用方拿到 session 后可订阅 events / 调 cancel / 等 record。
    /// 每个 session 持有独立 plug 实例。
    public func startSession(serialNumber: String? = nil) async -> TestSession {
        let mgr = PlugManager()
        for fn in registrationFns {
            await fn(mgr)
        }
        let session = TestSession(
            plan: plan,
            config: config,
            plugManager: mgr,
            outputCallbacks: outputCallbacks,
            serialNumber: serialNumber
        )
        activeSessions[session.id] = session

        // 桥接 session 事件到 executor 的聚合流（先订阅再 start，不丢事件）
        let stream = await session.events()
        Task { [weak self] in
            for await event in stream {
                await self?.broadcast(event)
            }
            await self?.removeSession(session.id)
        }
        await session.start()
        return session
    }

    /// 单 DUT 便利入口：派生 session、等待 record，一次性返回。
    /// 多 DUT 并发请改用 `startSession(serialNumber:)`。
    public func execute(serialNumber: String? = nil) async -> TestRecord {
        let session = await startSession(serialNumber: serialNumber)
        return await session.record()
    }

    /// 取消所有正在跑的 session（多 session 模式可单独 `session.cancel()`）
    public func cancel() async {
        for s in activeSessions.values {
            await s.cancel()
        }
    }

    private func removeSession(_ id: UUID) {
        activeSessions.removeValue(forKey: id)
    }

    // MARK: - 聚合事件流

    /// 订阅"所有 session"的聚合事件流。多 session 模式下事件会混合 —— 需区分时改订阅
    /// `session.events()`。
    ///
    /// 由 actor 隔离 —— 返回前 attach 已完成，调用方紧接着的 `execute()`/`startSession()`
    /// 不会丢事件。
    public func events() -> AsyncStream<TestEvent> {
        let id = UUID()
        var continuation: AsyncStream<TestEvent>.Continuation!
        let stream = AsyncStream<TestEvent> { c in continuation = c }
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.detach(id)
            }
        }
        return stream
    }

    private func detach(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func broadcast(_ event: TestEvent) {
        for c in continuations.values { c.yield(event) }
    }
}

/// 测试计划
public struct TestPlan: Sendable {
    public let name: String
    public let nodes: [PhaseNode]
    public let setupNodes: [PhaseNode]
    public let teardownNodes: [PhaseNode]
    public let continueOnFail: Bool

    /// 主初始化：直接用 PhaseNode 构造（含嵌套 Group）
    public init(
        name: String,
        nodes: [PhaseNode],
        setupNodes: [PhaseNode] = [],
        teardownNodes: [PhaseNode] = [],
        continueOnFail: Bool = false
    ) {
        self.name = name
        self.nodes = nodes
        self.setupNodes = setupNodes
        self.teardownNodes = teardownNodes
        self.continueOnFail = continueOnFail
    }
}

/// 测试错误
public enum TestError: LocalizedError {
    case timeout(String)
    case noRespond(String)
    case unknown(String)
    case validationFailed(String)
    case maxRetriesExceeded

    public var errorDescription: String? {
        switch self {
        case .timeout(let s): return s
        case .noRespond(let s): return s
        case .unknown(let s): return s
        case .validationFailed(let s): return s
        case .maxRetriesExceeded: return "Max retries exceeded"
        }
    }
}
