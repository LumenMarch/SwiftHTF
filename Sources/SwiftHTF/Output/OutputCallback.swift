import Foundation

/// 输出回调协议
///
/// 测试结束后由 `TestExecutor` 调用，可有多个回调并行实现（控制台、JSON、CSV、上传…）。
public protocol OutputCallback: Sendable {
    /// 保存测试记录
    func save(record: TestRecord) async
}

// MARK: - 控制台输出

private func formatBytes(_ n: Int) -> String {
    if n < 1024 { return "\(n) B" }
    let kb = Double(n) / 1024
    if kb < 1024 { return String(format: "%.1f KB", kb) }
    return String(format: "%.2f MB", kb / 1024)
}

private func phaseSymbol(_ o: PhaseOutcomeType) -> String {
    switch o {
    case .pass: "✓"
    case .marginalPass: "≈"
    case .skip: "⏭"
    case .fail, .error: "✗"
    case .timeout: "⏱"
    }
}

private func subtestSymbol(_ o: SubtestOutcome) -> String {
    switch o {
    case .pass: "✓"
    case .fail, .error: "✗"
    case .skip: "⏭"
    }
}

/// 控制台输出回调
public struct ConsoleOutput: OutputCallback {
    public init() {}

    public func save(record: TestRecord) async {
        var lines: [String] = []
        lines.append("=== Test Record ===")
        lines.append("Plan: \(record.planName)")
        lines.append("Serial: \(record.serialNumber ?? "N/A")")
        lines.append("Outcome: \(record.outcome.rawValue)")
        lines.append("Duration: \(String(format: "%.2f", record.duration))s")
        lines.append("Phases:")
        for phase in record.phases {
            let mark = phaseSymbol(phase.outcome)
            let prefix = phase.groupPath.isEmpty ? "" : "[" + phase.groupPath.joined(separator: " / ") + "] "
            lines.append("  \(mark) \(prefix)\(phase.name) (\(String(format: "%.2f", phase.duration))s)")
            for (name, m) in phase.measurements.sorted(by: { $0.key < $1.key }) {
                let mmark = phaseSymbol(m.outcome)
                let unit = m.unit.map { " \($0)" } ?? ""
                var line = "      \(mmark) \(name) = \(m.value.displayString)\(unit)"
                if !m.validatorMessages.isEmpty {
                    line += "  [\(m.validatorMessages.joined(separator: "; "))]"
                }
                lines.append(line)
            }
            for a in phase.attachments {
                lines.append("      📎 \(a.name) (\(a.mimeType), \(formatBytes(a.size)))")
            }
            for d in phase.diagnoses {
                lines.append("      🩺 [\(d.severity.rawValue)] \(d.code): \(d.message)")
            }
        }
        if !record.subtests.isEmpty {
            lines.append("Subtests:")
            for s in record.subtests {
                let mark = subtestSymbol(s.outcome)
                let durStr = s.endTime == nil ? "0.00" : String(format: "%.2f", s.duration)
                var line = "  \(mark) \(s.name) (\(durStr)s, \(s.phaseIDs.count) phases) → \(s.outcome.rawValue)"
                if let reason = s.failureReason {
                    line += " — \(reason)"
                }
                lines.append(line)
            }
        }
        if !record.diagnoses.isEmpty {
            lines.append("Diagnoses:")
            for d in record.diagnoses {
                lines.append("  🩺 [\(d.severity.rawValue)] \(d.code): \(d.message)")
            }
        }
        lines.append("===================")
        print(lines.joined(separator: "\n"))
    }
}

// MARK: - 文件名模板

/// OpenHTF 风格的文件名模板。占位符按字面替换；未知占位符保留 `{token}` 原样。
///
/// 支持 token：
/// - `{plan}` / `{test_name}` → `record.planName`
/// - `{serial}` / `{serial_number}` / `{dut_id}` → `record.serialNumber ?? "noSN"`
/// - `{start_time_millis}` → `Int(record.startTime.timeIntervalSince1970 * 1000)`
/// - `{start_time_iso}` → ISO8601（冒号替为 `-` 适配 NTFS）
/// - `{outcome}` → `record.outcome.rawValue`
///
/// ```swift
/// JSONOutput(
///     directory: dir,
///     filenameTemplate: "{dut_id}.{start_time_millis}.json"
/// )
/// ```
public struct OutputFilenameTemplate: Sendable {
    public let template: String

