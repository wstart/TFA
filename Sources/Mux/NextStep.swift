import AppKit
import SwiftUI
import SuperagentCore

// 任务卡的「下一步」横幅（设计评审 2026-11-08 定稿：C 的横幅 + A 的纸面风格）。位置固定在标题下：
// 需要你 / 等你定谁来做时是深色横幅，一句话说该做什么 + 主按钮；没事时是浅色横幅，写现在在发生什么。页面不跳。

/// 从原文和退回说明里认出项目目录：`~/…` 或 `/Users/…`，到空白或中文标点为止；只认真实存在的文件夹，家目录和根目录不算。
enum ScopeGuess {
    static func directory(in texts: [String], isDirectory: (String) -> Bool = ScopeGuess.isDirectory) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"(?:~|/Users)/[^\s，。、；：:（）()「」『』"'<>,;]*"#) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for text in texts {
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var p = ns.substring(with: m.range)
                while let last = p.last, last == "." || last == "," { p.removeLast() }
                var full = p.hasPrefix("~") ? home + String(p.dropFirst()) : p
                while full.count > 1, full.hasSuffix("/") { full.removeLast() }
                guard full != home, full != "/", isDirectory(full) else { continue }
                return full
            }
        }
        return nil
    }

    static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}

/// 横幅说什么（纯函数，可测）。
struct NextStep: Equatable {
    /// `needsYou`：有人卡住在等你（琥珀点）；`decide`：清单项还没定谁来做（石灰点，仍是深色横幅）；`quiet`：不用你管。
    enum Tone: Equatable { case needsYou, decide, quiet }

    /// 一键交给某个角色：`target` 任务的 `ords` 项交给 `role`。角色要改文件而任务还没目录时 `needsDirectory`，
    /// `directory` 是从原文里认出来的（可能没有，要人选）。
    struct QuickAssign: Equatable {
        let target: Int64
        let ords: [Int]
        let role: String
        let needsDirectory: Bool
        let directory: String?
    }

    var tone: Tone
    var eyebrow: String
    var title: String
    var body: String
    var quick: QuickAssign?
    /// 没事时可以去看 / 补充的那张工单。
    var ticket: Int64?

