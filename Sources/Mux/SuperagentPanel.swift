import AppKit
import SwiftUI
import SuperagentCore

/// 「主管」面板：先列需要你的工单，再列进行中的；问题只在有时出现，规则 / 定时任务 / 设置靠后，
/// 健康状态不占位置（docs/superagent-design.md「面板」）。
struct SuperagentPanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let sa = appModel.superagent
        let working = sa.openTickets.filter { $0.stage.needsPerson == nil }
        let ended = sa.views.filter(\.stage.isEnded)
            .sorted { ($0.ticket.endedAt ?? $0.ticket.updatedAt) > ($1.ticket.endedAt ?? $1.ticket.updatedAt) }
        // 启动 / 送达失败已经作为「送达失败」工单出现在「需要你」里，不再重复列一遍。
        let shown = Set(sa.needsYou.filter { $0.stage == .person(.delivery) }.map { String($0.id) })
        let problems = sa.problems.filter { !(($0.kind == .launch || $0.kind == .deliver) && shown.contains($0.key)) }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if let e = sa.setupError { Banner(text: e) }
                if let e = sa.actionError { Banner(text: e) { sa.actionError = nil } }
                RouterCard()
                if !sa.needsYou.isEmpty {
                    PanelSection(title: "需要你 · \(sa.needsYou.count)") {
                        ForEach(sa.needsYou) { NeedsYouCard(item: $0) }
                    }
                }
                PanelSection(title: "进行中") {
                    if working.isEmpty {
                        Text("没有进行中的工单。在主管终端里提需求即可。")
                            .font(.callout).foregroundStyle(Theme.textTertiary).padding(.horizontal, Theme.Space.xs)
                    } else {
                        RowList(items: working) { WorkingRow(item: $0) }
                    }
                }
                if !problems.isEmpty {
                    PanelSection(title: "问题") {
                        RowList(items: problems.map(IdentifiedEffect.init)) { ProblemRow(effect: $0.effect) }
                    }
                }
                if !ended.isEmpty {
                    Collapsible(title: "最近结束 · \(ended.count)") {
                        RowList(items: ended) { EndedRow(item: $0) }
                    }
                }
                RolesCard()
                RulesCard()
                SchedulesCard()
                SettingsCard()
                if !sa.decisions.isEmpty {
                    Collapsible(title: "决定记录 · \(sa.decisions.count)") {
                        RowList(items: sa.decisions.map(IdentifiedDecision.init)) { DecisionRow(decision: $0.decision) }
                    }
                }
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }
}

// MARK: - 主管终端

private struct RouterCard: View {
    @Environment(AppModel.self) private var appModel
    /// `routerDirectory` 存在 UserDefaults 里（不可观察），这里留一份给界面。
    @State private var dir = ""

    var body: some View {
        let sa = appModel.superagent
        let session = sa.routerSession
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: session == nil ? "moon.zzz" : "checkmark.circle.fill")
                    .foregroundStyle(session == nil ? Theme.Status.neutral : Theme.Status.positive)
                VStack(alignment: .leading, spacing: 2) {
                    Text("主管终端").font(Theme.Font.rowTitle)
                    Text(session.map { "运行中 · \($0)" } ?? "未启动")
                        .font(Theme.Font.rowSubtitle).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                Button(session == nil ? "启动主管" : "打开主管") { appModel.openRouter() }
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: Theme.Space.sm) {
                Text("目录").font(.caption).foregroundStyle(Theme.textTertiary)
                Text(tilde(dir)).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.head).help(dir)
                Button("更换…") {
                    if let path = pickFolder(from: dir, message: "主管终端的起始目录，也是新工单的默认目录") {
                        dir = path
                        appModel.routerDirectory = path
                    }
                }
                .controlSize(.small)
                .help(session == nil ? "主管终端的起始目录，也是新工单的默认目录" : "主管下次启动时生效")
                Spacer(minLength: 0)
            }
            Text("在主管终端里说需求，它拆成工单派给执行终端；执行终端用 Claude Code（全部放行），"
                 + (sa.settings.worktree ? "每个工单一个 git worktree。" : "直接在请求的目录里工作。"))
                .font(.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .saCard()
        .onAppear { dir = appModel.routerDirectory }
    }
}

