import SwiftUI
import SuperagentCore

// 工单阶段的视觉语言：沿用 DESIGN.md §6 的状态色——等人 = 琥珀（失败 / 送达失败 = 砖红），
// 工作中 = 墨色，排队 / 空闲 / 已结束 = 石灰；颜色只表达「需要你看」。

extension Stage {
    var tint: Color {
        switch self {
        case .person(.failed), .person(.delivery): return Theme.Status.error
        case .person: return Theme.Status.attention
        case .working(let queued): return queued ? Theme.Status.neutral : Theme.Status.active
        case .idle: return Theme.Status.neutral
        case .ended(.done): return Theme.Status.positive
        case .ended: return Theme.Status.neutral
        }
    }

    var symbol: String {
        switch self {
        case .person(.answer): return "questionmark.bubble"
        case .person(.review): return "checkmark.seal"
        case .person(.blocked): return "hand.raised"
        case .person(.failed): return "xmark.octagon"
        case .person(.delivery): return "exclamationmark.triangle"
        case .person(.stalled): return "pause.circle"
        case .working(let queued): return queued ? "clock" : "hammer"
        case .idle: return "moon.zzz"
        case .ended(.done): return "checkmark.circle"
        case .ended: return "minus.circle"
        }
    }
}

/// 人对一个工单要写的话：打回意见 / 回答问题 / 补充。
enum TicketFeedbackKind: String, Identifiable {
    case reject, answer, add
    var id: String { rawValue }

    var title: String {
        switch self {
        case .reject: return "打回"
        case .answer: return "回答"
        case .add: return "补充"
        }
    }

    /// 这个阶段默认该写哪种话。
    static func `default`(for stage: Stage) -> TicketFeedbackKind {
        switch stage {
        case .person(.review): return .reject
        case .person(.answer): return .answer
        default: return .add
        }
    }
}

/// 待人写的跟进（工单 + 哪种），驱动 `TicketFeedbackSheet`。
struct TicketFeedbackRequest: Identifiable, Equatable {
    let ticketID: Int64
    let kind: TicketFeedbackKind
    var id: String { "\(ticketID)-\(kind.rawValue)" }
}

/// 任务层的跟进：打回任务（意见送给原工单，没有工单时成为新清单项）。
struct TaskFeedbackRequest: Identifiable, Equatable {
    let taskID: Int64
    var id: Int64 { taskID }
}

extension StageKind {
    var label: String {
        switch self {
        case .todo: return "待领取"
        case .doing: return "进行中"
        case .review: return "待评审"
        case .done: return "完成"
        }
    }
}

// MARK: - 工作清单的读法（清单行、任务卡、谁来做共用；注意事项 F-20：状态词固定）

extension TaskView {
    /// 行 / 卡右上的状态标签：需要你 → 第一件事（着色，失败 / 送达失败砖红）；其余不着色（注意事项 A-04）。
    var stateTag: (text: String, tint: Color) {
        switch task.status {
        case .done: return ("已完成", Theme.Status.positive)
        case .cancelled: return ("已取消", Theme.Status.neutral)
        case .dropped: return ("已放弃", Theme.Status.neutral)
        case .open: break
        }
        if task.syncState == "claimable" { return ("待领取", Theme.Status.neutral) } // 组织的待领取（第 3 期）：还不是你的任务
        if let need = needsYou.first {
            return (need.label, need == .failed || need == .delivery ? Theme.Status.error : Theme.Status.attention)
        }
        if reviewing { return ("评审中", Theme.Status.neutral) }
        if unassignedCount > 0 { return ("待分配", Theme.Status.neutral) }
        return (task.stage, Theme.Status.neutral)
    }

    /// 某件需要你的事对应的打开工单；任务层的「待评审」（阶段 kind == review）和无工单的受阻没有工单。
    func ticket(needing a: PersonAction) -> TicketView? {
        tickets.first { $0.ticket.isOpen && $0.stage.needsPerson == a }
    }

    /// 清单项的状态词：待做 / 工作中 / 完成 / 受阻 / 排队 / 待你 / 待分配；链接项（退回成新任务，4C）写「→ A-13 · 待分配 / 进行中」，
    /// 状态跟随 A-13。`attention` = 该用琥珀（待你、受阻）。
    func statusWord(_ item: Item) -> (text: String, attention: Bool) {
        if let l = linked[item.ord] { return ("→ A-\(l.link.toTaskID) · \(l.state == .unassigned ? "待分配" : "进行中")", false) }
        switch item.status {
        case .done: return ("完成", false)
        case .doing: return ("工作中", false)
        case .blocked: return ("受阻", true)
        case .todo:
            switch item.assignee {
            case .unassigned: return ("待分配", false)
            case .you: return ("待做", false) // 琥珀只给「需要你」：每个没勾的自己项不算（A-04）
            case .agent:
                if let id = item.ticketID, let t = ticket(id), t.stage == .working(queued: true) { return ("排队", false) }
                return ("待做", false)
            }
        }
    }