    static func make(_ v: TaskView, task: (Int64) -> TaskView?, roles: [Role],
                     guess: ([String]) -> String? = { ScopeGuess.directory(in: $0) }) -> NextStep {
        let t = v.task
        switch t.status {
        case .done:
            let first = t.resultSummary.split(separator: "\n").first.map(String.init) ?? ""
            return NextStep(tone: .quiet, eyebrow: "已完成", title: first.isEmpty ? "这件事做完了" : first, body: "")
        case .cancelled: return NextStep(tone: .quiet, eyebrow: "已取消", title: "任务已取消", body: "")
        case .dropped: return NextStep(tone: .quiet, eyebrow: "已放弃", title: "任务已放弃", body: "")
        case .open: break
        }

        if let need = v.needsYou.first {
            var step = NextStep(tone: .needsYou, eyebrow: "下一步 · 等你决定", title: need.label, body: "")
            switch need {
            case .answer:
                if let tk = v.ticket(needing: .answer) {
                    step.title = "回答工单 #\(tk.id) 的问题"
                    step.body = tk.ticket.attention ?? ""
                }
            case .review:
                if t.stageKind == .review {
                    step.title = "看一下交付，决定完成还是打回"
                    step.body = v.reviewSummary ?? v.tickets.last { $0.ticket.reviewOf == nil && !$0.ticket.reportSummary.isEmpty }?.ticket.reportSummary ?? ""
                } else if let tk = v.ticket(needing: .review) {
                    step.title = "工单 #\(tk.id) 交付了，决定通过还是打回"
                    step.body = tk.ticket.reportSummary
                }
            case .blocked:
                if let c = v.syncConflicts.first {
                    step.title = "同步冲突：两边把第 \(c.ord) 项改得不一样"
                    step.body = c.line
                } else if let link = v.handbackNeed {
                    step.title = "工单 #\(link.ticketID) 退回的事要换人做"
                    let reason = v.tickets.first { $0.id == link.ticketID }?.ticket.reportSummary ?? ""
                    step.body = "第 \(link.itemOrd) 项已经成了任务 A-\(link.toTaskID)，在等你定谁来做。" + (reason.isEmpty ? "" : "原因：\(reason)")
                    if let b = task(link.toTaskID), b.task.isOpen {
                        let ords = b.items.filter { $0.assignee == .unassigned && $0.status != .done }.map(\.ord)
                        // 退回多半是角色做不了（只读的助理要改文件）：先给开发。
                        let from = v.items.first { $0.ord == link.itemOrd }?.assignee.role
                        let readOnly = from.flatMap { r in roles.first { $0.name == r } }.map { !$0.edits } ?? false
                        step.quick = quickAssign(b, ords: ords, roles: roles, prefer: readOnly ? Role.developer : nil,
                                                 extra: [reason, t.request], guess: guess)
                    }
                } else if let tk = v.ticket(needing: .blocked) {
                    step.title = "工单 #\(tk.id) 卡住了，补充说明让它继续"
                    step.body = tk.ticket.reportSummary
                } else {
                    let ords = v.items.filter { $0.status == .blocked }.map(\.ord)
                    step.title = ords.isEmpty ? "有清单项受阻" : "\(WorklistText.ords(ords))受阻，没有工单在做"
                    step.body = "重新定谁来做就能接着做。"
                }
            case .stalled:
                if let tk = v.ticket(needing: .stalled) {
                    step.title = "工单 #\(tk.id) 停下了，一直没回报"
                    step.body = "催过一次仍没回报：补充一句，或者让它重试。"
                }
            case .failed:
                if let tk = v.ticket(needing: .failed) {
                    step.title = "工单 #\(tk.id) 失败了"
                    step.body = tk.ticket.reportSummary
                }
            case .delivery:
                if let tk = v.ticket(needing: .delivery) {
                    step.title = "消息没送到工单 #\(tk.id)"
                    step.body = tk.ticket.deliveryError ?? ""
                }
            }
            return step
        }

        let unassigned = v.items.filter { $0.assignee == .unassigned && $0.status != .done }.map(\.ord)
        if !unassigned.isEmpty {
            let quick = quickAssign(v, ords: unassigned, roles: roles, prefer: nil, extra: [], guess: guess)
            let items = v.items.filter { unassigned.contains($0.ord) }
            return NextStep(tone: .decide, eyebrow: "下一步 · 定谁来做",
                            title: quick.map { "把\(WorklistText.ords(unassigned))交给\($0.role)" } ?? "定谁来做：\(WorklistText.ords(unassigned))还没定",
                            body: quick != nil ? (items.first?.text ?? "") : "交给 Agent 的项会开工单；你自己做的项在清单里勾掉。",
                            quick: quick)
        }

        // 不用你管：说现在在发生什么。
        if v.reviewing, let r = v.tickets.first(where: { $0.ticket.isOpen && $0.ticket.reviewOf != nil }) {
            return NextStep(tone: .quiet, eyebrow: "现在 · 不用你管", title: "评审在核对交付", body: "工单 #\(r.id)", ticket: r.id)
        }
        if let w = v.tickets.first(where: { $0.stage == .working(queued: false) }) {
            let ords = v.items.filter { $0.ticketID == w.id && $0.status != .done }.map(\.ord)
            let text = v.items.first { $0.ticketID == w.id && $0.status != .done }?.text ?? ""
            let who = w.ticket.role.isEmpty ? "执行者" : w.ticket.role
            return NextStep(tone: .quiet, eyebrow: "现在 · 不用你管",
                            title: "\(who)在做\(ords.isEmpty ? "" : WorklistText.ords(ords))" + (ords.count == 1 && !text.isEmpty ? "「\(text)」" : ""),
                            body: "工单 #\(w.id) · " + (w.ticket.reportSummary.isEmpty ? "刚开工" : "最近回报：\(w.ticket.reportSummary)") + "。有需要你的事会出现在这里。",
                            ticket: w.id)
        }
        if let q = v.tickets.first(where: { $0.stage == .working(queued: true) }) {
            return NextStep(tone: .quiet, eyebrow: "现在 · 不用你管", title: "工单 #\(q.id) 在排队", body: "并发满了，轮到它就开工。", ticket: q.id)
        }
        if let mine = v.items.first(where: { $0.assignee == .you && $0.status != .done }) {
            return NextStep(tone: .quiet, eyebrow: "现在 · 轮到你", title: "轮到你：第 \(mine.ord) 项「\(mine.text)」", body: "做完在清单里勾掉。")
        }
        return NextStep(tone: .quiet, eyebrow: "现在 · 不用你管", title: "清单项都在推进", body: "")
    }

