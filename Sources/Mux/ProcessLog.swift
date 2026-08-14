import Foundation

/// 终端过程记录(dsh 的核心思想搬到 TFA 的现实):TFA 能**观察到的事实**按时间追加进
/// 每终端一个的 JSONL 文件(`~/.tfa/process-log/<tfa_id>.jsonl`)——命令开始/结束(文本、
/// 退出码、耗时,来自 OSC 133/7770 shell 集成)、attention、连接/断开。永不改写旧行,
/// 只追加;UI(历史查看器的「过程」页)是它的只读投影。
///
/// 刻意不记录的:终端原始输出(那是 scrollback/快照的事)、agent 的自述(那在看板时间线,
/// 来源不同不能混,dsh: report ≠ settlement)。
struct ProcessEvent: Codable, Identifiable, Equatable {
    var at: Date
    var kind: String        // "command" | "attention" | "connected" | "closed"
    var text: String?       // command line / attention message
    var exit: Int?          // command exit code (when known)
    var seconds: Double?    // command duration

    var id: Double { at.timeIntervalSince1970 } // display identity (collisions harmless for UI)
}

@MainActor
enum ProcessLog {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tfa/process-log", isDirectory: true)
    }
    /// Rewrite threshold: past this size the file is compacted to the newest `keepLines`.
    static let maxBytes = 512 * 1024
    static let keepLines = 1500

    private static func url(_ stableID: String) -> URL {
        // stableID is a UUID/tmux-id (filename-safe by construction); guard anyway.
        let safe = stableID.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).jsonl")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// Append one event (creates dir/file on first use). Failures are silent by design — the log is
    /// an observer, it must never break the terminal it observes.
    static func append(_ stableID: String, _ event: ProcessEvent) {
        guard !stableID.isEmpty, var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        let u = url(stableID)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: u.path) { fm.createFile(atPath: u.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: u) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line)
        // Compaction: append-only until the file is big, then keep the newest tail. Checked after
        // the write so the just-appended event is never lost.
        if let size = try? fm.attributesOfItem(atPath: u.path)[.size] as? Int, size > maxBytes {
            compact(u)
        }
    }

    /// All events for a terminal, oldest → newest. Bad lines are skipped (forward compatibility).
    static func load(_ stableID: String) -> [ProcessEvent] {
        guard let data = try? Data(contentsOf: url(stableID)) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(ProcessEvent.self, from: $0) }
    }

    private static func compact(_ u: URL) {
        guard let data = try? Data(contentsOf: u) else { return }
        let lines = data.split(separator: 0x0A)
        guard lines.count > keepLines else { return }
        var out = Data()
        for l in lines.suffix(keepLines) { out.append(l); out.append(0x0A) }
        try? out.write(to: u, options: .atomic)
    }
}