    /// 名下打开工单的终端（取消任务会中断它们；注意事项 F-21）。
    var openSessions: [String] {
        var seen: [String] = []
        for t in tickets where t.ticket.isOpen && !t.ticket.session.isEmpty && !seen.contains(t.ticket.session) { seen.append(t.ticket.session) }
        return seen
    }

    /// 需要你条的正文：阶段名加粗 + 一句话。工单的回报固定前缀「工单 #12 回报：」（设计评审 2026-11-08，Pass 3）：
    /// 「通过：…」不再紧挨着「通过」按钮被读成已通过。
    var needLine: (title: String, body: String)? { needLine(handbackTarget: nil) }

    /// `handbackTarget` = 受阻的那一项退回成的新任务（有退回时传）：它还没定谁来做就写「等你定谁来做」，否则写它的状态。
    func needLine(handbackTarget: TaskView?) -> (title: String, body: String)? {
        guard let need = needsYou.first else { return nil }
        let t = ticket(needing: need)
        let who = t.map { "工单 #\($0.id)" } ?? ""
        func report(_ summary: String, or fallback: String) -> String { "\(who) 回报：" + (summary.isEmpty ? fallback : summary) }
        switch need {
        case .answer: return (need.label, t?.ticket.attention.map { "\(who) 问：\($0)" } ?? "")
        case .review:
            if let s = reviewSummary, !s.isEmpty {
                let reviewer = tickets.last { $0.ticket.reviewOf != nil && $0.ticket.status == .done }
                return (need.label, (reviewer.map { "工单 #\($0.id) 回报：" } ?? "评审回报：") + s)
            }
            if let t { return (need.label, report(t.ticket.reportSummary, or: "已就绪")) }
            return (need.label, "清单项都完成了，等你完成任务或打回")
        case .blocked:
            if let c = syncConflicts.first { // 组织同步冲突（第 3 期）：两边改成不同状态，人定一边
                return ("同步冲突", c.line + (syncConflicts.count > 1 ? "（还有 \(syncConflicts.count - 1) 处）" : ""))
            }
            if let link = handbackNeed { // 退回（4A）：指向新任务，人知道下一步点哪里
                let state = handbackTarget.map { $0.unassignedCount > 0 ? "等你定谁来做" : $0.stateTag.text } ?? "等你定谁来做"
                return (need.label, "工单 #\(link.ticketID) 退回了一件事 → 已成为任务 A-\(link.toTaskID)，\(state)")
            }
            if let t { return (need.label, report(t.ticket.reportSummary, or: "受阻")) }
            let ords = items.filter { $0.status == .blocked }.map(\.ord)
            return (need.label, ords.isEmpty ? "有清单项受阻" : "\(WorklistText.ords(ords))受阻，没有工单在做")
        case .failed: return (need.label, t.map { report($0.ticket.reportSummary, or: "失败") } ?? "")
        case .delivery: return (need.label, t.flatMap { $0.ticket.deliveryError }.map { "\(who)：\($0)" } ?? "")
        case .stalled: return (need.label, "\(who) 停下了，没有回报")
        }
    }

    /// 退回（4A / 4C）：第一件需要你的事是受阻，而它来自一个链接项——新任务还没人做 → 条改说退回、指向新任务。
    /// 有打开的工单正报着受阻（它剩下的项）时条先说它的回报——补充 / 重试在那里；链接项在清单里仍写「→ A-13」。
    var handbackNeed: HandbackLink? {
        guard needsYou.first == .blocked, syncConflicts.isEmpty, ticket(needing: .blocked) == nil else { return nil }
        for i in items { if let l = linked[i.ord], l.state == .unassigned { return l.link } }
        return nil
    }

    /// 这一项是不是链接项、指向哪个任务（4C）：退回成了新任务、新任务还开着、没被人改派走。做完的、新任务已结束的都不算。
    func handback(of item: Item) -> HandbackLink? {
        linked[item.ord]?.link
    }

