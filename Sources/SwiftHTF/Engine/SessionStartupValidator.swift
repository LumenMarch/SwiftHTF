import Foundation

/// `TestSession` 启动期校验器（纯函数 namespace，无 actor state）。
///
/// 当前只承载 `ConfigSchema` 校验：
/// - required keys 缺失 → 致命，调用方应立即标 record.outcome=.error 并退出
/// - strict 模式下未声明 keys 存在 → 致命
/// - warn 模式下未声明 keys 存在 → 仅 warning（不致命）
/// - lax / 无 schema → 静默
///
/// 与 `TestSession` 分离是为了：让 actor body 保持职责单一（只做"跑 plan + 写 record"），
/// 同时校验逻辑可独立测试。
enum SessionStartupValidator {
    /// 校验结果。`failureReason` 非 nil 表示需要 abort startup。
    struct Outcome {
        var warningLogs: [String] = []
        var failureReason: String?
    }

    static func validate(config: TestConfig) -> Outcome {
        var out = Outcome()
        guard let schema = config.schema else { return out }

        let missing = schema.requiredKeysMissing(in: config)
        if !missing.isEmpty {
            out.failureReason = "Config schema: required keys missing: \(missing.joined(separator: ", "))"
            return out
        }

        let undeclared = schema.undeclaredKeys(in: config)
        guard !undeclared.isEmpty else { return out }

        switch schema.strictness {
        case .strict:
            out.failureReason = "Config schema (strict): undeclared keys present: \(undeclared.joined(separator: ", "))"
        case .warn:
            out.warningLogs.append("Config schema: undeclared keys ignored (warn): \(undeclared.joined(separator: ", "))")
        case .lax:
            break
        }
        return out
    }
}
