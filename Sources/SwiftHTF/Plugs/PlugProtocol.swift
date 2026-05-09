import Foundation

/// Plug 协议（硬件插件）
///
/// 协议本身不限定 actor isolation——具体实现可以选择 `@MainActor`（如本项目的 UART）、
/// 自定义 actor、或非 isolated 类型。`setup()` / `tearDown()` 是 async，PlugManager
/// 调用时会自动跨 isolation 边界。
public protocol PlugProtocol: AnyObject, Sendable {
    /// 默认初始化（无参）。需要构造器参数时改用 `PlugManager.register(_:factory:)`。
    init()

    /// 此 plug 依赖的其他 plug 类型。声明后 PlugManager 会按拓扑顺序构造 / setup，
    /// 并在 `setup(resolver:)` 时通过 resolver 注入已就绪的依赖。
    static var dependencies: [any PlugProtocol.Type] { get }

    /// 测试开始前调用：建立硬件连接、设置初始状态等。
    /// 简单 plug 可只实现这个；需要访问其他 plug 时改实现 `setup(resolver:)`。
    func setup() async throws

    /// 带依赖解析的 setup —— 由 PlugManager 在拓扑顺序就绪后调用。
    /// 默认实现转发到 `setup()`。
    func setup(resolver: PlugResolver) async throws

    /// 测试结束时调用：保证执行，断开连接、释放资源等
    func tearDown() async
}

/// Plug 默认实现
public extension PlugProtocol {
    static var dependencies: [any PlugProtocol.Type] {
        []
    }

    func setup() async throws {}
    func setup(resolver _: PlugResolver) async throws {
        try await setup()
    }

    func tearDown() async {}
}

/// 在 plug.setup(resolver:) 中查询其他 plug 实例。
public actor PlugResolver {
    private let instances: [String: any PlugProtocol]

    init(instances: [String: any PlugProtocol]) {
        self.instances = instances
    }

    /// 查询某类型的 plug 实例。返回 nil 表示该 plug 未注册（声明依赖时 PlugManager 已校验，
    /// 故在 setup(resolver:) 内部通常不会拿到 nil）。
    public func get<T: PlugProtocol>(_ type: T.Type) -> T? {
        let key = String(describing: type)
        return instances[key] as? T
    }
}

/// PlugManager 的诊断错误
public enum PlugManagerError: LocalizedError {
    /// 检测到循环依赖（链路按发现顺序列出）
    case cyclicDependency([String])
    /// plug 声明依赖某类型但该类型没注册
    case unregisteredDependency(plug: String, dependency: String)

    public var errorDescription: String? {
        switch self {
        case let .cyclicDependency(cycle):
            "Cyclic plug dependency: \(cycle.joined(separator: " → "))"
        case let .unregisteredDependency(p, d):
            "Plug \(p) declares dependency on \(d) but it is not registered"
        }
    }
}
