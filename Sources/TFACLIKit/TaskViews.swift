import Foundation
import SuperagentCore

/// 工作清单的文本视图：`tfa read` 最前面的任务段、`tfa task list / show`、`tfa read ticket` 里的所属任务。
/// 清单项编号三处同源：都从 `Item.line` 来（注意事项 E-04）。
extension Views {
    /// 一个任务在清单里的分区（§9.1）：需要你 → 进行中 → 待分配（有未分配的项）；已结束另算。
    /// 组织的待领取（第 3 期，`syncState == "claimable"`）还不是你的任务：不进任务段的计数，`task list` 单独一组。
    enum Bucket { case needsYou, doing, unassigned, claimable, ended }

    static func bucket(_ v: TaskView) -> Bucket {
        if !v.task.isOpen { return .ended }
        if v.task.syncState == "claimable" { return .claimable }
        if !v.needsYou.isEmpty { return .needsYou }
        if v.unassignedCount > 0 { return .unassigned }
        return .doing
    }

    /// `A-12 [待评审] 标题 · 3/5 · 开发、你`（注意事项 E-05）：方括号里是需要你的事、「待分配」、阶段名或结束状态。
    static func taskLine(_ v: TaskView) -> String {
        let t = v.task
        let tag: String
        switch bucket(v) {
        case .needsYou: tag = v.firstNeed!.label
        case .unassigned: tag = "待分配"
        case .claimable: tag = "待领取"
        case .doing: tag = t.stage
        case .ended: tag = t.status.label
        }
        let who = v.assignees.isEmpty ? "未定" : v.assignees.map(\.label).joined(separator: "、")
        var s = "\(t.label) [\(tag)] \(t.title) · \(v.doneCount)/\(v.totalCount) · \(who)"
        if v.reviewing { s += " · 自动评审中" }
        if !t.scope.isEmpty { s += " · \(t.scope)" }
        if let o = v.handbackOrigin { s += " · \(origin(o))" }
        if let q = v.tickets.first(where: { $0.ticket.isOpen && $0.ticket.attention != nil })?.ticket.attention { s += " · 问：\(clip(q, 80))" }
        return s
    }

    /// 退回产生的任务的来源（设计评审 2026-11-08，4A）：`来自 A-12 的退回（工单 #13）`。
    static func origin(_ o: HandbackLink) -> String { "来自 A-\(o.fromTaskID) 的退回（工单 #\(o.ticketID)）" }

    /// `任务（需要你 N / 进行中 M / 待分配 K）：` + 每个打开的任务一行；没有打开的任务 → nil。
    static func taskSummary(_ views: [TaskView]) -> String? {
        let open = views.filter { $0.task.isOpen && bucket($0) != .claimable }
        guard !open.isEmpty else { return nil }
        let needs = open.filter { bucket($0) == .needsYou }.sorted { ($0.firstNeed!, $0.id) < ($1.firstNeed!, $1.id) }
        let doing = open.filter { bucket($0) == .doing }.sorted { $0.id < $1.id }
        let unassigned = open.filter { bucket($0) == .unassigned }.sorted { $0.id < $1.id }
        return "任务（需要你 \(needs.count) / 进行中 \(doing.count) / 待分配 \(unassigned.count)）：\n"
            + (needs + doing + unassigned).map { taskLine($0) + "\n" }.joined()
    }

    static func tasks(_ engine: SuperagentEngine, needsYou: Bool, scope: String?, stage: String?) throws -> String {
        var views = try engine.taskViews(endedLimit: needsYou ? 0 : 10)
        if let scope { views = views.filter { $0.task.scope == scope } }
        if let stage { views = views.filter { $0.task.stage == stage || $0.task.stageKind.rawValue == stage } }
        if needsYou {
            let needs = views.filter { bucket($0) == .needsYou }.sorted { ($0.firstNeed!, $0.id) < ($1.firstNeed!, $1.id) }
            guard !needs.isEmpty else { return "没有需要你的任务。\n" }
            return "需要你的任务（\(needs.count)）：\n" + needs.map { taskLine($0) + "\n" }.joined()
        }
        var s = taskSummary(views) ?? "没有打开的任务。\n"
        let claimable = views.filter { bucket($0) == .claimable }.sorted { $0.id < $1.id }
        if !claimable.isEmpty { s += "组织的待领取（\(claimable.count)，领了才是你的）：\n" + claimable.map { taskLine($0) + "\n" }.joined() }
        let ended = views.filter { bucket($0) == .ended }
        if !ended.isEmpty { s += "最近结束（\(ended.count)）：\n" + ended.map { taskLine($0) + "\n" }.joined() }
        return s
    }

    // MARK: - 任务详情