    public init(_ template: String) {
        self.template = template
    }

    /// 与历史 `JSONOutput` / `CSVOutput` 一致的旧默认：`{plan}_{serial}_{start_time_iso}.<ext>`。
    /// 调用方需自行补扩展名。
    public static func legacy(ext: String) -> OutputFilenameTemplate {
        OutputFilenameTemplate("{plan}_{serial}_{start_time_iso}.\(ext)")
    }

    /// 把 token 按 record 字段渲染成文件名。未知 token 保留原样（不报错，便于扩展）。
    public func render(record: TestRecord) -> String {
        var out = template
        let millis = Int64(record.startTime.timeIntervalSince1970 * 1000)
        let serial = record.serialNumber ?? "noSN"
        let iso = ISO8601DateFormatter()
            .string(from: record.startTime)
            .replacingOccurrences(of: ":", with: "-")
        let table: [(String, String)] = [
            ("{plan}", record.planName),
            ("{test_name}", record.planName),
            ("{serial}", serial),
            ("{serial_number}", serial),
            ("{dut_id}", serial),
            ("{start_time_millis}", String(millis)),
            ("{start_time_iso}", iso),
            ("{outcome}", record.outcome.rawValue),
        ]
        for (token, value) in table {
            out = out.replacingOccurrences(of: token, with: value)
        }
        return out
    }
}

// MARK: - JSON 输出

/// JSON 输出回调（每个测试记录写入一个文件）
public struct JSONOutput: OutputCallback {
    public let directory: URL
    public let filenameTemplate: OutputFilenameTemplate

    /// 旧 API：保留默认文件名规则不变（兼容既有调用）。
    public init(directory: URL) {
        self.init(directory: directory, filenameTemplate: .legacy(ext: "json"))
    }

    public init(directory: URL, filenameTemplate: OutputFilenameTemplate) {
        self.directory = directory
        self.filenameTemplate = filenameTemplate
    }

    public func save(record: TestRecord) async {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(record)
            let url = directory.appendingPathComponent(filenameTemplate.render(record: record))
            try data.write(to: url, options: .atomic)
        } catch {
            print("JSONOutput failed: \(error.localizedDescription)")
        }
    }

    /// 旧 API 兼容（CSV 仍引用）：按"plan_serial_iso.<ext>"格式生成名字。
    static func filename(for record: TestRecord, ext: String) -> String {
        OutputFilenameTemplate.legacy(ext: ext).render(record: record)
    }
}

// MARK: - CSV 输出

/// CSV 输出回调（每个测试记录写入一个文件，每行一个 phase）
public struct CSVOutput: OutputCallback {
    public let directory: URL
    public let filenameTemplate: OutputFilenameTemplate

    /// 旧 API：保留默认文件名规则不变。
    public init(directory: URL) {
        self.init(directory: directory, filenameTemplate: .legacy(ext: "csv"))
    }

    public init(directory: URL, filenameTemplate: OutputFilenameTemplate) {
        self.directory = directory
        self.filenameTemplate = filenameTemplate
    }

    public func save(record: TestRecord) async {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            // 反查每个 phase 所属的 subtest 名（按 phaseIDs 索引）
            var subtestByPhase: [UUID: String] = [:]
            for s in record.subtests {
                for pid in s.phaseIDs {
                    subtestByPhase[pid] = s.name
                }
            }
            var lines = ["name,outcome,subtest,duration_s,measurements_count,traces_count,attachments_count,diagnoses_count,error"]
            for p in record.phases {
                lines.append([
                    Self.escape(p.name),
                    p.outcome.rawValue,
                    Self.escape(subtestByPhase[p.id] ?? ""),
                    String(format: "%.3f", p.duration),
                    String(p.measurements.count),
                    String(p.traces.count),
                    String(p.attachments.count),
                    String(p.diagnoses.count),
                    Self.escape(p.errorMessage ?? ""),
                ].joined(separator: ","))
            }
            let url = directory.appendingPathComponent(filenameTemplate.render(record: record))
            let body = lines.joined(separator: "\n") + "\n"
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("CSVOutput failed: \(error.localizedDescription)")
        }
    }

    static func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