// MARK: - 需要你

private struct NeedsYouCard: View {
    @Environment(AppModel.self) private var appModel
    let item: TicketView
    @State private var confirmStop = false

    var body: some View {
        let t = item.ticket
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: item.stage.symbol).foregroundStyle(item.stage.tint)
                StateTag(text: item.stage.label, tint: item.stage.tint)
                Text("#\(t.id) \(t.title)").font(Theme.Font.rowTitle).lineLimit(1).help(t.title)
                Spacer(minLength: Theme.Space.sm)
                Ago(time: t.reportAt ?? t.updatedAt)
            }
            detail(t)
            meta(t)
            actions(t)
        }
        .saCard()
        .alert("停止工单 #\(t.id)？", isPresented: $confirmStop) {
            Button("停止", role: .destructive) { appModel.superagent.stop(t.id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会中断执行终端里的 agent 并结束工单。停止后不能再跟进，需要时请新开工单。")
        }
    }

    @ViewBuilder private func detail(_ t: Ticket) -> some View {
        switch item.stage.needsPerson {
        case .answer:
            if let q = t.attention {
                Text(q).font(.body).foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        case .delivery:
            if let e = t.deliveryError { clipped(e) }
        default:
            if !t.reportSummary.isEmpty { clipped(t.reportSummary) }
        }
    }

    private func clipped(_ s: String) -> some View {
        Text(s).font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(3).help(s)
    }

    private func meta(_ t: Ticket) -> some View {
        let place = t.dir.isEmpty ? t.repo : t.dir
        return HStack(spacing: Theme.Space.md) {
            if t.role != Role.developer {
                Label(t.role, systemImage: "person").lineLimit(1)
            }
            if !t.branch.isEmpty {
                Label(t.branch, systemImage: "arrow.triangle.branch").lineLimit(1)
            }
            if !place.isEmpty {
                Text(tilde(place)).lineLimit(1).truncationMode(.head).help(place)
            }
            Spacer(minLength: 0)
            if let path = t.reportPath {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                    Label("打开报告", systemImage: "doc.text")
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(Theme.textSecondary).help(path)
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(Theme.textTertiary)
    }

    private func actions(_ t: Ticket) -> some View {
        let sa = appModel.superagent
        return HStack(spacing: Theme.Space.sm) {
            switch item.stage.needsPerson {
            case .review:
                Button("通过") { sa.approve(t.id) }.buttonStyle(.borderedProminent)
                Button("打回…") { write(.reject) }
            case .answer:
                Button("回答…") { write(.answer) }.buttonStyle(.borderedProminent)
            default:
                Button("重试") { sa.retry(t.id) }.buttonStyle(.borderedProminent)
                Button("补充…") { write(.add) }
            }
            Button("前往终端") { appModel.goToTicket(t.id) }.disabled(t.session.isEmpty)
            Spacer()
            Button("停止") { confirmStop = true }
                .buttonStyle(.borderless).foregroundStyle(Theme.textTertiary)
        }
    }

    private func write(_ kind: TicketFeedbackKind) {
        appModel.ticketFeedback = TicketFeedbackRequest(ticketID: item.id, kind: kind)
    }
}

// MARK: - 进行中 / 问题 / 最近结束

private struct WorkingRow: View {
    @Environment(AppModel.self) private var appModel
    let item: TicketView

    var body: some View {
        let t = item.ticket
        HStack(spacing: Theme.Space.md) {
            StateTag(text: item.stage.label, tint: item.stage.tint).frame(minWidth: 50, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(t.id) \(t.title)").font(Theme.Font.rowTitle).lineLimit(1)
                Text(line).font(Theme.Font.rowSubtitle).foregroundStyle(Theme.textSecondary).lineLimit(1).help(line)
            }
            Spacer(minLength: Theme.Space.sm)
            if item.stage == .idle {
                Button("重试") { appModel.superagent.retry(t.id) }.controlSize(.small)
            }
            Button("前往") { appModel.goToTicket(t.id) }.controlSize(.small).disabled(t.session.isEmpty)
        }
        .contentShape(Rectangle())
        .onTapGesture { appModel.goToTicket(t.id) }
    }

    /// 执行者的一句确认；还没确认时说明它在哪一步。
    private var line: String {
        if !item.ticket.ack.isEmpty { return item.ticket.ack }
        switch item.stage {
        case .working(queued: true) where appModel.superagent.role(for: item.ticket).standing:
            return "排队等「\(item.ticket.role)」空闲"
        case .working(queued: true): return "等待启动"
        case .idle: return "执行终端已停下"
        default: return "已启动，还没确认"
        }
    }
}

private struct ProblemRow: View {
    let effect: Effect

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.error)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.sm) {
                    Text("\(effect.kind.panelLabel)失败").font(Theme.Font.rowTitle)
                    if effect.key != "router" {
                        Text("#\(effect.key)").font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    Text("已失败 \(effect.attempts) 次").font(.caption).foregroundStyle(Theme.Status.error)
                }
                if let e = effect.lastError {
                    Text(e).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2).help(e).textSelection(.enabled)
                }
            }
        }
    }
}

