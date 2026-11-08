import AppKit
import SwiftUI
import SuperagentCore

// 「谁来做」（TFA-工作清单-需求文档 §9.3、注意事项 F-12 / F-13 / D-08 / C-03）：每个清单项选 你 / 某个角色的 Agent；
// 交给 Agent 的项才开工单。在哪个目录、能否改文件由角色定义决定，这里不选。

/// 没有主管建议时的默认执行者（注意事项 F-13）：含「改 / 修 / 实现 / 提交 / 加 / 删 / 开发」→ 开发；含「查 / 问 / 分析 / 总结 / 看看」→ 助理；其余 → 你。
enum AssignHeuristic {
    static let developerWords = ["改", "修", "实现", "提交", "加", "删", "开发"]
    static let assistantWords = ["查", "问", "分析", "总结", "看看"]
    /// 看起来要改文件（注意事项 D-08：交给只读角色时提示，不拦）。
    static let editWords = ["改", "修", "提交", "实现"]

    static func suggest(_ text: String) -> Assignee {
        if developerWords.contains(where: text.contains) { return .agent(role: Role.developer) }
        if assistantWords.contains(where: text.contains) { return .agent(role: Role.assistant) }
        return .you
    }

    static func looksLikeEdit(_ text: String) -> Bool {
        editWords.contains(where: text.contains)
    }
}

/// 「将开 N 张工单：开发（第 1–3 项）、助理（第 5 项）」的预告和底部的后果预览（纯函数，可测）。
enum AssignPreview {
    /// `allocations` = 这次要交给 Agent 的项（ord → 角色）；`oneTicket` 为真时同一角色合成一张。
    static func text(_ allocations: [(ord: Int, role: String)], oneTicket: Bool) -> String {
        guard !allocations.isEmpty else { return "不开新工单" }
        var groups: [(role: String, ords: [Int])] = []
        for a in allocations.sorted(by: { $0.ord < $1.ord }) {
            if oneTicket, let i = groups.firstIndex(where: { $0.role == a.role }) { groups[i].ords.append(a.ord) }
            else { groups.append((a.role, [a.ord])) }
        }
        return "将开 \(groups.count) 张工单：" + groups.map { "\($0.role)（\(WorklistText.ords($0.ords))）" }.joined(separator: "、")
    }

    /// 底部一行后果预览（设计评审 2026-11-08，Pass 2）：「确认后：第 4 项归你；第 1–3 项交给开发（1 张工单）；改第 2 项的文字；
    /// 第 5 项已在工单 #13 排队，不变；会停掉工单 #9 的终端」。`changes` = 执行者变了的项；`queued` = 没动、仍在排队的项；
    /// `stopping` = 改派会停掉的工单。什么都没变为 nil。
    static func consequence(changes: [(ord: Int, to: Assignee)], oneTicket: Bool, edited: [Int] = [],
                            queued: [(ord: Int, ticket: Int64)] = [], stopping: [Int64] = []) -> String? {
        var parts: [String] = []
        let yours = changes.filter { $0.to == .you }.map(\.ord)
        if !yours.isEmpty { parts.append("\(WorklistText.ords(yours))归你") }
        var roles: [(role: String, ords: [Int])] = []
        for c in changes.sorted(by: { $0.ord < $1.ord }) {
            guard let role = c.to.role else { continue }
            if let i = roles.firstIndex(where: { $0.role == role }) { roles[i].ords.append(c.ord) } else { roles.append((role, [c.ord])) }
        }
        for r in roles {
            parts.append("\(WorklistText.ords(r.ords))交给\(r.role)（\(oneTicket ? 1 : r.ords.count) 张工单）")
        }
        let dropped = changes.filter { $0.to == .unassigned }.map(\.ord)
        if !dropped.isEmpty { parts.append("\(WorklistText.ords(dropped))回到待分配") }
        if !edited.isEmpty { parts.append("改\(WorklistText.ords(edited))的文字") }
        for q in queued.sorted(by: { $0.ord < $1.ord }) { parts.append("第 \(q.ord) 项已在工单 #\(q.ticket) 排队，不变") }
        if !stopping.isEmpty { parts.append("会停掉工单 " + stopping.map { "#\($0)" }.joined(separator: "、") + " 的终端") }
        return parts.isEmpty ? nil : "确认后：" + parts.joined(separator: "；")
    }