    /// 这几项的建议角色一致（`prefer` 优先，否则按文字的启发式）才给一键交出；角色要改文件而任务没目录时从原文认目录。
    private static func quickAssign(_ target: TaskView, ords: [Int], roles: [Role], prefer: String?, extra: [String],
                                    guess: ([String]) -> String?) -> QuickAssign? {
        let items = target.items.filter { ords.contains($0.ord) }
        guard !items.isEmpty else { return nil }
        var role = prefer
        if role == nil {
            let suggested = Set(items.map { AssignHeuristic.suggest($0.text) })
            guard suggested.count == 1, let r = suggested.first?.role else { return nil }
            role = r
        }
        guard let role, let def = roles.first(where: { $0.name == role }) else { return nil }
        let needsDirectory = def.edits && target.task.scope.isEmpty
        let directory = needsDirectory ? guess([target.task.request, target.task.title] + items.map(\.text) + extra) : nil
        return QuickAssign(target: target.id, ords: ords, role: role, needsDirectory: needsDirectory, directory: directory)
    }
}

// MARK: - 横幅

struct NextStepBanner: View {
    @Environment(AppModel.self) private var appModel
    let view: TaskView
    /// 打开这张卡的「谁来做」。
    let assign: () -> Void
    /// 人在横幅里换过的目录（盖过认出来的）。
    @State private var chosenDirectory: String?

    var body: some View {
        let sa = appModel.superagent
        let step = NextStep.make(view, task: { sa.task($0) }, roles: sa.roles)
        Group {
            if step.tone == .quiet { quiet(step) } else { loud(step) }
        }
        .onChange(of: view.id) { _, _ in chosenDirectory = nil }
    }

    // MARK: 深色：需要你 / 定谁来做

    private func loud(_ step: NextStep) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                words(step).frame(minWidth: 380, alignment: .leading)
                Spacer(minLength: 0)
                actions(step).fixedSize()
            }
            VStack(alignment: .leading, spacing: 16) {
                words(step)
                actions(step)
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.brand))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("下一步：\(step.title)")
    }

    private func words(_ step: NextStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(step.tone == .needsYou ? BannerInk.amberDot : Theme.Colors.mist).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(step.eyebrow).font(.system(size: 12, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(step.tone == .needsYou ? BannerInk.amberText : Theme.Colors.mist)
            }
            Text(step.title).font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.canvas)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !step.body.isEmpty {
                Text(step.body).font(.system(size: 13)).foregroundStyle(BannerInk.bodyText)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .help(step.body)
            }
        }
    }

    @ViewBuilder private func actions(_ step: NextStep) -> some View {
        HStack(spacing: 10) {
            if let q = step.quick {
                if q.needsDirectory { directoryButton(q) }
                Button("交给\(q.role)") { hand(q) }
                    .buttonStyle(BannerButtonStyle(kind: .prominent))
                    .disabled(q.needsDirectory && (chosenDirectory ?? q.directory) == nil)
                    .help(q.needsDirectory && (chosenDirectory ?? q.directory) == nil ? "先选一个项目目录" : "交给\(q.role)，开一张工单")
                if q.target != view.id {
                    Button("打开 A-\(q.target)") { appModel.openWorklist(task: q.target) }
                        .buttonStyle(BannerButtonStyle(kind: .ghost))
                }
                Button("谁来做…", action: assign).buttonStyle(BannerButtonStyle(kind: .ghost))
            } else if view.needsYou.isEmpty {
                Button("谁来做…", action: assign).buttonStyle(BannerButtonStyle(kind: .prominent))
            } else {
                TaskNeedActions(view: view, assign: assign).environment(\.needActionsOnDark, true)
            }
        }
    }

    private func directoryButton(_ q: NextStep.QuickAssign) -> some View {
        let dir = chosenDirectory ?? q.directory
        return Button {
            if let p = pickFolder(from: dir ?? "", message: "交给\(q.role)的项在这个目录里工作") { chosenDirectory = p }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 12))
                Text(dir.map(tilde) ?? "选择目录…").lineLimit(1).truncationMode(.head)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .buttonStyle(BannerButtonStyle(kind: .outline))
        .help(dir == nil ? "这个任务还没有项目目录：选一个，\(q.role)在那里工作" : (chosenDirectory == nil ? "目录是从原文里认出来的，点了更换" : dir!))
        .accessibilityLabel(dir.map { "目录 \($0)，点了更换" } ?? "选择项目目录")
    }

    /// 设目录（需要时）→ 交给角色；失败的原因贴在这张卡上。
    private func hand(_ q: NextStep.QuickAssign) {
        let sa = appModel.superagent
        if q.needsDirectory {
            guard let dir = chosenDirectory ?? q.directory else { return }
            if let e = attempt(sa, { sa.updateTask(q.target, scope: dir) }) { sa.actionErrors[view.id] = e; return }
        }
        let allocations = q.ords.map { SuperagentEngine.Allocation(ord: $0, to: .agent(role: q.role)) }
        if let e = attempt(sa, { sa.assign(q.target, allocations, oneTicket: true) }) { sa.actionErrors[view.id] = e; return }
        sa.noteEcho(view.id, q.target == view.id ? "已交给\(q.role)（\(WorklistText.ords(q.ords))）" : "已把 A-\(q.target) 交给\(q.role)")
    }

    // MARK: 浅色：不用你管

    private func quiet(_ step: NextStep) -> some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.brand).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(step.eyebrow).font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
                }
                Text(step.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if !step.body.isEmpty {
                    Text(step.body).font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(step.body)
                }
            }
            Spacer(minLength: 0)
            if let id = step.ticket {
                HStack(spacing: 16) {
                    Button("打开工单终端") { appModel.goToTicket(id) }.buttonStyle(BannerButtonStyle(kind: .text))
                    Button("补充说明…") { appModel.ticketFeedback = TicketFeedbackRequest(ticketID: id, kind: .add) }
                        .buttonStyle(BannerButtonStyle(kind: .text))
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("现在：\(step.title)")
    }
}