private struct EndedRow: View {
    let item: TicketView

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            StateTag(text: item.stage.label, tint: item.stage.tint).frame(minWidth: 50, alignment: .leading)
            Text("#\(item.id) \(item.ticket.title)").font(Theme.Font.rowTitle).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: Theme.Space.sm)
            Ago(time: item.ticket.endedAt ?? item.ticket.updatedAt)
        }
    }
}

private struct DecisionRow: View {
    let decision: Decision

    var body: some View {
        let d = decision
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            StateTag(text: d.kind.panelLabel, tint: Theme.Status.neutral).frame(minWidth: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.sm) {
                    if let tid = d.triggerID { Text(tid) }
                    if let id = d.ticketID { Text("#\(id)") }
                }
                .font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                if !d.reason.isEmpty {
                    Text(d.reason).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2).help(d.reason)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            Ago(time: d.createdAt)
        }
    }
}

// MARK: - 角色

private struct RoleDraft: Identifiable {
    let id = UUID()
    var role: Role
    var isNew: Bool
}

/// 主管接单时先选角色（docs/superagent-roles.md）。内置角色的运行方式固定，接什么和主要行为可以改。
private struct RolesCard: View {
    @Environment(AppModel.self) private var appModel
    @State private var editing: RoleDraft?
    @State private var deleting: Role?

    var body: some View {
        let sa = appModel.superagent
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("角色").font(Theme.Font.rowTitle)
            Text("主管按「接什么」选角色，再交给这个角色的 Agent；常驻角色一个终端接多张单。没有合适的，主管会先和你对焦再新建。")
                .font(.caption).foregroundStyle(Theme.textTertiary)
            ForEach(sa.roles) { r in
                Hairline()
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Space.sm) {
                            Text(r.name).font(Theme.Font.rowTitle).lineLimit(1)
                            Text(r.traits).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Text(r.scope).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2).help(r.scope)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    Button { editing = RoleDraft(role: r, isNew: false) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("编辑")
                    if !r.isBuiltin {
                        Button { deleting = r } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(Theme.textTertiary).help("删除")
                    }
                }
            }
            Button {
                editing = RoleDraft(role: Role(name: "", scope: "", behavior: "", standing: true, edits: false, review: false), isNew: true)
            } label: {
                Label("添加角色", systemImage: "plus")
            }
        }
        .saCard()
        .sheet(item: $editing) { d in
            RoleSheet(draft: d) { saved in attempt(sa) { sa.setRole(saved) } }
        }
        .alert("删除角色「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) {
                if let r = deleting { sa.deleteRole(r.name) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("它的终端不会被关掉；之后主管不能再把单交给它。")
        }
    }
}