    static func task(_ engine: SuperagentEngine, _ id: Int64) throws -> String {
        let v = try engine.taskView(id)
        let t = v.task
        var s = "\(t.label)「\(t.title)」 \(t.isOpen ? t.stage : t.status.label)\(v.reviewing ? "（自动评审中）" : "")\n"
        var meta = [v.handbackOrigin.map(origin) ?? "来源 \(t.source.label)\(t.sourceRef.map { "（\($0)）" } ?? "")", "优先级 \(t.priority.label)"]
        if let d = t.due { meta.append("截止 \(day(d))") }
        if !t.deps.isEmpty { meta.append("依赖 " + t.deps.map { "A-\($0)" }.joined(separator: "、")) }
        if !v.relatedKnowledge.isEmpty { meta.append("关联经验 " + v.relatedKnowledge.map(\.displayLabel).joined(separator: "、")) }
        if !v.derivedTasks.isEmpty { meta.append("后续关联 " + v.derivedTasks.map(\.label).joined(separator: "、")) }
        s += meta.joined(separator: " · ") + "\n"
        s += "范围：\(t.scope.isEmpty ? "没有（不针对某个项目）" : t.scope)\n"
        s += "阶段：" + t.stages.enumerated().map { $0.offset == t.stageIndex ? "[\($0.element.name)]" : $0.element.name }.joined(separator: " → ") + "\n"
        if !v.needsYou.isEmpty { s += "需要你：" + v.needsYou.map(\.label).joined(separator: "、") + "\n" }

        s += "\n【原文】\n\(t.request)\n"
        if !t.note.isEmpty { s += "\n【路由备注】\(t.note)\n" }
        s += "\n【清单】\(v.doneCount)/\(v.totalCount)：\n" + v.items.map { itemLine($0, handbacks: v.handbacks, linked: v.linked) + "\n" }.joined()
        if !v.tickets.isEmpty {
            s += "\n【工单】\(v.tickets.count) 张：\n"
            for tv in v.tickets {
                var l = line(tv)
                let ords = v.items.filter { tv.ticket.itemIDs.contains($0.id) }.map { String($0.ord) }
                if !ords.isEmpty { l += " · 第 \(ords.joined(separator: "、")) 项" }
                if let of = tv.ticket.reviewOf { l += " · 评审 #\(of)" }
                s += l + "\n"
            }
        }
        if let r = v.reviewSummary { s += "\n【评审结论】\(r)\n" }
        if !t.resultSummary.isEmpty { s += "\n【结果】\(t.resultSummary)\n" }
        if let kb = v.knowledge {
            s += "\n【任务总结（\(kb.kbLabel)\(kb.pinned ? " · 置顶" : "")）】\n\(kb.tldr)\n"
            if !kb.pitfalls.isEmpty {
                s += "避坑与决策：" + kb.pitfalls.joined(separator: "；") + "\n"
            }
            if !kb.files.isEmpty {
                s += "关键文件：" + kb.files.joined(separator: "、") + "\n"
            }
        }
        if !v.relatedKnowledge.isEmpty {
            s += "\n【关联历史经验】\n"
            for r in v.relatedKnowledge {
                s += "- \(r.displayLabel)「\(r.title)」：\(clip(r.tldr, 140))\n"
            }
        }
        let events = try engine.store.events(taskID: id, limit: 20)
        if !events.isEmpty {
            s += "\n【活动】最近 \(events.count) 条：\n" + events.map { "\(time($0.at)) \($0.kind) \(clip($0.text, 200))\n" }.joined()
        }
        return s
    }

    /// `3. 改为分段加锁，跑回归 · 开发 · #12 · 工作中`：`Item.line` 之后是执行者、工单号、状态词；没分配的项只标「待分配」。
    /// 退回出去、在等新任务的项（4A）状态词写 `→ A-13`。
    static func itemLine(_ i: Item, handbacks: [HandbackLink] = [], linked: [Int: LinkedItem] = [:]) -> String {
        // 链接项（4C）：执行者就是它指向的任务，状态跟着它走。
        if let l = linked[i.ord] { return i.line + " · → A-\(l.link.toTaskID) · " + (l.state == .unassigned ? "待分配" : "进行中") }
        guard i.assignee != .unassigned else { return i.line + " · 待分配" }
        var s = i.line + " · " + i.assignee.label
        if let id = i.ticketID { s += " · #\(id)" }
        if i.status == .blocked, let link = handbacks.last(where: { $0.itemOrd == i.ord }) { return s + " · → A-\(link.toTaskID)" }
        return s + " · " + i.status.label
    }

    /// `tfa read ticket` 里的所属任务和这张单负责的清单项（§6）：只列 `itemIDs` 里的项，不写别人的（注意事项 D-06）。
    static func taskLines(_ engine: SuperagentEngine, _ t: Ticket, _ taskID: Int64) throws -> String {
        let taskObj = try engine.store.task(taskID)
        var s = "所属任务：A-\(taskID)" + (taskObj.map { "「\($0.title)」" } ?? "") + "\n"
        if let of = t.reviewOf { return s + "你负责的清单项：没有（这张单核对 #\(of) 的交付）\n" }
        let mine = try engine.store.items(taskID).filter { t.itemIDs.contains($0.id) }
        s += mine.isEmpty ? "你负责的清单项：没有\n" : "你负责的清单项：\n" + mine.map { $0.line + "\n" }.joined()
        if let taskObj {
            let kbBlock = try engine.knowledgeContextBlock(for: taskObj)
            if !kbBlock.isEmpty { s += kbBlock + "\n" }
        }
        return s
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func day(_ t: Double) -> String { dayFormat.string(from: Date(timeIntervalSince1970: t)) }
}
