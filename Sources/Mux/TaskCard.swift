import AppKit
import SwiftUI
import SuperagentCore

// 任务卡（TFA-工作清单-需求文档 §9.2、注意事项 F-07～F-10；设计评审 2026-11-08）。够宽时分三列：左活动、中清单、右详情
// （头卡 → 需要你条 → 同步行 → 底部动作），左中两列窄、各列各自滚动；窄窗口退回单列：头卡 → 需要你条 → 工作清单 → 活动 →
// 底部动作。缺的部分不占位。一张卡只有一条需要你；工单号可点，跳到它的终端。

/// 三列的宽度（纯函数，可测）：容器宽 ≥ 900 才分列；左（活动）取 24%、限 220～300，中（清单）取 28%、限 260～360，右（详情）占其余。
enum TaskCardLayout {
    static let threeColumnMinWidth: CGFloat = 900

    static func columns(width: CGFloat) -> (activity: CGFloat, checklist: CGFloat)? {
        guard width >= threeColumnMinWidth else { return nil }
        return (min(max((width * 0.24).rounded(), 220), 300), min(max((width * 0.28).rounded(), 260), 360))
    }
}

struct TaskCard: View {
    @Environment(AppModel.self) private var appModel
    let view: TaskView
    /// 打开「谁来做」。
    let assign: () -> Void
    /// 活动时间线：打开时读，≤80 条（注意事项 F-17）。
    @State private var events: [TimelineEvent] = []
    @State private var newItem = ""
    @State private var editing: Item?
    @State private var editingSummaryItem: Item?
    @State private var expandedOrds: Set<Int> = []
    @State private var removing: Item?
    @State private var confirmCancel = false
    @State private var confirmDrop = false
    @State private var showDeps = false
    @State private var showRelatedKB = false
    @State private var showActivity = false
    /// 乐观更新的勾选（`Item.id` → 勾了没）：先翻状态再调引擎，失败回滚（注意事项 F-18）。
    @State private var pending: [Int64: Bool] = [:]
    @FocusState private var newItemFocused: Bool
    /// 整卡可聚焦，Esc 才有地方落（同设置页）。
    @FocusState private var cardFocused: Bool

    /// 还能改清单、分配：打开的和已完成的（跟进会重新打开，注意事项 C-10）；已取消 / 已放弃的不能。
    private var editable: Bool { view.task.status == .open || view.task.status == .done }
    /// 「已放弃？」只在这时出现（注意事项 D-04）：Agent 放弃过（有工单以放弃结束），现在所有项都未分配、没有一项完成。
    private var abandoned: Bool {
        view.task.isOpen && view.tickets.contains { $0.ticket.status == .dropped }
            && view.items.allSatisfy { $0.assignee == .unassigned && $0.status != .done }
    }

    var body: some View {
        let sa = appModel.superagent
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                TaskSummaryCard(view: view)
                checklistColumn
                diffSection
                detailColumn
                footerSection
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear { events = sa.taskEvents(view.id) }
        .onChange(of: view) { _, new in
            events = sa.taskEvents(new.id)
            for (id, done) in pending where new.items.first(where: { $0.id == id }).map({ ($0.status == .done) == done }) ?? true {
                pending[id] = nil
            }
        }
        .background(Theme.canvas)
        // Esc 回到清单（Pass 6，同设置页）：加项框里有字就先清掉。`openWorklist` 会在下一轮把第一响应者清空（`leaveTerminals`），
        // 所以晚一拍再要焦点。
        .focusable()
        .focusEffectDisabled()
        .focused($cardFocused)
        .onAppear { DispatchQueue.main.async { cardFocused = true } }
        .onExitCommand {
            if !newItem.isEmpty { newItem = "" } else { appModel.openWorklist() }
        }
        .sheet(item: $editing) { ItemTextSheet(taskID: view.id, item: $0).environment(appModel) }
        .sheet(item: $editingSummaryItem) { ItemSummarySheet(taskID: view.id, item: $0).environment(appModel) }
        .alert("删除第 \(removing?.ord ?? 0) 项？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("删除", role: .destructive) { if let i = removing { sa.removeItem(view.id, ord: i.ord) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(removing?.text ?? "")
        }
        .alert("取消任务 \(view.task.label)？", isPresented: $confirmCancel) {
            Button("取消任务", role: .destructive) {
                sa.cancelTask(view.id)
                appModel.worklistTaskID = nil
            }
            Button("保留", role: .cancel) {}
        } message: {
            let sessions = view.openSessions
            Text(sessions.isEmpty
                 ? "任务标为已取消；没有正在跑的终端。"
                 : "会中断 \(sessions.count) 个终端：\(sessions.joined(separator: "、"))。任务标为已取消，终端、目录和已有改动都保留。")
        }
        .alert("任务 \(view.task.label) 已放弃？", isPresented: $confirmDrop) {
            Button("标为已放弃", role: .destructive) {
                sa.dropTask(view.id)
                appModel.worklistTaskID = nil
            }
            Button("保留", role: .cancel) {}
        } message: {
            Text("Agent 放弃了它的清单项，现在没有一项完成、也没有人在做。标为已放弃后任务结束；还要做就改派给别人或自己做。")
        }
    }

