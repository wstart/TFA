import Foundation
import SuperagentCore

/// `tfa kb …`：项目知识库与已完成任务总结（主管、执行者与人共用读接口；写接口对主管和人开放，执行者也可在发现通用踩坑时 `kb add`）。
extension TFACommand {
    static func kb(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        guard let sub = args.first else {
            throw CLIError.usage("缺少子命令（list / search / show / add / summarize）", command: "kb")
        }
        let rest = args.dropFirst()
        switch sub {
        case "list": return try kbList(rest, c)
        case "search": return try kbSearch(rest, c)
        case "show": return try kbShow(rest, c)
        case "add": return try kbAdd(rest, c)
        case "summarize": return try kbSummarize(rest, c)
        case "-h", "--help": throw CLIError.help("kb")
        default: throw CLIError.usage("未知的子命令 kb \(sub)", command: "kb")
        }
    }

    private static func kbList(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "kb list"
        let a = try parse(args, cmd, values: ["scope", "tag", "limit"], flags: ["pinned"])
        try noPositional(a, cmd)
        let scope = a.value("scope").map { resolve($0, cwd: c.cwd) ?? $0 }
        let limit = try a.value("limit").map {
            guard let n = Int($0), n > 0 else { throw CLIError.usage("--limit 必须是正整数：\($0)", command: cmd) }
            return min(n, 200)
        } ?? 30
        let engine = try c.engine()
        let views: [KnowledgeView]
        if let tag = a.value("tag"), !tag.isEmpty {
            views = try engine.searchKnowledgeViews(query: "", preferredScope: scope ?? "", strictScope: scope != nil,
                                                    tag: tag, limit: limit)
        } else {
            views = try engine.knowledgeViews(scope: scope, pinnedOnly: a.flags.contains("pinned"), limit: limit)
        }
        return Outcome(out: Views.knowledgeList(views, header: "知识库"))
    }

    private static func kbSearch(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "kb search"
        let a = try parse(args, cmd, values: ["scope", "tag", "limit"], flags: ["strict-scope"])
        let query = a.positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || a.value("tag") != nil else {
            throw CLIError.usage("缺少检索关键词（如 tfa kb search \"断网 重试\"）", command: cmd)
        }
        let scope = a.value("scope").map { resolve($0, cwd: c.cwd) ?? $0 } ?? ""
        let limit = try a.value("limit").map {
            guard let n = Int($0), n > 0 else { throw CLIError.usage("--limit 必须是正整数：\($0)", command: cmd) }
            return min(n, 100)
        } ?? 15
        let views = try c.engine().searchKnowledgeViews(query: query, preferredScope: scope,
                                                        strictScope: a.flags.contains("strict-scope"),
                                                        tag: a.value("tag"), limit: limit)
        return Outcome(out: Views.knowledgeList(views, header: "匹配到的历史经验"))
    }

    private static func kbShow(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "kb show"
        let a = try parse(args, cmd)
        let raw = try onePositional(a, cmd, "任务号 A-12 或知识号 K-3")
        guard let ref = KnowledgeRef.parse(raw) else {
            throw CLIError.usage("编号格式应为 A-12 或 K-3：\(raw)", command: cmd)
        }
        let engine = try c.engine()
        if let v = try engine.knowledgeView(ref: ref) {
            return Outcome(out: Views.knowledgeDetail(v))
        }
        // 若传入的是已完成但还没沉淀入库的旧任务 A-N，即时返回它的总结预览
        if case .task(let tid) = ref, let task = try engine.store.task(tid) {
            let entry = try engine.summarizeTask(tid, aiRefine: task.status == .done, by: "TFA")
            if let v = try engine.knowledgeView(ref: .knowledge(entry.id)) {
                return Outcome(out: Views.knowledgeDetail(v), changed: true)
            }
        }
        throw SuperagentError("找不到知识卡 \(ref.label)")
    }

