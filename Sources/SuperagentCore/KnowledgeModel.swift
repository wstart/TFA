import Foundation

// 任务总结与项目知识库（Knowledge Base）：
// 1. 已完成任务自动沉淀为结构化经验卡（`task_id` 唯一对应 `A-<id>`），也支持手动新建独立经验卡（`K-<id>`）；
// 2. 主存储为 `~/.tfa/superagent.db`（CLI 与 App 共享），后台同步镜像一份可读的 Markdown 文件到 `~/.tfa/knowledge/`（或自定义目录）；
// 3. 新任务可通过 `task_context_link` 显式关联历史任务 / 经验卡，派发工单时自动向执行者注入精简结论与避坑要点。

/// 知识条目的外部引用标识：支持任务号（`A-12` / `a12` / `12`）或独立知识号（`K-3` / `k3`）。
public enum KnowledgeRef: Equatable, Hashable, Sendable {
    case task(Int64)
    case knowledge(Int64)

    public var label: String {
        switch self {
        case .task(let id): return "A-\(id)"
        case .knowledge(let id): return "K-\(id)"
        }
    }

    public static func parse(_ raw: String) -> KnowledgeRef? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("k-") {
            guard let n = Int64(lower.dropFirst(2)), n > 0 else { return nil }
            return .knowledge(n)
        }
        if lower.hasPrefix("k"), let n = Int64(lower.dropFirst()), n > 0 {
            return .knowledge(n)
        }
        if let tid = WorkTask.parseID(s) {
            return .task(tid)
        }
        return nil
    }

    public static func parseList(_ raw: String) -> [KnowledgeRef]? {
        var out: [KnowledgeRef] = []
        for part in raw.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }) {
            guard let ref = parse(String(part)) else { return nil }
            if !out.contains(ref) { out.append(ref) }
        }
        return out
    }
}

/// 一张结构化知识卡片（来自已完成任务 `A-<taskID>` 或手动沉淀 `K-<id>`）。
public struct KnowledgeEntry: Equatable, Sendable, Identifiable {
    public var id: Int64
    /// 来源于哪张任务（1 对 1）；nil = 手动新建的独立经验卡。
    public var taskID: Int64?
    /// 项目目录（空 = 通用经验）。
    public var scope: String
    public var title: String
    /// 一句话结论（≤160 字）。
    public var tldr: String
    /// 交付要点 / 解决方案（2–5 条）。
    public var outcomes: [String]
    /// 关键决策与踩坑避雷（下次关联时优先注入给执行 Agent）。
    public var pitfalls: [String]
    /// 涉及的关键文件路径 / 分支 / 报告产物。
    public var files: [String]
    /// 2–6 个主题短标签。
    public var tags: [String]
    /// 置顶为当前项目常驻经验（同项目新工单默认附带摘要）。
    public var pinned: Bool
    /// 归档隐藏（不再出现在默认列表与自动推荐中）。
    public var archived: Bool
    /// 人手动编辑过（重跑完成或批量补齐时不覆盖正文，除非显式点「重新提炼」）。
    public var userEdited: Bool
    /// 已由模型完成结构化提炼（false = 确定性兜底摘要）。
    public var aiRefined: Bool
    /// 等待后台模型异步提炼。
    public var needsRefine: Bool
    /// 最近一次同步落盘的 Markdown 绝对路径。
    public var mdPath: String
    public var createdAt: Double
    public var updatedAt: Double

    public init(id: Int64 = 0, taskID: Int64? = nil, scope: String = "", title: String, tldr: String = "",
                outcomes: [String] = [], pitfalls: [String] = [], files: [String] = [], tags: [String] = [],
                pinned: Bool = false, archived: Bool = false, userEdited: Bool = false,
                aiRefined: Bool = false, needsRefine: Bool = false, mdPath: String = "",
                createdAt: Double, updatedAt: Double) {
        self.id = id; self.taskID = taskID; self.scope = scope; self.title = title; self.tldr = tldr
        self.outcomes = outcomes; self.pitfalls = pitfalls; self.files = files; self.tags = tags
        self.pinned = pinned; self.archived = archived; self.userEdited = userEdited
        self.aiRefined = aiRefined; self.needsRefine = needsRefine; self.mdPath = mdPath
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// 对人展示的主编号：任务沉淀优先显示 `A-<taskID>`，独立经验显示 `K-<id>`。
    public var displayLabel: String { taskID.map { "A-\($0)" } ?? "K-\(id)" }
    /// 知识库内部编号 `K-<id>`。
    public var kbLabel: String { "K-\(id)" }

    public var projectName: String {
        guard !scope.isEmpty else { return "通用" }
        return URL(fileURLWithPath: scope).lastPathComponent
    }
}

/// 任务卡与 CLI 上展示的「关联上游经验」精简投影。
public struct RelatedKnowledgeSummary: Equatable, Sendable, Identifiable {
    public var id: Int64 { knowledgeID }
    public var knowledgeID: Int64
    public var taskID: Int64?
    public var displayLabel: String
    public var title: String
    public var tldr: String
    public var pitfalls: [String]
    public var files: [String]
    public var pinned: Bool