    // MARK: 顶部：标题行 + 「下一步」横幅（定稿：C 的横幅 + A 的纸面风格）

    /// 这张卡上动作的错误（`actionErrors[任务]`）和表单动作的错误（`actionError`）都在最上面（3A）。
    @ViewBuilder private var errorBanner: some View {
        let sa = appModel.superagent
        if let e = sa.actionErrors[view.id] ?? sa.actionError {
            Banner(text: e) { sa.actionErrors[view.id] = nil; sa.actionError = nil }
        }
    }

    private var header: some View {
        let sa = appModel.superagent
        let rest = view.task.isOpen ? Array(view.needsYou.dropFirst()) : []
        let meta = view.metaLine(includeScope: !editable)
        return VStack(alignment: .leading, spacing: 12) {
            errorBanner
            titleRow
            FlowLayout(spacing: Theme.Space.sm) {
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(minHeight: 26)
                    .help(view.task.scope)
                    .accessibilityLabel("元信息：\(meta)")
                if hasChips { metaChips }
            }
            NextStepBanner(view: view, assign: assign)
            if !rest.isEmpty || sa.actionEchoes[view.id] != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if !rest.isEmpty {
                        Text("还有 \(rest.count) 件：" + rest.map { need in
                            view.ticket(needing: need).map { "\(need.label)（工单 #\($0.id)）" } ?? need.label
                        }.joined(separator: "、"))
                    }
                    if let echo = sa.actionEchoes[view.id] { Text(echo) }
                }
                .font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
    }

    // MARK: 标题 + 阶段步进