private struct RoleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let draft: RoleDraft
    /// 保存；返回错误（nil = 成功）。
    let save: (Role) -> String?
    @State private var role = Role(name: "", scope: "", behavior: "", standing: true, edits: false, review: false)
    @State private var error: String?

    private var builtin: Bool { !draft.isNew && draft.role.isBuiltin }
    private var valid: Bool {
        !role.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !role.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !role.behavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && role.behavior.count <= Role.maxBehavior
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text(draft.isNew ? "添加角色" : "编辑角色「\(draft.role.name)」").font(Theme.Font.headerTitle)
            if draft.isNew {
                Field(title: "名称") {
                    TextField("例如：运维", text: $role.name).textFieldStyle(.roundedBorder)
                }
            }
            Field(title: "接什么（主管据此选角色）") {
                TextField("例如：本机环境、构建和发布相关的操作", text: $role.scope, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
            }
            Field(title: "主要行为") {
                TextEditor(text: $role.behavior).editorBox().frame(height: 140)
            }
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Toggle("常驻：一个终端先后接这个角色的所有单（追问带上下文）", isOn: $role.standing)
                Toggle("能改文件（否则只读）", isOn: $role.edits)
                Toggle("交付后待评审（否则交付即结单）", isOn: $role.review)
            }
            .toggleStyle(.checkbox).font(.callout).disabled(builtin)
            HStack(alignment: .firstTextBaseline) {
                Text(builtin ? "内置角色的运行方式固定。" : "每单一个终端、能改文件的角色会建 git worktree。").foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(role.behavior.count) / \(Role.maxBehavior)").monospacedDigit()
                    .foregroundStyle(role.behavior.count > Role.maxBehavior ? Theme.Status.error : Theme.textTertiary)
            }
            .font(.caption)
            SheetButtons(error: error, confirm: "保存", enabled: valid) {
                error = save(role)
                if error == nil { dismiss() }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 480)
        .onAppear { role = draft.role }
    }
}

// MARK: - 主动接单（规则）

private struct RulesCard: View {
    @Environment(AppModel.self) private var appModel
    @State private var editing: Rule?
    @State private var deleting: Rule?

    var body: some View {
        let sa = appModel.superagent
        let reviewed = sa.decisions.filter { $0.kind == .wouldAccept || $0.kind == .unavailable }.prefix(5)
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack {
                Text("主动接单（规则）").font(Theme.Font.rowTitle)
                Spacer()
                if !sa.policyVersion.isEmpty {
                    Text("版本 \(sa.policyVersion)").font(.caption.monospaced()).foregroundStyle(Theme.textTertiary)
                }
            }
            Picker("接单模式", selection: Binding(get: { sa.mode }, set: { sa.setMode($0) })) {
                ForEach(AcceptMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Text(sa.mode.panelHint).font(.caption).foregroundStyle(Theme.textTertiary)

            if sa.rules.isEmpty {
                Text("还没有规则。没有启用的规则时，不会主动接单。").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            ForEach(sa.rules) { rule in
                Hairline()
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in
                        sa.setRules(sa.rules.map { $0.id == rule.id ? Rule(id: $0.id, name: $0.name, enabled: on, instruction: $0.instruction) : $0 })
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.name).font(Theme.Font.rowTitle).lineLimit(1)
                        Text(rule.instruction).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2).help(rule.instruction)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    Button { editing = rule } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("编辑")
                    Button { deleting = rule } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(Theme.textTertiary).help("删除")
                }
            }
            Button { editing = Rule(id: nextID("r", sa.rules.map(\.id)), name: "", instruction: "") } label: {
                Label("添加规则", systemImage: "plus")
            }
            if !reviewed.isEmpty {
                Hairline()
                Text("最近研判").font(Theme.Font.sectionHeader).foregroundStyle(Theme.textTertiary)
                ForEach(reviewed, id: \.id) { DecisionRow(decision: $0) }
            }
        }
        .saCard()
        .sheet(item: $editing) { rule in
            RuleSheet(rule: rule, isNew: !sa.rules.contains { $0.id == rule.id }) { saved in
                attempt(sa) {
                    var list = sa.rules
                    if let i = list.firstIndex(where: { $0.id == saved.id }) { list[i] = saved } else { list.append(saved) }
                    sa.setRules(list)
                }
            }
        }
        .alert("删除规则「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) {
                if let r = deleting { sa.setRules(sa.rules.filter { $0.id != r.id }) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("规则版本会变化；依据旧规则接的工单会收到一条重新确认的提示。")
        }
    }
}

