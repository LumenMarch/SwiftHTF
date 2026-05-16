import Foundation

/// 测试执行事件
public enum TestEvent: Sendable {
    case testStarted(planName: String, serialNumber: String?)
    /// startup phase 跑完后广播一次（仅当 plan 声明了 `startup` 且未被 runIf 跳过）。
    /// 携带 startup 跑完后的 `ctx.serialNumber`，UI 可据此刷新标题；序列号未变也会发，
    /// 让订阅者知道"启动门控阶段已结束"。
    case serialNumberResolved(String?)
    case phaseCompleted(PhaseRecord)
    case log(String)
    case testCompleted(TestRecord)
}

/// 测试执行器：plan / config / plug 注册（含 bind / swap 替身）的容器，能派生多个并发 `TestSession`。
///
/// 单 DUT 用法（最常见）：直接 `executor.execute(serialNumber:)` 跑一轮。
/// 多 DUT 并发：`executor.startSession(serialNumber:)` 拿到独立 session，可同时跑多个。
///
/// 每个 session 持有自己的 plug 实例（factory 重新构造、独立 setup/tearDown），互不干扰；
/// 在 executor 上挂的 `bind` / `swap` 别名会随 register 一起灌入每个 session 的 PlugManager，
/// 适合「生产真实 / 测试 mock」类场景而不需改 phase 代码。
/// `events()` 是聚合流：所有 session 的事件汇到这里，方便单 session 简单消费；要区分
/// 多 session 时改订阅 `session.events()`。
public actor TestExecutor {
    private let plan: TestPlan
    private let outputCallbacks: [OutputCallback]
    private let config: TestConfig
    /// 站级 / 代码级长期固定元数据。每个 session 默认继承，可在 `startSession` 调用时覆盖。
    private let defaultMetadata: SessionMetadata

    /// 把每次 `register` / `bind` / `swap` 调用打包成"灌入新 PlugManager"的闭包，保留泛型类型信息。
    /// 派生 session 时按顺序回放，确保每个 session 拿到一份独立但配置一致的 PlugManager。
    private var registrationFns: [@Sendable (PlugManager) async -> Void] = []
    private var activeSessions: [UUID: TestSession] = [:]
    private var continuations: [UUID: AsyncStream<TestEvent>.Continuation] = [:]

    /// 初始化 executor。
    ///
    /// - Parameters:
    ///   - plan: 要执行的测试计划
    ///   - config: 静态配置（YAML / JSON / dict 来源都已规范化为 `TestConfig`）
    ///   - configSchema: 可选 schema，存在时启用 `conf.declare` 风格的校验 + 默认值注入
    ///   - outputCallbacks: 测试完成后跑的输出 sink（console / JSON / CSV / 自定义）
    ///   - defaultMetadata: 站级 / 代码级长期固定元数据，每 session 默认继承
    ///   - undeclaredKeyHandler: schema 启用且 strictness=.warn 时收到未声明 key 的回调；
    ///     nil 时默认写一行到 stderr
    public init(
        plan: TestPlan,
        config: TestConfig = TestConfig(),
        configSchema: ConfigSchema? = nil,
        outputCallbacks: [OutputCallback] = [],
        defaultMetadata: SessionMetadata = SessionMetadata(),
        undeclaredKeyHandler: (@Sendable (String) -> Void)? = nil
    ) {
        self.plan = plan
        self.outputCallbacks = outputCallbacks
        self.defaultMetadata = defaultMetadata
        if let schema = configSchema {
            // defaults 作为最低优先级 base；用户传入 config 覆盖；最后挂上 schema + handler
            let handler = undeclaredKeyHandler ?? Self.defaultUndeclaredKeyHandler
            let merged = schema.defaultsConfig().merging(config)
            self.config = merged.attaching(schema: schema, undeclaredKeyHandler: handler)
        } else {
            self.config = config
        }
    }

    /// 默认未声明 key 处理：写一行到 stderr。
    private static let defaultUndeclaredKeyHandler: @Sendable (String) -> Void = { key in
        let line = "[SwiftHTF] warning: undeclared config key '\(key)' read\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    // MARK: - Plug 注册

    /// 注册 Plug 类型（无参 init）
    public func register(_ type: (some PlugProtocol).Type) async {
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
    public func bind(
        _ abstract: (some PlugProtocol).Type,
        to concrete: (some PlugProtocol).Type
    ) async {
        registrationFns.append { mgr in
            await mgr.bind(abstract, to: concrete)
        }
    }

    /// 用 `B` 替换 `A` 的注册（mock 注入）。会移除 A 的 factory，注册 B，
    /// 并把 `A` 别名到 `B`，使 `ctx.getPlug(A.self)` 得到 B 实例。
    public func swap(
        _ a: (some PlugProtocol).Type,
        with b: (some PlugProtocol).Type
    ) async {
        registrationFns.append { mgr in
            await mgr.swap(a, with: b)
        }
    }

    /// 工厂闭包版 swap
    public func swap<B: PlugProtocol>(
        _ a: (some PlugProtocol).Type,
        with b: B.Type,
        factory: @escaping @MainActor @Sendable () -> B
    ) async {
        registrationFns.append { mgr in
            await mgr.swap(a, with: b, factory: factory)
        }
    }

    // MARK: - Session 派生

    /// 派生一个新的测试会话；返回后调用方可订阅 ``TestSession/events()`` / 调
    /// ``TestSession/cancel()`` / 等 ``TestSession/record()``。
    ///
    /// 每个 session 持有独立 plug 实例（factory 重新构造、独立 setUp / tearDown），互不干扰；
    /// 注册的 plug 别名（`bind` / `swap`）会随每个 session 灌入对应 PlugManager。
    ///
    /// - Parameters:
    ///   - serialNumber: DUT 序列号；phase 内可通过 `ctx.serialNumber` 读取并改写（扫码回填）
    ///   - metadata: per-session 元数据，非 nil 字段覆盖 `defaultMetadata` 同名字段
    /// - Returns: 已 start 的 `TestSession`；events 流已 attach，调用方紧接着 `events()`
    ///   不会丢 `testStarted`
    public func startSession(
        serialNumber: String? = nil,
        metadata: SessionMetadata? = nil
    ) async -> TestSession {
        let mgr = PlugManager()
        for fn in registrationFns {
            await fn(mgr)
        }
        let merged = defaultMetadata.merging(metadata)
        let session = TestSession(
            plan: plan,
            config: config,
            plugManager: mgr,
            outputCallbacks: outputCallbacks,
            serialNumber: serialNumber,
            metadata: merged
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
    ///
    /// 多 DUT 并发改用 ``startSession(serialNumber:metadata:)``。
    ///
    /// - Parameters:
    ///   - serialNumber: DUT 序列号
    ///   - metadata: per-session 元数据
    /// - Returns: 完成态的 `TestRecord`（含 outcome / phases / measurements / log）
    public func execute(
        serialNumber: String? = nil,
        metadata: SessionMetadata? = nil
    ) async -> TestRecord {
        let session = await startSession(serialNumber: serialNumber, metadata: metadata)
        return await session.record()
    }

    /// 取消所有正在跑的 session（多 session 模式可单独调 ``TestSession/cancel()``）。
    ///
    /// 与 ``AbortRegistry`` 配合：`executor.bindToAbortRegistry(...)` + Ctrl-C
    /// 信号 handler 可让 SIGINT 触发全 executor 优雅停止。
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
        for c in continuations.values {
            c.yield(event)
        }
    }
}

/// 测试计划
public struct TestPlan: Sendable {
    public let name: String
    /// 启动门控 phase：跑在 plug `setUp()` 之后、`setupNodes` 之前，可用 plug（典型用例：
    /// 用 `PromptPlug` 扫码拿 DUT SN 再回填 `ctx.serialNumber`）。语义详见 README "Startup phase"。
    ///
    /// - 返回 `.continue` → 放行，进入 `setupNodes` / `nodes`
    /// - 返回 `.stop` → `TestRecord.outcome = .aborted`，跳过 `setupNodes` / `nodes`，但仍跑
    ///   `teardownNodes` 与 plug tearDown
    /// - 返回 `.failAndContinue` / `.fail*` → `outcome = .fail`，跳过主体、跑 teardown
    /// - 抛非白名单异常 → `outcome = .error`；timeout → `outcome = .timeout`
    /// - `runIf` 返回 false → 当作未声明 startup，主体照常跑（不写 SkipRecord，不发
    ///   `serialNumberResolved` 事件）
    ///
    /// startup 的 `PhaseRecord` 仍写入 `record.phases`，`groupPath = ["__startup__"]` 便于消费者区分。
    public let startup: Phase?
    public let nodes: [PhaseNode]
    public let setupNodes: [PhaseNode]
    public let teardownNodes: [PhaseNode]
    public let continueOnFail: Bool
    /// 测试级诊断器：测试收尾时（outcome 已定、tearDown 之前）依次跑。
    /// 返回的 Diagnosis 追加到 `TestRecord.diagnoses`。
    public let diagnosers: [any TestDiagnoser]

    /// 主初始化：直接用 PhaseNode 构造（含嵌套 Group / Subtest）。
    ///
    /// 常规用法通过 result builder `init(name:setup:teardown:...phases:)`
    /// 构造，本 init 留给程序化拼装节点的场景。
    ///
    /// - Parameters:
    ///   - name: 测试计划名（出现在 `TestRecord.planName` / 文件名模板 `{plan}` 等）
    ///   - startup: 启动门控 phase（可选）；语义见 `startup` 属性文档
    ///   - nodes: 主体节点序列（顶层）
    ///   - setupNodes: 顶层 setup 节点；任一失败 → 跳过主体 + teardown
    ///   - teardownNodes: 顶层 teardown 节点；总是跑（无视主体是否失败）
    ///   - continueOnFail: 主体任一节点失败时是否继续跑后续兄弟
    ///   - diagnosers: 测试级诊断器；test 终态确定后按 trigger 过滤触发
    public init(
        name: String,
        startup: Phase? = nil,
        nodes: [PhaseNode],
        setupNodes: [PhaseNode] = [],
        teardownNodes: [PhaseNode] = [],
        continueOnFail: Bool = false,
        diagnosers: [any TestDiagnoser] = []
    ) {
        self.name = name
        self.startup = startup
        self.nodes = nodes
        self.setupNodes = setupNodes
        self.teardownNodes = teardownNodes
        self.continueOnFail = continueOnFail
        self.diagnosers = diagnosers
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
        case let .timeout(s): s
        case let .noRespond(s): s
        case let .unknown(s): s
        case let .validationFailed(s): s
        case .maxRetriesExceeded: "Max retries exceeded"
        }
    }
}