    private var titleRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                titleText
                Spacer(minLength: 0)
                StageStepper(stages: view.task.stages, current: view.task.stageIndex)
            }
            VStack(alignment: .leading, spacing: 8) {
                titleText
                StageStepper(stages: view.task.stages, current: view.task.stageIndex)
            }
        }
    }

    private var titleText: some View {
        let t = view.task
        let tag = view.stateTag
        return HStack(alignment: .center, spacing: 10) {
            Text(t.label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
            Text(t.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(t.title)
            StateTag(text: tag.text, tint: tag.tint)
        }
    }

    // MARK: 改动（内嵌 diff）

    @ViewBuilder private var diffSection: some View {
        let diffable = TaskDiff.tickets(view)
        if let id = appModel.worklistDiffTicketID, view.ticket(id) != nil {
            TaskDiffSection(view: view, ticketID: id)
        } else if let last = diffable.last {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Button(diffable.count > 1 ? "查看工单 #\(last.id) 等 \(diffable.count) 张的代码改动" : "查看工单 #\(last.id) 的代码改动") {
                    appModel.showTaskDiff(task: view.id, ticket: last.id)
                }
                .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .help("按文件查看分支 \(last.ticket.branch) 相对分叉点的改动")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
        }
    }

    // MARK: 原文与结果（有内容才渲染卡片）

    @ViewBuilder private var detailColumn: some View {
        let t = view.task
        let request = t.request != t.title ? t.request : ""
        let result = (t.status == .done && view.knowledge != nil) ? "" : t.resultSummary
        let sections: [(label: String, text: String)] = t.status == .done
            ? [("结果", result), ("需求原文", request)]
            : [("需求原文", request), ("上一轮结果", result)]
        let nonEmpty = sections.filter { !$0.text.isEmpty }
        if !nonEmpty.isEmpty || !view.relatedKnowledge.isEmpty || t.origin != nil {
            VStack(alignment: .leading, spacing: 18) {
                if !view.relatedKnowledge.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(title: "关联历史经验（派单自动附给 Agent）")
                        ForEach(view.relatedKnowledge) { rel in
                            HStack(alignment: .top, spacing: 8) {
                                Button {
                                    if let tid = rel.taskID {
                                        appModel.openWorklist(task: tid)
                                    } else {
                                        appModel.openKnowledgeBase(entryID: rel.knowledgeID)
                                    }
                                } label: {
                                    Text(rel.displayLabel)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Theme.textPrimary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rel.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    if !rel.tldr.isEmpty {
                                        Text(rel.tldr)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.textSecondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 4)
                                if editable {
                                    Button {
                                        appModel.superagent.removeTaskKnowledgeLink(view.id, knowledgeID: rel.knowledgeID)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("移除这条经验关联")
                                }
                            }
                        }
                    }
                    if !nonEmpty.isEmpty { Hairline() }
                }
                ForEach(Array(nonEmpty.enumerated()), id: \.element.label) { idx, section in
                    if idx > 0 { Hairline() }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(title: section.label)
                        LongText(label: "", text: section.text)
                    }
                }
                OrgSyncRow(view: view)
            }
            .saCard()
        }
    }

    /// 只有可点的才做 chip：退回来源、组织 T-128、依赖、关联经验、后续衍生任务。
    private var hasChips: Bool {
        view.handbackOrigin != nil || (view.task.origin != nil && view.task.originID != nil)
            || editable || !view.task.deps.isEmpty || !view.relatedKnowledge.isEmpty || !view.derivedTasks.isEmpty
    }

    @ViewBuilder private var metaChips: some View {
        let t = view.task
        let sa = appModel.superagent
        if let origin = view.handbackOrigin { // 退回产生的任务（4A）：点回原任务
            MetaChip(text: "来自 A-\(origin.fromTaskID) · 工单 #\(origin.ticketID)", action: { appModel.openWorklist(task: origin.fromTaskID) })
                .help("A-\(origin.fromTaskID) 第 \(origin.itemOrd) 项在等它")
                .accessibilityLabel("来自任务 A-\(origin.fromTaskID) 第 \(origin.itemOrd) 项的退回，打开 A-\(origin.fromTaskID)")
        }
        OrgTaskChip(task: t) // 组织任务（第 3 期）：「组织 · T-128」，点开服务端任务页；本地任务不显示
        if editable {
            // 目录 chip 可点 → 选文件夹：交给会改文件的角色前必须有（引擎 H-02 拒绝时就指这里）。
            MetaChip(text: TaskView.scopeChip(t.scope), faint: t.scope.isEmpty, action: {
                if let p = pickFolder(from: t.scope, message: "任务的项目目录：交给会改文件的角色（开发）时在这里工作") { sa.updateTask(view.id, scope: p) }
            })
            .help(t.scope.isEmpty ? "还没有项目目录：交给开发之前先选一个" : t.scope)
            .accessibilityLabel(t.scope.isEmpty ? "选项目目录" : "项目目录 \(t.scope)，点了更换")
            // 依赖 chip 可点 → 选前置任务（第 2 期）；没有依赖时是淡色的「依赖…」。
            MetaChip(text: WorklistText.deps(t.deps, done: { sa.task($0)?.task.status == .done }), faint: t.deps.isEmpty,
                     action: { showDeps = true })
                .help("前置任务没完成时不能交给 Agent；分配给你不限")
                .accessibilityLabel(t.deps.isEmpty ? "选前置任务" : "前置任务：" + t.deps.map { "A-\($0)" }.joined(separator: "、"))
                .popover(isPresented: $showDeps, arrowEdge: .bottom) {
                    DepsPicker(candidates: depCandidates,
                               selected: Binding(get: { Set(view.task.deps) },
                                                 set: { sa.updateTask(view.id, deps: Array($0).sorted()) }),
                               open: { id in showDeps = false; appModel.worklistTaskID = id })
                        .environment(appModel)
                }
            let relText = view.relatedKnowledge.isEmpty
                ? "关联经验…"
                : "关联经验：" + view.relatedKnowledge.map(\.displayLabel).joined(separator: "、")
            MetaChip(text: relText, faint: view.relatedKnowledge.isEmpty, action: { showRelatedKB = true })
                .help("关联历史已完成任务或知识卡，派单时自动把上次结论和避坑点提供给执行 Agent")
                .accessibilityLabel(relText)
                .popover(isPresented: $showRelatedKB, arrowEdge: .bottom) {
                    KnowledgeLinkPicker(
                        currentTaskID: view.id,
                        preferredScope: t.scope,
                        selectedIDs: Binding(
                            get: { Set(view.relatedKnowledge.map(\.knowledgeID)) },
                            set: { sa.setTaskKnowledgeLinks(view.id, knowledgeIDs: Array($0).sorted()) }
                        ),
                        onOpenTask: { tid in showRelatedKB = false; appModel.worklistTaskID = tid }
                    )
                    .environment(appModel)
                }
        } else {
            if !t.deps.isEmpty {
                MetaChip(text: WorklistText.deps(t.deps, done: { sa.task($0)?.task.status == .done }))
            }
            if !view.relatedKnowledge.isEmpty {
                MetaChip(text: "关联经验：" + view.relatedKnowledge.map(\.displayLabel).joined(separator: "、"))
            }
        }
        ForEach(view.derivedTasks) { dt in
            MetaChip(text: "后续 \(dt.label)", action: { appModel.openWorklist(task: dt.id) })
                .help("后续关联任务：\(dt.label) \(dt.title)（\(dt.status.label)）")
        }
    }

    /// 可选的前置：其它打开的任务，加上已经是依赖但不再打开的（能取消勾选）。新的在前。
    private var depCandidates: [TaskView] {
        let sa = appModel.superagent
        let open = sa.openTasks.filter { $0.id != view.id }
        let closed = view.task.deps.compactMap { id in open.contains { $0.id == id } ? nil : sa.task(id) }
        return (open + closed).sorted { $0.id > $1.id }
    }

    // MARK: 工作清单卡片（全宽清晰呈现，不再挤在 280pt 窄栏里）

    private var checklistColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    SectionLabel(title: "清单")
                    Text("\(view.doneCount) / \(view.totalCount)")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel("完成 \(view.doneCount) 项，共 \(view.totalCount) 项")
                    Spacer(minLength: 0)
                    if editable {
                        Button("分配 / 谁来做…", action: assign)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("谁来做")
                    }
                }
                ProgressLine(done: view.doneCount, total: view.totalCount)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Hairline()

            VStack(spacing: 0) {
                ForEach(Array(view.items.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 { Hairline() }
                    let expanded = expandedOrds.contains(item.ord)
                    let summary = Self.effectiveItemSummary(item: item, in: view)
                    ItemRow(
                        view: view,
                        item: item,
                        status: shownStatus(item),
                        summary: summary,
                        expanded: expanded,
                        editable: editable,
                        toggle: { toggle(item) },
                        toggleExpand: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                if expanded { expandedOrds.remove(item.ord) } else { expandedOrds.insert(item.ord) }
                            }
                        },
                        editSummary: { editingSummaryItem = item },
                        edit: { editing = item },
                        remove: { removing = item }
                    )
                    .padding(.horizontal, 18)

                    if expanded {
                        ItemSummaryDrawer(
                            view: view,
                            item: item,
                            summary: summary,
                            editSummary: { editingSummaryItem = item }
                        )
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                    }
                }
                if editable {
                    if !view.items.isEmpty { Hairline() }
                    addField.padding(.horizontal, 18)
                }
            }
        }
        .saCard(padding: 0)
    }

    /// 一直在的「加一项」：与 `ItemRow` 共享完全相同的「16pt 序号列 + 10pt + 20pt 勾选框列 + 10pt + 文本列」网格，保证纵向像素级对齐。
    private var addField: some View {
        HStack(alignment: .center, spacing: 10) {
            Color.clear.frame(width: 16, height: 1).accessibilityHidden(true)
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.pewter)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            TextField("加一项，回车确认", text: $newItem)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($newItemFocused)
                .onSubmit(addItem)
                .accessibilityLabel("加一项")
        }
        .padding(.vertical, 12)
    }

    private func shownStatus(_ item: Item) -> ItemStatus {
        if let p = pending[item.id] { return p ? .done : .todo }
        return item.status
    }

    private func toggle(_ item: Item) {
        let sa = appModel.superagent
        let done = shownStatus(item) != .done
        pending[item.id] = done
        sa.actionError = nil
        sa.setItemDone(view.id, ord: item.ord, done: done)
        if sa.actionError != nil { pending[item.id] = nil }
    }

    private func addItem() {
        let text = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let sa = appModel.superagent
        if attempt(sa, { sa.addItems(view.id, [text]) }) == nil {
            newItem = ""
            newItemFocused = true
        } else {
            sa.actionError = "加不进去：" + (sa.actionError ?? "")
        }
    }

    // MARK: 底部折叠活动记录与操作

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if !events.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { showActivity.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(showActivity ? 90 : 0))
                            Text("活动记录 · \(events.count) 条")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if abandoned {
                    Button("已放弃？") { confirmDrop = true }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.textTertiary)
                        .help("Agent 放弃了全部清单项：确认后任务标为已放弃")
                        .accessibilityLabel("标为已放弃")
                }
                if view.task.isOpen {
                    Button("取消任务…") { confirmCancel = true }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.textTertiary)
                        .help("名下正在跑的工单会被中断")
                        .accessibilityLabel("取消任务")
                }
            }

            if showActivity, !events.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(events.reversed(), id: \.id) { e in
                        let tone = ActivityTone.of(e.kind, text: e.text)
                        HStack(alignment: .top, spacing: 10) {
                            TimelineDot(tone: tone).padding(.top, 4)
                            Text(Self.time(e.at))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 68, alignment: .leading)
                                .padding(.top, 1)
                            Text(e.text)
                                .font(.system(size: 13, weight: tone == .attention ? .medium : .regular))
                                .foregroundStyle(tone == .attention ? Theme.textPrimary : Theme.textSecondary)
                                .lineLimit(4)
                                .help(e.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .saCard()
                .transition(.opacity)
            }
        }
        .padding(.top, 4)
    }

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dated: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f }()

    private static func time(_ at: Double) -> String {
        let d = Date(timeIntervalSince1970: at)
        return (Calendar.current.isDateInToday(d) ? clock : dated).string(from: d)
    }

    static func effectiveItemSummary(item: Item, in view: TaskView) -> String {
        let saved = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty { return saved }
        if let tid = item.ticketID, let tv = view.ticket(tid) {
            let report = tv.ticket.reportSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !report.isEmpty { return report }
        }
        return ""
    }
}