private struct RuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let rule: Rule
    let isNew: Bool
    /// 保存；返回错误（nil = 成功）。
    let save: (Rule) -> String?
    @State private var name = ""
    @State private var instruction = ""
    @State private var error: String?

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && instruction.count <= Rule.maxInstruction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text(isNew ? "添加规则" : "编辑规则").font(Theme.Font.headerTitle)
            Field(title: "名称") {
                TextField("例如：CI 失败就修", text: $name).textFieldStyle(.roundedBorder)
            }
            Field(title: "什么情况下接单") {
                TextEditor(text: $instruction).editorBox().frame(height: 140)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("写清命中与不接的边界；方向不明确的一律不接。").foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(instruction.count) / \(Rule.maxInstruction)").monospacedDigit()
                    .foregroundStyle(instruction.count > Rule.maxInstruction ? Theme.Status.error : Theme.textTertiary)
            }
            .font(.caption)
            SheetButtons(error: error, confirm: "保存", enabled: valid) {
                error = save(Rule(id: rule.id, name: name.trimmingCharacters(in: .whitespaces), enabled: rule.enabled,
                                  instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines)))
                if error == nil { dismiss() }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .onAppear { name = rule.name; instruction = rule.instruction }
    }
}

// MARK: - 定时任务

private struct SchedulesCard: View {
    @Environment(AppModel.self) private var appModel
    @State private var editing: Schedule?
    @State private var deleting: Schedule?

    var body: some View {
        let sa = appModel.superagent
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("定时任务").font(Theme.Font.rowTitle)
            Text("每天到点，把一条请求交给主管——和你在主管终端里说的一样。").font(.caption).foregroundStyle(Theme.textTertiary)
            ForEach(sa.schedules) { s in
                Hairline()
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    Toggle("", isOn: Binding(get: { s.enabled }, set: { on in
                        sa.setSchedules(sa.schedules.map { var x = $0; if x.id == s.id { x.enabled = on }; return x })
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Space.sm) {
                            Text(s.name).font(Theme.Font.rowTitle).lineLimit(1)
                            Text("每天 \(s.time)").font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                        Text(s.request).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).help(s.request)
                        Text(tilde(s.repo)).font(.caption.monospaced()).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1).truncationMode(.head).help(s.repo)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    Button { editing = s } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("编辑")
                    Button { deleting = s } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(Theme.textTertiary).help("删除")
                }
            }
            Button {
                editing = Schedule(id: nextID("s", sa.schedules.map(\.id)), name: "", time: "09:00", request: "",
                                   repo: appModel.routerDirectory)
            } label: {
                Label("添加定时任务", systemImage: "plus")
            }
        }
        .saCard()
        .sheet(item: $editing) { s in
            ScheduleSheet(schedule: s, isNew: !sa.schedules.contains { $0.id == s.id }) { saved in
                attempt(sa) {
                    var list = sa.schedules
                    if let i = list.firstIndex(where: { $0.id == saved.id }) { list[i] = saved } else { list.append(saved) }
                    sa.setSchedules(list)
                }
            }
        }
        .alert("删除定时任务「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) {
                if let s = deleting { sa.setSchedules(sa.schedules.filter { $0.id != s.id }) }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

private struct ScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let schedule: Schedule
    let isNew: Bool
    let save: (Schedule) -> String?
    @State private var name = ""
    @State private var time = Date()
    @State private var request = ""
    @State private var repo = ""
    @State private var error: String?

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !repo.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text(isNew ? "添加定时任务" : "编辑定时任务").font(Theme.Font.headerTitle)
            HStack(alignment: .bottom, spacing: Theme.Space.md) {
                Field(title: "名称") {
                    TextField("例如：每日依赖巡检", text: $name).textFieldStyle(.roundedBorder)
                }
                Field(title: "每天") {
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                }
                .fixedSize()
            }
            Field(title: "请求") {
                TextEditor(text: $request).editorBox().frame(height: 100)
            }
            Field(title: "目录") {
                HStack(spacing: Theme.Space.sm) {
                    Text(repo.isEmpty ? "未选择" : tilde(repo)).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.head).help(repo)
                    Spacer()
                    Button("选择…") { if let p = pickFolder(from: repo, message: "定时任务的目录") { repo = p } }
                        .controlSize(.small)
                }
            }
            SheetButtons(error: error, confirm: "保存", enabled: valid) {
                var s = schedule
                s.name = name.trimmingCharacters(in: .whitespaces)
                s.time = Self.hhmm(time)
                s.request = request.trimmingCharacters(in: .whitespacesAndNewlines)
                s.repo = repo
                error = save(s)
                if error == nil { dismiss() }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .onAppear {
            name = schedule.name; request = schedule.request; repo = schedule.repo
            let p = schedule.time.split(separator: ":").compactMap { Int($0) }
            time = Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
        }
    }

