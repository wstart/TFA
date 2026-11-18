import Foundation

// 知识库与跨任务经验关联存储（`knowledge` + `task_context_link`）。
extension SuperagentStore {
    private static let knowledgeColumns = """
        id,task_id,scope,title,tldr,outcomes,pitfalls,files,tags,
        pinned,archived,user_edited,ai_refined,needs_refine,md_path,created_at,updated_at
        """

    private static func decodeStrings(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    private static func encodeStrings(_ list: [String]) -> String {
        guard let data = try? JSONEncoder().encode(list),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static func knowledgeRow(_ r: SQLRow) -> KnowledgeEntry {
        KnowledgeEntry(
            id: r.int(0),
            taskID: r.optInt(1),
            scope: r.text(2),
            title: r.text(3),
            tldr: r.text(4),
            outcomes: decodeStrings(r.text(5)),
            pitfalls: decodeStrings(r.text(6)),
            files: decodeStrings(r.text(7)),
            tags: decodeStrings(r.text(8)),
            pinned: r.int(9) != 0,
            archived: r.int(10) != 0,
            userEdited: r.int(11) != 0,
            aiRefined: r.int(12) != 0,
            needsRefine: r.int(13) != 0,
            mdPath: r.text(14),
            createdAt: r.double(15),
            updatedAt: r.double(16)
        )
    }

    public func knowledgeEntry(id: Int64) throws -> KnowledgeEntry? {
        try db.query("SELECT \(Self.knowledgeColumns) FROM knowledge WHERE id=?", [.int(id)])
            .first.map(Self.knowledgeRow)
    }

    public func knowledgeEntry(taskID: Int64) throws -> KnowledgeEntry? {
        try db.query("SELECT \(Self.knowledgeColumns) FROM knowledge WHERE task_id=?", [.int(taskID)])
            .first.map(Self.knowledgeRow)
    }

    public func knowledgeEntry(ref: KnowledgeRef) throws -> KnowledgeEntry? {
        switch ref {
        case .knowledge(let id): return try knowledgeEntry(id: id)
        case .task(let tid): return try knowledgeEntry(taskID: tid)
        }
    }

    /// 全部未归档知识条目的轻量 `(id, taskID)` 映射（供关联树快速建图）。
    public func activeKnowledgeGraphMeta() throws -> [(id: Int64, taskID: Int64?)] {
        try db.query("SELECT id, task_id FROM knowledge WHERE archived=0 ORDER BY id")
            .map { ($0.int(0), $0.optInt(1)) }
    }

    /// 按知识条目 ID 批量读取（不局限于条数上限）。
    public func knowledgeEntries(ids: [Int64]) throws -> [Int64: KnowledgeEntry] {
        var out: [Int64: KnowledgeEntry] = [:]
        let unique = Array(Set(ids))
        for chunk in Self.chunks(unique) {
            let rows = try db.query("SELECT \(Self.knowledgeColumns) FROM knowledge WHERE id IN (\(Self.marks(chunk.count)))",
                                    chunk.map(SQLValue.int))
            for e in rows.map(Self.knowledgeRow) { out[e.id] = e }
        }
        return out
    }

    /// 按来源任务 ID 批量读取未归档知识条目。
    public func knowledgeEntries(taskIDs: [Int64]) throws -> [Int64: KnowledgeEntry] {
        var out: [Int64: KnowledgeEntry] = [:]
        let unique = Array(Set(taskIDs))
        for chunk in Self.chunks(unique) {
            let rows = try db.query(
                "SELECT \(Self.knowledgeColumns) FROM knowledge WHERE archived=0 AND task_id IN (\(Self.marks(chunk.count)))",
                chunk.map(SQLValue.int)
            )
            for e in rows.map(Self.knowledgeRow) {
                if let tid = e.taskID { out[tid] = e }
            }
        }
        return out
    }

    public func knowledgeEntries(includeArchived: Bool = false, scope: String? = nil, pinnedOnly: Bool = false,
                                 limit: Int = 500) throws -> [KnowledgeEntry] {
        var clauses: [String] = []
        var args: [SQLValue] = []
        if !includeArchived { clauses.append("archived=0") }
        if pinnedOnly { clauses.append("pinned=1") }
        if let scope, !scope.isEmpty {
            clauses.append("scope=?")
            args.append(.text(scope))
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        args.append(.int(Int64(max(1, limit))))
        return try db.query("""
            SELECT \(Self.knowledgeColumns) FROM knowledge \(whereSQL)
            ORDER BY pinned DESC, updated_at DESC, id DESC LIMIT ?
            """, args).map(Self.knowledgeRow)
    }

    /// 等待后台模型异步提炼的条目（旧的优先）。
    public func pendingRefineKnowledge(limit: Int = 5) throws -> [KnowledgeEntry] {
        try db.query("""
            SELECT \(Self.knowledgeColumns) FROM knowledge
            WHERE needs_refine=1 AND archived=0
            ORDER BY updated_at ASC, id ASC LIMIT ?
            """, [.int(Int64(max(1, limit)))]).map(Self.knowledgeRow)
    }

    /// 还没有生成知识总结的已完成任务 id（新的在前）。
    public func unindexedDoneTaskIDs(limit: Int = 200) throws -> [Int64] {
        try db.query("""
            SELECT t.id FROM task t
            LEFT JOIN knowledge k ON k.task_id = t.id
            WHERE t.status = 'done' AND k.id IS NULL
            ORDER BY t.updated_at DESC, t.id DESC LIMIT ?
            """, [.int(Int64(max(1, limit)))]).map { $0.int(0) }
    }

    @discardableResult
    func insertKnowledge(_ e: KnowledgeEntry) throws -> Int64 {
        try db.run("""
            INSERT INTO knowledge (
              task_id,scope,title,tldr,outcomes,pitfalls,files,tags,
              pinned,archived,user_edited,ai_refined,needs_refine,md_path,created_at,updated_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                e.taskID.map(SQLValue.int) ?? .null, .text(e.scope), .text(e.title), .text(e.tldr),
                .text(Self.encodeStrings(e.outcomes)), .text(Self.encodeStrings(e.pitfalls)),
                .text(Self.encodeStrings(e.files)), .text(Self.encodeStrings(e.tags)),
                .bool(e.pinned), .bool(e.archived), .bool(e.userEdited),
                .bool(e.aiRefined), .bool(e.needsRefine), .text(e.mdPath),
                .real(e.createdAt), .real(e.updatedAt),
            ])
        return db.lastInsertID
    }

    func updateKnowledge(_ e: KnowledgeEntry) throws {
        try db.run("""
            UPDATE knowledge SET
              task_id=?,scope=?,title=?,tldr=?,outcomes=?,pitfalls=?,files=?,tags=?,
              pinned=?,archived=?,user_edited=?,ai_refined=?,needs_refine=?,md_path=?,updated_at=?
            WHERE id=?
            """, [
                e.taskID.map(SQLValue.int) ?? .null, .text(e.scope), .text(e.title), .text(e.tldr),
                .text(Self.encodeStrings(e.outcomes)), .text(Self.encodeStrings(e.pitfalls)),
                .text(Self.encodeStrings(e.files)), .text(Self.encodeStrings(e.tags)),
                .bool(e.pinned), .bool(e.archived), .bool(e.userEdited),
                .bool(e.aiRefined), .bool(e.needsRefine), .text(e.mdPath),
                .real(e.updatedAt), .int(e.id),
            ])
    }

    public func updateKnowledgeMDPath(id: Int64, mdPath: String) throws {
        try db.run("UPDATE knowledge SET md_path=? WHERE id=?", [.text(mdPath), .int(id)])
    }

    // MARK: - 工单终端输出归档（终端会话关闭后仍可在归档弹窗里查阅）

    public func ticketArchive(_ ticketID: Int64) throws -> String? {
        try kv("ticket.archive.\(ticketID)")?.nilIfEmpty
    }

    public func saveTicketArchive(_ ticketID: Int64, text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try setKV("ticket.archive.\(ticketID)", String(trimmed.suffix(12000)))
    }

    // MARK: - 任务 ↔ 知识关联（`task_context_link`）

    public func linkedKnowledgeIDs(forTask taskID: Int64) throws -> [Int64] {
        try db.query("SELECT knowledge_id FROM task_context_link WHERE task_id=? ORDER BY created_at, knowledge_id",
                     [.int(taskID)]).map { $0.int(0) }
    }

    public func linkedKnowledgeEntries(forTask taskID: Int64) throws -> [KnowledgeEntry] {
        try db.query("""
            SELECT k.id,k.task_id,k.scope,k.title,k.tldr,k.outcomes,k.pitfalls,k.files,k.tags,
                   k.pinned,k.archived,k.user_edited,k.ai_refined,k.needs_refine,k.md_path,k.created_at,k.updated_at
            FROM task_context_link l
            JOIN knowledge k ON k.id = l.knowledge_id
            WHERE l.task_id=?
            ORDER BY l.created_at, k.id
            """, [.int(taskID)]).map(Self.knowledgeRow)
    }

    /// 全部 `task_id → [knowledge_id]` 与 `knowledge_id → [task_id]` 映射（列表批量装配用）。
    public func allTaskContextLinks() throws -> (byTask: [Int64: [Int64]], byKnowledge: [Int64: [Int64]]) {
        var byTask: [Int64: [Int64]] = [:]
        var byKnowledge: [Int64: [Int64]] = [:]
        for r in try db.query("SELECT task_id, knowledge_id FROM task_context_link ORDER BY created_at, task_id, knowledge_id") {
            let tid = r.int(0), kid = r.int(1)
            byTask[tid, default: []].append(kid)
            byKnowledge[kid, default: []].append(tid)
        }
        return (byTask, byKnowledge)
    }

    func addContextLink(taskID: Int64, knowledgeID: Int64, note: String = "", at: Double) throws {
        try db.run("""
            INSERT INTO task_context_link (task_id, knowledge_id, note, created_at) VALUES (?,?,?,?)
            ON CONFLICT(task_id, knowledge_id) DO UPDATE SET note=excluded.note
            """, [.int(taskID), .int(knowledgeID), .text(note), .real(at)])
    }

    func removeContextLink(taskID: Int64, knowledgeID: Int64) throws {
        try db.run("DELETE FROM task_context_link WHERE task_id=? AND knowledge_id=?", [.int(taskID), .int(knowledgeID)])
    }

    func replaceContextLinks(taskID: Int64, knowledgeIDs: [Int64], at: Double) throws {
        try db.run("DELETE FROM task_context_link WHERE task_id=?", [.int(taskID)])
        var seen = Set<Int64>()
        for kid in knowledgeIDs where seen.insert(kid).inserted {
            try addContextLink(taskID: taskID, knowledgeID: kid, at: at)
        }
    }

    // MARK: - 中英混合检索与智能相关性排序

    /// 搜索知识库：支持按标签、编号（`A-12` / `K-3`）、中文子串、英文词、文件路径多维加权打分；
    /// 传入 `preferredScope` 时同项目经验加权靠前，不会硬过滤跨项目可借鉴经验（除非 `strictScope == true`）。
    public func searchKnowledge(query: String, preferredScope: String = "", strictScope: Bool = false,
                                tag: String? = nil, includeArchived: Bool = false, limit: Int = 20) throws -> [KnowledgeEntry] {
        let pool = try knowledgeEntries(includeArchived: includeArchived, scope: strictScope ? preferredScope : nil, limit: 1000)
        let filterTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = pool.filter { entry in
            guard let filterTag, !filterTag.isEmpty else { return true }
            return entry.tags.contains { $0.lowercased() == filterTag }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return Array(filtered.sorted { a, b in
                let aSame = !preferredScope.isEmpty && a.scope == preferredScope
                let bSame = !preferredScope.isEmpty && b.scope == preferredScope
                if aSame != bSame { return aSame && !bSame }
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return a.updatedAt > b.updatedAt
            }.prefix(max(1, limit)))
        }

        // 若直接输入编号（如 A-12 / K-3），精确命中置顶
        let exactRef = KnowledgeRef.parse(q)
        let tokens = Self.searchTokens(q)
        guard !tokens.isEmpty || exactRef != nil else { return [] }

        var scored: [(entry: KnowledgeEntry, score: Int)] = []
        for e in filtered {
            var score = 0
            if let exactRef {
                switch exactRef {
                case .task(let tid) where e.taskID == tid: score += 100
                case .knowledge(let kid) where e.id == kid: score += 100
                default: break
                }
            }
            let titleLower = e.title.lowercased()
            let tldrLower = e.tldr.lowercased()
            let tagsLower = e.tags.map { $0.lowercased() }
            let pitfallsLower = e.pitfalls.joined(separator: "\n").lowercased()
            let outcomesLower = e.outcomes.joined(separator: "\n").lowercased()
            let filesLower = e.files.joined(separator: "\n").lowercased()
            let labelLower = e.displayLabel.lowercased()

            for tok in tokens {
                var hit = false
                if labelLower == tok || e.kbLabel.lowercased() == tok { score += 40; hit = true }
                if titleLower.contains(tok) { score += 12; hit = true }
                if tagsLower.contains(where: { $0.contains(tok) }) { score += 10; hit = true }
                if pitfallsLower.contains(tok) { score += 7; hit = true }
                if tldrLower.contains(tok) { score += 7; hit = true }
                if filesLower.contains(tok) { score += 6; hit = true }
                if outcomesLower.contains(tok) { score += 4; hit = true }
                if !hit, !preferredScope.isEmpty, e.scope.lowercased().contains(tok) { score += 2 }
            }
            guard score > 0 else { continue }
            if !preferredScope.isEmpty, e.scope == preferredScope { score += 5 }
            if e.pinned { score += 2 }
            scored.append((e, score))
        }
        return scored
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.entry.updatedAt > b.entry.updatedAt
            }
            .prefix(max(1, limit))
            .map(\.entry)
    }

    /// 把中英混合查询拆成有效检索词（保留英文/数字词 + 连续中文词及 2 字二元切分，避免中文长句无空格漏召回）。
    static func searchTokens(_ query: String) -> [String] {
        let lower = query.lowercased()
        let rawParts = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        func add(_ s: String) {
            guard !s.isEmpty, !stopWords.contains(s), !out.contains(s) else { return }
            out.append(s)
        }
        for part in rawParts {
            let hasCJK = part.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
            if !hasCJK {
                if part.count >= 2 { add(part) }
                continue
            }
            if part.count <= 6 {
                add(part)
            }
            // 对较长中文短语切出 2 字 bigram，使「把界面重做并修断网」也能命中「界面」「断网」
            let chars = Array(part)
            if chars.count >= 3 {
                for i in 0..<(chars.count - 1) {
                    let bi = String(chars[i...i + 1])
                    add(bi)
                }
            } else {
                add(part)
            }
        }
        return Array(out.prefix(16))
    }

    private static let stopWords: Set<String> = [
        "任务", "需要", "一下", "一个", "这个", "那个", "我们", "可以", "怎么", "如何",
        "已经", "完成", "状态", "问题", "修改", "优化", "支持", "实现", "增加", "添加",
        "the", "and", "for", "with", "from", "this", "that",
    ]
}
