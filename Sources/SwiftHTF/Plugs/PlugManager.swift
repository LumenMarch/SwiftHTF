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

    /// 拓扑排序后构造所有实例并按依赖顺序 setup。
    /// - Throws: `PlugManagerError.cyclicDependency` 或 `unregisteredDependency`
    /// - Returns: 类型名 → 实例 的字典，供 TestContext 持有
    func setupAll() async throws -> [String: any PlugProtocol] {
        let ordered = try topologicalOrder()
        // 按拓扑顺序构造（依赖在前）
        for key in ordered where instances[key] == nil {
            guard let factory = factories[key] else { continue }
            instances[key] = await factory()
        }
        let resolver = PlugResolver(instances: instances)
        for key in ordered {
            guard let plug = instances[key] else { continue }
            try await plug.setup(resolver: resolver)
        }
        return instances
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

        func visit(_ key: String, path: [String]) throws {
            if visited.contains(key) { return }
            if inProgress.contains(key) {
                let cycleStart = path.firstIndex(of: key) ?? 0
                let cycle = Array(path[cycleStart...]) + [key]
                throw PlugManagerError.cyclicDependency(cycle)
            }
            inProgress.insert(key)
            for dep in depsByKey[key] ?? [] {
                if factories[dep] == nil {
                    throw PlugManagerError.unregisteredDependency(plug: key, dependency: dep)
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