    private static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

// MARK: - 设置

private struct SettingsCard: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let s = appModel.superagent.settings
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("设置").font(Theme.Font.rowTitle)
            SettingRow(title: "并发执行数", note: "人的跟进额外 +1") {
                Stepper(value: bind(\.slots), in: 1...8) { Text("\(s.slots)").monospacedDigit() }
            }
            SettingRow(title: "每个工单建 git worktree") {
                Toggle("", isOn: bind(\.worktree)).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingRow(title: "停下多久催报") {
                Stepper(value: bind(\.idleSeconds), in: 30...600, step: 30) { Text("\(Int(s.idleSeconds)) 秒").monospacedDigit() }
            }
            SettingRow(title: "交付前验收（LobeHub Acceptance）", note: "需要 Node ≥ 22.15；只对 Web 界面改动生效") {
                Button("安装验收工具") {
                    appModel.runSetupCommand(name: "安装验收工具", "npm install -g @lobehub/cli && lh acceptance install")
                }
                .controlSize(.small)
                Toggle("", isOn: bind(\.acceptance)).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        .saCard()
    }

    private func bind<T>(_ key: WritableKeyPath<SuperagentCore.Settings, T>) -> Binding<T> {
        let sa = appModel.superagent
        return Binding(get: { sa.settings[keyPath: key] }, set: { var s = sa.settings; s[keyPath: key] = $0; sa.saveSettings(s) })
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                if let note { Text(note).font(.caption).foregroundStyle(Theme.textTertiary) }
            }
            Spacer(minLength: Theme.Space.md)
            control()
        }
    }
}

// MARK: - 跟进（打回 / 回答 / 补充）

/// 给一个工单写打回意见 / 回答 / 补充，原样送到它的执行终端。发送失败时草稿留着、显示真实错误。
struct TicketFeedbackSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let request: TicketFeedbackRequest
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let t = appModel.superagent.views.first { $0.id == request.ticketID }?.ticket
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("\(request.kind.title) #\(request.ticketID) \(t?.title ?? "")").font(Theme.Font.headerTitle).lineLimit(2)
            if request.kind == .answer, let q = t?.attention {
                Text(q).font(.callout).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    .padding(.leading, Theme.Space.md)
                    .overlay(alignment: .leading) { Theme.Status.attention.frame(width: 3) }
                    .padding(Theme.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Status.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(Theme.textTertiary)
            }
            TextEditor(text: $text).editorBox().frame(minHeight: 120).focused($focused)
            SheetButtons(error: error, confirm: "发送", enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                         shortcut: KeyboardShortcut(.return, modifiers: .command)) {
                let sa = appModel.superagent
                error = attempt(sa) { sa.feedback(request.ticketID, text) }
                if error == nil { dismiss() }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .onAppear { focused = true }
    }

    private var hint: String? {
        switch request.kind {
        case .reject: return "说清哪里不对、要改成什么——会原样送到执行终端"
        case .add: return "会原样送到执行终端，它读到后接着做"
        case .answer: return nil
        }
    }
}

// MARK: - 小部件

private struct Banner: View {
    let text: String
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.error)
            Text(text).font(.callout).foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(Theme.textTertiary).help("关闭")
            }
        }
        .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.md)
        .background(Theme.Status.error.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(Theme.Font.sectionHeader).foregroundStyle(Theme.textTertiary).padding(.horizontal, Theme.Space.xs)
            content()
        }
    }
}

