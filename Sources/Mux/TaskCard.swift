import AppKit
import SwiftUI
import SuperagentCore

// 任务卡（TFA-工作清单-需求文档 §9.2、注意事项 F-07～F-10）。顺序固定：标题 → 元信息 chips → 阶段条 → 工作清单 →
// 需要你条 → 活动 → 底部动作；缺的部分不占位。一张卡只有一条需要你；工单号可点，跳到它的终端。

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
    @State private var showDeps = false
    /// 乐观更新的勾选（`Item.id` → 勾了没）：先翻状态再调引擎，失败回滚（注意事项 F-18）。
    @State private var pending: [Int64: Bool] = [:]
    @FocusState private var newItemFocused: Bool

    /// 还能改清单、分配：打开的和已完成的（跟进会重新打开，注意事项 C-10）；已取消 / 已放弃的不能。
    private var editable: Bool { view.task.status == .open || view.task.status == .done }

    var body: some View {
        let sa = appModel.superagent
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if let e = sa.actionError { Banner(text: e) { sa.actionError = nil } }
                    titleCard
                    workflowCard
                    needBar.id("needs")
                    checklistCard
                    activityCard
                    bottomActions
                }
                .padding(Theme.Space.xxl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                events = sa.taskEvents(view.id)
                if !view.needsYou.isEmpty { proxy.scrollTo("needs", anchor: .center) }
            }
            .onChange(of: view) { _, new in
                events = sa.taskEvents(new.id)
                for (id, done) in pending where new.items.first(where: { $0.id == id }).map({ ($0.status == .done) == done }) ?? true {
                    pending[id] = nil
                }
            }
        }
        .background(Theme.canvas)
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
    }

    // MARK: 标题 + 元信息 + 原文

    private var titleCard: some View {
        let t = view.task
        let tag = view.stateTag
        return VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                Text(t.label).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                Text(t.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).textSelection(.enabled)
                StateTag(text: tag.text, tint: tag.tint)
                Spacer(minLength: 0)
            }
            FlowLayout(spacing: Theme.Space.md) { metaChips }
            if !t.request.isEmpty, t.request != t.title {
                (Text("原文：").foregroundStyle(Theme.textTertiary) + Text(t.request))
                    .font(.callout).foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !t.resultSummary.isEmpty {
                (Text("结果：").foregroundStyle(Theme.textTertiary) + Text(t.resultSummary))
                    .font(.callout).foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .saCard()
    }

    @ViewBuilder private var metaChips: some View {
        let t = view.task
        let sa = appModel.superagent
        MetaChip(text: "来源 · \(t.source.label)" + (t.sourceRef.map { " · \($0)" } ?? ""))
        if !t.scope.isEmpty {
            MetaChip(text: "范围 · \(WorklistSections.projectName(t.scope))").help(t.scope)
        }
        MetaChip(text: "负责人 · \(t.owner)", strong: true)
        if let due = t.due {
            MetaChip(text: "截止 · \(DueText.long(due))")
        }
        if t.priority != .medium {
            MetaChip(text: "优先级 · \(t.priority.label)")
        }
        if editable {
            // 依赖 chip 可点 → 选前置任务（第 2 期）；没有依赖时是淡色的「依赖…」。
            MetaChip(text: WorklistText.deps(t.deps, done: { sa.task($0)?.task.status == .done }), faint: t.deps.isEmpty,
                     action: { showDeps = true })
                .help("前置任务没完成时不能交给 Agent；分配给你不限")
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

    // MARK: 阶段条

    private var workflowCard: some View {
        let t = view.task
        let name = appModel.superagent.workflows.first { $0.id == t.workflow }?.name ?? t.workflow
        return VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("工作流 · \(name)").font(Theme.Font.sectionHeader).foregroundStyle(Theme.textTertiary)
            StageBar(stages: t.stages, current: t.stageIndex)
        }
        .saCard()
    }

    // MARK: 需要你条（F-10）

    @ViewBuilder private var needBar: some View {
        if view.task.isOpen, let line = view.needLine {
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
                }
                Spacer(minLength: Theme.Space.md)
                TaskNeedActions(view: view, assign: assign)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.md)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Status.attention.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Status.attention, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("需要你：\(line.title)。\(line.body)")
        } else if view.task.isOpen, view.reviewing {
            quietBar("评审中", "TFA 正在核对交付；核对完才进待评审。")
        } else if view.task.isOpen, view.unassignedCount > 0 {
            quietBar("等你定谁来做", "\(WorklistText.ords(view.items.filter { $0.assignee == .unassigned }.map(\.ord)))还没定。") {
                Button("谁来做…", action: assign)
            }
        }
    }

    private func quietBar(_ title: String, _ body: String) -> some View {
        quietBar(title, body) { EmptyView() }
    }

    private func quietBar<Trailing: View>(_ title: String, _ body: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Theme.Space.md) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.textTertiary).frame(width: 8, height: 8).accessibilityHidden(true)
            (Text(title).fontWeight(.semibold) + Text("  " + body))
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

    private var checklistCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.md) {
                Text("工作清单").font(Theme.Font.rowTitle)
                Text("\(view.doneCount)/\(view.totalCount)").font(.callout).monospacedDigit().foregroundStyle(Theme.textTertiary)
                Spacer()
                if editable {
                    Button("谁来做…", action: assign)
                    Button { startAdding() } label: { Label("加一项", systemImage: "plus") }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.lg)
            ForEach(view.items) { item in
                Hairline()
                ItemRow(view: view, item: item, status: shownStatus(item), editable: editable,
                        toggle: { toggle(item) }, edit: { editing = item }, remove: { removing = item })
                    .padding(.horizontal, Theme.Space.xl)
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

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("活动").font(Theme.Font.rowTitle)
            if events.isEmpty {
                Text("还没有活动。").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            ForEach(events, id: \.id) { e in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                    Text(Self.time(e.at)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    Text(e.text).font(.callout).foregroundStyle(Theme.textSecondary)
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

    // MARK: 底部动作

    private var bottomActions: some View {
        HStack(spacing: Theme.Space.md) {
            if editable {
                Button("谁来做…", action: assign).buttonStyle(.borderedProminent)
                Button { startAdding() } label: { Label("加一项", systemImage: "plus") }
            }
            Spacer()
            if view.task.isOpen {
                Button("取消任务…") { confirmCancel = true }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    .help("名下正在跑的工单会被中断")
            }
        }
    }
}

// MARK: - 阶段条（F-08）

/// 每段 32pt、`Radius.md`；当前 = Charcoal 填充 + 象牙字，已过 = Cream + stone，未到 = 白底 + Linen 描边；
/// 段间 24pt 的 1px Linen 连线。不用颜色区分阶段。
struct StageBar: View {
    let stages: [WorkflowStage]
    let current: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                segment(s.name, i)
                if i < stages.count - 1 {
                    Theme.border.frame(width: 24, height: 1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("阶段：" + stages.enumerated().map { $0.offset == current ? "\($0.element.name)（当前）" : $0.element.name }.joined(separator: "，"))
    }

    private func segment(_ name: String, _ i: Int) -> some View {
        let isCurrent = i == current
        let past = i < current
        return Text(isCurrent ? "\(name) · 当前" : name)
            .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? Theme.canvas : past ? Theme.textTertiary : Theme.textPrimary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(isCurrent ? Theme.brand : past ? Theme.chrome : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay {
                if !isCurrent && !past {
                    RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1)
                }
            }
    }
}

// MARK: - 清单项行（F-09）

/// 40pt：序号 · 勾选框（你的项可点，Agent 的只读）· 文字（≤2 行）· 执行者 chip · 工单号 chip（可点跳终端）· 状态词 60pt 右对齐。
private struct ItemRow: View {
    @Environment(AppModel.self) private var appModel
    let view: TaskView
    let item: Item
    /// 乐观更新后显示的状态。
    let status: ItemStatus
    let editable: Bool
    let toggle: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        var shown = item
        shown.status = status
        let word = view.statusWord(shown)
        let mine = item.assignee == .you && editable
        return HStack(spacing: Theme.Space.md) {
            Text("\(item.ord)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                .frame(width: 18, alignment: .trailing)
            if mine {
                Button(action: toggle) { ItemCheckbox(status: status) }
                    .buttonStyle(.plain)
                    .help(status == .done ? "取消勾选" : "标为完成")
            } else {
                ItemCheckbox(status: status)
            }
            Text(item.text).font(.callout)
                .foregroundStyle(status == .done ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(2).help(item.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            AssigneeChip(assignee: item.assignee)
            if let id = item.ticketID {
                TicketChip(id: id, action: { appModel.goToTicket(id) })
            } else {
                Text("—").font(.system(size: 11)).foregroundStyle(Theme.Colors.mist).frame(width: 34)
                    .accessibilityHidden(true)
            }
            Text(word.text).font(.system(size: 12))
                .foregroundStyle(word.attention ? Theme.Status.attention : Theme.textSecondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, Theme.Space.xs)
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
