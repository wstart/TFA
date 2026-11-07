import AppKit
import SwiftUI
import SuperagentCore

// 我的清单（TFA-工作清单-需求文档 §9.1、注意事项 F）：首屏是任务，不是工单。分区 需要你 / 进行中 / 待分配 / 已完成，
// 空分区不显示；琥珀只出现在需要你的地方（注意事项 A-04）；行点击在同一面板内推入任务卡（F-06）。
// 人能看到的概念只有：任务、清单项、谁来做、工作流、需要你（A-03）。

/// 详情区的「我的清单」：`appModel.worklistTaskID` 为 nil 显示清单，否则显示那张任务卡（同一面板内推入，带返回）。
struct WorklistView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showingNewTask = false
    /// 「谁来做」sheet 正在处理的任务。
    @State private var assigning: TaskView?
    /// 建完任务 → 关掉「+ 任务」后再弹「谁来做」（两个 sheet 不能同时开）。
    @State private var pendingAssign: Int64?
    @State private var searching = false
    @State private var search = ""
    @State private var filter: WorklistFilter = .all
    @State private var project: String?
    @State private var showDone = false

    var body: some View {
        let sa = appModel.superagent
        VStack(spacing: 0) {
            if let id = appModel.worklistTaskID {
                // 「‹ 我的清单 · 任务 A-12」：返回在标题左侧（参考图 02）。
                ToolHeaderBar(icon: "list.bullet.clipboard", title: "任务 A-\(id)",
                              subtitle: "这张卡上的「需要你」只有一条；工单号可点，跳到它的终端。", leading: {
                    Button {
                        appModel.worklistTaskID = nil
                    } label: {
                        Label("我的清单", systemImage: "chevron.left")
                            .font(Theme.Font.headerTitle)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .help("回到我的清单")
                    .accessibilityLabel("返回我的清单")
                    .keyboardShortcut("[", modifiers: .command)
                })
                Divider()
                if let tv = sa.task(id) {
                    TaskCard(view: tv, assign: { assigning = tv })
                        .id(tv.id) // 换一张卡就换一份状态（正在加的项、乐观勾选、活动）
                } else {
                    VStack(spacing: Theme.Space.lg) {
                        Text("任务 A-\(id) 不在清单里。").font(Theme.Font.emptyBody).foregroundStyle(Theme.textTertiary)
                        Button("回到我的清单") { appModel.worklistTaskID = nil }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ToolHeaderBar(icon: "list.bullet.clipboard", title: "我的清单",
                              subtitle: "先定谁来做。需要你的事在最上面；健康的清单不占地方。", trailing: {
                    if searching {
                        TextField("搜索任务", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .accessibilityLabel("搜索任务")
                    }
                    Button {
                        searching.toggle()
                        if !searching { search = "" }
                    } label: {
                        Image(systemName: searching ? "xmark" : "magnifyingglass")
                    }
                    .help(searching ? "关闭搜索" : "搜索任务")
                    .accessibilityLabel(searching ? "关闭搜索" : "搜索任务")
                    Button {
                        showingNewTask = true
                    } label: {
                        Label("任务", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("新建任务")
                    .accessibilityLabel("新建任务")
                })
                Divider()
                list
            }
        }
        .background(Theme.canvas)
        .sheet(isPresented: $showingNewTask, onDismiss: {
            // 建完直接弹「谁来做」（需求文档 §9.1）。
            if let id = pendingAssign {
                pendingAssign = nil
                if let tv = sa.task(id) { assigning = tv }
            }
        }) {
            NewTaskSheet { id in
                appModel.worklistTaskID = id
                pendingAssign = id
            }
            .environment(appModel)
        }
        .sheet(item: $assigning) { tv in
            AssignSheet(view: tv, roles: sa.roles).environment(appModel)
        }
    }

    // MARK: 清单

    private var list: some View {
        let sa = appModel.superagent
        let sections = WorklistSections.make(sa.tasks, filter: filter, project: project, search: search)
        let projects = WorklistSections.projects(sa.tasks)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if let e = sa.setupError { Banner(text: e) }
                    if let e = sa.actionError { Banner(text: e) { sa.actionError = nil } }
                    InterruptionRow(used: sa.interruptionsToday, budget: sa.settings.interruptionBudget,
                                    filter: $filter, project: $project, projects: projects)
                    if sa.tasks.isEmpty {
                        empty("清单是空的。对主管说一句，或点 +。")
                    } else if sections.isEmpty {
                        empty("这个筛选下没有任务。")
                    }
                    if !sections.needsYou.isEmpty {
                        section("需要你", count: sections.needsYou.count, attention: true) {
                            ForEach(sections.needsYou) { row($0) }
                        }
                    }
                    if !sections.working.isEmpty {
                        section("进行中", count: sections.working.count) {
                            ForEach(sections.working) { row($0) }
                        }
                    }
                    if !sections.unassigned.isEmpty {
                        section("待分配", count: sections.unassigned.count) {
                            ForEach(sections.unassigned) { row($0) }
                        }
                    }
                    if !sections.done.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            Button {
                                showDone.toggle()
                            } label: {
                                HStack(spacing: Theme.Space.sm) {
                                    Text("已完成").font(Theme.Font.sectionHeader).foregroundStyle(Theme.textPrimary)
                                    CountBadge(count: sections.done.count)
                                    Spacer()
                                    HStack(spacing: Theme.Space.xs) {
                                        Text(showDone ? "收起" : "展开")
                                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                            .rotationEffect(.degrees(showDone ? 90 : 0))
                                    }
                                    .font(.caption).foregroundStyle(Theme.textTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, Theme.Space.xs)
                            .accessibilityLabel("已完成 \(sections.done.count) 件，\(showDone ? "收起" : "展开")")
                            if showDone {
                                ForEach(sections.done) { row($0) }
                            }
                        }
                    }
                    SettingsFold()
                        .padding(.top, Theme.Space.md)
                        .id("settings")
                }
                .padding(Theme.Space.xxl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                if appModel.worklistShowsSettings { proxy.scrollTo("settings", anchor: .top) }
            }
            .onChange(of: appModel.worklistShowsSettings) { _, show in
                if show { proxy.scrollTo("settings", anchor: .top) }
            }
        }
    }

    private func row(_ tv: TaskView) -> some View {
        TaskRow(view: tv, open: { appModel.worklistTaskID = tv.id }, assign: { assigning = tv })
    }

    private func section<Content: View>(_ title: String, count: Int, attention: Bool = false,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text(title).font(Theme.Font.sectionHeader).foregroundStyle(Theme.textPrimary)
                CountBadge(count: count, attention: attention)
            }
            .padding(.horizontal, Theme.Space.xs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) \(count) 件")
            content()
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.emptyBody)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.xxxl)
    }
}

