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

// MARK: - JSON 输出

/// JSON 输出回调（每个测试记录写入一个文件）
public struct JSONOutput: OutputCallback {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
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
            let url = directory.appendingPathComponent(
                Self.filename(for: record, ext: "json")
            )
            try data.write(to: url, options: .atomic)
        } catch {
            print("JSONOutput failed: \(error.localizedDescription)")
        }
    }

    static func filename(for record: TestRecord, ext: String) -> String {
        let stamp = Self.timestamp(record.startTime)
        let serial = record.serialNumber ?? "noSN"
        return "\(record.planName)_\(serial)_\(stamp).\(ext)"
    }

    static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }
}

// MARK: - CSV 输出

/// CSV 输出回调（每个测试记录写入一个文件，每行一个 phase）
public struct CSVOutput: OutputCallback {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
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
            let url = directory.appendingPathComponent(
                JSONOutput.filename(for: record, ext: "csv")
            )
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