// MARK: - 阶段步进（F-08；设计评审 2026-11-08，6A）

/// 头卡内标题下的一行 24pt 文字「待领取 › 进行中 › 待评审 › 完成」：当前段 Charcoal 半粗 + 2px Charcoal 下划线，
/// 已过段 stone，未到段 pewter。它是状态，不是重点——卡上最轻的墨；最重的墨留给需要你条。不用颜色区分阶段。
struct StageStepper: View {
    let stages: [WorkflowStage]
    let current: Int

    enum Tone: Equatable { case past, current, ahead }

    static func tone(_ i: Int, current: Int) -> Tone {
        i == current ? .current : i < current ? .past : .ahead
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                if i > 0 {
                    Text("›").font(.system(size: 13)).foregroundStyle(Theme.Colors.pewter).accessibilityHidden(true)
                }
                segment(s.name, Self.tone(i, current: current))
            }
        }
        .frame(height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("阶段：" + stages.enumerated().map { $0.offset == current ? "\($0.element.name)（当前）" : $0.element.name }.joined(separator: "，"))
    }

    private func segment(_ name: String, _ tone: Tone) -> some View {
        Text(name)
            .font(.system(size: 13, weight: tone == .current ? .semibold : .regular))
            .foregroundStyle(tone == .current ? Theme.brand : tone == .past ? Theme.textTertiary : Theme.Colors.pewter)
            .lineLimit(1)
            .frame(height: 26)
            .overlay(alignment: .bottom) { if tone == .current { Theme.brand.frame(height: 2) } }
    }
}