// MARK: - 分区与筛选（纯函数，可测）

enum WorklistFilter: Hashable {
    case all, today, week
}

/// 清单页的四个分区：需要你 → 进行中 → 待分配（有未分配清单项）→ 已完成（最近 30）。
struct WorklistSections: Equatable {
    var needsYou: [TaskView] = []
    var working: [TaskView] = []
    var unassigned: [TaskView] = []
    var done: [TaskView] = []

    var isEmpty: Bool { needsYou.isEmpty && working.isEmpty && unassigned.isEmpty && done.isEmpty }

    static func make(_ tasks: [TaskView], filter: WorklistFilter = .all, project: String? = nil, search: String = "",
                     now: Date = Date(), calendar: Calendar = .current) -> WorklistSections {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var r = WorklistSections()
        for tv in tasks {
            if let project, tv.task.scope != project { continue }
            if !q.isEmpty, !matches(tv, q) { continue }
            if !within(tv, filter, now: now, calendar: calendar) { continue }
            if !tv.task.isOpen { r.done.append(tv) }
            else if !tv.needsYou.isEmpty { r.needsYou.append(tv) }
            else if tv.unassignedCount > 0 { r.unassigned.append(tv) }
            else { r.working.append(tv) }
        }
        // 需要你：按第一件事的 PersonAction 顺序，再新的在前（§4.3）；其余新的在前，不随回报跳动。
        r.needsYou.sort { ($0.needsYou[0], -$0.id) < ($1.needsYou[0], -$1.id) }
        r.working.sort { $0.id > $1.id }
        r.unassigned.sort { $0.id > $1.id }
        r.done.sort { $0.task.updatedAt > $1.task.updatedAt }
        r.done = Array(r.done.prefix(30))
        return r
    }

