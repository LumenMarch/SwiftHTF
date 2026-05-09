import Foundation

/// 测试计划节点：单个 Phase 或一个嵌套的 Group。
///
/// 通过 `@TestPlanBuilder` 自动从 `Phase` / `Group` 表达式包装，使用方很少直接构造。
public enum PhaseNode: Sendable {
    case phase(Phase)
    indirect case group(Group)

    /// 节点名（phase 名 / group 名）
    public var name: String {
        switch self {
        case .phase(let p): return p.definition.name
        case .group(let g): return g.name
        }
    }

    public var asPhase: Phase? {
        if case .phase(let p) = self { return p }
        return nil
    }

    public var asGroup: Group? {
        if case .group(let g) = self { return g }
        return nil
    }
}

/// 嵌套 Group：含独立的 setup / children / teardown 与局部 `continueOnFail`。
///
/// ```swift
/// Group("PowerRail") {
///     Phase(name: "PowerOn") { _ in .continue }
///     Phase(name: "VccCheck") { _ in .continue }
/// } setup: {
///     Phase(name: "Connect") { _ in .continue }
/// } teardown: {
///     Phase(name: "Disconnect") { _ in .continue }
/// }
/// ```
///
/// 执行语义（`TestExecutor` 实现）：
/// - 依次跑 setup → children → teardown
/// - setup 任一节点 `.fail/.error` 视为 group 失败，**跳过 children**，仍跑 teardown
/// - children 内 fail 时，看 `continueOnFail`（局部），后续兄弟是否继续
/// - teardown 必跑
public struct Group: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let setup: [PhaseNode]
    public let children: [PhaseNode]
    public let teardown: [PhaseNode]
    public let continueOnFail: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        setup: [PhaseNode] = [],
        children: [PhaseNode],
        teardown: [PhaseNode] = [],
        continueOnFail: Bool = false
    ) {
        self.id = id
        self.name = name
        self.setup = setup
        self.children = children
        self.teardown = teardown
        self.continueOnFail = continueOnFail
    }
}

// MARK: - DSL 友好 init

public extension Group {
    /// 仅 children 的 builder 形式
    init(
        _ name: String,
        continueOnFail: Bool = false,
        @TestPlanBuilder children: () -> [PhaseNode]
    ) {
        self.init(
            name: name,
            setup: [],
            children: children(),
            teardown: [],
            continueOnFail: continueOnFail
        )
    }

    /// 同时声明 setup / teardown 的 builder 形式
    init(
        _ name: String,
        continueOnFail: Bool = false,
        @TestPlanBuilder children: () -> [PhaseNode],
        @TestPlanBuilder setup: () -> [PhaseNode] = { [] },
        @TestPlanBuilder teardown: () -> [PhaseNode] = { [] }
    ) {
        self.init(
            name: name,
            setup: setup(),
            children: children(),
            teardown: teardown(),
            continueOnFail: continueOnFail
        )
    }
}