/// 默认收起的分区（最近结束、决定记录）。
private struct Collapsible<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button { expanded.toggle() } label: {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).font(Theme.Font.sectionHeader)
                }
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Space.xs)
            if expanded { content() }
        }
    }
}

/// 一张白卡里的紧凑行，行间是 Linen 细线。
private struct RowList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Hairline() }
                row(item).padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.md)
            }
        }
        .saCard(padding: 0)
    }
}

private struct IdentifiedEffect: Identifiable {
    let effect: Effect
    var id: String { "\(effect.kind.rawValue):\(effect.key)" }
}

private struct IdentifiedDecision: Identifiable {
    let decision: Decision
    var id: Int64 { decision.id }
}

private struct Hairline: View {
    var body: some View { Theme.border.frame(height: 1) }
}

private struct Field<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

/// 表单底部：错误（草稿保留）+ 取消 / 主按钮。
private struct SheetButtons: View {
    @Environment(\.dismiss) private var dismiss
    let error: String?
    let confirm: String
    let enabled: Bool
    var shortcut = KeyboardShortcut.defaultAction
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.Status.error).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm, action: action).buttonStyle(.borderedProminent).keyboardShortcut(shortcut).disabled(!enabled)
            }
        }
    }
}

/// 相对时间（「刚刚」「3 分钟前」「2 小时前」，更早显示日期），每分钟刷新；悬停看完整时间。
private struct Ago: View {
    let time: Double
    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f }()
    private static let full: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            Text(Self.text(time, now: ctx.date)).font(.caption).monospacedDigit().foregroundStyle(Theme.textTertiary)
                .lineLimit(1).fixedSize()
        }
        .help(Self.full.string(from: Date(timeIntervalSince1970: time)))
    }

    static func text(_ t: Double, now: Date) -> String {
        let d = now.timeIntervalSince1970 - t
        if d < 60 { return "刚刚" }
        if d < 3600 { return "\(Int(d / 60)) 分钟前" }
        if d < 86400 { return "\(Int(d / 3600)) 小时前" }
        return day.string(from: Date(timeIntervalSince1970: t))
    }
}

private extension View {
    func saCard(padding: CGFloat = Theme.Space.xl) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.border, lineWidth: 1))
    }

    func editorBox() -> some View {
        self.font(.callout)
            .scrollContentBackground(.hidden)
            .padding(Theme.Space.sm)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
    }
}

private extension AcceptMode {
    var panelHint: String {
        switch self {
        case .off: return "关闭：只接你明确提出的请求。"
        case .observe: return "只观察：照常研判，只记录「本会接单」，不执行。"
        case .auto: return "自动接单：命中规则就接单。"
        }
    }
}

private extension EffectKind {
    var panelLabel: String {
        switch self {
        case .launch: return "启动"
        case .deliver: return "送达"
        case .relay: return "转达给主管"
        case .stop: return "中断"
        case .notify: return "通知"
        }
    }
}

private extension DecisionKind {
    var panelLabel: String {
        switch self {
        case .accept: return "接单"
        case .ignore: return "不接"
        case .wouldAccept: return "本会接单"
        case .unavailable: return "研判超时"
        case .stop: return "停止"
        case .attach: return "挂接"
        }
    }
}

/// 跑一个写库操作，把它的错误（`actionError`）拿回来给表单显示，不再弹到面板顶部。
@MainActor private func attempt(_ sa: SuperagentRuntime, _ body: () -> Void) -> String? {
    sa.actionError = nil
    body()
    defer { sa.actionError = nil }
    return sa.actionError
}

/// 下一个 `r1` / `s1` 式 id：已有编号的最大值 + 1（删掉的编号不复用，旧研判记录不会指错）。
private func nextID(_ prefix: String, _ taken: [String]) -> String {
    let n = taken.compactMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil }.max() ?? 0
    return "\(prefix)\(n + 1)"
}

private func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

@MainActor private func pickFolder(from start: String, message: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "选择"
    panel.message = message
    if !start.isEmpty { panel.directoryURL = URL(fileURLWithPath: start) }
    return panel.runModal() == .OK ? panel.url?.path : nil
}
