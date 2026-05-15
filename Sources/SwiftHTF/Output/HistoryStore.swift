import Foundation

/// 历史查询条件
public struct HistoryQuery: Sendable {
    public var serialNumber: String?
    public var planName: String?
    public var outcomes: [TestOutcome]?
    public var since: Date?
    public var until: Date?
    public var limit: Int?
    /// 按 station id 过滤（精确匹配 `TestRecord.stationInfo?.stationId`）
    public var stationId: String?
    /// 按操作员名过滤（精确匹配 `TestRecord.operatorName`）
    public var operatorName: String?
    /// 默认按 startTime 倒序（最新在前）
    public var sortDescending: Bool

    public init(
        serialNumber: String? = nil,
        planName: String? = nil,
        outcomes: [TestOutcome]? = nil,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int? = nil,
        stationId: String? = nil,
        operatorName: String? = nil,
        sortDescending: Bool = true
    ) {
        self.serialNumber = serialNumber
        self.planName = planName
        self.outcomes = outcomes
        self.since = since
        self.until = until
        self.limit = limit
        self.stationId = stationId
        self.operatorName = operatorName
        self.sortDescending = sortDescending
    }

    /// 全部历史，按时间倒序
    public static let all = HistoryQuery()

    /// 默认 list 参数：按 SN 过滤
    public static func bySerial(_ sn: String) -> HistoryQuery {
        HistoryQuery(serialNumber: sn)
    }

    /// 命中判定
    func matches(_ r: TestRecord) -> Bool {
        if let sn = serialNumber, r.serialNumber != sn { return false }
        if let plan = planName, r.planName != plan { return false }
        if let outcomes, !outcomes.contains(r.outcome) { return false }
        if let since, r.startTime < since { return false }
        if let until, r.startTime > until { return false }
        if let stationId, r.stationInfo?.stationId != stationId { return false }
        if let operatorName, r.operatorName != operatorName { return false }
        return true
    }
}

/// 历史记录存储协议
///
/// 抽象 record 的持久化层。实现可基于内存（测试）、文件（生产）、SQLite、远端服务等。
/// 框架默认提供 `InMemoryHistoryStore` 与 `JSONFileHistoryStore` 两个实现。
public protocol HistoryStore: Sendable {
    /// 保存一条 record（已存在同 id 则覆盖）
    func save(_ record: TestRecord) async throws

    /// 按 id 加载
    func load(id: UUID) async throws -> TestRecord?

    /// 按查询条件列出
    func list(_ query: HistoryQuery) async throws -> [TestRecord]

    /// 删除指定 record
    func delete(id: UUID) async throws

    /// 清空所有
    func clear() async throws
}

// MARK: - 内存实现

/// 内存 history store —— 重启即丢失。适合测试 / 临时开发。
public actor InMemoryHistoryStore: HistoryStore {
    private var records: [UUID: TestRecord] = [:]

    public init() {}

    public func save(_ record: TestRecord) async throws {
        records[record.id] = record
    }

    public func load(id: UUID) async throws -> TestRecord? {
        records[id]
    }

    public func list(_ query: HistoryQuery) async throws -> [TestRecord] {
        var matched = records.values.filter { query.matches($0) }
        matched.sort { lhs, rhs in
            query.sortDescending ? lhs.startTime > rhs.startTime : lhs.startTime < rhs.startTime
        }
        if let limit = query.limit { matched = Array(matched.prefix(limit)) }
        return matched
    }

    public func delete(id: UUID) async throws {
        records.removeValue(forKey: id)
    }

    public func clear() async throws {
        records.removeAll()
    }
}

// MARK: - 文件实现

/// 基于目录的 JSON file history store。
///
/// 每条 record 落到一个独立 `<id>.json`。`list` 扫描整目录解析后过滤；
/// 1k~10k 条以内可用，更大规模可换 SQLite/外部 DB。
public actor JSONFileHistoryStore: HistoryStore {
    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        // 用秒级 Double 时间戳保留毫秒精度（ISO8601 默认丢毫秒）
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        decoder = dec
    }

    public func save(_ record: TestRecord) async throws {
        let url = url(for: record.id)
        let data = try encoder.encode(record)
        try data.write(to: url, options: .atomic)
    }

    public func load(id: UUID) async throws -> TestRecord? {
        let url = url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(TestRecord.self, from: data)
    }

    public func list(_ query: HistoryQuery) async throws -> [TestRecord] {
        let urls = try listFiles()
        var records: [TestRecord] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let r = try? decoder.decode(TestRecord.self, from: data),
                  query.matches(r) else { continue }
            records.append(r)
        }
        records.sort { lhs, rhs in
            query.sortDescending ? lhs.startTime > rhs.startTime : lhs.startTime < rhs.startTime
        }
        if let limit = query.limit { records = Array(records.prefix(limit)) }
        return records
    }

    public func delete(id: UUID) async throws {
        let url = url(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func clear() async throws {
        for url in try listFiles() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func listFiles() throws -> [URL] {
        let all = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return all.filter { $0.pathExtension.lowercased() == "json" }
    }
}

// MARK: - 与 OutputCallback 桥接

/// 把 HistoryStore 包装成 OutputCallback —— 注册给 TestExecutor 后，
/// 每次 record 完成自动入库。
public struct HistoryOutputCallback: OutputCallback {
    public let store: any HistoryStore

    public init(store: any HistoryStore) {
        self.store = store
    }

    public func save(record: TestRecord) async {
        try? await store.save(record)
    }
}
