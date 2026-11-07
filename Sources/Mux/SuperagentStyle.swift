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

    /// 清单项的状态词：待做 / 工作中 / 完成 / 受阻 / 排队 / 待你 / 待分配。`attention` = 该用琥珀（待你、受阻）。
    func statusWord(_ item: Item) -> (text: String, attention: Bool) {
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

    /// 需要你条的正文：阶段名加粗 + 问题原文 / 回报摘要（一句）。
    var needLine: (title: String, body: String)? {
        guard let need = needsYou.first else { return nil }
        let t = ticket(needing: need)
        let who = t.map { "工单 #\($0.id)" } ?? ""
        switch need {
        case .answer: return (need.label, t?.ticket.attention.map { "\(who) 问：\($0)" } ?? "")
        case .review:
            if let s = reviewSummary, !s.isEmpty { return (need.label, s) }
            if let t { return (need.label, "\(who) 已就绪" + (t.ticket.reportSummary.isEmpty ? "" : "：\(t.ticket.reportSummary)")) }
            return (need.label, "清单项都完成了，等你通过或打回")
        case .blocked:
            if let t { return (need.label, "\(who) 受阻" + (t.ticket.reportSummary.isEmpty ? "" : "：\(t.ticket.reportSummary)")) }
            let ords = items.filter { $0.status == .blocked }.map(\.ord)
            return (need.label, ords.isEmpty ? "有清单项受阻" : "\(WorklistText.ords(ords))受阻，没有工单在做")
        case .failed: return (need.label, t.map { "\(who) 失败" + ($0.ticket.reportSummary.isEmpty ? "" : "：\($0.ticket.reportSummary)") } ?? "")
        case .delivery: return (need.label, t.flatMap { $0.ticket.deliveryError }.map { "\(who)：\($0)" } ?? "")
        case .stalled: return (need.label, "\(who) 停下了，没有回报")
        }
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

/// 工单号 chip：等宽、Cream；给了 `action` 就可点（跳到执行终端）。
struct TicketChip: View {
    let id: Int64
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }.buttonStyle(.plain).help("前往工单 #\(id) 的终端")
                    .accessibilityLabel("工单 #\(id)，前往终端")
            } else {
                label.accessibilityLabel("工单 #\(id)")
            }
        }
    }

    private var label: some View {
        Text("#\(id)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
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
        .background(Theme.Colors.linen.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)
    }
}

/// 分区标题后的计数胶囊：需要你 = amber 底象牙字，其余 Linen 底 stone 字。
struct CountBadge: View {
    let count: Int
    var attention = false

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(attention ? Theme.canvas : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(attention ? Theme.Status.attention : Theme.border, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
    }
}

/// 清单项勾选框 22pt、圆角 6：完成 = Charcoal 填充 + 象牙勾；工作中 = 半圆（静态，注意事项 F-19）；
/// 待做 = Cool Stone 描边；受阻 = amber 描边 + 手掌。只画形状，可不可点由调用方决定。
struct ItemCheckbox: View {
    let status: ItemStatus
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(status == .done ? Theme.brand : Theme.surface)
            RoundedRectangle(cornerRadius: 6).stroke(stroke, lineWidth: status == .done ? 0 : 1)
            switch status {
            case .done:
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.canvas)
            case .doing:
                ZStack {
                    Circle().stroke(Theme.brand, lineWidth: 1.5)
                    Circle().trim(from: 0.25, to: 0.75).fill(Theme.brand)
                }
                .frame(width: size * 0.5, height: size * 0.5)
            case .blocked:
                Image(systemName: "hand.raised").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.Status.attention)
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