    /// 头卡的元信息一行（设计评审 2026-11-08，Pass 4）：「来源 主管 · 范围 payment-service · 负责人 你 · 截止 周四 · 优先级 高」。
    /// 可点的（依赖、组织 T-128、退回来源）另做 chip，不在这行；触发器 id（t88040）不上卡，进决定记录。
    /// `includeScope`：能编辑的卡把目录画成可点的「范围」chip（`scopeChip`），这一行就不再写它。
    func metaLine(now: Date = Date(), includeScope: Bool = true) -> String {
        var parts: [String] = []
        switch task.source {
        case .org: break // 有可点的 chip
        case .handback where handbackOrigin != nil: break // 同上；没绑定原任务的退回没有 chip，这行写来源
        default: parts.append("来源 \(task.source.label)")
        }
        if includeScope, !task.scope.isEmpty { parts.append("范围 \(WorklistSections.projectName(task.scope))") }
        parts.append("负责人 \(task.owner)")
        if let due = task.due { parts.append("截止 \(DueText.long(due, now: now))") }
        if task.priority != .medium { parts.append("优先级 \(task.priority.label)") }
        return parts.joined(separator: " · ")
    }

    /// 任务卡页头的状态行（设计评审 2026-11-08，Pass 1；替掉那句说明）：「更新于 刚刚 · 工单 #12 · 分支 tfa/12」，
    /// 结束态前缀「已完成 · 」。只列打开的工单和它们的分支。
    /// 任务卡上可点的目录 chip：没填是淡色的「范围…」，填了是「范围 · myclaw」。
    static func scopeChip(_ scope: String) -> String {
        scope.isEmpty ? "范围…" : "范围 · \(WorklistSections.projectName(scope))"
    }

    func headerStatus(now: Date = Date()) -> String {
        var parts: [String] = []
        if !task.isOpen { parts.append(task.status.label) }
        parts.append("更新于 \(WorklistText.ago(task.updatedAt, now: now))")
        let open = tickets.filter { $0.ticket.isOpen }
        if !open.isEmpty { parts.append("工单 " + open.map { "#\($0.id)" }.joined(separator: "、")) }
        var branches: [String] = []
        for b in open.map(\.ticket.branch) where !b.isEmpty && !branches.contains(b) { branches.append(b) }
        if !branches.isEmpty { parts.append("分支 " + branches.joined(separator: "、")) }
        return parts.joined(separator: " · ")
    }
}

/// 清单项编号的说法：「第 1–3 项」「第 1、3 项」「第 5 项」（谁来做的预告、工单条的任务 chip 都用它）。
enum WorklistText {
    static func ords(_ ords: [Int]) -> String {
        let sorted = Array(Set(ords)).sorted()
        guard !sorted.isEmpty else { return "" }
        var runs: [(Int, Int)] = []
        for o in sorted {
            if let last = runs.last, last.1 == o - 1 { runs[runs.count - 1].1 = o } else { runs.append((o, o)) }
        }
        let parts = runs.map { $0.0 == $0.1 ? "\($0.0)" : "\($0.0)–\($0.1)" }
        return "第 " + parts.joined(separator: "、") + " 项"
    }

    /// 顶部一行：「今天打扰你 2 / 8 次」；超预算只多说一句「超了」，不压制、不着琥珀（注意事项 G-03 / A-04）。
    static func interruptions(used: Int, budget: Int) -> String {
        "今天打扰你 \(used) / \(budget) 次" + (used > budget ? " · 超了" : "")
    }

    /// 观察记录顶上的一行：「研判准确率：判断正确 2 / 标过 3 · 还有 1 条没标」。
    static func accuracy(correct: Int, annotated: Int, pending: Int) -> String {
        let head = annotated == 0 ? "研判准确率：还没标过" : "研判准确率：判断正确 \(correct) / 标过 \(annotated)"
        return pending == 0 ? head : head + " · 还有 \(pending) 条没标"
    }

    /// 任务卡的依赖 chip：「依赖 · A-10 ✓、A-11」；没有依赖时「依赖…」。
    static func deps(_ deps: [Int64], done: (Int64) -> Bool) -> String {
        guard !deps.isEmpty else { return "依赖…" }
        return "依赖 · " + deps.map { "A-\($0)" + (done($0) ? " ✓" : "") }.joined(separator: "、")
    }

