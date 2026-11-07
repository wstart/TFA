import Foundation
import SuperagentCore

/// 工作清单的文本视图：`tfa read` 最前面的任务段、`tfa task list / show`、`tfa read ticket` 里的所属任务。
/// 清单项编号三处同源：都从 `Item.line` 来（注意事项 E-04）。
extension Views {
    /// 一个任务在清单里的分区（§9.1）：需要你 → 进行中 → 待分配（有未分配的项）；已结束另算。
    enum Bucket { case needsYou, doing, unassigned, ended }

    static func bucket(_ v: TaskView) -> Bucket {
        if !v.task.isOpen { return .ended }
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
        case .doing: tag = t.stage
        case .ended: tag = t.status.label
        }
        let who = v.assignees.isEmpty ? "未定" : v.assignees.map(\.label).joined(separator: "、")
        var s = "\(t.label) [\(tag)] \(t.title) · \(v.doneCount)/\(v.totalCount) · \(who)"
        if v.reviewing { s += " · 自动评审中" }
        if !t.scope.isEmpty { s += " · \(t.scope)" }
        if let q = v.tickets.first(where: { $0.ticket.isOpen && $0.ticket.attention != nil })?.ticket.attention { s += " · 问：\(clip(q, 80))" }
        return s
    }

    /// `任务（需要你 N / 进行中 M / 待分配 K）：` + 每个打开的任务一行；没有打开的任务 → nil。
    static func taskSummary(_ views: [TaskView]) -> String? {
        let open = views.filter { $0.task.isOpen }
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
        let ended = views.filter { bucket($0) == .ended }
        if !ended.isEmpty { s += "最近结束（\(ended.count)）：\n" + ended.map { taskLine($0) + "\n" }.joined() }
        return s
    }

    // MARK: - 任务详情

    static func task(_ engine: SuperagentEngine, _ id: Int64) throws -> String {
        let v = try engine.taskView(id)
        let t = v.task
        var s = "\(t.label)「\(t.title)」 \(t.isOpen ? t.stage : t.status.label)\(v.reviewing ? "（自动评审中）" : "")\n"
        var meta = ["来源 \(t.source.label)\(t.sourceRef.map { "（\($0)）" } ?? "")", "优先级 \(t.priority.label)"]
        if let d = t.due { meta.append("截止 \(day(d))") }
        if !t.deps.isEmpty { meta.append("依赖 " + t.deps.map { "A-\($0)" }.joined(separator: "、")) }
        s += meta.joined(separator: " · ") + "\n"
        s += "范围：\(t.scope.isEmpty ? "没有（不针对某个项目）" : t.scope)\n"
        s += "阶段：" + t.stages.enumerated().map { $0.offset == t.stageIndex ? "[\($0.element.name)]" : $0.element.name }.joined(separator: " → ") + "\n"
        if !v.needsYou.isEmpty { s += "需要你：" + v.needsYou.map(\.label).joined(separator: "、") + "\n" }

        s += "\n【原文】\n\(t.request)\n"
        if !t.note.isEmpty { s += "\n【路由备注】\(t.note)\n" }
        s += "\n【清单】\(v.doneCount)/\(v.totalCount)：\n" + v.items.map { itemLine($0) + "\n" }.joined()
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
        let events = try engine.store.events(taskID: id, limit: 20)
        if !events.isEmpty {
            s += "\n【活动】最近 \(events.count) 条：\n" + events.map { "\(time($0.at)) \($0.kind) \(clip($0.text, 200))\n" }.joined()
        }
        return s
    }

    /// `3. 改为分段加锁，跑回归 · 开发 · #12 · 工作中`：`Item.line` 之后是执行者、工单号、状态词；没分配的项只标「待分配」。
    static func itemLine(_ i: Item) -> String {
        guard i.assignee != .unassigned else { return i.line + " · 待分配" }
        var s = i.line + " · " + i.assignee.label
        if let id = i.ticketID { s += " · #\(id)" }
        return s + " · " + i.status.label
    }

    /// `tfa read ticket` 里的所属任务和这张单负责的清单项（§6）：只列 `itemIDs` 里的项，不写别人的（注意事项 D-06）。
    static func taskLines(_ engine: SuperagentEngine, _ t: Ticket, _ taskID: Int64) throws -> String {
        var s = "所属任务：A-\(taskID)" + (try engine.store.task(taskID).map { "「\($0.title)」" } ?? "") + "\n"
        if let of = t.reviewOf { return s + "你负责的清单项：没有（这张单核对 #\(of) 的交付）\n" }
        let mine = try engine.store.items(taskID).filter { t.itemIDs.contains($0.id) }
        s += mine.isEmpty ? "你负责的清单项：没有\n" : "你负责的清单项：\n" + mine.map { $0.line + "\n" }.joined()
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
