import AppKit
import SwiftUI
import SuperagentCore

// 任务卡的「下一步」横幅（设计评审 2026-11-08 定稿：C 的横幅 + A 的纸面风格）。位置固定在标题下：
// 需要你 / 等你定谁来做时是深色横幅，一句话说该做什么 + 主按钮；没事时是浅色横幅，写现在在发生什么。页面不跳。

/// 从原文和退回说明里认出项目目录：`~/…` 或 `/Users/…`，到空白或中文标点为止；只认真实存在的文件夹，家目录和根目录不算。
enum ScopeGuess {
    static func directory(in text: String, isDirectory: (String) -> Bool = ScopeGuess.isDirectory) -> String? {
        directory(in: [text], isDirectory: isDirectory)
    }

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
        // 链接项（4C）：只剩在等退回产生的任务。
        if let l = v.linked.values.sorted(by: { $0.link.itemOrd < $1.link.itemOrd }).first {
            return NextStep(tone: .quiet, eyebrow: "现在 · 不用你管", title: "第 \(l.link.itemOrd) 项在等 A-\(l.link.toTaskID) 完成",
                            body: "A-\(l.link.toTaskID) 完成时这一项自动勾掉。")
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

    /// 折叠态预览清洗：将连续空行合并为单个换行，避免空行白白占掉折叠预览行数；同时返回是否需要显示「展开完整内容」按钮。
    static func previewBody(_ raw: String, maxPreviewLines: Int = 4, maxPreviewChars: Int = 150) -> (preview: String, canExpand: Bool) {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return ("", false) }
        let rawLines = normalized.components(separatedBy: "\n")
        let nonBlankLines = rawLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let preview = nonBlankLines.joined(separator: "\n")
        let collapsedBlankLines = nonBlankLines.count < rawLines.count
        let newlineCount = max(0, nonBlankLines.count - 1)
        let canExpand = newlineCount >= maxPreviewLines
            || normalized.count > maxPreviewChars
            || (collapsedBlankLines && normalized.count > 80)
        return (preview, canExpand)
    }

    /// 找出当前横幅关联的工单号（供「查看工单 #id 详情」使用）。
    static func relevantTicketID(_ step: NextStep, in view: TaskView) -> Int64? {
        if let tid = step.ticket { return tid }
        guard let need = view.needsYou.first else { return nil }
        if let tk = view.ticket(needing: need) { return tk.id }
        if need == .blocked, let link = view.handbackNeed { return link.ticketID }
        if need == .review {
            return view.tickets.last { $0.ticket.reviewOf == nil && !$0.ticket.reportSummary.isEmpty }?.id
                ?? view.tickets.last { !$0.ticket.reportSummary.isEmpty }?.id
        }
        return nil
    }
}

// MARK: - 横幅

