import AppKit
import SwiftUI
import SuperagentCore

// 「谁来做」（TFA-工作清单-需求文档 §9.3、注意事项 F-12 / F-13 / D-08 / C-03）：每个清单项选 你 / 某个角色的 Agent；
// 交给 Agent 的项才开工单。在哪个目录、能否改文件由角色定义决定，这里不选。

/// 没有主管建议时的默认执行者（注意事项 F-13）：含「改 / 修 / 实现 / 提交 / 加 / 删」→ 开发；含「查 / 问 / 分析 / 总结 / 看看」→ 助理；其余 → 你。
enum AssignHeuristic {
    static let developerWords = ["改", "修", "实现", "提交", "加", "删"]
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

/// 「将开 N 张工单：开发（第 1–3 项）、助理（第 5 项）」的预告（纯函数，可测）。
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
}

struct AssignSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let view: TaskView
    /// 角色（按 `tfa read roles` 顺序）：分段控件的选项、只读提示。
    let roles: [Role]
    @State private var rows: [Row]
    @State private var initial: [Row]
    @State private var oneTicket = true
    @State private var error: String?
    /// 确认前列出会被中断的终端（改派有工单的项；注意事项 C-03）。
    @State private var interrupting: [String]?

    struct Row: Identifiable, Equatable {
        let item: Item
        var text: String
        var to: Assignee
        var id: Int64 { item.id }
    }

    /// 默认值在这里算好（sheet 按内容定大小，不能等 onAppear）：`Item.assignee` 有值就用它，否则按启发式；
    /// 启发式给的角色不存在就退到你。
    init(view: TaskView, roles: [Role]) {
        self.view = view
        self.roles = roles
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
    }

    /// 分段控件的选项：你 + 各角色（按 `roles` 顺序）；项当前的角色不在列表里也补上，免得没得选。
    private var options: [Assignee] {
        var list: [Assignee] = [.you] + roles.map { .agent(role: $0.name) }
        for r in rows where r.to.isAgent && !list.contains(r.to) { list.append(r.to) }
        return list
    }
    /// 每行定高（带提示的高一些），滚动区按行数定高：sheet 不会把滚动区挤成 0。
    private var listHeight: CGFloat {
        min(rows.reduce(CGFloat(0)) { $0 + rowHeight($1) } + CGFloat(max(rows.count - 1, 0)), 420)
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
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("谁来做 · \(view.task.label) \(view.task.title)").font(Theme.Font.headerTitle).lineLimit(2)
            Text("每一项选你或某个角色的 Agent。默认是主管的建议，可以改。交给 Agent 的项会开工单；在哪个目录、能否改文件由角色决定。")
                .font(.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            Hairline()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($rows) { $row in
                        itemRow($row)
                        if row.id != rows.last?.id { Hairline() }
                    }
                }
            }
            .frame(height: listHeight)
            Hairline()
            HStack(spacing: Theme.Space.md) {
                Toggle("同一角色的项合成一张工单", isOn: $oneTicket).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Text(AssignPreview.text(agentAllocations, oneTicket: oneTicket))
                    .font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(2).multilineTextAlignment(.trailing)
            }
            Text("交给 Agent 的项会开工单；在哪个目录、能否改文件由角色决定。")
                .font(.caption).foregroundStyle(Theme.textTertiary)
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
        let done = r.item.status == .done
        let hint = hintFor(r)
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.md) {
                Text("\(r.item.ord)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 18, alignment: .trailing)
                TextField("一句话、可验证的结果", text: row.text)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(done ? Theme.textTertiary : Theme.textPrimary)
                    .disabled(done)
                    .accessibilityLabel("第 \(r.item.ord) 项的文字")
                SegmentedChoice(selection: row.to, options: options.map { ($0, $0.label) }, disabled: done)
                    .accessibilityLabel("第 \(r.item.ord) 项谁来做")
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(Theme.textTertiary).padding(.leading, 18 + Theme.Space.md)
            }
        }
        .frame(height: rowHeight(r))
    }

    /// 已完成的项说明一下；交给只读角色而文字像要改文件时提示一句（D-08，不拦）；有工单的项改派会中断。
    private func hintFor(_ r: Row) -> String? {
        if r.item.status == .done { return "已完成，不能改派" }
        if let role = r.to.role, let def = roles.first(where: { $0.name == role }), !def.edits,
           AssignHeuristic.looksLikeEdit(r.text) {
            return "这项看起来要改文件，「\(role)」只读"
        }
        if r.to != r.item.assignee, let id = r.item.ticketID, view.ticket(id)?.ticket.isOpen == true {
            return "改派会停掉工单 #\(id)"
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
        let sessions = rows.filter { $0.item.status != .done && $0.to != $0.item.assignee }
            .compactMap { r in r.item.ticketID.flatMap { view.ticket($0) } }
            .filter { $0.ticket.isOpen && !$0.ticket.session.isEmpty }
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