    public init(entry: KnowledgeEntry) {
        self.knowledgeID = entry.id
        self.taskID = entry.taskID
        self.displayLabel = entry.displayLabel
        self.title = entry.title
        self.tldr = entry.tldr
        self.pitfalls = entry.pitfalls
        self.files = entry.files
        self.pinned = entry.pinned
    }
}

/// 任务卡与知识卡上展示的「后续衍生任务」精简投影（双向追溯）。
public struct DerivedTaskSummary: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var title: String
    public var status: TaskStatus

    public init(id: Int64, title: String, status: TaskStatus) {
        self.id = id; self.title = title; self.status = status
    }

    public var label: String { "A-\(id)" }
}

/// 知识库页面的读视图：卡片本体 + 引用过它的后续任务。
public struct KnowledgeView: Equatable, Sendable, Identifiable {
    public var id: Int64 { entry.id }
    public var entry: KnowledgeEntry
    public var derivedTasks: [DerivedTaskSummary]

    public init(entry: KnowledgeEntry, derivedTasks: [DerivedTaskSummary] = []) {
        self.entry = entry
        self.derivedTasks = derivedTasks
    }
}

/// 新建 / 编辑 / 模型提炼知识卡的内容载荷。
public struct KnowledgeDraft: Equatable, Sendable {
    public var scope: String
    public var title: String
    public var tldr: String
    public var outcomes: [String]
    public var pitfalls: [String]
    public var files: [String]
    public var tags: [String]
    public var pinned: Bool

    public init(scope: String = "", title: String = "", tldr: String = "",
                outcomes: [String] = [], pitfalls: [String] = [], files: [String] = [],
                tags: [String] = [], pinned: Bool = false) {
        self.scope = scope; self.title = title; self.tldr = tldr
        self.outcomes = outcomes; self.pitfalls = pitfalls; self.files = files
        self.tags = tags; self.pinned = pinned
    }
}

// MARK: - 本地 Markdown 镜像生成与同步

public enum KnowledgeMarkdown {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 渲染单张知识卡的 Markdown 文本（带 YAML frontmatter，可直接放进 Obsidian 或代码编辑器查阅）。
    public static func render(_ e: KnowledgeEntry, derived: [DerivedTaskSummary] = []) -> String {
        func yamlQuote(_ s: String) -> String {
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            return "\"\(escaped)\""
        }
        var lines: [String] = ["---"]
        lines.append("id: \(e.kbLabel)")
        if let tid = e.taskID { lines.append("task: A-\(tid)") }
        lines.append("title: \(yamlQuote(e.title))")
        if !e.scope.isEmpty { lines.append("scope: \(yamlQuote(e.scope))") }
        if !e.tags.isEmpty {
            lines.append("tags: [" + e.tags.map(yamlQuote).joined(separator: ", ") + "]")
        }
        lines.append("pinned: \(e.pinned ? "true" : "false")")
        lines.append("updated_at: \(isoFormatter.string(from: Date(timeIntervalSince1970: e.updatedAt)))")
        lines.append("---")
        lines.append("")
        lines.append("# [\(e.displayLabel)] \(e.title)")
        lines.append("")
        if !e.tldr.isEmpty {
            lines.append("## 一句话结论")
            lines.append(e.tldr)
            lines.append("")
        }
        if !e.outcomes.isEmpty {
            lines.append("## 交付要点")
            for item in e.outcomes { lines.append("- \(item)") }
            lines.append("")
        }
        if !e.pitfalls.isEmpty {
            lines.append("## 踩坑与关键决策")
            for item in e.pitfalls { lines.append("- \(item)") }
            lines.append("")
        }
        if !e.files.isEmpty {
            lines.append("## 涉及文件与产物")
            for f in e.files { lines.append("- `\(f)`") }
            lines.append("")
        }
        if !derived.isEmpty {
            lines.append("## 后续关联任务")
            for d in derived { lines.append("- \(d.label)「\(d.title)」（\(d.status.label)）") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 计算目标文件路径：`<baseDir>/<项目名或global>/<A-12或K-3>-<安全文件名>.md`。
    public static func targetURL(for e: KnowledgeEntry, baseDir: URL) -> URL {
        let folder = e.scope.isEmpty ? "global" : sanitizeFilename(URL(fileURLWithPath: e.scope).lastPathComponent, fallback: "project")
        let slug = sanitizeFilename(String(e.title.prefix(40)), fallback: "summary")
        return baseDir
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("\(e.displayLabel)-\(slug).md")
    }

    /// 同步单张知识卡到磁盘（归档条目删除旧镜像；改标题/改项目时自动清理旧路径）。返回最新路径。
    @discardableResult
    public static func sync(_ e: KnowledgeEntry, derived: [DerivedTaskSummary] = [], baseDir: URL) -> String {
        let fm = FileManager.default
        if e.archived {
            if !e.mdPath.isEmpty { try? fm.removeItem(atPath: e.mdPath) }
            return ""
        }
        let dst = targetURL(for: e, baseDir: baseDir)
        if !e.mdPath.isEmpty, e.mdPath != dst.path {
            try? fm.removeItem(atPath: e.mdPath)
        }
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let body = render(e, derived: derived)
            if (try? String(contentsOf: dst, encoding: .utf8)) != body {
                try body.write(to: dst, atomically: true, encoding: .utf8)
            }
            return dst.path
        } catch {
            return e.mdPath
        }
    }

    private static func sanitizeFilename(_ raw: String, fallback: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        let cleaned = raw.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return cleaned.isEmpty ? fallback : cleaned
    }
}