    /// 定时任务到点后谁来做（`Schedule.assignee`）：空 = 待分配。
    static func scheduleAssignee(_ raw: String) -> String {
        raw.isEmpty ? "待分配" : raw
    }

    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f }()

    /// 相对时间（页头状态行）：「刚刚」「3 分钟前」「2 小时前」，更早显示「M月d日 HH:mm」。
    static func ago(_ t: Double, now: Date = Date()) -> String {
        let d = now.timeIntervalSince1970 - t
        if d < 60 { return "刚刚" }
        if d < 3600 { return "\(Int(d / 60)) 分钟前" }
        if d < 86400 { return "\(Int(d / 3600)) 小时前" }
        return day.string(from: Date(timeIntervalSince1970: t))
    }
}

/// 观察记录（需求文档第 2 期）：研判过的决定——接单 / 本会接单 / 不接，且来自候选；最新在前。
/// 人明确提的请求由主管直接接单，决定没有原因，不是研判，不列（它的准确率没有意义）。
enum ObservationLog {
    static func rows(_ decisions: [Decision], limit: Int = 10) -> [Decision] {
        Array(decisions.filter {
            $0.triggerID != nil && [.accept, .wouldAccept, .ignore].contains($0.kind) && !($0.kind == .accept && $0.reason.isEmpty)
        }.sorted { $0.id > $1.id }.prefix(limit))
    }
}

// MARK: - 工作清单的小组件（DESIGN.md §9：执行者 chip、工单号 chip、任务 chip、计数胶囊、勾选框）

/// 执行者 chip：22pt · Cream · 圆角 6 · 11pt；「你」= Charcoal 1pt 描边，角色 = Linen 描边，未定 = stone 字。
struct AssigneeChip: View {
    let assignee: Assignee

    var body: some View {
        Text(assignee.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(assignee == .unassigned ? Theme.textTertiary : Theme.textPrimary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(assignee == .you ? Theme.brand : Theme.border, lineWidth: 1))
            .accessibilityLabel(assignee.spoken)
    }
}

extension Assignee {
    /// VoiceOver 里的说法：「你」「Agent · 开发」「未定」。
    var spoken: String {
        switch self {
        case .unassigned: return "未定"
        case .you: return "你"
        case .agent(let role): return "Agent · \(role)"
        }
    }
}

/// 「任务 A-12 · 第 1–3 项」chip（执行终端的工单条用，注意事项 F-11）：clipboard 图标 + 等宽编号；点了打开任务卡。
struct TaskChip: View {
    let label: String
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "list.bullet.clipboard").font(.system(size: 10))
                Text("任务 \(label)").font(.system(size: 11, design: .monospaced))
                if let detail, !detail.isEmpty { Text("· \(detail)").font(.system(size: 11)) }
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("打开任务 \(label)")
        .accessibilityLabel("任务 \(label)，打开任务卡")
    }
}

/// 紧凑的分段控件（谁来做：你 / 各角色）：Linen 井、`md` 圆角，选中段 White 浮起 + 1pt Linen 环——同侧栏的 在线 / 已断开。
/// 不随容器拉宽；stock 的 segmented Picker 在这里会和 DESIGN.md 的井差一截。
struct SegmentedChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var disabled = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: 7).fill(Theme.surface)
                                RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)
    }
}

/// 分区标题后的计数胶囊：需要你 = amber 底亮色字，其余柔和底色。
struct CountBadge: View {
    let count: Int
    var attention = false

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(attention ? Color.white : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(attention ? Theme.Status.attention : Theme.surface2, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
    }
}

/// 清单项勾选框 20pt、圆角 6：完成 = 品牌填充 + 对勾；工作中 = 半圆（静态，注意事项 F-19）；
/// 待做 = 描边；受阻 = amber 描边 + 手掌。只画形状，可不可点由调用方决定。
struct ItemCheckbox: View {
    let status: ItemStatus
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(status == .done ? Theme.brand : Theme.surface)
            RoundedRectangle(cornerRadius: 5).stroke(stroke, lineWidth: status == .done ? 0 : 1)
            switch status {
            case .done:
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onBrand)
            case .doing:
                ZStack {
                    Circle().stroke(Theme.brand, lineWidth: 1.5)
                    Circle().trim(from: 0.25, to: 0.75).fill(Theme.brand)
                }
                .frame(width: size * 0.5, height: size * 0.5)
            case .blocked:
                Image(systemName: "hand.raised").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.Status.attention)
            case .todo:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var stroke: Color {
        switch status {
        case .blocked: return Theme.Status.attention
        case .done: return .clear
        case .doing, .todo: return Theme.borderStrong
        }
    }
}