    /// 「按项目」菜单的候选：任务里出现过的目录（去重，按名字）。
    static func projects(_ tasks: [TaskView]) -> [String] {
        Array(Set(tasks.map(\.task.scope).filter { !$0.isEmpty })).sorted { projectName($0) < projectName($1) }
    }

    static func projectName(_ path: String) -> String { (path as NSString).lastPathComponent }

    private static func matches(_ tv: TaskView, _ q: String) -> Bool {
        if tv.task.label.lowercased().contains(q) || tv.task.title.lowercased().contains(q) || tv.task.request.lowercased().contains(q) { return true }
        if projectName(tv.task.scope).lowercased().contains(q) { return true }
        return tv.items.contains { $0.text.lowercased().contains(q) }
    }

    /// 今天 = 需要你的 + 今天到期（含过期）的 + 今天有动静的；本周同理按本周算。
    private static func within(_ tv: TaskView, _ filter: WorklistFilter, now: Date, calendar: Calendar) -> Bool {
        let interval: DateInterval
        switch filter {
        case .all: return true
        case .today: interval = calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 86400)
        case .week: interval = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: now, duration: 7 * 86400)
        }
        if tv.task.isOpen && !tv.needsYou.isEmpty { return true }
        if tv.task.isOpen, let due = tv.task.due, due < interval.end.timeIntervalSince1970 { return true }
        return tv.task.updatedAt >= interval.start.timeIntervalSince1970
    }
}

/// 截止的说法：清单行只在 3 天内显示（注意事项 F-05）；任务卡的 chip 全都显示。
enum DueText {
    private static let weekday = ["日", "一", "二", "三", "四", "五", "六"]
    private static let date: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日"; return f }()

    static func short(_ due: Double, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard days(due, now: now, calendar: calendar) <= 3 else { return nil }
        return long(due, now: now, calendar: calendar)
    }

    static func long(_ due: Double, now: Date = Date(), calendar: Calendar = .current) -> String {
        let d = Date(timeIntervalSince1970: due)
        let n = days(due, now: now, calendar: calendar)
        if n < 0 { return "已过期 \(date.string(from: d))" }
        if n == 0 { return "今天" }
        if n == 1 { return "明天" }
        if n < 7 { return "周" + weekday[calendar.component(.weekday, from: d) - 1] }
        return date.string(from: d)
    }

    private static func days(_ due: Double, now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                to: calendar.startOfDay(for: Date(timeIntervalSince1970: due))).day ?? 0
    }
}

// MARK: - 顶部一行：打扰计数 + 筛选

/// 「今天打扰你 N / 预算 次」（注意事项 G-03：超预算只显示，不压制）+ 今天 / 本周 / 按项目。
private struct InterruptionRow: View {
    let used: Int
    let budget: Int
    @Binding var filter: WorklistFilter
    @Binding var project: String?
    let projects: [String]

