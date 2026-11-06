import SwiftUI
import SuperagentCore

/// Under the terminal header of a ticket terminal: where the ticket stands, what it last said, and
/// the one or two actions that stage calls for (通过 / 打回 / 回答 / 重试 / 补充 / 停止).
struct TicketBar: View {
    @Environment(AppModel.self) private var appModel
    let view: TicketView
    @State private var confirmStop = false

    var body: some View {
        let t = view.ticket
        let stage = view.stage
        HStack(spacing: Theme.Space.md) {
            Image(systemName: stage.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(stage.tint)
                .frame(width: 16)
            StateTag(text: stage.label, tint: stage.tint)
            Text("#\(t.id) \(t.title)")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .layoutPriority(1)
            if !t.branch.isEmpty {
                Text(t.branch)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 4))
                    .help(t.dir)
            }
            if let line = summaryLine, !line.isEmpty {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(stage.needsPerson == .answer ? Theme.Status.attention : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(line)
            }
            Spacer(minLength: Theme.Space.md)
            actions(stage, t)
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stage.needsPerson != nil ? stage.tint.opacity(0.06) : Theme.canvas)
        .alert("停止工单 #\(t.id)？", isPresented: $confirmStop) {
            Button("停止", role: .destructive) { appModel.superagent.stop(t.id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("中断执行终端里的 agent，工单结束。终端、目录和已有改动都保留。")
        }
    }

    /// The question while it waits for an answer, else the latest report / error / confirmation.
    private var summaryLine: String? {
        let t = view.ticket
        switch view.stage {
        case .person(.answer): return t.attention
        case .person(.delivery): return t.deliveryError
        case .person, .ended: return t.reportSummary.isEmpty ? nil : t.reportSummary
        case .working, .idle: return t.ack.isEmpty ? (t.reportState == .progress ? t.reportSummary : nil) : t.ack
        }
    }

    @ViewBuilder
    private func actions(_ stage: Stage, _ t: Ticket) -> some View {
        let sa = appModel.superagent
        if let path = t.reportPath, !path.isEmpty {
            Button("报告") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                .help(path)
        }
        switch stage {
        case .person(.review):
            Button("打回…") { appModel.ticketFeedback = .init(ticketID: t.id, kind: .reject) }
            Button("通过") { sa.approve(t.id) }.buttonStyle(.borderedProminent)
        case .person(.answer):
            Button("回答…") { appModel.ticketFeedback = .init(ticketID: t.id, kind: .answer) }.buttonStyle(.borderedProminent)
        case .person(.blocked), .person(.failed), .person(.delivery), .person(.stalled), .idle:
            Button("补充…") { appModel.ticketFeedback = .init(ticketID: t.id, kind: .add) }
            Button("重试") { sa.retry(t.id) }.buttonStyle(.borderedProminent)
        case .working:
            Button("补充…") { appModel.ticketFeedback = .init(ticketID: t.id, kind: .add) }
        case .ended(let status):
            if status != .stopped {
                Button("再提要求…") { appModel.ticketFeedback = .init(ticketID: t.id, kind: .add) }
                    .help("工单会恢复，消息送到这个执行终端")
            }
        }
        if t.isOpen {
            Button { confirmStop = true } label: { Image(systemName: "stop.circle") }
                .help("停止工单")
                .accessibilityLabel("停止工单")
        }
    }
}

/// Under the header of the「主管」terminal: what this terminal is for, plus the panel.
struct RouterBar: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let sa = appModel.superagent
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.brand)
                .frame(width: 16)
            Text("在这里用自然语言提需求：主管拆成工单，派给各自的执行终端；做完或要你决定时才说话。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Space.md)
            if !sa.needsYou.isEmpty {
                StateTag(text: "\(sa.needsYou.count) 个需要你", tint: Theme.Status.attention)
            }
            Button("工单面板") { appModel.openSuperagent() }
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas)
    }
}
