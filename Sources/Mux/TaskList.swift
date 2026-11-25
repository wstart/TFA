import AppKit
import SwiftUI
import SuperagentCore

// 我的工作（TFA-工作清单-需求文档 §9.1、注意事项 F；设计评审 2026-11-08）：首屏是任务，不是工单。分区按 1A 的顺序
// 需要你 / 待分配 / 进行中 / 待领取 / 已完成，空分区不显示；琥珀只出现在需要你的地方（注意事项 A-04）；行点击在同一面板内推入任务卡（F-06）。
// 人能看到的概念只有：任务、清单项、谁来做、工作流、需要你（A-03）。

/// 详情区的「我的工作」：`appModel.worklistTaskID` 为 nil 时在 清单 / 主管 / 知识库 三栏间切换，否则显示那张任务卡（同一面板内推入，带返回）。
struct WorklistView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingNewTask = false
    @State private var activeSeed: AppModel.NewTaskSeed?
    @State private var showingNewKnowledge = false
    /// 「谁来做」sheet 正在处理的任务；`assignFocus` = 「改派第 N 项…」要定位到的项。
    @State private var assigning: TaskView?
    @State private var assignFocus: Int?
    /// 「完成任务…」确认单（5A，wl-card 的 `TaskFinishSheet`）正在处理的任务。
    @State private var finishing: TaskView?
    /// 建完任务 → 关掉「+ 任务」后再弹「谁来做」（两个 sheet 不能同时开）。
    @State private var pendingAssign: Int64?
    @State private var searching = false
    @State private var search = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var filter: WorklistFilter = .all
    @State private var originFilter: WorklistOriginFilter = .all
    @State private var onlineOrigin: String?
    @State private var project: String?
    @State private var showDone = false
    /// 清单区的宽度：≥ 900 第三行显示来源 / 执行者 chips，< 720 行尾动作收进「…」菜单（Pass 1 / Pass 6）。
    @State private var width: CGFloat = 980
    /// 键盘焦点所在的行：↑↓ 移动、回车打开任务卡（Pass 6）。
    @FocusState private var focusedRow: Int64?
    /// 行内回声（3A）：有回声的行原地停住（分区、位置、当时的样子），回声消失才归位。
    @State private var holds: [Int64: WorklistSections.Hold] = [:]
    /// 上一份任务列表：回声到来时任务多半已经变了（通过 → 已完成），停住的位置要按变化前的算。
    @State private var previousTasks: [TaskView] = []

    var body: some View {
        let sa = appModel.superagent
        VStack(spacing: 0) {
            if let id = appModel.worklistTaskID {
                VStack(spacing: 0) {
                    ToolHeaderBar(icon: "list.bullet.clipboard", title: "任务 A-\(id)",
                                  subtitle: sa.task(id)?.headerStatus(now: Date()) ?? "找不到该任务。", leading: {
                        Button {
                            Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) {
                                appModel.worklistTaskID = nil
                            }
                        } label: {
                            Label("我的工作", systemImage: "chevron.left")
                                .font(Theme.Font.headerTitle)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(PaperPressButtonStyle(hoverWash: true))
                        .help("回到我的工作")
                        .accessibilityLabel("返回我的工作")
                        .keyboardShortcut("[", modifiers: .command)
                    })
                    if let tv = sa.task(id) {
                        TaskCard(view: tv, assign: { assigning = tv })
                            .id(tv.id)
                    } else {
                        VStack(spacing: Theme.Space.lg) {
                            Text("找不到任务 A-\(id)，可能已删除或尚未同步。")
                                .font(Theme.Font.emptyBody)
                                .foregroundStyle(Theme.textTertiary)
                            Button("回到我的工作") {
                                Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) {
                                    appModel.worklistTaskID = nil
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .transition(.opacity)
            } else {
                let tab = appModel.worklistTab
                WorklistHeader(empty: sa.loaded && sa.tasks.isEmpty && holds.isEmpty) {
                    if tab != .router {
                        let inKB = tab == .knowledge
                        if searching {
                            TextField(inKB ? "搜索知识库" : "搜索任务", text: $search)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                                .focused($searchFieldFocused)
                                .onExitCommand {
                                    Theme.Motion.run(Theme.Motion.snap, reduceMotion: reduceMotion) {
                                        searching = false
                                        search = ""
                                        searchFieldFocused = false
                                    }
                                }
                                .accessibilityLabel(inKB ? "搜索知识库" : "搜索任务")
                                .transition(Theme.Motion.reveal(edge: .trailing, reduceMotion: reduceMotion))
                        }
                        Button {
                            Theme.Motion.run(Theme.Motion.snap, reduceMotion: reduceMotion) {
                                searching.toggle()
                                if searching {
                                    DispatchQueue.main.async { searchFieldFocused = true }
                                } else {
                                    search = ""
                                    searchFieldFocused = false
                                }
                            }
                        } label: {
                            Image(systemName: searching ? "xmark" : "magnifyingglass")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .help(searching ? "关闭搜索" : (inKB ? "搜索知识库" : "搜索任务"))
                        .accessibilityLabel(searching ? "关闭搜索" : (inKB ? "搜索知识库" : "搜索任务"))
                    }
                    if tab == .knowledge {
                        Button {
                            showingNewKnowledge = true
                        } label: {
                            Label("经验", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("手动沉淀一条项目经验或避坑指南")
                        .accessibilityLabel("记一条经验")
                    } else {
                        Button {
                            activeSeed = nil
                            showingNewTask = true
                        } label: {
                            Label("任务", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("新建任务")
                        .accessibilityLabel("新建任务")
                    }
                    Button {
                        appModel.openWorklistSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("设置：主管终端、组织、工作流、角色、规则、定时任务、记录")
                    .accessibilityLabel("清单设置")
                }
                switch tab {
                case .tasks:
                    list
                        .transition(.opacity)
                case .router:
                    EmbeddedRouterTerminalView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .knowledge:
                    KnowledgeBrowserView(search: search, showingNewEntry: $showingNewKnowledge)
                        .transition(.opacity)
                }
            }
        }
        .background(Theme.canvas)
        // 挂在整页上，不挂在清单上：任务卡开着的时候回声到期也要放开停住的行，否则它会一直钉在旧分区里。
        .onAppear {
            previousTasks = sa.tasks
            consumeNewTaskSeed()
        }
        .onChange(of: sa.tasks) { old, _ in previousTasks = old }
        .onChange(of: sa.actionEchoes) { old, new in updateHolds(old: old, new: new) }
        .onChange(of: appModel.newTaskSeed) { _, _ in consumeNewTaskSeed() }
        .onChange(of: appModel.worklistTab) { _, tab in
            if tab == .router {
                searching = false
                search = ""
            }
            appModel.syncEmbeddedRouterViewing()
        }
        .onChange(of: appModel.worklistTaskID) { _, _ in
            appModel.syncEmbeddedRouterViewing()
        }
        .onChange(of: appModel.worklistSearchTogglePulse) { _, _ in
            guard appModel.worklistTaskID == nil, appModel.worklistTab != .router else { return }
            Theme.Motion.run(Theme.Motion.snap, reduceMotion: reduceMotion) {
                if searching {
                    searching = false
                    search = ""
                    searchFieldFocused = false
                } else {
                    searching = true
                    DispatchQueue.main.async { searchFieldFocused = true }
                }
            }
        }
        .onChange(of: originFilter) { _, newValue in
            if newValue == .online {
                project = nil
            } else {
                onlineOrigin = nil
            }
        }
        .sheet(isPresented: $showingNewTask, onDismiss: {
            activeSeed = nil
            // 若建单时未自动完成分配（未勾选或需手选目录），再弹「谁来做」（需求文档 §9.1）。
            if let id = pendingAssign {
                pendingAssign = nil
                if let tv = sa.task(id), tv.unassignedCount > 0 { assigning = tv }
            }
        }) {
            NewTaskSheet(seed: activeSeed) { id in
                appModel.worklistTaskID = id
                pendingAssign = id
            }
            .environment(appModel)
        }
        .sheet(item: $assigning, onDismiss: { assignFocus = nil }) { tv in
            AssignSheet(view: tv, roles: sa.roles, focusOrd: assignFocus).environment(appModel)
        }
        .sheet(item: $finishing) { tv in
            TaskFinishSheet(taskID: tv.id).environment(appModel)
        }
    }

    // MARK: 清单

    private var list: some View {
        let sa = appModel.superagent
        let activeProject = originFilter == .online ? nil : project
        let activeOnlineOrigin = originFilter == .online ? onlineOrigin : nil
        let sections = WorklistSections.make(
            sa.tasks,
            filter: filter,
            project: activeProject,
            search: search,
            originFilter: originFilter,
            onlineOrigin: activeOnlineOrigin
        ).holding(holds)
        let originCounts = WorklistSections.originCounts(sa.tasks)
        let hasOnlineContext = sa.org.registered || originCounts.online > 0 || originFilter != .all
        let projects = WorklistSections.projects(
            originFilter == .local || !hasOnlineContext
                ? sa.tasks.filter { ($0.task.origin ?? "").isEmpty }
                : sa.tasks
        )
        let multipleLocalProjects = projects.count > 1
        let hasActiveFilter = originFilter != .all || filter != .all || project != nil || onlineOrigin != nil || !search.isEmpty
        var onlineOrigins = WorklistSections.onlineOrigins(sa.tasks)
        if sa.org.registered, !sa.org.settings.serverURL.isEmpty, !onlineOrigins.contains(sa.org.settings.serverURL) {
            onlineOrigins.append(sa.org.settings.serverURL)
            onlineOrigins.sort()
        }
        let order = sections.orderedIDs(showDone: showDone)
        let compact = width < 720, wide = width >= 900
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if let e = sa.setupError {
                    Banner(text: e)
                        .transition(Theme.Motion.reveal(edge: .top, reduceMotion: reduceMotion))
                }
                if let e = sa.actionError {
                    Banner(text: e) {
                        Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) {
                            sa.actionError = nil
                        }
                    } // 页顶只留全局错误；按任务的贴在行下（3A）
                    .transition(Theme.Motion.reveal(edge: .top, reduceMotion: reduceMotion))
                }
                if !sa.loaded {
                    // 首个快照还没到：什么都不画，免得空态闪一下（Pass 2）。
                    EmptyView()
                } else {
                    EmbeddedRouterBar(onManualNewTask: { activeSeed = nil; showingNewTask = true })
                    if sa.tasks.isEmpty && holds.isEmpty {
                        emptyState
                    } else {
                        if !sa.tasks.isEmpty || originFilter != .all || filter != .all || project != nil || onlineOrigin != nil {
                            FilterRow(
                                originFilter: $originFilter,
                                originCounts: originCounts,
                                hasOnlineContext: hasOnlineContext,
                                onlineOrigin: $onlineOrigin,
                                onlineOrigins: onlineOrigins,
                                orgRegistered: sa.org.registered,
                                orgName: { sa.org.organizationName(for: $0) },
                                filter: $filter,
                                project: $project,
                                projects: projects,
                                hasActiveFilter: hasActiveFilter,
                                onReset: { resetFilters() }
                            )
                        }
                        if sections.isEmpty {
                            if originFilter == .online && originCounts.online == 0 {
                                onlineEmptyState
                            } else if originFilter == .local && originCounts.local == 0 {
                                empty("当前没有本地项目任务。")
                            } else {
                                filteredEmptyState
                            }
                        }
                        ForEach(WorklistSections.Kind.allCases, id: \.self) { kind in
                            let tasks = sections[kind]
                            if !tasks.isEmpty {
                                let count = sections.counts[kind] ?? tasks.count
                                if kind == .done {
                                    doneSection(tasks, count: count, order: order, wide: wide, compact: compact,
                                                hasOnlineContext: hasOnlineContext, multipleLocalProjects: multipleLocalProjects)
                                } else {
                                    section(kind, tasks, count: count, order: order, wide: wide, compact: compact,
                                            hasOnlineContext: hasOnlineContext, multipleLocalProjects: multipleLocalProjects)
                                }
                            }
                        }
                    }
                }
            }
            .animation(Theme.Motion.value(Theme.Motion.panel, reduceMotion: reduceMotion), value: sa.setupError != nil)
            .animation(Theme.Motion.value(Theme.Motion.panel, reduceMotion: reduceMotion), value: sa.actionError != nil)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// 新来的回声 → 按变化前的清单记下那行的分区和位置（任务多半已经变了：通过 → 已完成，领取失败 → 占位行没了）；
    /// 回声消失 → 放开，行归位。
    private func updateHolds(old: [Int64: String], new: [Int64: String]) {
        let sa = appModel.superagent
        let activeProject = originFilter == .online ? nil : project
        let activeOnlineOrigin = originFilter == .online ? onlineOrigin : nil
        let before = WorklistSections.make(
            previousTasks,
            filter: filter,
            project: activeProject,
            search: search,
            originFilter: originFilter,
            onlineOrigin: activeOnlineOrigin
        )
        let current = WorklistSections.make(
            sa.tasks,
            filter: filter,
            project: activeProject,
            search: search,
            originFilter: originFilter,
            onlineOrigin: activeOnlineOrigin
        )
        for id in new.keys where old[id] == nil && holds[id] == nil {
            guard let place = before.placement(of: id) ?? current.placement(of: id),
                  let snapshot = previousTasks.first(where: { $0.id == id }) ?? sa.task(id) else { continue }
            holds[id] = .init(kind: place.kind, index: place.index, snapshot: snapshot)
        }
        let expired = old.keys.filter { new[$0] == nil }
        if !expired.isEmpty {
            Theme.Motion.run(Theme.Motion.layout, reduceMotion: reduceMotion) {
                for id in expired { holds[id] = nil }
            }
        }
    }

    private func row(_ tv: TaskView, kind: WorklistSections.Kind, order: [Int64], wide: Bool, compact: Bool,
                     hasOnlineContext: Bool, multipleLocalProjects: Bool) -> some View {
        TaskRow(view: tv, kind: kind, wide: wide, compact: compact,
                hasOnlineContext: hasOnlineContext, multipleLocalProjects: multipleLocalProjects,
                focused: $focusedRow,
                open: {
                    Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) {
                        appModel.openWorklist(task: tv.id)
                    }
                },
                assign: { assigning = tv },
                reassign: { ord in assignFocus = ord; assigning = tv }, finish: { finishing = tv }) { step in
            guard let i = order.firstIndex(of: tv.id), order.indices.contains(i + step) else { return }
            focusedRow = order[i + step]
        }
        .transition(.opacity)
    }

    /// `count` = 计数胶囊的数目：按真正的分区算（`WorklistSections.counts`），停住的行只是暂时画在这里。
    private func section(_ kind: WorklistSections.Kind, _ tasks: [TaskView], count: Int, order: [Int64], wide: Bool, compact: Bool,
                         hasOnlineContext: Bool, multipleLocalProjects: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .center, spacing: Theme.Space.sm) {
                Text(kind.title).font(Theme.Font.sectionHeader).foregroundStyle(Theme.textPrimary)
                CountBadge(count: count, attention: kind == .needsYou)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(kind.title) \(count) 件")
            ForEach(tasks) {
                row($0, kind: kind, order: order, wide: wide, compact: compact,
                    hasOnlineContext: hasOnlineContext, multipleLocalProjects: multipleLocalProjects)
            }
        }
    }

    private func doneSection(_ tasks: [TaskView], count: Int, order: [Int64], wide: Bool, compact: Bool,
                             hasOnlineContext: Bool, multipleLocalProjects: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button {
                Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) {
                    showDone.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: Theme.Space.sm) {
                    Text(WorklistSections.Kind.done.title).font(Theme.Font.sectionHeader).foregroundStyle(Theme.textPrimary)
                    CountBadge(count: count)
                    Spacer()
                    HStack(alignment: .center, spacing: Theme.Space.xs) {
                        Text(showDone ? "收起" : "展开")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showDone ? 90 : 0))
                            .animation(Theme.Motion.value(Theme.Motion.snap, reduceMotion: reduceMotion), value: showDone)
                    }
                    .font(.caption).foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("已完成 \(count) 件，\(showDone ? "收起" : "展开")")
            if showDone {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ForEach(tasks) {
                        row($0, kind: .done, order: order, wide: wide, compact: compact,
                            hasOnlineContext: hasOnlineContext, multipleLocalProjects: multipleLocalProjects)
                    }
                }
                .transition(Theme.Motion.reveal(edge: .top, reduceMotion: reduceMotion))
            }
        }
    }

    private func resetFilters() {
        Theme.Motion.run(Theme.Motion.snap, reduceMotion: reduceMotion) {
            originFilter = .all
            onlineOrigin = nil
            project = nil
            filter = .all
            search = ""
        }
    }

    /// 空态（上方已常驻 `EmbeddedRouterBar`，这里给出简洁指引与可选的组织连接入口）。
    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Text("清单是空的。直接在上方对主管说一句拆单，或粘贴线上组织的接入口令。")
                .font(Theme.Font.emptyBody)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            if !appModel.superagent.org.registered {
                Button {
                    appModel.openWorklistSettings(.org)
                } label: {
                    Label("前往连接组织", systemImage: "globe")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("在设置里连接团队的 TFA-Org 线上组织")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xxl)
    }

    /// 切到「线上项目」且当前没有任何线上任务时的友好空态。
    private var onlineEmptyState: some View {
        let org = appModel.superagent.org
        return VStack(spacing: Theme.Space.md) {
            if !org.registered {
                Text("尚未接入线上组织，可在上方主管栏直接粘贴一句接入口令，或前往设置连接。")
                    .font(Theme.Font.emptyBody)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                Button {
                    appModel.openWorklistSettings(.org)
                } label: {
                    Label("前往连接组织", systemImage: "globe")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help("打开组织同步设置，填入服务器地址和邀请码即可连接")
            } else {
                Text("已连接「\(org.organizationName(for: org.settings.serverURL))」，当前还没有同步到线上任务。")
                    .font(Theme.Font.emptyBody)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                Button {
                    appModel.openWorklistSettings(.org)
                } label: {
                    Label("查看组织设置", systemImage: "globe")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xxxl)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Text("这个筛选下没有任务。")
                .font(Theme.Font.emptyBody)
                .foregroundStyle(Theme.textTertiary)
            Button("重置筛选") {
                Theme.Motion.run(Theme.Motion.snap, reduceMotion: reduceMotion) {
                    originFilter = .all
                    onlineOrigin = nil
                    project = nil
                    filter = .all
                    search = ""
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xxxl)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.emptyBody)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.xxxl)
    }

    private func consumeNewTaskSeed() {
        guard let seed = appModel.newTaskSeed else { return }
        activeSeed = seed
        appModel.newTaskSeed = nil
        appModel.worklistTaskID = nil
        showingNewTask = true
    }
}

// MARK: - 页头

/// 清单页头（Pass 1）：和 `ToolHeaderBar` 同一套排版——侧栏开关、图标 + 标题、右侧小控件——但标题下不是宣言，而是一行可带按钮的
/// meta：「主管 运行中 · 今天打扰 0 / 8」；主管没开就是「主管 未启动」+ 小「启动」；超预算时打扰那段加重；空态下不显示打扰数（Pass 2）。
/// Unified 44pt single-row header for「我的工作」, sharing the exact Y=44pt bottom hairline and vertical
/// center axis with `SidebarHeader`, `ToolHeaderBar`, and `ActiveTerminalHeader`.
private struct WorklistHeader<Trailing: View>: View {
    @Environment(AppModel.self) private var appModel
    let empty: Bool
    @ViewBuilder let trailing: () -> Trailing

    private var headerIcon: String {
        switch appModel.worklistTab {
        case .tasks: return "list.bullet.clipboard"
        case .router: return "terminal"
        case .knowledge: return "books.vertical"
        }
    }

    var body: some View {
        @Bindable var model = appModel
        let sa = appModel.superagent
        let budget = WorklistHeaderText.interruptions(used: sa.interruptionsToday, budget: sa.settings.interruptionBudget)
        let kbCount = sa.knowledge.count
        let kbTitle = kbCount > 0 ? "知识库 \(kbCount)" : "知识库"
        HStack(alignment: .center, spacing: 10) {
            Button { appModel.toggleSidebar() } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(PaperPressButtonStyle(hoverWash: true))
            .help(appModel.sidebarCollapsed ? "显示侧栏 (⌘\\)" : "隐藏侧栏 (⌘\\)")
            .accessibilityLabel(appModel.sidebarCollapsed ? "Show sidebar" : "Hide sidebar")

            HStack(alignment: .center, spacing: 6) {
                Image(systemName: headerIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.brand)
                Text("我的工作")
                    .font(Theme.Font.headerTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }

            SegmentedChoice(
                selection: $model.worklistTab,
                options: [
                    (value: AppModel.WorklistTab.tasks, label: "清单"),
                    (value: AppModel.WorklistTab.router, label: "主管"),
                    (value: AppModel.WorklistTab.knowledge, label: kbTitle),
                ],
                dots: sa.routerBusy ? [.router] : []
            )
            .accessibilityLabel("切换清单、主管与知识库")

            if sa.org.registered {
                let orgTitle = sa.org.organizationName(for: sa.org.settings.serverURL)
                Button {
                    appModel.openWorklistSettings(.org)
                } label: {
                    HStack(alignment: .center, spacing: 5) {
                        Circle()
                            .fill(sa.org.online ? Theme.Status.positive : Theme.Status.neutral)
                            .frame(width: 6, height: 6)
                        Image(systemName: "globe")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Text("\(orgTitle) · \(sa.org.online ? "在线" : "离线")")
                    }
                    .font(Theme.Font.headerMeta)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 6))
                    .lineLimit(1)
                }
                .buttonStyle(PaperPressButtonStyle())
                .help("线上组织同步状态：\(sa.org.statusText)（点击打开组织设置）")
                .accessibilityLabel("线上组织 \(orgTitle)，\(sa.org.online ? "在线" : "离线")")
            }

            if !empty && budget.over {
                HStack(alignment: .center, spacing: 6) {
                    Text("·").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                    Text(budget.text).monospacedDigit()
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.textPrimary)
                }
                .font(Theme.Font.headerMeta)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(alignment: .center, spacing: Theme.Space.sm) {
                trailing()
                AppearanceMenuButton()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// 页头 meta 的文案（可测）。
enum WorklistHeaderText {
    /// 「主管 运行中」/「主管 未启动」。
    static func router(running: Bool) -> String { running ? "主管 运行中" : "主管 未启动" }

    /// 「今天打扰 2 / 8」；超预算：「今天打扰 9 / 8 · 超了」+ `over`（页头把这段加重）。只显示，不压制（注意事项 G-03）。
    static func interruptions(used: Int, budget: Int) -> (text: String, over: Bool) {
        let over = used > budget
        return ("今天打扰 \(used) / \(budget)" + (over ? " · 超了" : ""), over)
    }
}

// MARK: - 筛选一行

/// 筛选独立成一行（Pass 2 + 本地/线上分栏），不包卡：
/// 最左侧「全部 | 本地项目 | 线上项目」分段 + 线上组织 / 本地项目目录菜单 + 右侧「全部 | 今天 | 本周」时间分段。
private struct FilterRow: View {
    @Binding var originFilter: WorklistOriginFilter
    let originCounts: (all: Int, local: Int, online: Int)
    let hasOnlineContext: Bool
    @Binding var onlineOrigin: String?
    let onlineOrigins: [String]
    let orgRegistered: Bool
    let orgName: (String) -> String
    @Binding var filter: WorklistFilter
    @Binding var project: String?
    let projects: [String]
    let hasActiveFilter: Bool
    let onReset: () -> Void

    private var originOptions: [(value: WorklistOriginFilter, label: String)] {
        [
            (value: .all, label: WorklistOriginFilter.all.label),
            (value: .local, label: originCounts.local > 0 ? "\(WorklistOriginFilter.local.label) \(originCounts.local)" : WorklistOriginFilter.local.label),
            (value: .online, label: originCounts.online > 0 ? "\(WorklistOriginFilter.online.label) \(originCounts.online)" : WorklistOriginFilter.online.label),
        ]
    }

    private var hasPrimaryFilters: Bool {
        hasOnlineContext || projects.count > 1 || project != nil
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.lg) {
                if hasPrimaryFilters {
                    primaryFilters.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: Theme.Space.sm)
                }
                timeAndReset.fixedSize(horizontal: true, vertical: false)
                if !hasPrimaryFilters {
                    Spacer(minLength: 0)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if hasPrimaryFilters { primaryFilters }
                timeAndReset
            }
        }
    }

    private var primaryFilters: some View {
        HStack(spacing: Theme.Space.md) {
            if hasOnlineContext {
                SegmentedChoice(selection: $originFilter, options: originOptions)
                    .help("按任务来源分栏：全部 / 本地项目 / 线上项目")
                    .accessibilityLabel("按来源筛选，当前：\(originFilter.label)")
            }
            if hasOnlineContext && originFilter == .online {
                if onlineOrigins.count > 1 || (orgRegistered && !onlineOrigins.isEmpty) || onlineOrigin != nil {
                    Menu {
                        Button("全部组织") { onlineOrigin = nil }
                        if !onlineOrigins.isEmpty { Divider() }
                        ForEach(onlineOrigins, id: \.self) { origin in
                            Button(orgName(origin)) { onlineOrigin = origin }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "globe").font(.system(size: 11))
                            Text(onlineOrigin.map(orgName) ?? "全部组织")
                        }
                        .font(.caption.weight(onlineOrigin == nil ? .regular : .semibold))
                        .foregroundStyle(onlineOrigin == nil ? Theme.textTertiary : Theme.textPrimary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(onlineOrigin.map { "只看组织：\(orgName($0))" } ?? "按线上组织筛选")
                }
            } else if projects.count > 1 || project != nil {
                Menu {
                    Button("全部项目") { project = nil }
                    if !projects.isEmpty { Divider() }
                    ForEach(projects, id: \.self) { p in
                        Button(WorklistSections.projectName(p)) { project = p }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 11))
                        Text(project.map(WorklistSections.projectName) ?? "全部项目")
                    }
                    .font(.caption.weight(project == nil ? .regular : .semibold))
                    .foregroundStyle(project == nil ? Theme.textTertiary : Theme.textPrimary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(project.map { "只看 \($0)" } ?? "按项目目录筛选")
            }
        }
    }

    private var timeAndReset: some View {
        HStack(spacing: Theme.Space.sm) {
            SegmentedChoice(selection: $filter, options: WorklistFilter.allCases.map { (value: $0, label: $0.label) })
                .help(WorklistFilter.help)
                .accessibilityLabel("按时间筛选，当前：\(filter.label)")
            if hasActiveFilter {
                Button("重置", action: onReset)
                    .buttonStyle(PaperPressButtonStyle(hoverWash: true))
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .help("清除所有筛选条件")
                    .accessibilityLabel("重置筛选")
            }
        }
    }
}

// MARK: - 分区与筛选（纯函数，可测）

enum WorklistOriginFilter: Hashable, CaseIterable {
    case all, local, online

    var label: String {
        switch self {
        case .all: return "全部"
        case .local: return "本地项目"
        case .online: return "线上项目"
        }
    }
}

enum WorklistFilter: Hashable, CaseIterable {
    case all, today, week

    var label: String {
        switch self {
        case .all: return "全部"
        case .today: return "今天"
        case .week: return "本周"
        }
    }

    /// 「今天」的口径（tooltip）。
    static let help = "今天 = 需要你的 + 今天到期（含过期）的 + 今天有动静的 + 你名下拖了两天还没勾的；本周按本周算；全部不筛。"
}

/// 清单页的分区（1A）：需要你 → 待分配（有未分配清单项）→ 进行中 → 待领取（组织，第 3 期）→ 已完成（最近 30）。
struct WorklistSections: Equatable {
    /// 页内顺序就是声明顺序。
    enum Kind: CaseIterable, Hashable {
        case needsYou, unassigned, working, claimable, done

        var title: String {
            switch self {
            case .needsYou: return "需要你"
            case .unassigned: return "待分配"
            case .working: return "进行中"
            case .claimable: return "待领取"
            case .done: return "已完成"
            }
        }
    }

    var needsYou: [TaskView] = []
    var working: [TaskView] = []
    var unassigned: [TaskView] = []
    /// 组织的待领取任务（本地的占位行，`syncState == "claimable"`）。
    var claimable: [TaskView] = []
    var done: [TaskView] = []
    /// 各分区真正的数目（`make` 算好），计数胶囊用它：`holding` 把行挪到原位画，不改它——停住的行不算进它停住的那个分区。
    var counts: [Kind: Int] = [:]

    subscript(kind: Kind) -> [TaskView] {
        get {
            switch kind {
            case .needsYou: return needsYou
            case .unassigned: return unassigned
            case .working: return working
            case .claimable: return claimable
            case .done: return done
            }
        }
        set {
            switch kind {
            case .needsYou: needsYou = newValue
            case .unassigned: unassigned = newValue
            case .working: working = newValue
            case .claimable: claimable = newValue
            case .done: done = newValue
            }
        }
    }

    var isEmpty: Bool { Kind.allCases.allSatisfy { self[$0].isEmpty } }

    /// 行内回声（3A）把某行停在原位：分区、位置和当时的样子（任务从清单里消失了就按这份画）。
    struct Hold: Equatable {
        var kind: Kind
        var index: Int
        var snapshot: TaskView
    }

    func placement(of id: Int64) -> (kind: Kind, index: Int)? {
        for kind in Kind.allCases {
            if let i = self[kind].firstIndex(where: { $0.id == id }) { return (kind, i) }
        }
        return nil
    }

    /// 停住的行：从它现在的分区拿出来，放回记下的分区和位置；已经不在清单里的用当时的样子。
    func holding(_ holds: [Int64: Hold]) -> WorklistSections {
        guard !holds.isEmpty else { return self }
        var r = self
        let order = holds.sorted { (Kind.allCases.firstIndex(of: $0.value.kind)!, $0.value.index, $0.key) < (Kind.allCases.firstIndex(of: $1.value.kind)!, $1.value.index, $1.key) }
        for (id, hold) in order {
            var current: TaskView?
            for kind in Kind.allCases {
                if let i = r[kind].firstIndex(where: { $0.id == id }) { current = r[kind].remove(at: i) }
            }
            var list = r[hold.kind]
            list.insert(current ?? hold.snapshot, at: min(hold.index, list.count))
            r[hold.kind] = list
        }
        return r
    }

    /// 页面上从上到下的任务 id（键盘 ↑↓ 用）；已完成折叠着就不算。
    func orderedIDs(showDone: Bool) -> [Int64] {
        Kind.allCases.flatMap { $0 == .done && !showDone ? [] : self[$0].map(\.id) }
    }

    static func make(_ tasks: [TaskView], filter: WorklistFilter = .all, project: String? = nil, search: String = "",
                     originFilter: WorklistOriginFilter = .all, onlineOrigin: String? = nil,
                     now: Date = Date(), calendar: Calendar = .current) -> WorklistSections {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var r = WorklistSections()
        for tv in tasks {
            let isOnline = !(tv.task.origin ?? "").isEmpty
            switch originFilter {
            case .all:
                break
            case .local:
                if isOnline { continue }
            case .online:
                if !isOnline { continue }
                if let org = onlineOrigin, tv.task.origin != org { continue }
            }
            if let project, tv.task.scope != project { continue }
            if !q.isEmpty, !matches(tv, q) { continue }
            if !within(tv, filter, now: now, calendar: calendar) { continue }
            if !tv.task.isOpen { r.done.append(tv) }
            else if tv.task.syncState == "claimable" { r.claimable.append(tv) }
            else if !tv.needsYou.isEmpty { r.needsYou.append(tv) }
            else if tv.unassignedCount > 0 { r.unassigned.append(tv) }
            else { r.working.append(tv) }
        }
        // 需要你：按第一件事的 PersonAction 顺序，再新的在前（§4.3）；其余新的在前，不随回报跳动。
        r.needsYou.sort { ($0.needsYou[0], -$0.id) < ($1.needsYou[0], -$1.id) }
        if filter == .today {
            // 「今天」：你名下做了超过 2 天还没勾的项所在任务提到进行中最前（需求文档 §13：忘了勾的项别永远沉底）；不弹窗。
            r.working.sort { (staleYourItems($0, now: now).isEmpty ? 1 : 0, -$0.id) < (staleYourItems($1, now: now).isEmpty ? 1 : 0, -$1.id) }
        } else {
            r.working.sort { $0.id > $1.id }
        }
        r.unassigned.sort { $0.id > $1.id }
        r.claimable.sort { $0.id > $1.id }
        r.done.sort { $0.task.updatedAt > $1.task.updatedAt }
        r.done = Array(r.done.prefix(30))
        for kind in Kind.allCases { r.counts[kind] = r[kind].count }
        return r
    }

    /// 你名下开始做了 ≥ `staleAfter` 还没勾的项（打开的任务；`Item.startedAt` 从分给你那一刻算）。
    static func staleYourItems(_ tv: TaskView, now: Date = Date()) -> [Item] {
        guard tv.task.isOpen else { return [] }
        return tv.items.filter {
            $0.assignee == .you && ($0.status == .todo || $0.status == .doing)
                && ($0.startedAt.map { now.timeIntervalSince1970 - $0 >= staleAfter } ?? false)
        }
    }

    static let staleAfter: Double = 2 * 86400

    /// 清单行上的那句小字：「第 2 项已做 3 天」（几项一起就「第 2、4 项已做 3 天」，天数按最早的算）；没有就 nil。
    static func staleLine(_ items: [Item], now: Date = Date()) -> String? {
        guard let oldest = items.compactMap(\.startedAt).min() else { return nil }
        return "\(WorklistText.ords(items.map(\.ord)))已做 \(Int((now.timeIntervalSince1970 - oldest) / 86400)) 天"
    }

    /// 统计来源任务数：全部 / 本地项目 / 线上项目（用于分栏标签）。
    static func originCounts(_ tasks: [TaskView]) -> (all: Int, local: Int, online: Int) {
        var local = 0
        var online = 0
        for tv in tasks {
            if (tv.task.origin ?? "").isEmpty {
                local += 1
            } else {
                online += 1
            }
        }
        return (all: tasks.count, local: local, online: online)
    }

    /// 线上任务里出现过的组织源（去重排序后的非空 `task.origin`）。
    static func onlineOrigins(_ tasks: [TaskView]) -> [String] {
        Array(Set(tasks.compactMap { tv -> String? in
            guard let origin = tv.task.origin, !origin.isEmpty else { return nil }
            return origin
        })).sorted()
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

    /// 今天 = 需要你的 + 今天到期（含过期）的 + 今天有动静的 + 你名下拖了 2 天还没勾的；本周同理按本周算。
    private static func within(_ tv: TaskView, _ filter: WorklistFilter, now: Date, calendar: Calendar) -> Bool {
        let interval: DateInterval
        switch filter {
        case .all: return true
        case .today: interval = calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 86400)
        case .week: interval = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: now, duration: 7 * 86400)
        }
        if tv.task.isOpen && !tv.needsYou.isEmpty { return true }
        if filter == .today, !staleYourItems(tv, now: now).isEmpty { return true }
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

// MARK: - 清单行的文案（纯函数，可测）

/// 清单行的读法（Pass 1 / Pass 6）：第二行 = 该阶段的一句话 + 时间，与待处理中心同格式；第三行 = 进度 · 截止 · 来源；
/// VoiceOver 读整句「A-12 结算对账任务偶发超时，待评审，等你通过」。
enum WorklistRowText {
    struct Line: Equatable {
        var text: String
        /// 相对时间（「3 分钟前」）的基准；nil = 这句话里已经带了时间。
        var at: Double?
    }

    /// 第二行。需要你 → 需要你条那句（问题 / 受阻原因 / 回报摘要）；待领取 → 组织；待分配 → 「第 1–3 项还没定」（退回产生的 →
    /// 「来自 A-12 的退回 · A-12 第 2 项在等它」）；进行中 → 你忘了勾的项 > 最后一次回报摘要 > 「开发在做第 2 项」；已结束 → 结果一句话。
    /// `followUps`：人刚发出的跟进（工单 id → 时刻），执行者没回应前这行是「已发送 / 已送达」。
    static func line(_ tv: TaskView, followUps: [Int64: Double] = [:], now: Date = Date()) -> Line {
        guard tv.task.isOpen else { return closed(tv) }
        if tv.task.syncState == "claimable" { return Line(text: "组织的任务 · 领取后才在这里推进", at: tv.task.updatedAt) }
        if let need = tv.needsYou.first {
            let t = tv.ticket(needing: need)
            let body = tv.needLine.map { $0.body.isEmpty ? $0.title : $0.body } ?? need.label
            return Line(text: body, at: t.map { $0.ticket.reportAt ?? $0.ticket.updatedAt } ?? tv.task.updatedAt)
        }
        if let f = tv.tickets.first(where: { $0.ticket.isOpen && followUps[$0.id] != nil }), let at = followUps[f.id] {
            return Line(text: f.pendingInputs > 0 ? "已发送，等送达 · 工单 #\(f.id)" : "已送达 · 等工单 #\(f.id) 回应", at: at)
        }
        if tv.unassignedCount > 0 {
            if let o = tv.handbackOrigin { return Line(text: handback(o), at: tv.task.updatedAt) }
            return Line(text: "\(WorklistText.ords(tv.items.filter { $0.assignee == .unassigned }.map(\.ord)))还没定", at: tv.task.updatedAt)
        }
        return working(tv, now: now)
    }

    private static func working(_ tv: TaskView, now: Date) -> Line {
        // 你忘了勾的项：一句小字，不着琥珀（A-04），不弹窗。
        if let stale = WorklistSections.staleLine(WorklistSections.staleYourItems(tv, now: now), now: now) { return Line(text: stale, at: nil) }
        let reports = tv.tickets.filter { $0.ticket.isOpen && $0.ticket.reportState != nil && !$0.ticket.reportSummary.isEmpty }
        if let r = reports.max(by: { ($0.ticket.reportAt ?? 0) < ($1.ticket.reportAt ?? 0) }) {
            return Line(text: "工单 #\(r.id) 回报：\(r.ticket.reportSummary)", at: r.ticket.reportAt ?? r.ticket.updatedAt)
        }
        let doing = tv.items.filter { $0.status == .doing && tv.linked[$0.ord] == nil }
        if !doing.isEmpty {
            return Line(text: byAssignee(doing.map { ($0.assignee, $0.ord) }) { "\($0)在做\($1)" },
                        at: doing.compactMap(\.startedAt).max() ?? tv.task.updatedAt)
        }
        if let o = tv.handbackOrigin { return Line(text: handback(o), at: tv.task.updatedAt) }
        // 链接项（4C）：跟着退回产生的任务走。
        if let l = tv.linked.values.sorted(by: { $0.link.itemOrd < $1.link.itemOrd }).first {
            return Line(text: "第 \(l.link.itemOrd) 项跟着 A-\(l.link.toTaskID)" + (l.state == .unassigned ? "，它还没定谁来做" : "，它在做"), at: tv.task.updatedAt)
        }
        let agents = tv.items.filter { $0.status == .todo && $0.assignee != .you && $0.assignee != .unassigned && tv.linked[$0.ord] == nil }
        if !agents.isEmpty {
            let queued = agents.contains { $0.ticketID.flatMap { tv.ticket($0) }?.stage == .working(queued: true) }
            return Line(text: byAssignee(agents.map { ($0.assignee, $0.ord) }) { queued ? "\($0)排队中 · \($1)" : "\($0)还没开始做\($1)" },
                        at: tv.task.updatedAt)
        }
        let yours = tv.items.filter { $0.status == .todo && $0.assignee == .you }
        if !yours.isEmpty { return Line(text: "等你做\(WorklistText.ords(yours.map(\.ord)))", at: tv.task.updatedAt) }
        if tv.reviewing { return Line(text: "评审中 · TFA 在核对交付", at: tv.task.updatedAt) }
        return Line(text: "清单都做完了", at: tv.task.updatedAt)
    }

    /// 完成态在标题下优先显示已提炼的知识卡一句话结论，再回退到结果摘要，最后按数目说。
    private static func closed(_ tv: TaskView) -> Line {
        if tv.task.status == .done, let kb = tv.knowledge, !kb.tldr.isEmpty {
            return Line(text: kb.tldr, at: tv.task.updatedAt)
        }
        if !tv.task.resultSummary.isEmpty { return Line(text: tv.task.resultSummary, at: tv.task.updatedAt) }
        let text: String
        switch tv.task.status {
        case .done: text = "全部 \(tv.totalCount) 项完成"
        case .cancelled: text = "已取消，完成 \(tv.doneCount)/\(tv.totalCount)"
        case .dropped: text = "Agent 放弃了，完成 \(tv.doneCount)/\(tv.totalCount)"
        case .open: text = tv.task.stage
        }
        return Line(text: text, at: tv.task.updatedAt)
    }

    /// 「来自 A-12 的退回 · A-12 第 2 项在等它」。
    static func handback(_ o: HandbackLink) -> String {
        "来自 A-\(o.fromTaskID) 的退回 · A-\(o.fromTaskID) 第 \(o.itemOrd) 项在等它"
    }

    /// 「开发在做第 5–7 项」「开发在做第 1 项，助理在做第 2 项」「你在做第 3 项」：按执行者分组（清单顺序），`phrase(执行者, 第几项)`。
    private static func byAssignee(_ pairs: [(Assignee, Int)], _ phrase: (String, String) -> String) -> String {
        var groups: [(Assignee, [Int])] = []
        for (who, ord) in pairs {
            if let k = groups.firstIndex(where: { $0.0 == who }) { groups[k].1.append(ord) } else { groups.append((who, [ord])) }
        }
        return groups.map { phrase($0.0.label, WorklistText.ords($0.1)) }.joined(separator: "，")
    }

    /// 第三行（宽时）/ tooltip：「3/5 · 周四 · 来自主管」。截止只在 3 天内（注意事项 F-05）。
    static func meta(_ tv: TaskView, now: Date = Date()) -> String {
        var parts = ["\(tv.doneCount)/\(tv.totalCount)"]
        if tv.task.isOpen, let due = tv.task.due, let s = DueText.short(due, now: now) { parts.append(s) }
        if let s = source(tv) { parts.append(s) }
        return parts.joined(separator: " · ")
    }

    /// 来源（Pass 1）：「来自主管 / 来自规则 / 来自定时 / 来自组织 / 来自 A-12 的退回」；自己建的不写，触发器 id 不出现。
    static func source(_ tv: TaskView) -> String? {
        switch tv.task.source {
        case .manual: return nil
        case .handback: return tv.handbackOrigin.map { "来自 A-\($0.fromTaskID) 的退回" } ?? "来自退回"
        default: return "来自\(tv.task.source.label)"
        }
    }

    /// 鼠标悬停：标题全文 + meta + 执行者。
    static func tooltip(_ tv: TaskView, now: Date = Date()) -> String {
        let who = tv.assignees.map(\.label)
        return tv.task.title + "\n" + meta(tv, now: now) + (who.isEmpty ? "" : " · " + who.joined(separator: "、"))
    }

    /// VoiceOver：「A-12 结算对账任务偶发超时，待评审，等你通过」——编号、标题、状态词、这一步要你做什么（状态 tag 不单独读）。
    static func spoken(_ tv: TaskView, line: Line) -> String {
        "\(tv.task.label) \(tv.task.title)，\(tv.stateTag.text)，\(hint(tv, line: line))"
    }

    static func hint(_ tv: TaskView, line: Line) -> String {
        if tv.task.isOpen, tv.task.syncState == "claimable" { return "等你领取" }
        if tv.task.isOpen, let need = tv.needsYou.first {
            switch need {
            case .review: return "等你通过"
            case .answer: return "等你回答"
            case .blocked: return tv.syncConflicts.isEmpty ? "受阻，等你补充或重试" : "同步冲突，等你定以哪边为准"
            case .failed: return "失败，等你重试"
            case .delivery: return "送达失败，等你重试"
            case .stalled: return "停下没回报，等你补充"
            }
        }
        if tv.task.isOpen, tv.unassignedCount > 0 { return "等你定谁来做" }
        return line.text
    }
}

/// 行内回声的文案（3A）：动作成功后那一句。
enum WorklistEchoText {
    /// 谁来做之后：「已交给 开发（第 1–2 项）、你（第 3 项）」；没分给任何人就「已定谁来做」。
    static func assigned(_ allocations: [SuperagentEngine.Allocation]) -> String {
        var groups: [(Assignee, [Int])] = []
        for a in allocations where a.to != .unassigned {
            if let k = groups.firstIndex(where: { $0.0 == a.to }) { groups[k].1.append(a.ord) } else { groups.append((a.to, [a.ord])) }
        }
        guard !groups.isEmpty else { return "已定谁来做" }
        return "已交给 " + groups.map { "\($0.0.label)（\(WorklistText.ords($0.1))）" }.joined(separator: "、")
    }
}

/// 侧栏「我的工作」行的副标题（1A）：「N 件需要你」(琥珀) > 「N 件待分配」> 「N 件进行中」> 迁移失败 > 「清单是空的」。
/// `attention` = 着琥珀（只有需要你；待分配不着琥珀、不计数胶囊）。
enum WorklistSidebarText {
    static func subtitle(needs: Int, unassigned: Int, open: Int, available: Bool = true) -> (text: String, attention: Bool) {
        if needs > 0 { return ("\(needs) 件需要你", true) }
        if unassigned > 0 { return ("\(unassigned) 件待分配", false) }
        if open > 0 { return ("\(open) 件进行中", false) }
        if !available { return ("迁移失败 · 先用主管面板", false) } // 注意事项 K-05：原因在面板顶部
        return ("清单是空的", false)
    }
}

// MARK: - 清单行（注意事项 F-05；设计评审 Pass 1 / 3A / Pass 6）

/// 白卡 · Linen 1pt · 最小高 52：第一行 `A-12` + 标题 + 右侧 `StateTag`（与分区同名就不显示；只在需要你时着色）+ 该阶段的动作；
/// 第二行 该阶段的一句话 + 石灰时间（回声时是回声那句）；第三行（宽 ≥ 900）进度 · 截止 · 来源 + 执行者 chips，否则进 tooltip；
/// 动作失败的原因是砖红小字贴在最下面。需要你时整行 amber 6% 底；键盘焦点 = 炭黑描边。
struct TaskRow: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let view: TaskView
    /// 所在分区。
    let kind: WorklistSections.Kind
    var wide = true
    /// 窗口 < 720：行尾动作收进「…」菜单。
    var compact = false
    /// 是否存在线上组织上下文（纯单机单项目下隐藏冗余来源徽标）。
    var hasOnlineContext = true
    /// 是否存在多个本地项目目录。
    var multipleLocalProjects = true
    @FocusState.Binding var focused: Int64?
    let open: () -> Void
    let assign: () -> Void
    /// 「改派第 N 项…」：打开谁来做并定位到那一项（4A）。
    var reassign: ((Int) -> Void)? = nil
    /// 「完成任务…」：打开确认单（5A）；挂在行上，动作收进「…」菜单时也能开。
    var finish: (() -> Void)? = nil
    /// ↑↓：把焦点移到上一行 / 下一行。
    var move: (Int) -> Void = { _ in }
    @State private var isHovered = false

    var body: some View {
        let sa = appModel.superagent
        let tag = view.stateTag
        let needs = view.task.isOpen && !view.needsYou.isEmpty
        let line = WorklistRowText.line(view, followUps: sa.followUps)
        let echo = sa.actionEchoes[view.id]
        let error = sa.actionErrors[view.id]
        let isFocused = focused == view.id
        HStack(alignment: .center, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: Theme.Space.sm) {
                    Text(view.task.label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                    TaskOriginBadge(
                        task: view.task,
                        showProject: true,
                        hasOnlineContext: hasOnlineContext,
                        multipleLocalProjects: multipleLocalProjects
                    )
                    Text(view.task.title)
                        .font(Theme.Font.rowTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if view.totalCount > 1 {
                        Text("\(view.doneCount)/\(view.totalCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .contentTransition(.numericText())
                            .animation(Theme.Motion.value(Theme.Motion.snap, reduceMotion: reduceMotion), value: view.doneCount)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                    }
                    if view.task.status == .done, view.knowledge != nil {
                        Text("✦ 已总结")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                    }
                    if !view.relatedKnowledge.isEmpty {
                        Text("关联 \(view.relatedKnowledge.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                HStack(alignment: .center, spacing: Theme.Space.sm) {
                    if let echo {
                        Text(echo).font(Theme.Font.rowSubtitle).fontWeight(.medium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    } else {
                        Text(line.text).font(Theme.Font.rowSubtitle).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                        if let at = line.at { AgoText(time: at) }
                        if wide, !(view.task.origin ?? "").isEmpty, !view.task.scope.isEmpty {
                            Text("· \(WorklistSections.projectName(view.task.scope))")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
                if let error {
                    HStack(spacing: Theme.Space.xs) {
                        Text(error).font(.caption).foregroundStyle(Theme.Status.error).lineLimit(2).textSelection(.enabled)
                        Button {
                            Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) {
                                sa.actionErrors[view.id] = nil
                            }
                        } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).foregroundStyle(Theme.textTertiary).controlSize(.small)
                            .help("关闭").accessibilityLabel("关闭错误")
                    }
                    .transition(Theme.Motion.reveal(edge: .top, reduceMotion: reduceMotion))
                }
            }
            .animation(Theme.Motion.value(Theme.Motion.panel, reduceMotion: reduceMotion), value: error != nil)
            Spacer(minLength: Theme.Space.md)
            if tag.text != kind.title { StateTag(text: tag.text, tint: tag.tint) }
            if compact, hasActions {
                Menu { actions } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("这一步的动作").accessibilityLabel("动作")
            } else {
                actions.controlSize(.regular)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(needs ? Theme.Status.attention.opacity(0.06) : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(isFocused ? Theme.brand : (isHovered ? Theme.borderStrong : Theme.border), lineWidth: 1)
        )
        .animation(Theme.Motion.value(Theme.Motion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture {
            focused = view.id
            open()
        }
        .focusable()
        .focused($focused, equals: view.id)
        .focusEffectDisabled()
        .onKeyPress(.return) { open(); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .help(WorklistRowText.tooltip(view))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(WorklistRowText.spoken(view, line: line))
        .accessibilityAddTraits(.isButton)
    }

    private var hasActions: Bool {
        view.task.syncState == "claimable"
            || (view.task.isOpen && (!view.needsYou.isEmpty || view.unassignedCount > 0 || view.canRetry))
    }

    /// 该阶段的一两个动作（和任务卡的需要你条同一套 `TaskNeedActions`；进行中或中断的任务直接提供一键重试）。
    @ViewBuilder private var actions: some View {
        if view.task.syncState == "claimable" {
            let org = appModel.superagent.org
            Button("领取") { claim() }
                .buttonStyle(.borderedProminent)
                .disabled(org.busy || !org.registered)
                .frame(minHeight: 28)
                .help("向组织领取这个任务；别人先领走了就从这里消失")
        } else if view.task.isOpen {
            if !view.needsYou.isEmpty {
                TaskNeedActions(view: view, assign: assign, reassign: reassign, finish: finish)
            } else if view.unassignedCount > 0 {
                if view.canRetry {
                    Button { appModel.superagent.retryTask(view.id) } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 28)
                    .help("网络断开或任务卡住时一键重试当前执行工单")
                }
                Button("谁来做…", action: assign).buttonStyle(.borderedProminent).frame(minHeight: 28)
            } else if view.canRetry {
                Button { appModel.superagent.retryTask(view.id) } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 28)
                .help("网络断开或任务卡住时一键重试当前执行工单")
                .accessibilityLabel("重试任务 \(view.task.label)")
            }
        }
    }

    /// 领取：成了就回声一句；被别人领走（409 / 403）占位行已经没了，回声让它在原位留几秒再消失（Pass 2）。
    private func claim() {
        let sa = appModel.superagent
        Task { @MainActor in
            await sa.org.claim(view.id)
            sa.noteEcho(view.id, sa.org.lastError ?? "已领取 · 等你定谁来做")
        }
    }
}

/// 第一件需要你的事对应的动作——清单行与任务卡的需要你条共用，一处实现（设计评审 2026-11-08，Pass 3 / 4A / 5A）：
/// 待评审 → 看改动 + 打回… + 完成任务…（任务层，开确认单）/ 通过工单 #12（工单层）；等你回答 → 回答…；
/// 受阻 / 停下未回报 → 重试 + 补充…（补充为主）；失败 / 送达失败 → 补充… + 重试（重试为主）；
/// 受阻的那项已被退回成新任务（4A）→ 改派第 N 项… + 去分配 A-13…；受阻且没有工单（前置任务被取消）→ 谁来做…。
/// 主按钮 `.borderedProminent` 排最后；按钮最少 28pt 高（Pass 6）。组织同步冲突的两个按钮是 `OrgConflictButtons`。
struct TaskNeedActions: View {
    @Environment(AppModel.self) private var appModel
    let view: TaskView
    /// 打开「谁来做」。
    var assign: (() -> Void)?
    /// 「改派第 N 项…」：打开谁来做并定位到那一项；没给就当普通的谁来做。
    var reassign: ((Int) -> Void)? = nil
    /// 「完成任务…」：调用方自己开确认单（清单行：动作可能收在「…」菜单里，sheet 得挂在行上）；没给就在这里开。
    var finish: (() -> Void)? = nil
    @State private var finishing = false
    /// 放在任务卡深色的「下一步」横幅上：换成横幅的按钮样式。
    @Environment(\.needActionsOnDark) private var onDark

    var body: some View {
        let sa = appModel.superagent
        switch view.needsYou.first {
        case .review?:
            let ticket = view.ticket(needing: .review)
            if let t = ticket ?? delivered { viewChanges(t) }
            if view.task.stageKind != .review, let t = ticket {
                plain("打回…") { appModel.ticketFeedback = TicketFeedbackRequest(ticketID: t.id, kind: .reject) }
                prominent(sa.merging.contains(t.id) ? "合并中…" : "通过工单 #\(t.id)") { sa.approve(t.id) }
                    .disabled(sa.merging.contains(t.id))
                    .help(t.ticket.branch.isEmpty ? "结单" : "把 \(t.ticket.branch) 合并进主仓库当前分支，然后结单")
            } else {
                let quickPlan = FinishPlan.derive(view, target: nil)
                let canQuickFinish = quickPlan.branches.isEmpty && quickPlan.unfinishedOrds.isEmpty
                plain("打回…") { appModel.taskFeedback = TaskFeedbackRequest(taskID: view.id) }
                    .help("意见送给原工单；没有工单的项会成为新的清单项")
                if canQuickFinish {
                    prominent(sa.mergingTasks.contains(view.id) ? "完成中…" : "完成任务") {
                        _ = sa.approveTask(view.id)
                    }
                    .disabled(sa.mergingTasks.contains(view.id))
                    .help("无待合并分支且清单全部完成，点击直接结单")
                } else {
                    prominent(sa.mergingTasks.contains(view.id) ? "合并中…" : "完成任务…") {
                        if let finish { finish() } else { finishing = true }
                    }
                    .disabled(sa.mergingTasks.contains(view.id))
                    .help("先看要合并的分支、没有分支的工单和没做完的项，确认后合并并完成")
                    .sheet(isPresented: $finishing) { TaskFinishSheet(taskID: view.id).environment(appModel) }
                }
            }
        case .answer?:
            if let t = view.ticket(needing: .answer) {
                plain("重试") { sa.retry(t.id) }
                    .help("若因断网或状态过时，重新让工单 #\(t.id) 检查并继续")
                prominent("回答…") { appModel.ticketFeedback = TicketFeedbackRequest(ticketID: t.id, kind: .answer) }
            }
        case .blocked?, .failed?, .delivery?, .stalled?:
            let need = view.needsYou[0]
            if need == .blocked, let c = view.syncConflicts.first {
                OrgConflictButtons(taskID: view.id, conflict: c) // 组织同步冲突（第 3 期）：人定一边
            } else if need == .blocked, let link = view.handbackNeed {
                // 退回（4A）：退回的请求已经成了新任务；先去分配它，改派原来那项是次选。
                let assignable = sa.task(link.toTaskID).map { $0.task.isOpen && $0.unassignedCount > 0 } ?? true
                plain("改派第 \(link.itemOrd) 项…") {
                    if let reassign { reassign(link.itemOrd) } else { assign?() }
                }
                prominent(assignable ? "去分配 A-\(link.toTaskID)…" : "打开 A-\(link.toTaskID)") { appModel.openWorklist(task: link.toTaskID) }
                    .help("A-\(link.toTaskID) 做完，这里的第 \(link.itemOrd) 项自动完成")
            } else if let t = view.ticket(needing: need) {
                if need == .failed || need == .delivery {
                    plain("补充…") { appModel.ticketFeedback = TicketFeedbackRequest(ticketID: t.id, kind: .add) }
                    prominent("重试") { sa.retry(t.id) }
                } else {
                    // 受阻 / 停下未回报：先补充它缺的信息，重试是次选（Pass 3）。
                    plain("重试") { sa.retry(t.id) }
                    prominent("补充…") { appModel.ticketFeedback = TicketFeedbackRequest(ticketID: t.id, kind: .add) }
                }
            } else if let assign {
                prominent("谁来做…", action: assign)
            }
        case nil:
            EmptyView()
        }
    }

    /// 「看改动」指向的交付：最近一张交付了的开发工单（有分支或报告；评审工单只审不改，不算）。
    private var delivered: TicketView? {
        view.tickets.last {
            $0.ticket.reviewOf == nil && ($0.ticket.status == .done || $0.ticket.reportState == .ready)
                && (!$0.ticket.branch.isEmpty || !($0.ticket.reportPath ?? "").isEmpty)
        }
    }

    /// 有分支就在任务卡上展开改动（内嵌 diff）；没有分支时有报告就打开报告，否则跳到工单的终端。
    private func viewChanges(_ t: TicketView) -> some View {
        let report = t.ticket.reportPath ?? ""
        let branch = t.ticket.branch
        let showing = appModel.worklistDiffTicketID == t.id && appModel.worklistTaskID == view.id
        return plain(showing ? "收起改动" : "看改动") {
            if !branch.isEmpty { appModel.showTaskDiff(task: view.id, ticket: t.id) }
            else if report.isEmpty { appModel.goToTicket(t.id) } else { NSWorkspace.shared.open(URL(fileURLWithPath: report)) }
        }
        .help(!branch.isEmpty ? "在任务卡上看工单 #\(t.id) 的改动（分支 \(branch)）"
              : report.isEmpty ? "前往工单 #\(t.id) 的终端看改动" : "打开报告 \(report)")
    }

    @ViewBuilder private func plain(_ title: String, action: @escaping () -> Void) -> some View {
        if onDark {
            Button(title, action: action).buttonStyle(BannerButtonStyle(kind: .outline))
        } else {
            Button(title, action: action).buttonStyle(.bordered).frame(minHeight: 28)
        }
    }

    @ViewBuilder private func prominent(_ title: String, action: @escaping () -> Void) -> some View {
        if onDark {
            Button(title, action: action).buttonStyle(BannerButtonStyle(kind: .prominent))
        } else {
            Button(title, action: action).buttonStyle(.borderedProminent).frame(minHeight: 28)
        }
    }
}

/// 石灰的相对时间（「刚刚」「3 分钟前」），每分钟刷新；悬停看完整时间。
private struct AgoText: View {
    let time: Double
    private static let full: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            Text(WorklistText.ago(time, now: ctx.date)).font(.caption).monospacedDigit().foregroundStyle(Theme.textTertiary)
                .lineLimit(1).fixedSize()
        }
        .help(Self.full.string(from: Date(timeIntervalSince1970: time)))
    }
}

// MARK: - 「+ 任务」（需求文档 §9.1）

/// 标题 + 原文（可选）+ 范围（项目目录）+ 清单项（每行一条）+ 工作流模板 + 优先级 + 截止。建完回调新任务的 id。
/// 校验的提示先是石灰；试过提交才变砖红（Pass 2）。
struct NewTaskSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var seed: AppModel.NewTaskSeed? = nil
    let created: (Int64) -> Void
    @State private var title = ""
    @State private var request = ""
    @State private var scope = ""
    @State private var scopeEditedByUser = false
    @State private var itemsText = ""
    @State private var workflow: String?
    @State private var priority: TaskPriority = .medium
    @State private var hasDue = false
    @State private var due = Date()
    @State private var deps: Set<Int64> = []
    @State private var showDeps = false
    @State private var relatedIDs: Set<Int64> = []
    @State private var seedTaskRefs: [KnowledgeRef] = []
    @State private var showRelated = false
    @State private var showMoreOptions = false
    @State private var autoAssign = true
    @State private var error: String?
    /// 试过提交：从这以后校验不过才标砖红。
    @State private var tried = false
    @FocusState private var focused: Bool

    private var items: [String] { Self.parseItems(itemsText) }
    private var problem: String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "写一个标题" }
        if t.count > WorkTask.maxTitle { return "标题最多 \(WorkTask.maxTitle) 字" }
        if let long = items.first(where: { $0.count > Item.maxText }) { return "清单项最多 \(Item.maxText) 字：\(long.prefix(20))…" }
        return nil
    }

    private var hasNonDefaultMoreOptions: Bool {
        !deps.isEmpty || workflow != nil || priority != .medium || hasDue
    }

    private var combinedRelatedRefs: [KnowledgeRef] {
        var out: [KnowledgeRef] = seedTaskRefs
        let byID = Dictionary(uniqueKeysWithValues: appModel.superagent.knowledge.map { ($0.entry.id, $0.entry) })
        for kid in relatedIDs.sorted() {
            let ref: KnowledgeRef = byID[kid]?.taskID.map { .task($0) } ?? .knowledge(kid)
            if !out.contains(ref) { out.append(ref) }
        }
        return out
    }

    var body: some View {
        let sa = appModel.superagent
        let suggestions = sa.suggestKnowledge(title: title, request: request, scope: scope, limit: 3)
            .filter { entry in
                !relatedIDs.contains(entry.id) && !seedTaskRefs.contains(where: { r in
                    if case .task(let tid) = r { return tid == entry.taskID }
                    if case .knowledge(let kid) = r { return kid == entry.id }
                    return false
                })
            }
        let expandedMore = showMoreOptions || hasNonDefaultMoreOptions
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text(seed == nil ? "新建任务" : "接着做 · 新建后续任务").font(Theme.Font.headerTitle)
            Field(title: "标题") {
                TextField("一句话说清要做成什么", text: $title).textFieldStyle(.roundedBorder).focused($focused)
            }
            Field(title: "原文（可选；执行者从这里推导需求）") {
                TextEditor(text: $request).editorBox().frame(height: 72)
            }
            Field(title: "清单项（每行一条，可验证的结果；留空就一项 = 标题）") {
                TextEditor(text: $itemsText).editorBox().frame(height: 88)
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("发现可复用的历史经验（点一下即可关联给执行者）：")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions) { entry in
                            Button {
                                relatedIDs.insert(entry.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.brand)
                                    Text("\(entry.displayLabel) \(entry.title)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                            }
                            .buttonStyle(PaperPressButtonStyle())
                            .help(entry.tldr)
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: Theme.Space.xl) {
                Field(title: "范围（项目目录）") {
                    HStack(spacing: Theme.Space.sm) {
                        Text(scope.isEmpty ? "不针对项目" : tilde(scope)).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.head).help(scope)
                        if !scope.isEmpty {
                            Button("清除") { scopeEditedByUser = true; scope = "" }.controlSize(.small)
                        }
                        Button("选择…") {
                            if let p = pickFolder(from: scope, message: "任务的项目目录；交给 Agent 的项在这里工作") {
                                scopeEditedByUser = true
                                scope = p
                            }
                        }
                        .controlSize(.small)
                    }
                }
                Field(title: "关联历史经验（可选）") {
                    HStack(spacing: Theme.Space.sm) {
                        let refs = combinedRelatedRefs
                        Text(refs.isEmpty ? "未关联" : refs.map(\.label).joined(separator: "、"))
                            .font(.caption).foregroundStyle(refs.isEmpty ? Theme.textTertiary : Theme.textPrimary).lineLimit(1)
                        if !refs.isEmpty {
                            Button("清除") { relatedIDs.removeAll(); seedTaskRefs.removeAll() }.controlSize(.small)
                        }
                        Button("选择…") { showRelated = true }
                            .controlSize(.small)
                            .popover(isPresented: $showRelated, arrowEdge: .bottom) {
                                KnowledgeLinkPicker(currentTaskID: nil, preferredScope: scope, selectedIDs: $relatedIDs)
                                    .environment(appModel)
                            }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Button {
                    Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) {
                        showMoreOptions.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(expandedMore ? "收起更多选项" : "更多选项（依赖、工作流、优先级、截止）")
                            .font(.caption.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expandedMore ? 90 : 0))
                            .animation(Theme.Motion.value(Theme.Motion.snap, reduceMotion: reduceMotion), value: expandedMore)
                    }
                    .foregroundStyle(Theme.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expandedMore {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        Field(title: "依赖（可选）") {
                            HStack(spacing: Theme.Space.sm) {
                                Text(deps.isEmpty ? "没有前置任务" : deps.sorted().map { "A-\($0)" }.joined(separator: "、"))
                                    .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                Button("选择…") { showDeps = true }
                                    .controlSize(.small)
                                    .popover(isPresented: $showDeps, arrowEdge: .bottom) {
                                        DepsPicker(candidates: sa.openTasks.sorted { $0.id > $1.id }, selected: $deps)
                                    }
                            }
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
                    }
                    .transition(Theme.Motion.reveal(edge: .top, reduceMotion: reduceMotion))
                }
            }

            Toggle("建完直接按智能建议分配", isOn: $autoAssign)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            Text(problem ?? (autoAssign ? "建完将按智能建议自动分配并开工单；若缺项目目录再弹窗确认。" : "交给 Agent 的项之后在「谁来做」里定；关联的历史经验会自动附给执行 Agent。"))
                .font(.caption).foregroundStyle(problem == nil || !tried ? Theme.textTertiary : Theme.Status.error)
            SheetButtons(error: error, confirm: "建任务", enabled: true,
                         shortcut: KeyboardShortcut(.return, modifiers: .command)) {
                tried = true
                guard problem == nil else { return }
                var id: Int64?
                error = attempt(sa) {
                    id = sa.createTask(.init(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                             request: request.trimmingCharacters(in: .whitespacesAndNewlines), scope: scope,
                                             items: items, workflow: workflow, priority: priority,
                                             due: hasDue ? Calendar.current.startOfDay(for: due).addingTimeInterval(86399).timeIntervalSince1970 : nil,
                                             deps: deps.sorted(), related: combinedRelatedRefs))
                }
                if error == nil, let id {
                    if autoAssign, let tv = sa.task(id) {
                        let allocations: [SuperagentEngine.Allocation] = tv.items.map { item in
                            var to = AssignHeuristic.suggest(item.text)
                            if let role = to.role, !sa.roles.contains(where: { $0.name == role }) { to = .you }
                            return SuperagentEngine.Allocation(ord: item.ord, to: to)
                        }
                        let needsDir = AssignPreview.needsDirectory(
                            changes: allocations.map { ($0.ord, $0.to) },
                            roles: sa.roles,
                            scope: scope
                        )
                        let blockedByDeps = allocations.contains { $0.to.isAgent }
                            && deps.contains { sa.task($0)?.task.status != .done }
                        if !allocations.isEmpty, !needsDir, !blockedByDeps {
                            if attempt(sa, { sa.assign(id, allocations, oneTicket: true) }) == nil {
                                sa.noteEcho(id, WorklistEchoText.assigned(allocations))
                            }
                        }
                    }
                    created(id)
                    dismiss()
                } else if error == nil {
                    error = "任务创建失败，请重试"
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 600)
        .onChange(of: title) { _, _ in refreshInferredScope() }
        .onChange(of: request) { _, _ in refreshInferredScope() }
        .onAppear {
            if let seed {
                showMoreOptions = true
                for ref in seed.relatedRefs {
                    switch ref {
                    case .knowledge(let kid):
                        relatedIDs.insert(kid)
                    case .task(let tid):
                        if let existing = sa.knowledge.first(where: { $0.entry.taskID == tid }) {
                            relatedIDs.insert(existing.id)
                        } else {
                            seedTaskRefs.append(ref)
                        }
                    }
                }
            }
            refreshInferredScope()
            focused = true
        }
    }

    private func refreshInferredScope() {
        guard !scopeEditedByUser else { return }
        let fallback = appModel.selectedConnection?.currentPath ?? ""
        scope = AppModel.inferProjectDirectory(
            explicit: seed?.scope ?? "",
            text: title + "\n" + request,
            fallbackDir: fallback
        )
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
