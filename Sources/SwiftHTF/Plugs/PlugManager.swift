import Foundation

/// Plug 管理器
///
/// 注册 Plug 类型与可选的工厂闭包；测试运行前 `setupAll()` 解析所有实例并依次 setup，
/// 运行后 `tearDownAll()` 反向清理。
///
/// 实例构造在 `@MainActor` 上完成；setupAll 按 plug 静态声明的 `dependencies`
/// 拓扑排序，依赖先就绪再 setup 后置者。
public actor PlugManager {
    private var instances: [String: any PlugProtocol] = [:]
    private var factories: [String: @MainActor @Sendable () -> any PlugProtocol] = [:]
    private var depsByKey: [String: [String]] = [:]
    /// 抽象类型 → 具体注册类型 的映射。bind / swap 使用。
    /// 解析时优先级：依赖与 ctx.getPlug 都先查 aliases，再查 factories / instances。
    private var aliases: [String: String] = [:]

    public init() {}

    /// 注册 Plug 类型，使用类型自带的 `init()` 创建实例
    public func register<T: PlugProtocol>(_ type: T.Type) {
        let key = String(describing: type)
        factories[key] = { @MainActor in type.init() }
        depsByKey[key] = T.dependencies.map { String(describing: $0) }
    }

    /// 注册 Plug 类型，使用工厂闭包创建实例（适合需要构造器参数的场景）
    public func register<T: PlugProtocol>(
        _ type: T.Type,
        factory: @escaping @MainActor @Sendable () -> T
    ) {
        let key = String(describing: type)
        factories[key] = { @MainActor in factory() }
        depsByKey[key] = T.dependencies.map { String(describing: $0) }
    }

    /// 解除注册（swap 时使用）
    public func unregister<T: PlugProtocol>(_ type: T.Type) {
        let key = String(describing: type)
        factories.removeValue(forKey: key)
        depsByKey.removeValue(forKey: key)
        instances.removeValue(forKey: key)
    }

    /// 把抽象类型别名到具体类型。`Abstract` 在 phase 代码中可作为 `ctx.getPlug` 的查询键，
    /// 实际解析到 `Concrete` 的实例。`Concrete` 必须已经 register。
    ///
    /// 用于：
    /// - protocol 抽象 + 多实现切换（生产 vs 仿真）
    /// - 方便测试时把真实 plug 替换成 mock（结合 `swap`）
    public func bind<A: PlugProtocol, C: PlugProtocol>(
        _ abstract: A.Type,
        to concrete: C.Type
    ) {
        aliases[String(describing: abstract)] = String(describing: concrete)
    }

    /// 用 `B` 替换 `A` 的注册（典型 mock 注入）：
    /// 1. 移除 A 的 factory
    /// 2. 注册 B
    /// 3. 把 `A` 别名到 `B`，`ctx.getPlug(A.self)` 仍能拿到（实际是 B 实例）
    public func swap<A: PlugProtocol, B: PlugProtocol>(
        _ a: A.Type,
        with b: B.Type
    ) {
        unregister(a)
        register(b)
        bind(a, to: b)
    }

    /// 工厂闭包版本的 swap
    public func swap<A: PlugProtocol, B: PlugProtocol>(
        _ a: A.Type,
        with b: B.Type,
        factory: @escaping @MainActor @Sendable () -> B
    ) {
        unregister(a)
        register(b, factory: factory)
        bind(a, to: b)
    }

    /// 拓扑排序后构造所有实例并按依赖顺序 setup。
    /// - Throws: `PlugManagerError.cyclicDependency` 或 `unregisteredDependency`
    /// - Returns: 类型名 → 实例 的字典（含 alias 副本），供 TestContext 持有
    func setupAll() async throws -> [String: any PlugProtocol] {
        let ordered = try topologicalOrder()
        // 按拓扑顺序构造（依赖在前）
        for key in ordered where instances[key] == nil {
            guard let factory = factories[key] else { continue }
            instances[key] = await factory()
        }
        // 把 alias 复制成同一实例（resolver 与外部 ctx 都能用别名查）
        var withAliases = instances
        for (alias, target) in aliases {
            if let plug = instances[target] {
                withAliases[alias] = plug
            }
        }
        let resolver = PlugResolver(instances: withAliases)
        for key in ordered {
            guard let plug = instances[key] else { continue }
            try await plug.setup(resolver: resolver)
        }
        return withAliases
    }

    /// 清理所有 Plug
    func tearDownAll() async {
        for (_, plug) in instances {
            await plug.tearDown()
        }
        instances.removeAll()
    }

    // MARK: - 拓扑排序

    private func topologicalOrder() throws -> [String] {
        var visited: Set<String> = []
        var inProgress: Set<String> = []
        var order: [String] = []

        func resolve(_ key: String) -> String {
            // 抽象类型先解 alias 拿到具体注册键
            aliases[key] ?? key
        }

        func visit(_ key: String, path: [String]) throws {
            if visited.contains(key) { return }
            if inProgress.contains(key) {
                let cycleStart = path.firstIndex(of: key) ?? 0
                let cycle = Array(path[cycleStart...]) + [key]
                throw PlugManagerError.cyclicDependency(cycle)
            }
            inProgress.insert(key)
            for rawDep in depsByKey[key] ?? [] {
                let dep = resolve(rawDep)
                if factories[dep] == nil {
                    throw PlugManagerError.unregisteredDependency(plug: key, dependency: rawDep)
                }
                try visit(dep, path: path + [key])
            }
            inProgress.remove(key)
            visited.insert(key)
            order.append(key)
        }

        for key in factories.keys.sorted() {
            try visit(key, path: [])
        }
        return order
    }
}