    private static func kbAdd(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "kb add"
        let a = try parse(args, cmd, values: ["title", "tldr", "scope", "outcome", "pitfall", "file", "tag"],
                          flags: ["pin"], repeatable: ["outcome", "pitfall", "file", "tag"])
        try noPositional(a, cmd)
        guard let title = a.value("title") else { throw CLIError.usage("缺少 --title（经验标题）", command: cmd) }
        let tldr = a.value("tldr") ?? c.piped() ?? ""
        guard !tldr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(a.values["outcome"] ?? []).isEmpty else {
            throw CLIError.usage("缺少 --tldr（一句话结论）或 --outcome", command: cmd)
        }
        let scope = try a.value("scope").map(c.directory) ?? ""
        let who = c.isRouter ? "主管" : (c.inWorkerTerminal ? "执行者" : "你")
        let rawTags: [String] = a.values["tag"] ?? []
        let tags = rawTags.flatMap { $0.split(whereSeparator: { $0 == "," || $0 == "，" }).map(String.init) }
        let entry = try c.engine().saveKnowledge(
            draft: KnowledgeDraft(
                scope: scope,
                title: title,
                tldr: tldr,
                outcomes: a.values["outcome"] ?? [],
                pitfalls: a.values["pitfall"] ?? [],
                files: a.values["file"] ?? [],
                tags: tags,
                pinned: a.flags.contains("pin")
            ),
            by: who
        )
        return Outcome(out: "已写入知识库：\(entry.kbLabel)「\(entry.title)」\(entry.pinned ? "（已置顶为项目常驻经验）" : "")。\n", changed: true)
    }

    private static func kbSummarize(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "kb summarize"
        let a = try parse(args, cmd, flags: ["force"])
        let raw = try onePositional(a, cmd, "任务号 A-12")
        guard let tid = WorkTask.parseID(raw) else { throw CLIError.usage("任务号应写成 A-12 或 12：\(raw)", command: cmd) }
        let who = c.isRouter ? "主管" : "你"
        let entry = try c.engine().summarizeTask(tid, aiRefine: true, force: a.flags.contains("force"), by: who)
        return Outcome(out: "已生成任务 A-\(tid) 的知识总结（\(entry.kbLabel)），后台将自动精炼并同步 Markdown。\n", changed: true)
    }

    static func parseKnowledgeRefs(_ raws: [String], _ command: String, flag: String) throws -> [KnowledgeRef] {
        var out: [KnowledgeRef] = []
        for raw in raws {
            guard let parsed = KnowledgeRef.parseList(raw), !parsed.isEmpty else {
                throw CLIError.usage("\(flag) 应填任务号或知识号（如 A-12,K-3）：\(raw)", command: command)
            }
            for r in parsed where !out.contains(r) { out.append(r) }
        }
        return out
    }
}

extension Views {
    static func knowledgeList(_ views: [KnowledgeView], header: String) -> String {
        guard !views.isEmpty else { return "\(header)：没有匹配的经验记录。\n" }
        var s = "\(header)（\(views.count) 条，详情运行 tfa kb show <编号>）：\n"
        for v in views {
            let e = v.entry
            var badges: [String] = []
            if e.pinned { badges.append("置顶") }
            if !e.scope.isEmpty { badges.append(e.projectName) }
            if !e.tags.isEmpty { badges.append(e.tags.prefix(3).map { "#\($0)" }.joined(separator: " ")) }
            if !v.derivedTasks.isEmpty { badges.append("关联 \(v.derivedTasks.count) 次") }
            let meta = badges.isEmpty ? "" : " [" + badges.joined(separator: " · ") + "]"
            s += "- \(e.displayLabel)「\(e.title)」\(meta)\n"
            if !e.tldr.isEmpty { s += "  结论：\(clip(e.tldr, 140))\n" }
            if let pit = e.pitfalls.first { s += "  避坑：\(clip(pit, 120))\n" }
        }
        return s
    }

    static func knowledgeDetail(_ v: KnowledgeView) -> String {
        let e = v.entry
        var s = "\(e.displayLabel)「\(e.title)」"
        if e.taskID != nil { s += "（知识号 \(e.kbLabel)）" }
        if e.pinned { s += " [置顶常驻]" }
        s += "\n"
        s += "范围：\(e.scope.isEmpty ? "通用" : e.scope)\n"
        if !e.tags.isEmpty { s += "标签：" + e.tags.map { "#\($0)" }.joined(separator: " ") + "\n" }
        if !e.mdPath.isEmpty { s += "文档：\(e.mdPath)\n" }

        if !e.tldr.isEmpty { s += "\n【一句话结论】\n\(e.tldr)\n" }
        if !e.outcomes.isEmpty {
            s += "\n【交付要点】\n" + e.outcomes.map { "- \($0)\n" }.joined()
        }
        if !e.pitfalls.isEmpty {
            s += "\n【踩坑与关键决策】\n" + e.pitfalls.map { "- \($0)\n" }.joined()
        }
        if !e.files.isEmpty {
            s += "\n【关键文件与产物】\n" + e.files.map { "- \($0)\n" }.joined()
        }
        if !v.derivedTasks.isEmpty {
            s += "\n【后续关联任务】\n" + v.derivedTasks.map { "- \($0.label)「\($0.title)」（\($0.status.label)）\n" }.joined()
        }
        return s
    }
}
