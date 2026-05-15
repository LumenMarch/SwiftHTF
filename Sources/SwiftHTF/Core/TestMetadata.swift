import Foundation

/// 工站信息：测试台架硬件 / 物理位置 / 主机标识。
///
/// 一台站对应一个 `StationInfo`，在 `TestExecutor.init(defaultMetadata:)` 注入；
/// 每个 session 默认继承，可在 `startSession(serialNumber:metadata:)` 覆盖。
public struct StationInfo: Sendable, Codable, Equatable {
    /// 工站唯一标识（产线 + 工序编号等），HistoryStore 查询的过滤键。
    public var stationId: String
    /// 人类可读工站名（"焊接工位 A"）
    public var stationName: String?
    /// 物理位置（"上海工厂 3F"）
    public var location: String?
    /// 测试机主机名 / IP
    public var hostName: String?

    public init(
        stationId: String,
        stationName: String? = nil,
        location: String? = nil,
        hostName: String? = nil
    ) {
        self.stationId = stationId
        self.stationName = stationName
        self.location = location
        self.hostName = hostName
    }
}

/// 被测物（Device Under Test）信息。
///
/// 与 `TestRecord.serialNumber` 平行存在：`serialNumber` 是顶层主键，
/// 此处的 `serialNumber` 字段保留给那些"同物理 DUT 上有多个 SN（板载 SN + 工单 SN）"的场景。
/// 通常只填一个就够。
public struct DUTInfo: Sendable, Codable, Equatable {
    public var serialNumber: String?
    /// 物料号 / SKU
    public var partNumber: String?
    /// 设备类型（"radio_module" / "mainboard"）
    public var deviceType: String?
    /// 制造日期
    public var manufactureDate: Date?
    /// 自由扩展字段（lot / wafer / 板号等）
    public var attributes: [String: AnyCodableValue]

    public init(
        serialNumber: String? = nil,
        partNumber: String? = nil,
        deviceType: String? = nil,
        manufactureDate: Date? = nil,
        attributes: [String: AnyCodableValue] = [:]
    ) {
        self.serialNumber = serialNumber
        self.partNumber = partNumber
        self.deviceType = deviceType
        self.manufactureDate = manufactureDate
        self.attributes = attributes
    }
}

/// 代码版本信息：用于把 record 关联到具体的测试程序版本。
///
/// 一般由 CI 注入（环境变量 / Info.plist），phase 不应改它。
public struct CodeInfo: Sendable, Codable, Equatable {
    /// 语义版本 / build tag（"1.2.3"）
    public var version: String?
    /// git commit hash
    public var gitCommit: String?
    /// CI build id / pipeline run number
    public var buildId: String?
    /// 运行环境（"production" / "staging" / "dev"）
    public var environment: String?

    public init(
        version: String? = nil,
        gitCommit: String? = nil,
        buildId: String? = nil,
        environment: String? = nil
    ) {
        self.version = version
        self.gitCommit = gitCommit
        self.buildId = buildId
        self.environment = environment
    }
}

/// 一次 session 的元数据 bundle。
///
/// `TestExecutor` 持有 `defaultMetadata`（站级 / 代码级长期固定字段）；
/// `startSession(serialNumber:metadata:)` 接受 per-session override。
/// 合并语义：override 中非 nil 的整字段替换 default 对应字段（不做 deep merge，
/// 因为 DUTInfo 子字段需要原子语义 —— 一次 session 不会跨 DUT）。
public struct SessionMetadata: Sendable, Codable, Equatable {
    public var stationInfo: StationInfo?
    public var dutInfo: DUTInfo?
    public var codeInfo: CodeInfo?
    /// 操作员标识（用户名 / 工号）
    public var operatorName: String?

    public init(
        stationInfo: StationInfo? = nil,
        dutInfo: DUTInfo? = nil,
        codeInfo: CodeInfo? = nil,
        operatorName: String? = nil
    ) {
        self.stationInfo = stationInfo
        self.dutInfo = dutInfo
        self.codeInfo = codeInfo
        self.operatorName = operatorName
    }

    /// 整字段覆盖合并：`override` 非 nil 字段替换本实例对应字段。
    public func merging(_ override: SessionMetadata?) -> SessionMetadata {
        guard let override else { return self }
        return SessionMetadata(
            stationInfo: override.stationInfo ?? stationInfo,
            dutInfo: override.dutInfo ?? dutInfo,
            codeInfo: override.codeInfo ?? codeInfo,
            operatorName: override.operatorName ?? operatorName
        )
    }
}