/// 横幅上的颜色：深色底上的琥珀点 / 字和正文灰（对比度够 4.5:1）。
private enum BannerInk {
    static let amberDot = Color(.sRGB, red: 0.878, green: 0.643, blue: 0.388, opacity: 1)   // #e0a463
    static let amberText = Color(.sRGB, red: 0.914, green: 0.780, blue: 0.612, opacity: 1)  // #e9c79c
    static let bodyText = Color(.sRGB, red: 0.839, green: 0.827, blue: 0.784, opacity: 1)   // #d6d3c8
    static let outline = Color(.sRGB, red: 0.333, green: 0.325, blue: 0.302, opacity: 1)    // #55534d
}

/// 横幅按钮：`prominent` 象牙底墨字（深色横幅上的主按钮）；`outline` 细框象牙字；`ghost` 只有字；`text` 浅色横幅上带下划线的字。
struct BannerButtonStyle: ButtonStyle {
    enum Kind { case prominent, outline, ghost, text }
    var kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: kind == .prominent ? 14 : 13, weight: kind == .prominent ? .semibold : .regular))
            .foregroundStyle(foreground)
        return Group {
            if kind == .text {
                label.underline(true, color: Theme.Colors.mist)
            } else {
                label
                    .padding(.horizontal, kind == .prominent ? 20 : 14)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 9).fill(kind == .prominent ? Theme.canvas : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(kind == .outline ? BannerInk.outline : Color.clear, lineWidth: 1))
            }
        }
        .contentShape(Rectangle())
        .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }

    private var foreground: Color {
        switch kind {
        case .prominent: return Theme.textPrimary
        case .outline: return Theme.canvas
        case .ghost: return BannerInk.bodyText
        case .text: return Theme.textSecondary
        }
    }
}

/// 「需要你」按钮放在深色横幅上时换成横幅的按钮样式（`TaskNeedActions` 读它）。
private struct NeedActionsOnDarkKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var needActionsOnDark: Bool {
        get { self[NeedActionsOnDarkKey.self] }
        set { self[NeedActionsOnDarkKey.self] = newValue }
    }
}