    /// 这次交给了会改文件的角色、而任务还没有目录：引擎会拒绝（H-02），sheet 要先让人选目录。
    static func needsDirectory(changes: [(ord: Int, to: Assignee)], roles: [Role], scope: String) -> Bool {
        guard scope.isEmpty else { return false }
        return changes.contains { c in c.to.role.flatMap { name in roles.first { $0.name == name } }?.edits ?? false }
    }

    /// 改派会停掉的工单（引擎 `assign`，注意事项 C-03）：只有它名下没做完的项**全部**被改派走才停；还剩项就继续做，
    /// 只是告诉它哪项不用做了。`reassigned` = 这次换了执行者的项的序号，`open` = 还开着的工单。按工单号升序。
    static func stopping(items: [Item], reassigned: Set<Int>, open: Set<Int64>) -> [Int64] {
        var held: [Int64: [Item]] = [:]
        for i in items where i.status != .done { if let id = i.ticketID, open.contains(id) { held[id, default: []].append(i) } }
        return held.filter { $0.value.allSatisfy { reassigned.contains($0.ord) } }.keys.sorted()
    }
}

struct AssignSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let view: TaskView
    /// 角色（按 `tfa read roles` 顺序）：分段控件的选项、只读提示。
    let roles: [Role]
    /// 打开时定位到这一项（退回条的「改派第 N 项…」，4A）：滚到它、浅浅着色。
    let focusOrd: Int?
    @State private var rows: [Row]
    @State private var initial: [Row]
    @State private var oneTicket = true
    @State private var error: String?
    /// 确认前列出会被中断的终端（改派有工单的项；注意事项 C-03）。
    @State private var interrupting: [String]?
    /// 任务的目录：`view` 是打开时的快照，在这里选了目录要立刻反映出来。
    @State private var scope: String

    struct Row: Identifiable, Equatable {
        let item: Item
        var text: String
        var to: Assignee
        var id: Int64 { item.id }
    }

    /// 默认值在这里算好（sheet 按内容定大小，不能等 onAppear）：`Item.assignee` 有值就用它，否则按启发式；
    /// 启发式给的角色不存在就退到你。
    init(view: TaskView, roles: [Role], focusOrd: Int? = nil) {
        self.view = view
        self.roles = roles
        self.focusOrd = focusOrd
        let rows = view.items.map { item -> Row in
            var to = item.assignee
            if to == .unassigned {
                to = AssignHeuristic.suggest(item.text)
                if let role = to.role, !roles.contains(where: { $0.name == role }) { to = .you }
            }
            return Row(item: item, text: item.text, to: to)
        }
        _rows = State(initialValue: rows)
        _initial = State(initialValue: rows)
        _scope = State(initialValue: view.task.scope)
    }

    /// 分段控件的选项：你 + 各角色（按 `roles` 顺序）；项当前的角色不在列表里也补上，免得没得选。
    private var options: [Assignee] {
        var list: [Assignee] = [.you] + roles.map { .agent(role: $0.name) }
        for r in rows where r.to.isAgent && !list.contains(r.to) { list.append(r.to) }
        return list
    }
    /// 已完成的项合成一行「第 1–3 项已完成，不能改派」，不占一行一个。
    private var doneOrds: [Int] { rows.filter { $0.item.status == .done }.map(\.item.ord) }
    private var openRows: [Row] { rows.filter { $0.item.status != .done } }
    /// 每行定高（带提示的高一些），滚动区按行数定高：sheet 不会把滚动区挤成 0。
    private var listHeight: CGFloat {
        let rows = openRows
        let done: CGFloat = doneOrds.isEmpty ? 0 : 28
        return min(done + rows.reduce(CGFloat(0)) { $0 + rowHeight($1) } + CGFloat(max(rows.count - 1, 0)), 420)
    }
    private func rowHeight(_ r: Row) -> CGFloat { hintFor(r) == nil ? 48 : 66 }
    private var dirty: Bool { rows != initial }
    /// 选了和现在一样的执行者也算改动的情况：受阻且没有打开的工单（前置被取消 / 工单被停）→ 重新分配就是解阻；
    /// 交给某个角色但它的工单已结束 → 再派一张。引擎支持，这里要让它可达。
    private func redispatch(_ r: Row) -> Bool {
        guard r.item.status != .done, r.to == r.item.assignee else { return false }
        let open = r.item.ticketID.flatMap { view.ticket($0) }?.ticket.isOpen ?? false
        if r.item.status == .blocked && !open { return true }
        return r.to.isAgent && r.item.ticketID != nil && !open
    }
    private var changed: [Row] { rows.filter { $0.item.status != .done && ($0.to != $0.item.assignee || $0.text != $0.item.text || redispatch($0)) } }
    private var agentAllocations: [(ord: Int, role: String)] {
        rows.filter { $0.item.status != .done && ($0.to != $0.item.assignee || redispatch($0)) }.compactMap { r in r.to.role.map { (r.item.ord, $0) } }
    }
    private var problem: String? {
        if let r = rows.first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return "第 \(r.item.ord) 项没有文字" }
        if let r = rows.first(where: { $0.text.count > Item.maxText }) { return "第 \(r.item.ord) 项超过 \(Item.maxText) 字" }
        if changed.isEmpty { return "没有改动" }
        if needsDirectory { return "先选项目目录" }
        return nil
    }
    /// 交给了会改文件的角色、任务还没有目录：确认前要先选（引擎 H-02）。
    private var needsDirectory: Bool {
        let changes = rows.filter { $0.item.status != .done && ($0.to != $0.item.assignee || redispatch($0)) }.map { (ord: $0.item.ord, to: $0.to) }
        return AssignPreview.needsDirectory(changes: changes, roles: roles, scope: scope)
    }
    /// 会被停掉的工单：名下没做完的项全被改派走的（`AssignPreview.stopping`），按工单号。
    private var stoppingTickets: [Int64] {
        let reassigned = Set(rows.filter { $0.item.status != .done && $0.to != $0.item.assignee }.map(\.item.ord))
        return AssignPreview.stopping(items: view.items, reassigned: reassigned, open: Set(view.tickets.filter(\.ticket.isOpen).map(\.id)))
    }
    /// 底部的后果预览；什么都没变就不显示。
    private var consequence: String? {
        let changes = rows.filter { $0.item.status != .done && ($0.to != $0.item.assignee || redispatch($0)) }.map { (ord: $0.item.ord, to: $0.to) }
        let edited = rows.filter { $0.item.status != .done && $0.text != $0.item.text }.map(\.item.ord)
        let queued = rows.filter { r in r.item.status != .done && !changed.contains(r) }.compactMap { r -> (ord: Int, ticket: Int64)? in
            guard let id = r.item.ticketID, view.ticket(id)?.stage == .working(queued: true) else { return nil }
            return (r.item.ord, id)
        }
        guard !changes.isEmpty || !edited.isEmpty else { return nil }
        return AssignPreview.consequence(changes: changes, oneTicket: oneTicket, edited: edited, queued: queued, stopping: stoppingTickets)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("谁来做 · \(view.task.label) \(view.task.title)").font(Theme.Font.headerTitle).lineLimit(2)
            Text("每一项选你或某个角色的 Agent。默认是主管的建议，可以改。交给 Agent 的项会开工单；在哪个目录、能否改文件由角色决定。")
                .font(.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if !doneOrds.isEmpty {
                            Text("\(WorklistText.ords(doneOrds))已完成，不能改派")
                                .font(.caption).foregroundStyle(Theme.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 28)
                                .padding(.leading, 18 + Theme.Space.md)
                            if !openRows.isEmpty { Hairline() }
                        }
                        ForEach($rows) { $row in
                            if row.item.status != .done {
                                itemRow($row).id(row.id)
                                if row.id != openRows.last?.id { Hairline() }
                            }
                        }
                    }
                }
                .frame(height: listHeight)
                .onAppear {
                    if let ord = focusOrd, let r = rows.first(where: { $0.item.ord == ord }) { proxy.scrollTo(r.id, anchor: .center) }
                }
            }
            Hairline()
            if !agentAllocations.isEmpty { // 合单开关只在会开工单时有意义；默认开
                Toggle("同一角色的项合成一张工单", isOn: $oneTicket).toggleStyle(.switch).controlSize(.small)
            }
            if needsDirectory {
                HStack(spacing: Theme.Space.md) {
                    Text("开发要改文件，这个任务还没有项目目录。").font(.caption).foregroundStyle(Theme.Status.attention)
                    Button("选择目录…") {
                        if let p = pickFolder(from: scope, message: "任务的项目目录：交给会改文件的角色（开发）时在这里工作") {
                            if let e = attempt(appModel.superagent, { appModel.superagent.updateTask(view.id, scope: p) }) { error = e } else { scope = p }
                        }
                    }
                    .controlSize(.small)
                }
            } else if !scope.isEmpty, scope != view.task.scope {
                Text("项目目录：\(tilde(scope))").font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.head)
            }
            if let consequence {
                Text(consequence).font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(consequence)
            }
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if let error {
                    Text(error).font(.caption).foregroundStyle(Theme.Status.error).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let problem, problem != "没有改动" {
                        Text(problem).font(.caption).foregroundStyle(Theme.Status.error)
                    }
                    Spacer()
                    Button("取消", role: .cancel) { cancel() }.keyboardShortcut(.cancelAction)
                    Button("确认分配") { confirm() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(problem != nil)
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
        .alert("会中断 \(interrupting?.count ?? 0) 个终端", isPresented: Binding(get: { interrupting != nil }, set: { if !$0 { interrupting = nil } })) {
            Button("改派并中断", role: .destructive) { perform() }
            Button("取消", role: .cancel) {}
        } message: {
            Text((interrupting ?? []).joined(separator: "、") + "。改派有工单的项要先停掉那张工单；终端、目录和已有改动都保留。")
        }
    }

    private func itemRow(_ row: Binding<Row>) -> some View {
        let r = row.wrappedValue
        let hint = hintFor(r)
        let focused = r.item.ord == focusOrd
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.md) {
                Text("\(r.item.ord)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 18, alignment: .trailing)
                TextField("一句话、可验证的结果", text: row.text)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityLabel("第 \(r.item.ord) 项的文字")
                SegmentedChoice(selection: row.to, options: options.map { ($0, $0.label) })
                    .accessibilityLabel("第 \(r.item.ord) 项谁来做")
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(Theme.textTertiary).padding(.leading, 18 + Theme.Space.md)
            }
        }
        .frame(height: rowHeight(r))
        .padding(.horizontal, focused ? Theme.Space.sm : 0)
        .background(focused ? Theme.brand.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    /// 交给只读角色而文字像要改文件时提示一句（D-08，不拦）；有工单的项改派会中断。
    private func hintFor(_ r: Row) -> String? {
        if let role = r.to.role, let def = roles.first(where: { $0.name == role }), !def.edits,
           AssignHeuristic.looksLikeEdit(r.text) {
            return "这项看起来要改文件，「\(role)」只读"
        }
        if r.to != r.item.assignee, let id = r.item.ticketID, view.ticket(id)?.ticket.isOpen == true {
            return stoppingTickets.contains(id) ? "改派会停掉工单 #\(id)" : "工单 #\(id) 继续做它剩下的项"
        }
        return nil
    }

    /// 关闭时有改动未确认：保存 / 放弃 / 取消三选（DESIGN.md）。
    private func cancel() {
        guard dirty else { dismiss(); return }
        let alert = NSAlert()
        alert.messageText = "分配还没确认"
        alert.informativeText = "确认分配后交给 Agent 的项会开工单；放弃则什么都不变。"
        alert.addButton(withTitle: "确认分配")
        alert.addButton(withTitle: "放弃改动")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: if problem == nil { confirm() }
        case .alertSecondButtonReturn: dismiss()
        default: break
        }
    }

    private func confirm() {
        guard problem == nil else { return }
        let sessions = stoppingTickets.compactMap { view.ticket($0) }
            .filter { !$0.ticket.session.isEmpty }
            .map(\.ticket.session)
        let unique = sessions.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if unique.isEmpty { perform() } else { interrupting = unique }
    }

    /// 先改文字，再 `assign`（只送改了的项）；任一步失败就停，错误留在表单里。
    private func perform() {
        let sa = appModel.superagent
        for r in changed where r.text != r.item.text {
            if let e = attempt(sa, { sa.editItem(view.id, ord: r.item.ord, text: r.text.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                error = "第 \(r.item.ord) 项：\(e)"
                return
            }
        }
        let allocations = changed.filter { $0.to != $0.item.assignee }.map { SuperagentEngine.Allocation(ord: $0.item.ord, to: $0.to) }
        if !allocations.isEmpty {
            if let e = attempt(sa, { sa.assign(view.id, allocations, oneTicket: oneTicket) }) {
                error = e
                return
            }
        }
        dismiss()
    }
}