struct NextStepBanner: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let view: TaskView
    /// 打开这张卡的「谁来做」。
    let assign: () -> Void
    /// 人在横幅里换过的目录（盖过认出来的）。
    @State private var chosenDirectory: String?
    /// 正文是否展开完整内容。
    @State private var bodyExpanded = false

    var body: some View {
        let sa = appModel.superagent
        let step = NextStep.make(view, task: { sa.task($0) }, roles: sa.roles) { texts in
            let inferred = AppModel.inferProjectDirectory(
                text: texts.joined(separator: "\n"),
                fallbackDir: appModel.selectedConnection?.currentPath ?? ""
            )
            return inferred.isEmpty ? nil : inferred
        }
        Group {
            if step.tone == .quiet {
                quiet(step).transition(.opacity)
            } else {
                loud(step).transition(.opacity)
            }
        }
        .animation(Theme.Motion.value(Theme.Motion.panel, reduceMotion: reduceMotion), value: step.tone)
        .onChange(of: view.id) { _, _ in
            chosenDirectory = nil
            bodyExpanded = false
        }
        .onChange(of: step.body) { _, _ in
            bodyExpanded = false
        }
    }

    // MARK: 深色：需要你 / 定谁来做

    private func loud(_ step: NextStep) -> some View {
        let bodyInfo = NextStep.previewBody(step.body)
        let isExpanded = bodyExpanded && bodyInfo.canExpand
        let relevantTicketID = NextStep.relevantTicketID(step, in: view)
        return Group {
            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    words(step, preview: bodyInfo.preview, canExpand: bodyInfo.canExpand, isExpanded: true, relevantTicketID: relevantTicketID)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Spacer(minLength: 0)
                        actions(step)
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 20) {
                        words(step, preview: bodyInfo.preview, canExpand: bodyInfo.canExpand, isExpanded: false, relevantTicketID: relevantTicketID)
                            .frame(minWidth: 320, alignment: .leading)
                        Spacer(minLength: 0)
                        actions(step).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        words(step, preview: bodyInfo.preview, canExpand: bodyInfo.canExpand, isExpanded: false, relevantTicketID: relevantTicketID)
                        actions(step)
                    }
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(BannerInk.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).stroke(step.tone == .needsYou ? BannerInk.needsYouStroke : BannerInk.cardStroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("下一步：\(step.title)")
    }

    private func words(_ step: NextStep, preview: String, canExpand: Bool, isExpanded: Bool, relevantTicketID: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(step.tone == .needsYou ? BannerInk.amberDot : BannerInk.mutedText).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(step.eyebrow).font(.system(size: 11, weight: .semibold)).tracking(0.4)
                    .foregroundStyle(step.tone == .needsYou ? BannerInk.amberText : BannerInk.mutedText)
            }
            Text(step.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(BannerInk.titleText)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !step.body.isEmpty {
                if isExpanded {
                    Text(step.body)
                        .font(.system(size: 13))
                        .foregroundStyle(BannerInk.bodyText)
                        .lineLimit(nil)
                        .lineSpacing(3.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text(preview)
                        .font(.system(size: 13))
                        .foregroundStyle(BannerInk.bodyText)
                        .lineLimit(5)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .help(step.body)
                }
            }
            if canExpand || relevantTicketID != nil {
                HStack(spacing: 14) {
                    if canExpand {
                        Button {
                            Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) { bodyExpanded.toggle() }
                        } label: {
                            Text(isExpanded ? "收起内容 ▴" : "展开完整内容 ▾")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(BannerInk.amberText)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isExpanded ? "收起内容" : "展开完整内容")
                    }
                    if let tid = relevantTicketID {
                        Button {
                            appModel.goToTicket(tid)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 10.5))
                                Text("查看工单 #\(tid) 详情")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(BannerInk.bodyText)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("打开工单 #\(tid)（终端在线时跳终端，已结束时弹出完整工单归档记录）")
                        .accessibilityLabel("查看工单 #\(tid) 详情")
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private func actions(_ step: NextStep) -> some View {
        HStack(spacing: 10) {
            if let q = step.quick {
                if q.needsDirectory { directoryButton(q) }
                Button("交给\(q.role)") { hand(q) }
                    .buttonStyle(BannerButtonStyle(kind: .prominent))
                    .help(q.needsDirectory && (chosenDirectory ?? q.directory) == nil ? "点选项目目录并直接交给\(q.role)" : "交给\(q.role)，开一张工单")
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
        .help(dir == nil ? "这个任务还没有项目目录：选一个，\(q.role)在那里工作" : (chosenDirectory == nil ? "目录是系统自动识别的，点击可更换" : dir!))
        .accessibilityLabel(dir.map { "目录 \($0)，点了更换" } ?? "选择项目目录")
    }

    /// 设目录（需要时直接弹出选择框并一步派单）→ 交给角色；失败的原因贴在这张卡上。
    private func hand(_ q: NextStep.QuickAssign) {
        let sa = appModel.superagent
        if q.needsDirectory {
            let resolved: String
            if let existing = chosenDirectory ?? q.directory {
                resolved = existing
            } else if let picked = pickFolder(from: "", message: "选择项目目录，选完立即交给\(q.role)") {
                chosenDirectory = picked
                resolved = picked
            } else {
                return
            }
            if let e = attempt(sa, { sa.updateTask(q.target, scope: resolved) }) { sa.actionErrors[view.id] = e; return }
        }
        let allocations = q.ords.map { SuperagentEngine.Allocation(ord: $0, to: .agent(role: q.role)) }
        if let e = attempt(sa, { sa.assign(q.target, allocations, oneTicket: true) }) { sa.actionErrors[view.id] = e; return }
        sa.noteEcho(view.id, q.target == view.id ? "已交给\(q.role)（\(WorklistText.ords(q.ords))）" : "已把 A-\(q.target) 交给\(q.role)")
    }

    // MARK: 浅色静默条：不用你管时只占紧凑一行，不抢占视觉重心；正文较长或含换行时支持一键展开全文

    private func quiet(_ step: NextStep) -> some View {
        let canExpandQuiet = !step.body.isEmpty && (step.body.count > 70 || step.body.contains("\n"))
        let isExpanded = bodyExpanded && canExpandQuiet
        return HStack(alignment: isExpanded ? .top : .center, spacing: 12) {
            Circle().fill(Theme.Status.positive).frame(width: 7, height: 7)
                .padding(.top, isExpanded ? 5 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: isExpanded ? 5 : 2) {
                Text(step.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(isExpanded ? nil : 1).textSelection(.enabled)
                if !step.body.isEmpty {
                    if isExpanded {
                        Text(step.body)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(nil)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        Text(NextStep.previewBody(step.body).preview.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .help(step.body)
                    }
                    if canExpandQuiet {
                        Button {
                            Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) { bodyExpanded.toggle() }
                        } label: {
                            Text(isExpanded ? "收起 ▴" : "展开完整内容 ▾")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isExpanded ? "收起内容" : "展开完整内容")
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                if let id = step.ticket {
                    Button("打开终端") { appModel.goToTicket(id) }.buttonStyle(BannerButtonStyle(kind: .text))
                    Button("补充…") { appModel.ticketFeedback = TicketFeedbackRequest(ticketID: id, kind: .add) }
                        .buttonStyle(BannerButtonStyle(kind: .text))
                }
                if view.canRetry {
                    Button {
                        if let id = step.ticket {
                            appModel.superagent.retry(id)
                        } else {
                            appModel.superagent.retryTask(view.id)
                        }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("网络中断或执行卡住时，从当前进度重新唤醒执行")
                    .accessibilityLabel("重试")
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("现在：\(step.title)")
    }
}

/// 横幅上的颜色：浅色下保持高对比深炭卡片；深色下略提背景层次并加温和亮边/琥珀边，避免与普通深色卡片混成一片。
private enum BannerInk {
    private static func dynamic(
        light: (CGFloat, CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }

    static let cardFill = dynamic(
        light: (0.118, 0.125, 0.149, 1), // #1e2026
        dark: (0.153, 0.169, 0.212, 1)   // #272b36 — 明显高于深色普通卡片 #1e2128
    )
    static let cardStroke = dynamic(
        light: (0.220, 0.235, 0.278, 1), // #383c47
        dark: (0.310, 0.345, 0.424, 1)   // #4f586c — 深色下清晰的纸面轮廓线
    )
    static let needsYouStroke = dynamic(
        light: (0.220, 0.235, 0.278, 1), // #383c47
        dark: (0.941, 0.659, 0.251, 0.44)// 深色下温和琥珀描边，一眼区分「等你决定」
    )
    static let titleText = Color(.sRGB, red: 0.965, green: 0.969, blue: 0.976, opacity: 1)   // #f6f7f9
    static let mutedText = Color(.sRGB, red: 0.651, green: 0.678, blue: 0.729, opacity: 1)   // #a6adb9
    static let amberDot = Color(.sRGB, red: 0.941, green: 0.659, blue: 0.251, opacity: 1)    // #f0a840
    static let amberText = Color(.sRGB, red: 0.965, green: 0.796, blue: 0.522, opacity: 1)   // #f6cb85
    static let bodyText = Color(.sRGB, red: 0.800, green: 0.816, blue: 0.851, opacity: 1)    // #ccd0d9
    static let outline = Color(.sRGB, red: 0.320, green: 0.341, blue: 0.396, opacity: 1)     // #525765
    static let buttonFill = Color(.sRGB, red: 0.976, green: 0.980, blue: 0.988, opacity: 1)  // #f9fafc
    static let buttonText = Color(.sRGB, red: 0.094, green: 0.102, blue: 0.122, opacity: 1)  // #181a1f
}

/// 横幅按钮：`prominent` 亮底深字；`outline` 细框亮字；`ghost` 轻字；`text` 浅色状态条上的链接字。
struct BannerButtonStyle: ButtonStyle {
    enum Kind { case prominent, outline, ghost, text }
    var kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 13, weight: kind == .prominent ? .semibold : .regular))
            .foregroundStyle(foreground)
        return Group {
            if kind == .text {
                label
            } else {
                label
                    .padding(.horizontal, kind == .prominent ? 16 : 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(kind == .prominent ? BannerInk.buttonFill : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(kind == .outline ? BannerInk.outline : Color.clear, lineWidth: 1))
            }
        }
        .contentShape(Rectangle())
        .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
        .scaleEffect(isEnabled && configuration.isPressed && !reduceMotion ? 0.985 : 1)
        .animation(Theme.Motion.value(Theme.Motion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .prominent: return BannerInk.buttonText
        case .outline: return BannerInk.titleText
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