// MARK: - 清单项行（F-09）

/// 序号 · 勾选框（你的项可点，Agent 的只读）· 文字（≤3 行，做完划掉），下一行「执行者 · 工单 #12（可点跳终端）· 状态」
/// （退回成新任务的项写「→ A-13」，可点）。
private struct ItemRow: View {
    @Environment(AppModel.self) private var appModel
    let view: TaskView
    let item: Item
    /// 乐观更新后显示的状态。
    let status: ItemStatus
    let summary: String
    let expanded: Bool
    let editable: Bool
    let toggle: () -> Void
    let toggleExpand: () -> Void
    let editSummary: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    private var canExpand: Bool {
        !summary.isEmpty || item.ticketID != nil || status == .done || !view.task.isOpen
    }

    var body: some View {
        var shown = item
        shown.status = status
        let word = view.statusWord(shown)
        let handback = view.handback(of: shown)
        return HStack(alignment: .center, spacing: 10) {
            Text("\(item.ord)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16, alignment: .trailing)
            checkbox
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.system(size: 14))
                    .foregroundStyle(status == .done ? Theme.textSecondary : Theme.textPrimary)
                    .strikethrough(status == .done, color: Theme.Colors.mist)
                    .lineLimit(2)
                    .help(item.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !expanded, !summary.isEmpty {
                    Text(summary.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if handback == nil {
                    AssigneeChip(assignee: item.assignee)
                    if let id = item.ticketID {
                        Button("#\(id)") { appModel.goToTicket(id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .frame(height: 22)
                            .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                            .help("打开工单 #\(id)（终端在线时跳终端，终端已结束时打开归档摘要）")
                    }
                    if status != .done, view.task.isOpen, item.assignee.role != nil {
                        Button {
                            retryItem()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                                Text("重试").font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("重试第 \(item.ord) 项对应的执行工单")
                        .accessibilityLabel("重试第 \(item.ord) 项")
                    }
                }
                if let handback {
                    Button(word.text) { appModel.openWorklist(task: handback.toTaskID) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                        .help("这项被工单 #\(handback.ticketID) 退回，成了任务 A-\(handback.toTaskID)；点击打开")
                        .accessibilityLabel("跟随任务 A-\(handback.toTaskID)，\(word.text)，打开它")
                } else if word.attention || status == .doing {
                    Text(word.text)
                        .font(.system(size: 11, weight: word.attention ? .semibold : .regular))
                        .foregroundStyle(word.attention ? Theme.Status.attention : Theme.textTertiary)
                }
                if canExpand {
                    Button(action: toggleExpand) {
                        HStack(spacing: 3) {
                            Text(summary.isEmpty ? "详情" : "摘要")
                                .font(.system(size: 11))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .foregroundStyle(expanded ? Theme.textPrimary : Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                        .background(expanded ? Theme.surface2 : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "收起本项摘要" : "展开查看本项保存的执行摘要与记录")
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if canExpand { toggleExpand() }
        }
        .contextMenu {
            if canExpand {
                Button(expanded ? "收起本项摘要" : "查看本项摘要", action: toggleExpand)
            }
            Button("编辑本项摘要…", action: editSummary)
            if editable {
                Divider()
                if status != .done, item.assignee.role != nil, handback == nil {
                    Button("重试此项") { retryItem() }
                    Divider()
                }
                Button("改文字…", action: edit)
                Button("删除…", role: .destructive, action: remove).disabled(item.ticketID != nil)
                if item.ticketID != nil { Text("有工单的项先取消工单才能删") }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("第 \(item.ord) 项，\(item.assignee.spoken)，\(word.text)：\(item.text)")
    }

    private func retryItem() {
        let sa = appModel.superagent
        if let id = item.ticketID {
            if let tv = view.ticket(id), tv.ticket.isOpen {
                sa.retry(id)
            } else if let tv = view.ticket(id), tv.ticket.status != .stopped {
                sa.feedback(id, "请重试并继续完成第 \(item.ord) 项（若因网络断开中断请从当前进度继续）。")
            } else {
                sa.retryTask(view.id)
            }
        } else {
            sa.retryTask(view.id)
        }
    }

    /// 你的项可点（乐观更新），Agent 的只读。
    @ViewBuilder private var checkbox: some View {
        if item.assignee == .you && editable {
            Button(action: toggle) { ItemCheckbox(status: status) }
                .buttonStyle(.plain)
                .help(status == .done ? "取消勾选" : "标为完成")
                .accessibilityLabel(status == .done ? "取消勾选第 \(item.ord) 项" : "第 \(item.ord) 项标为完成")
        } else {
            ItemCheckbox(status: status)
        }
    }
}

// MARK: - 小件：分区标题、进度线、时间线圆点

/// 「活动」「清单」「原文」这类小标题：12pt 半粗、略加字距、石灰。
private struct SectionLabel: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 12, weight: .semibold)).tracking(1).foregroundStyle(Theme.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 清单的进度：3pt 的细线，做完的部分炭黑。
private struct ProgressLine: View {
    let done: Int
    let total: Int
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border.opacity(0.7))
                Capsule().fill(Theme.brand).frame(width: total == 0 ? 0 : geo.size.width * CGFloat(done) / CGFloat(total))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// 活动事件的语气：要人管的（受阻、失败、提问、退回、停下、评审有问题）琥珀；交付 / 完成 / 评审通过绿；其余空心。
/// 任务层的事件 kind 很笼统（item / review / stage），所以也看文字。
enum ActivityTone: Equatable {
    case attention, done, plain

    static func of(_ kind: String, text: String = "") -> ActivityTone {
        let k = kind.lowercased()
        if ["blocked", "failed", "ask", "handback", "waiting", "stalled", "delivery"].contains(where: k.contains)
            || ["退回", "受阻", "失败", "有问题", "没回报"].contains(where: text.contains) { return .attention }
        if ["ready", "done", "approve", "complete", "merged"].contains(where: k.contains)
            || ["交付", "全部完成", "任务完成"].contains(where: text.contains)
            || (text.contains("评审结论") && text.contains("通过")) { return .done }
        return .plain
    }
}

private struct TimelineDot: View {
    let tone: ActivityTone
    var body: some View {
        Circle()
            .fill(tone == .attention ? Theme.Status.attention : tone == .done ? Theme.Status.positive : Theme.canvas)
            .overlay(Circle().stroke(tone == .plain ? Theme.Colors.pewter : Color.clear, lineWidth: 1.5))
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
}

// MARK: - 长文（原文 / 结果）

/// 「原文：…」「结果：…」：超过 6 行（或 240 字）先收起，点「展开全部」看完。空文字不占位。
private struct LongText: View {
    let label: String
    let text: String
    @State private var expanded = false

    private var long: Bool { text.count > 240 || text.filter { $0 == "\n" }.count > 5 }

    var body: some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ((label.isEmpty ? Text("") : Text("\(label)：").foregroundStyle(Theme.textTertiary)) + Text(text))
                    .font(.system(size: 14)).lineSpacing(4).foregroundStyle(Theme.textPrimary)
                    .lineLimit(long && !expanded ? 6 : nil)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if long {
                    Button(expanded ? "收起" : "展开全部") { expanded.toggle() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel(expanded ? "收起\(label)" : "展开\(label)全文")
                }
            }
        }
    }
}

// MARK: - 元信息 chip

private struct MetaChip: View {
    let text: String
    var strong = false
    /// 淡色：还没填的可选项（「依赖…」）。
    var faint = false
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }.buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(faint ? Theme.textTertiary : Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(faint ? Theme.surface : Theme.chrome, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(strong ? Theme.brand : Theme.border, lineWidth: 1))
    }
}

/// 前置任务选择器（任务卡的依赖 chip、「+ 任务」）：其它打开的任务，多选；前置没完成时引擎拒绝交给 Agent（注意事项 C-14）。
struct DepsPicker: View {
    let candidates: [TaskView]
    @Binding var selected: Set<Int64>
    /// 打开那张卡（任务卡里用；新建任务时没有）。
    var open: ((Int64) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("前置任务").font(Theme.Font.sectionHeader).foregroundStyle(Theme.textTertiary)
            if candidates.isEmpty {
                Text("没有别的打开的任务。").font(.caption).foregroundStyle(Theme.textTertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(candidates) { tv in
                            HStack(spacing: Theme.Space.sm) {
                                Toggle(isOn: Binding(get: { selected.contains(tv.id) },
                                                     set: { on in if on { selected.insert(tv.id) } else { selected.remove(tv.id) } })) {
                                    HStack(spacing: Theme.Space.sm) {
                                        Text(tv.task.label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                                        Text(tv.task.title).font(.callout).lineLimit(1)
                                        if !tv.task.isOpen { StateTag(text: tv.stateTag.text, tint: tv.stateTag.tint) }
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .accessibilityLabel("前置任务 \(tv.task.label) \(tv.task.title)")
                                Spacer(minLength: 0)
                                if let open {
                                    Button { open(tv.id) } label: { Image(systemName: "arrow.right.circle") }
                                        .buttonStyle(.borderless).foregroundStyle(Theme.textTertiary)
                                        .help("打开 \(tv.task.label)")
                                        .accessibilityLabel("打开任务 \(tv.task.label)")
                                }
                            }
                            .frame(height: 22)
                        }
                    }
                }
                .frame(height: min(CGFloat(candidates.count) * (22 + Theme.Space.xs), 240)) // popover 按内容定大小，滚动区要定高
            }
            Text("前置没完成时不能交给 Agent；分配给你不限。").font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.lg)
        .frame(width: 380)
    }
}

/// 从左到右排、放不下就换行（元信息 chips）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: width == .infinity ? widest : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var rows: [[(subview: LayoutSubview, size: CGSize)]] = []
        var currentRow: [(subview: LayoutSubview, size: CGSize)] = []
        var x = bounds.minX
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if !currentRow.isEmpty, x + size.width > bounds.maxX {
                rows.append(currentRow)
                currentRow = []
                x = bounds.minX
            }
            currentRow.append((s, size))
            x += size.width + spacing
        }
        if !currentRow.isEmpty { rows.append(currentRow) }

        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map(\.size.height).max() ?? 0
            var rowX = bounds.minX
            for item in row {
                let centeredY = y + (rowHeight - item.size.height) * 0.5
                item.subview.place(at: CGPoint(x: rowX, y: centeredY), proposal: ProposedViewSize(item.size))
                rowX += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

// MARK: - 改清单项文字

private struct ItemTextSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let taskID: Int64
    let item: Item
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        let sa = appModel.superagent
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("改第 \(item.ord) 项的文字").font(Theme.Font.headerTitle)
            TextEditor(text: $text).editorBox().frame(height: 80)
            HStack(alignment: .firstTextBaseline) {
                Text(item.ticketID.map { "这项有工单 #\($0)，改了会提示执行者。" } ?? "一句话、可验证的结果。")
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(trimmed.count) / \(Item.maxText)").monospacedDigit()
                    .foregroundStyle(trimmed.count > Item.maxText ? Theme.Status.error : Theme.textTertiary)
            }
            .font(.caption)
            SheetButtons(error: error, confirm: "保存", enabled: !trimmed.isEmpty && trimmed.count <= Item.maxText && trimmed != item.text) {
                error = attempt(sa) { sa.editItem(taskID, ord: item.ord, text: trimmed) }
                if error == nil { dismiss() }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .onAppear { text = item.text }
    }
}