    var body: some View {
        HStack(spacing: Theme.Space.lg) {
            HStack(spacing: 3) {
                ForEach(0..<max(budget, 1), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i < used ? Theme.brand : Theme.border) // 已用的格子是墨色：琥珀只表示需要你（A-04）
                        .frame(width: 10, height: 12)
                }
            }
            .accessibilityHidden(true)
            Text("今天打扰你 \(used) / \(budget) 次")
                .font(.callout).monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Space.md)
            HStack(spacing: Theme.Space.lg) {
                filterButton("今天", .today)
                filterButton("本周", .week)
                Menu {
                    Button("全部项目") { project = nil }
                    if !projects.isEmpty { Divider() }
                    ForEach(projects, id: \.self) { p in
                        Button(WorklistSections.projectName(p)) { project = p }
                    }
                } label: {
                    Text(project.map(WorklistSections.projectName) ?? "按项目")
                        .font(.callout.weight(project == nil ? .regular : .semibold))
                        .foregroundStyle(project == nil ? Theme.textTertiary : Theme.textPrimary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(project.map { "只看 \($0)" } ?? "按项目目录筛选")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
    }

    private func filterButton(_ title: String, _ value: WorklistFilter) -> some View {
        let on = filter == value
        return Button {
            filter = on ? .all : value
        } label: {
            Text(title)
                .font(.callout.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary)
        }
        .buttonStyle(.plain)
        .help(on ? "取消筛选" : "只看\(title)的任务")
        .accessibilityLabel(on ? "只看\(title)，已选中" : "只看\(title)")
    }
}

// MARK: - 清单行（注意事项 F-05）

/// 白卡 · Linen 1pt · 最小高 52：第一行 `A-12` + 标题 + 右侧 `StateTag`（只在需要你时着色）+ 该阶段的动作；
/// 第二行 进度 `3/5` · 截止（3 天内）· 来源 · 执行者 chips（≤3）。需要你时整行 amber 6% 底。
struct TaskRow: View {
    let view: TaskView
    let open: () -> Void
    let assign: () -> Void

    var body: some View {
        let tag = view.stateTag
        let needs = view.task.isOpen && !view.needsYou.isEmpty
        HStack(spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Theme.Space.sm) {
                    Text(view.task.label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    Text(view.task.title).font(Theme.Font.rowTitle).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.tail).help(view.task.title)
                }
                HStack(spacing: Theme.Space.sm) {
                    Text(meta).font(Theme.Font.rowSubtitle).monospacedDigit().foregroundStyle(Theme.textSecondary).lineLimit(1)
                    ForEach(view.assignees.prefix(3), id: \.self) { AssigneeChip(assignee: $0) }
                    if view.assignees.isEmpty && view.task.isOpen { AssigneeChip(assignee: .unassigned) }
                }
            }
            Spacer(minLength: Theme.Space.md)
            StateTag(text: tag.text, tint: tag.tint)
            if view.task.isOpen {
                if needs {
                    TaskNeedActions(view: view, assign: assign)
                } else if view.unassignedCount > 0 {
                    Button("谁来做…", action: assign).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Theme.Space.md)
        .frame(minHeight: 52)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(needs ? Theme.Status.attention.opacity(0.06) : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("任务 \(view.task.label) \(view.task.title)，\(tag.text)，\(meta)")
        .accessibilityAddTraits(.isButton)
    }

    private var meta: String {
        var parts = ["\(view.doneCount)/\(view.totalCount)"]
        if view.task.isOpen, let due = view.task.due, let s = DueText.short(due) { parts.append(s) }
        if view.task.source != .manual { parts.append("来自\(view.task.source.label)") }
        return parts.joined(separator: " · ")
    }
}

/// 第一件需要你的事对应的动作（和 `TicketBar.actions` 同一套；清单行与任务卡的需要你条共用）：
/// 待评审 → 打回… + 通过；等你回答 → 回答…；受阻 / 失败 / 送达失败 / 停下未回报 → 补充… + 重试；
/// 受阻且没有工单（前置任务被取消）→ 谁来做…。任务层的待评审（阶段 kind == review）走 approveTask / rejectTask。
struct TaskNeedActions: View {
    @Environment(AppModel.self) private var appModel
    let view: TaskView
    var assign: (() -> Void)?

    var body: some View {
        let sa = appModel.superagent
        switch view.needsYou.first {
        case .review?:
            if view.task.stageKind != .review, let t = view.ticket(needing: .review) {
                Button("打回…") { appModel.ticketFeedback = TicketFeedbackRequest(ticketID: t.id, kind: .reject) }
                Button(sa.merging.contains(t.id) ? "合并中…" : "通过") { sa.approve(t.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(sa.merging.contains(t.id))
                    .help(t.ticket.branch.isEmpty ? "结单" : "把 \(t.ticket.branch) 合并进主仓库当前分支，然后结单")
            } else {
                Button("打回…") { appModel.taskFeedback = TaskFeedbackRequest(taskID: view.id) }
                    .help("意见送给原工单；没有工单的项会成为新的清单项")
                Button(sa.mergingTasks.contains(view.id) ? "合并中…" : "通过") { sa.approveTask(view.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(sa.mergingTasks.contains(view.id))
                    .help("任务完成；名下交付了的开发工单分支先合并进主仓库当前分支，合不了就留在待评审")
            }
        case .answer?:
            if let t = view.ticket(needing: .answer) {
                Button("回答…") { appModel.ticketFeedback = TicketFeedbackRequest(ticketID: t.id, kind: .answer) }
                    .buttonStyle(.borderedProminent)
            }
        case .blocked?, .failed?, .delivery?, .stalled?:
            if let t = view.ticket(needing: view.needsYou[0]) {
                Button("补充…") { appModel.ticketFeedback = TicketFeedbackRequest(ticketID: t.id, kind: .add) }
                Button("重试") { sa.retry(t.id) }.buttonStyle(.borderedProminent)
            } else if let assign {
                Button("谁来做…", action: assign).buttonStyle(.borderedProminent)
            }
        case nil:
            EmptyView()
        }
    }
}

// MARK: - 底部「设置」折叠区

/// 主管面板的内容都在这里（`WorklistSettings`）；工具栏的「主管」按钮用 `openWorklist(settings: true)` 展开它。
private struct SettingsFold: View {
    @Environment(AppModel.self) private var appModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Button {
                expanded.toggle()
                if !expanded { appModel.worklistShowsSettings = false }
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("设置").font(Theme.Font.sectionHeader).foregroundStyle(Theme.textPrimary)
                    Text("主管终端 · 工作流模板 · 角色 · 规则 · 定时任务 · 决定记录")
                        .font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Space.xs)
            .accessibilityLabel(expanded ? "收起设置" : "展开设置")
            if expanded { WorklistSettings() }
        }
        .onAppear { expanded = appModel.worklistShowsSettings }
        .onChange(of: appModel.worklistShowsSettings) { _, show in
            if show { expanded = true }
        }
    }
}

// MARK: - 「+ 任务」（需求文档 §9.1）

/// 标题 + 原文（可选）+ 范围（项目目录）+ 清单项（每行一条）+ 工作流模板 + 优先级 + 截止。建完回调新任务的 id。
struct NewTaskSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let created: (Int64) -> Void
    @State private var title = ""
    @State private var request = ""
    @State private var scope = ""
    @State private var itemsText = ""
    @State private var workflow: String?
    @State private var priority: TaskPriority = .medium
    @State private var hasDue = false
    @State private var due = Date()
    @State private var error: String?
    @FocusState private var focused: Bool

    private var items: [String] { Self.parseItems(itemsText) }
    private var problem: String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "写一个标题" }
        if t.count > WorkTask.maxTitle { return "标题最多 \(WorkTask.maxTitle) 字" }
        if let long = items.first(where: { $0.count > Item.maxText }) { return "清单项最多 \(Item.maxText) 字：\(long.prefix(20))…" }
        return nil
    }

    var body: some View {
        let sa = appModel.superagent
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("新建任务").font(Theme.Font.headerTitle)
            Field(title: "标题") {
                TextField("一句话说清要做成什么", text: $title).textFieldStyle(.roundedBorder).focused($focused)
            }
            Field(title: "原文（可选；执行者从这里推导需求）") {
                TextEditor(text: $request).editorBox().frame(height: 72)
            }
            Field(title: "清单项（每行一条，可验证的结果；留空就一项 = 标题）") {
                TextEditor(text: $itemsText).editorBox().frame(height: 96)
            }
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                Field(title: "范围（项目目录）") {
                    HStack(spacing: Theme.Space.sm) {
                        Text(scope.isEmpty ? "不针对项目" : tilde(scope)).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.head).help(scope)
                        if !scope.isEmpty { Button("清除") { scope = "" }.controlSize(.small) }
                        Button("选择…") { if let p = pickFolder(from: scope, message: "任务的项目目录；交给 Agent 的项在这里工作") { scope = p } }
                            .controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                Field(title: "工作流") {
                    Picker("", selection: $workflow) {
                        Text("按范围默认").tag(String?.none)
                        ForEach(sa.workflows) { w in Text(w.name).tag(String?.some(w.id)) }
                    }
                    .labelsHidden().fixedSize()
                }
                Field(title: "优先级") {
                    Picker("", selection: $priority) {
                        ForEach(TaskPriority.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Field(title: "截止") {
                    HStack(spacing: Theme.Space.sm) {
                        Toggle("", isOn: $hasDue).labelsHidden().toggleStyle(.checkbox)
                        DatePicker("", selection: $due, displayedComponents: .date).labelsHidden().disabled(!hasDue)
                    }
                }
            }
            Text(problem ?? "交给 Agent 的项之后在「谁来做」里定；你自己做的项不开终端。")
                .font(.caption).foregroundStyle(problem == nil ? Theme.textTertiary : Theme.Status.error)
            SheetButtons(error: error, confirm: "建任务", enabled: problem == nil,
                         shortcut: KeyboardShortcut(.return, modifiers: .command)) {
                var id: Int64?
                error = attempt(sa) {
                    id = sa.createTask(.init(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                             request: request.trimmingCharacters(in: .whitespacesAndNewlines), scope: scope,
                                             items: items, workflow: workflow, priority: priority,
                                             due: hasDue ? Calendar.current.startOfDay(for: due).addingTimeInterval(86399).timeIntervalSince1970 : nil))
                }
                if error == nil, let id {
                    created(id)
                    dismiss()
                } else if error == nil {
                    error = "没有建成任务"
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
        .onAppear {
            scope = WorkspaceStore.shared.selected?.path ?? ""
            focused = true
        }
    }

    /// 每行一条；去掉行首的「- 」「• 」「1. 」「1、」。
    static func parseItems(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            var s = line.trimmingCharacters(in: .whitespaces)
            if let r = s.range(of: #"^(\d+[.、)]|[-•*])\s*"#, options: .regularExpression) { s.removeSubrange(r) }
            s = s.trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
    }
}

// MARK: - 打回任务（需求文档 §5.1 rejectTask）

/// 意见送给原工单（有工单的项 → feedback），没有工单时成为新的清单项；任务回到进行中。
struct TaskRejectSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let request: TaskFeedbackRequest
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let sa = appModel.superagent
        let tv = sa.task(request.taskID)
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("打回 A-\(request.taskID) \(tv?.task.title ?? "")").font(Theme.Font.headerTitle).lineLimit(2)
            Text("说清哪里不对、要改成什么。意见会原样送到原工单的执行终端；没有工单的项会变成一条新的清单项。")
                .font(.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).editorBox().frame(minHeight: 120).focused($focused)
            SheetButtons(error: error, confirm: "打回", enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                         shortcut: KeyboardShortcut(.return, modifiers: .command)) {
                error = attempt(sa) { sa.rejectTask(request.taskID, text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if error == nil { dismiss() }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .onAppear { focused = true }
    }
}
