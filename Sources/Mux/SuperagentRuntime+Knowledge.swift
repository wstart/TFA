import Foundation
import SuperagentCore

// 知识库在 App 运行时的后台精炼、Markdown 镜像落盘与界面交互动作（与 2s Pass 循环解耦，不阻塞工单调度）。
extension SuperagentRuntime {
    /// 当前生效的本地 Markdown 知识库目录（默认 `~/.tfa/knowledge`，也可在设置里指向 Obsidian 子目录）。
    var knowledgeBaseDir: URL {
        let custom = settings.knowledgeSyncDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !custom.isEmpty else { return SuperagentPaths.knowledgeDir }
        return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
    }

    func startKnowledgeWorker() {
        kickKnowledge()
        knowledgeLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.knowledgePass()
            }
        }
    }

    func kickKnowledge() {
        guard engine != nil, !knowledgeBusy else { return }
        Task { @MainActor [weak self] in
            await self?.knowledgePass()
        }
    }

    /// 一轮知识库同步与 AI 提炼：
    /// 1. 把新增/更新的知识卡写成干净的 `.md` 镜像文件；
    /// 2. 对 `needsRefine == true` 的已完成任务，异步调用 `ModelBackend` 生成高信噪比结构化总结并回写数据库 + 刷新 `.md`。
    func knowledgePass() async {
        guard let engine, !knowledgeBusy else { return }
        knowledgeBusy = true
        defer {
            knowledgeBusy = false
            knowledgeRefining = false
        }

        // 1. 同步未落盘或有更新的 Markdown 文件
        await syncPendingMarkdown(engine: engine)

        // 2. 异步调用模型提炼待精炼条目（每次最多 3 条，避免占用过久）
        let pending = (try? engine.store.pendingRefineKnowledge(limit: 3)) ?? []
        guard !pending.isEmpty else { return }
        knowledgeRefining = true
        let backend = modelBackend ?? ModelBackends.make(settings)
        var refinedAny = false

        for entry in pending {
            if Task.isCancelled { break }
            guard let tid = entry.taskID, let task = try? engine.store.task(tid) else {
                try? engine.markKnowledgeRefineFailed(id: entry.id, error: "无关联任务")
                continue
            }
            let items = (try? engine.store.items(tid)) ?? []
            let tickets = (try? engine.store.tickets(task: tid)) ?? []
            let events = (try? engine.store.events(taskID: tid, limit: 50)) ?? []
            let gitFiles = await Self.collectGitChangedFiles(scope: task.scope, tickets: tickets)
            let prompt = SuperagentEngine.knowledgeRefinePrompt(task: task, items: items, tickets: tickets,
                                                                events: events, gitFiles: gitFiles)
            do {
                let raw = try await backend.complete(system: prompt.system, user: prompt.user)
                let draft = try SuperagentEngine.parseRefinedKnowledge(raw, fallbackScope: task.scope, fallbackTitle: task.title)
                if (try engine.applyRefinedKnowledge(id: entry.id, draft: draft, extraFiles: gitFiles)) != nil {
                    mdSyncedStamp[entry.id] = nil
                    refinedAny = true
                }
            } catch {
                try? engine.markKnowledgeRefineFailed(id: entry.id, error: "\(error)")
                refinedAny = true
            }
        }

        if refinedAny {
            await syncPendingMarkdown(engine: engine)
            reload()
        }
    }

    private func syncPendingMarkdown(engine: SuperagentEngine) async {
        let baseDir = knowledgeBaseDir
        let currentViews = (try? engine.knowledgeViews(includeArchived: true, limit: 500)) ?? []
        let unsynced = currentViews.filter { v in
            let e = v.entry
            if e.archived { return !e.mdPath.isEmpty }
            return mdSyncedStamp[e.id] != e.updatedAt || e.mdPath.isEmpty
        }
        guard !unsynced.isEmpty else { return }
        let updates = await Task.detached(priority: .utility) { () -> [(id: Int64, updatedAt: Double, mdPath: String, oldPath: String)] in
            var out: [(Int64, Double, String, String)] = []
            for v in unsynced {
                let path = KnowledgeMarkdown.sync(v.entry, derived: v.derivedTasks, baseDir: baseDir)
                out.append((v.entry.id, v.entry.updatedAt, path, v.entry.mdPath))
            }
            return out
        }.value

        var pathChanged = false
        for u in updates {
            mdSyncedStamp[u.id] = u.updatedAt
            if u.mdPath != u.oldPath {
                try? engine.store.updateKnowledgeMDPath(id: u.id, mdPath: u.mdPath)
                pathChanged = true
            }
        }
        if pathChanged { reload() }
    }

    /// 从仓库 git 记录提取该任务下开发工单分支涉及的改动文件名（即使已合并进 main，只要分支名或 merge commit 在也能尽量提取）。
    nonisolated static func collectGitChangedFiles(scope: String, tickets: [Ticket]) async -> [String] {
        guard !scope.isEmpty else { return [] }
        let branches = tickets.filter { $0.reviewOf == nil && !$0.branch.isEmpty }.map(\.branch)
        guard !branches.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            var files: [String] = []
            for branch in branches {
                let r = SuperagentTmux.exec("/usr/bin/git", ["-C", scope, "log", "-n", "5", "--name-only", "--pretty=format:", branch])
                guard r.status == 0 else { continue }
                for rawLine in r.out.split(separator: "\n") {
                    let f = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !f.isEmpty, !files.contains(f) {
                        files.append(f)
                        if files.count >= 25 { return files }
                    }
                }
            }
            return files
        }.value
    }

    // MARK: - 界面交互方法

    /// 对单个任务生成或重新提炼总结。
    func summarizeTask(_ taskID: Int64, force: Bool = false) {
        if act(task: taskID, { _ = try $0.summarizeTask(taskID, aiRefine: true, force: force) }) {
            noteEcho(taskID, force ? "正在重新提炼任务总结…" : "已生成任务总结")
            kickKnowledge()
        }
    }

    /// 批量补齐所有尚未入库的历史已完成任务总结。
    func backfillCompletedTasks(aiRefine: Bool = true) {
        var count = 0
        if act({ count = try $0.backfillCompletedTasks(aiRefine: aiRefine).count }), count > 0 {
            kickKnowledge()
        }
    }

    @discardableResult
    func saveKnowledge(id: Int64? = nil, draft: KnowledgeDraft) -> KnowledgeEntry? {
        var saved: KnowledgeEntry?
        if act({ saved = try $0.saveKnowledge(id: id, draft: draft) }) {
            if let s = saved { mdSyncedStamp[s.id] = nil }
            kickKnowledge()
        }
        return saved
    }

    func setKnowledgePinned(_ id: Int64, pinned: Bool) {
        if act({ try $0.setKnowledgePinned(id, pinned: pinned) }) {
            mdSyncedStamp[id] = nil
            kickKnowledge()
        }
    }

    func setKnowledgeArchived(_ id: Int64, archived: Bool) {
        if act({ try $0.setKnowledgeArchived(id, archived: archived) }) {
            mdSyncedStamp[id] = nil
            kickKnowledge()
        }
    }

    func refineKnowledge(_ id: Int64) {
        if act({ try $0.requestKnowledgeRefine(id) }) {
            kickKnowledge()
        }
    }

    func setTaskKnowledgeLinks(_ taskID: Int64, knowledgeIDs: [Int64]) {
        if act(task: taskID, { try $0.setTaskKnowledgeLinks(taskID, knowledgeIDs: knowledgeIDs) }) {
            noteEcho(taskID, knowledgeIDs.isEmpty ? "已清空关联经验" : "已更新关联经验（\(knowledgeIDs.count) 条）")
        }
    }

    func addTaskKnowledgeLink(_ taskID: Int64, ref: KnowledgeRef) {
        if act(task: taskID, { _ = try $0.updateTaskKnowledgeLinks(taskID, refs: [ref], remove: false) }) {
            noteEcho(taskID, "已关联 \(ref.label)")
        }
    }

    func removeTaskKnowledgeLink(_ taskID: Int64, knowledgeID: Int64) {
        guard let engine else { return }
        if act(task: taskID, {
            if let entry = try engine.store.knowledgeEntry(id: knowledgeID) {
                _ = try $0.updateTaskKnowledgeLinks(taskID, refs: [.knowledge(entry.id)], remove: true)
            }
        }) {
            noteEcho(taskID, "已移除关联")
        }
    }

    /// 新建任务弹窗的实时经验推荐：按标题 + 原文 + 项目范围返回最相关的历史知识卡。
    func suggestKnowledge(title: String, request: String, scope: String, excludingTask: Int64? = nil, limit: Int = 3) -> [KnowledgeEntry] {
        guard let engine else { return [] }
        let combined = [title, String(request.prefix(200))].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.isEmpty {
            guard !scope.isEmpty else { return [] }
            return ((try? engine.store.knowledgeEntries(includeArchived: false, scope: scope, limit: limit)) ?? [])
                .filter { $0.taskID != excludingTask }
        }
        return ((try? engine.store.searchKnowledge(query: combined, preferredScope: scope, limit: limit + 2)) ?? [])
            .filter { $0.taskID != excludingTask }
            .prefix(limit)
            .map { $0 }
    }
}
