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
    @State private var addingItem = false
    @State private var newItem = ""
    @State private var editing: Item?
    @State private var removing: Item?
    @State private var confirmCancel = false
    @State private var confirmDrop = false
    @State private var showDeps = false
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
        GeometryReader { geo in
            if let cols = TaskCardLayout.columns(width: geo.size.width) {
                threeColumns(cols)
            } else {
                singleColumn
            }
        }
        .onAppear { events = sa.taskEvents(view.id) }
        .onChange(of: view) { _, new in
            events = sa.taskEvents(new.id)
            for (id, done) in pending where new.items.first(where: { $0.id == id }).map({ ($0.status == .done) == done }) ?? true {
                pending[id] = nil
            }
        }
        .background(Theme.canvas)
        // Esc 回到清单（Pass 6，同设置页）：正在加项就先收起输入行。`openWorklist` 会在下一轮把第一响应者清空（`leaveTerminals`），
        // 所以晚一拍再要焦点。
        .focusable()
        .focusEffectDisabled()
        .focused($cardFocused)
        .onAppear { DispatchQueue.main.async { cardFocused = true } }
        .onExitCommand {
            if addingItem { addingItem = false; newItem = "" } else { appModel.openWorklist() }
        }
        .sheet(item: $editing) { ItemTextSheet(taskID: view.id, item: $0).environment(appModel) }
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

    // MARK: 版式：三列 / 单列

    /// 这张卡上动作的错误（`actionErrors[任务]`）和表单动作的错误（`actionError`）都在详情最上面（3A）。
    @ViewBuilder private var errorBanner: some View {
        let sa = appModel.superagent
        if let e = sa.actionErrors[view.id] ?? sa.actionError {
            Banner(text: e) { sa.actionErrors[view.id] = nil; sa.actionError = nil }
        }
    }

    /// 左活动、中清单、右详情；三列各自滚动，左中两列定宽（`TaskCardLayout`）。
    private func threeColumns(_ cols: (activity: CGFloat, checklist: CGFloat)) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.lg) {
            ScrollView { activityCard(compact: true).padding(.vertical, Theme.Space.xxl) }
                .frame(width: cols.activity)
            ScrollView { checklistCard(compact: true).padding(.vertical, Theme.Space.xxl) }
                .frame(width: cols.checklist)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    errorBanner
                    titleCard
                    needBar
                    textCard
                    OrgSyncRow(view: view) // 同步行（第 3 期）：只有组织任务显示
                    bottomActions
                }
                .padding(.vertical, Theme.Space.xxl)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Theme.Space.xxl)
    }

    /// 窄窗口：原来的单列，最宽 760。
    private var singleColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    errorBanner
                    titleCard
                    needBar.id("needs")
                    textCard
                    checklistCard(compact: false)
                    if !events.isEmpty { activityCard(compact: false) } // 没有活动不占一张卡
                    OrgSyncRow(view: view)
                    bottomActions
                }
                .padding(Theme.Space.xxl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { if !view.needsYou.isEmpty { proxy.scrollTo("needs", anchor: .center) } }
        }
    }

    // MARK: 标题 + 阶段步进 + 元信息 + 原文

    private var titleCard: some View {
        let t = view.task
        let tag = view.stateTag
        let meta = view.metaLine(includeScope: !editable)
        return VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                Text(t.label).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                Text(t.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).textSelection(.enabled)
                StateTag(text: tag.text, tint: tag.tint)
                Spacer(minLength: 0)
            }
            StageStepper(stages: t.stages, current: t.stageIndex)
            Text(meta).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .help(t.scope)
                .accessibilityLabel("元信息：\(meta)")
            if hasChips { FlowLayout(spacing: Theme.Space.md) { metaChips } }
        }
        .saCard()
    }

    // MARK: 原文 + 结果：放在需要你条之后，长文先收起（不把需要你条挤下去）

    @ViewBuilder private var textCard: some View {
        let t = view.task
        let request = t.request != t.title ? t.request : ""
        if !request.isEmpty || !t.resultSummary.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                // 完成了先看结果，没完成先看原文。
                if t.status == .done {
                    LongText(label: "结果", text: t.resultSummary)
                    LongText(label: "原文", text: request)
                } else {
                    LongText(label: "原文", text: request)
                    LongText(label: "结果", text: t.resultSummary)
                }
            }
            .saCard()
        }
    }

    /// 只有可点的才做 chip：退回来源、组织 T-128、依赖。
    private var hasChips: Bool {
        view.handbackOrigin != nil || (view.task.origin != nil && view.task.originID != nil) || editable || !view.task.deps.isEmpty
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
        } else if !t.deps.isEmpty {
            MetaChip(text: WorklistText.deps(t.deps, done: { sa.task($0)?.task.status == .done }))
        }
    }

    /// 可选的前置：其它打开的任务，加上已经是依赖但不再打开的（能取消勾选）。新的在前。
    private var depCandidates: [TaskView] {
        let sa = appModel.superagent
        let open = sa.openTasks.filter { $0.id != view.id }
        let closed = view.task.deps.compactMap { id in open.contains { $0.id == id } ? nil : sa.task(id) }
        return (open + closed).sorted { $0.id > $1.id }
    }

    // MARK: 需要你条（F-10）：紧贴头卡之下

    @ViewBuilder private var needBar: some View {
        let sa = appModel.superagent
        if view.task.isOpen, let line = view.needLine(handbackTarget: view.handbackNeed.flatMap { sa.task($0.toTaskID) }) {
            let rest = view.needsYou.dropFirst()
            HStack(alignment: .center, spacing: Theme.Space.md) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.Status.attention).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    (Text(line.title).fontWeight(.semibold) + Text(line.body.isEmpty ? "" : "  " + line.body))
                        .font(.callout).foregroundStyle(Theme.textPrimary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if !rest.isEmpty {
                        Text("还有 \(rest.count) 件：" + rest.map { need in
                            view.ticket(needing: need).map { "\(need.label)（工单 #\($0.id)）" } ?? need.label
                        }.joined(separator: "、"))
                        .font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    if let echo = sa.actionEchoes[view.id] { // 回答 / 打回 / 补充后的「已送达」（3A）
                        Text(echo).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.Space.md)
                // 动作集合一处实现（清单行同款）：看改动 / 打回… / 完成任务… 等都在它里面，确认单也由它挂。
                TaskNeedActions(view: view, assign: assign)
                    .controlSize(.large) // 28pt 的点击目标（Pass 6）
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.md)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Status.attention.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Status.attention, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("需要你：\(line.title)。\(line.body)")
        } else if view.task.isOpen, let echo = sa.actionEchoes[view.id] {
            quietBar(echo, "") // 动作之后没有别的需要你了：回声留 6 秒（3A）
        } else if view.task.isOpen, view.reviewing {
            quietBar("评审中", "TFA 正在核对交付；核对完才进待评审。")
        } else if view.task.isOpen, view.unassignedCount > 0 {
            quietBar("等你定谁来做", "\(WorklistText.ords(view.items.filter { $0.assignee == .unassigned }.map(\.ord)))还没定。") {
                Button("谁来做…", action: assign).controlSize(.large)
            }
        }
    }

    private func quietBar(_ title: String, _ body: String) -> some View {
        quietBar(title, body) { EmptyView() }
    }

    private func quietBar<Trailing: View>(_ title: String, _ body: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Theme.Space.md) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.textTertiary).frame(width: 8, height: 8).accessibilityHidden(true)
            (Text(title).fontWeight(.semibold) + Text(body.isEmpty ? "" : "  " + body))
                .font(.callout).foregroundStyle(Theme.textPrimary).lineLimit(2)
            Spacer(minLength: Theme.Space.md)
            trailing()
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
    }

    // MARK: 工作清单（F-09）

    /// `compact`：三列里的窄清单列，每项的执行者 / 工单 / 状态挪到文字下一行。
    private func checklistCard(compact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.md) {
                Text("工作清单").font(Theme.Font.rowTitle)
                Text("\(view.doneCount)/\(view.totalCount)").font(.callout).monospacedDigit().foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("完成 \(view.doneCount) 项，共 \(view.totalCount) 项")
                Spacer()
                if editable { // 「谁来做… / 加一项」只在这里（Pass 4）
                    Button("谁来做…", action: assign)
                        .accessibilityLabel("谁来做")
                    Button { startAdding() } label: { Label("加一项", systemImage: "plus") }
                        .accessibilityLabel("加一项")
                }
            }
            .controlSize(.large) // 28pt 的点击目标（Pass 6）
            .padding(.horizontal, compact ? Theme.Space.lg : Theme.Space.xl)
            .padding(.vertical, Theme.Space.md)
            ForEach(view.items) { item in
                Hairline()
                ItemRow(view: view, item: item, status: shownStatus(item), editable: editable, compact: compact,
                        toggle: { toggle(item) }, edit: { editing = item }, remove: { removing = item })
                    .padding(.horizontal, compact ? Theme.Space.lg : Theme.Space.xl)
            }
            if addingItem {
                Hairline()
                HStack(spacing: Theme.Space.md) {
                    TextField("一句话、可验证的结果", text: $newItem)
                        .textFieldStyle(.roundedBorder)
                        .focused($newItemFocused)
                        .onSubmit(addItem)
                        .accessibilityLabel("新清单项")
                    Button("加入", action: addItem)
                        .disabled(newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("完成") { addingItem = false; newItem = "" }
                }
                .controlSize(.small)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.md)
            }
        }
        .saCard(padding: 0)
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

    private func startAdding() {
        addingItem = true
        newItemFocused = true
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

    // MARK: 活动

    /// `compact`：三列里的窄活动列，每条最多 4 行（悬停看全文），免得一条长回报占满一屏。
    private func activityCard(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("活动").font(Theme.Font.rowTitle)
            if events.isEmpty { // 三列时这一列总在，空着要说一句
                Text("还没有活动。").font(.callout).foregroundStyle(Theme.textTertiary)
            }
            ForEach(events, id: \.id) { e in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                    Text(Self.time(e.at)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    Text(e.text).font(.callout).foregroundStyle(Theme.textSecondary)
                        .lineLimit(compact ? 4 : nil).help(compact ? e.text : "")
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .saCard()
    }

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dated: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f }()

    private static func time(_ at: Double) -> String {
        let d = Date(timeIntervalSince1970: at)
        return (Calendar.current.isDateInToday(d) ? clock : dated).string(from: d)
    }

    // MARK: 底部动作：只剩「取消任务…」（Pass 4）

    private var bottomActions: some View {
        HStack(spacing: Theme.Space.md) {
            Spacer()
            if abandoned {
                Button("已放弃？") { confirmDrop = true }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    .help("Agent 放弃了全部清单项：确认后任务标为已放弃")
                    .accessibilityLabel("标为已放弃")
            }
            if view.task.isOpen {
                Button("取消任务…") { confirmCancel = true }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    .help("名下正在跑的工单会被中断")
                    .accessibilityLabel("取消任务")
            }
        }
        .controlSize(.large)
        .frame(minHeight: 28)
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
        HStack(spacing: Theme.Space.md) {
            ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                if i > 0 {
                    Text("›").font(.system(size: 13)).foregroundStyle(Theme.Colors.pewter).accessibilityHidden(true)
                }
                segment(s.name, Self.tone(i, current: current))
            }
        }
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("阶段：" + stages.enumerated().map { $0.offset == current ? "\($0.element.name)（当前）" : $0.element.name }.joined(separator: "，"))
    }

    private func segment(_ name: String, _ tone: Tone) -> some View {
        Text(name)
            .font(.system(size: 13, weight: tone == .current ? .semibold : .regular))
            .foregroundStyle(tone == .current ? Theme.brand : tone == .past ? Theme.textTertiary : Theme.Colors.pewter)
            .lineLimit(1)
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) { if tone == .current { Theme.brand.frame(height: 2) } }
    }
}

