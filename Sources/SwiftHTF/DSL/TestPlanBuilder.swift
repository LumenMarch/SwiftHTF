import Foundation

/// 测试计划 result builder
///
/// 用法：
/// ```swift
/// let plan = TestPlan(name: "X3531") {
///     Phase(name: "Connect_DUT") { ctx in ... }
///     Group("PowerRail") {
///         Phase(name: "PowerOn") { ctx in ... }
///         Phase(name: "VccCheck") { ctx in ... }
///     } teardown: {
///         Phase(name: "PowerOff") { ctx in ... }
///     }
///     if config.includeBootTest {
///         Phase(name: "Boot_Test") { ctx in ... }
///     }
///     for item in items {
///         Phase(name: item.name) { ctx in ... }
///     }
/// }
/// ```
@resultBuilder
public enum TestPlanBuilder {
    public static func buildBlock(_ components: [PhaseNode]...) -> [PhaseNode] {
        components.flatMap { $0 }
    }

    /// 单 Phase / Group / PhaseNode 表达式
    public static func buildExpression(_ phase: Phase) -> [PhaseNode] {
        [.phase(phase)]
    }

    public static func buildExpression(_ group: Group) -> [PhaseNode] {
        [.group(group)]
    }

    public static func buildExpression(_ subtest: Subtest) -> [PhaseNode] {
        [.subtest(subtest)]
    }

    public static func buildExpression(_ checkpoint: Checkpoint) -> [PhaseNode] {
        [.checkpoint(checkpoint)]
    }

    public static func buildExpression(_ node: PhaseNode) -> [PhaseNode] {
        [node]
    }

    /// 数组表达式
    public static func buildExpression(_ phases: [Phase]) -> [PhaseNode] {
        phases.map { .phase($0) }
    }

    public static func buildExpression(_ nodes: [PhaseNode]) -> [PhaseNode] {
        nodes
    }

    public static func buildOptional(_ nodes: [PhaseNode]?) -> [PhaseNode] {
        nodes ?? []
    }

    public static func buildEither(first nodes: [PhaseNode]) -> [PhaseNode] {
        nodes
    }

    public static func buildEither(second nodes: [PhaseNode]) -> [PhaseNode] {
        nodes
    }

    public static func buildArray(_ components: [[PhaseNode]]) -> [PhaseNode] {
        components.flatMap { $0 }
    }

    public static func buildLimitedAvailability(_ nodes: [PhaseNode]) -> [PhaseNode] {
        nodes
    }
}

public extension TestPlan {
    /// 使用 result builder 构建测试计划（嵌套 Group 友好）
    ///
    /// `startup` 是可选的启动门控 phase，跑在 plug `setUp()` 之后、`setup` / 主体 phases 之前。
    /// 典型用法：用 `PromptPlug` 扫码拿 DUT SN，回填 `ctx.serialNumber` 后再放行业务流程。
    /// 详细语义见 ``TestPlan/startup``。
    init(
        name: String,
        startup: Phase? = nil,
        setup: [Phase]? = nil,
        teardown: [Phase]? = nil,
        continueOnFail: Bool = false,
        diagnosers: [any TestDiagnoser] = [],
        @TestPlanBuilder phases: () -> [PhaseNode]
    ) {
        self.init(
            name: name,
            startup: startup,
            nodes: phases(),
            setupNodes: (setup ?? []).map { .phase($0) },
            teardownNodes: (teardown ?? []).map { .phase($0) },
            continueOnFail: continueOnFail,
            diagnosers: diagnosers
        )
    }
}