// MARK: - 清单项行（F-09）

/// 40pt：序号 · 勾选框（你的项可点，Agent 的只读）· 文字（≤2 行）· 执行者 chip · 工单号 chip（可点跳终端）· 状态词 60pt 右对齐
/// （退回成新任务的项写「→ A-13」，可点）。
private struct ItemRow: View {
    @Environment(AppModel.self) private var appModel
    let view: TaskView
    let item: Item
    /// 乐观更新后显示的状态。
    let status: ItemStatus
    let editable: Bool
    /// 窄清单列（三列版式）：文字独占一行（≤3 行），执行者 / 工单 / 状态放在它下面一行。
    var compact = false
    let toggle: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        var shown = item
        shown.status = status
        let word = view.statusWord(shown)
        let handback = view.handback(of: shown)
        return Group {
            if compact {
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    ordinal.padding(.top, 4)
                    checkbox
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        itemText(lines: 3)
                        HStack(spacing: Theme.Space.sm) {
                            AssigneeChip(assignee: item.assignee)
                            if let id = item.ticketID { TicketChip(id: id, action: { appModel.goToTicket(id) }) }
                            Spacer(minLength: 0)
                            statusWord(word, handback: handback, width: nil)
                        }
                    }
                }
            } else {
                HStack(spacing: Theme.Space.md) {
                    ordinal
                    checkbox
                    itemText(lines: 2)
                    AssigneeChip(assignee: item.assignee)
                    if let id = item.ticketID {
                        TicketChip(id: id, action: { appModel.goToTicket(id) })
                    } else {
                        Text("—").font(.system(size: 11)).foregroundStyle(Theme.Colors.mist).frame(width: 34)
                            .accessibilityHidden(true)
                    }
                    statusWord(word, handback: handback, width: 60)
                }
            }
        }
        .padding(.vertical, compact ? Theme.Space.sm : Theme.Space.xs)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .contextMenu {
            if editable {
                Button("改文字…", action: edit)
                Button("删除…", role: .destructive, action: remove).disabled(item.ticketID != nil)
                if item.ticketID != nil { Text("有工单的项先取消工单才能删") }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("第 \(item.ord) 项，\(item.assignee.spoken)，\(word.text)：\(item.text)")
    }

    private var ordinal: some View {
        Text("\(item.ord)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
            .frame(width: 18, alignment: .trailing)
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

    private func itemText(lines: Int) -> some View {
        Text(item.text).font(.callout)
            .foregroundStyle(status == .done ? Theme.textSecondary : Theme.textPrimary)
            .lineLimit(lines).help(item.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 状态词；退回成新任务的项写「→ A-13」，可点打开它。`width` 为 nil 时按内容宽（窄列里靠右）。
    @ViewBuilder private func statusWord(_ word: (text: String, attention: Bool), handback: HandbackLink?, width: CGFloat?) -> some View {
        if let handback {
            Button(word.text) { appModel.openWorklist(task: handback.toTaskID) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .frame(width: width, alignment: .trailing)
                .help("这项被工单 #\(handback.ticketID) 退回，成了任务 A-\(handback.toTaskID)；打开它")
                .accessibilityLabel("打开任务 A-\(handback.toTaskID)")
        } else {
            Text(word.text).font(.system(size: 12))
                .foregroundStyle(word.attention ? Theme.Status.attention : Theme.textSecondary)
                .frame(width: width, alignment: .trailing)
        }
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
                (Text("\(label)：").foregroundStyle(Theme.textTertiary) + Text(text))
                    .font(.callout).foregroundStyle(Theme.textPrimary)
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
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
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
