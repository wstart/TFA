import SwiftUI

private let amber = Theme.Status.attention

/// Kanban task board. Group by STATUS (todo/doing/done/blocked) or by the assigned terminal AGENT.
/// Cards drag between lanes (status mode → change status; agent mode → reassign), have hover quick-
/// actions, show live agent activity, and a "待接管" amber state when the assigned terminal needs you.
/// Backed by the shared SQLite board (~/.tfa/board.db) so agents (via the tfa-task CLI / skill) can
/// also create/claim/update tasks.
struct TaskBoardView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing: BoardTask?
    @State private var dispatchTarget: (taskID: UUID, agentID: String)?
    @State private var dropTarget: String?
    @State private var composingLane: String?
    @State private var draft = ""
    @State private var groupBy: GroupMode = .status
    @FocusState private var draftFocused: Bool

    private var store: TaskBoardStore { appModel.taskBoard }
    enum GroupMode: String, CaseIterable, Identifiable { case status = "按状态", agent = "按终端"; var id: String { rawValue } }

    /// One column on the board (a status or an agent).
    private struct Lane: Identifiable {
        let id: String
        let title: String
        let accent: Color
        let tasks: [BoardTask]
        let onDrop: (UUID) -> Void
        let onAdd: (String) -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                let ls = lanes()
                // Lanes STRETCH to fill the width when few; once they'd get narrower than a comfortable
                // width (e.g. many agent lanes), each takes that width and the row scrolls horizontally.
                let avail = max(0, geo.size.width - Theme.Space.lg * 2)
                let fit = ls.isEmpty ? avail : (avail - Theme.Space.md * CGFloat(ls.count - 1)) / CGFloat(ls.count)
                let laneW = max(220, fit)
                ScrollView(.horizontal, showsIndicators: laneW > fit) {
                    HStack(alignment: .top, spacing: Theme.Space.md) {
                        ForEach(ls) { laneView($0, width: laneW) }
                    }
                    .padding(Theme.Space.lg)
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        // Only poll the board DB (1.2s) while the board is actually on screen.
        .onAppear { store.watchFast = true; store.tickIfChanged() } // instant freshness on open
        .onDisappear { store.watchFast = false } // heartbeat keeps a slow watch (attention relies on it)
        .sheet(item: $editing) { task in
            TaskEditor(taskID: task.id, agents: store.board.agents,
                       onDispatch: { tid, a in editing = nil; dispatchTarget = (tid, a) },
                       onClose: { editing = nil })
        }
        .alert("派发任务到终端？", isPresented: Binding(get: { dispatchTarget != nil }, set: { if !$0 { dispatchTarget = nil } })) {
            Button("派发") { if let d = dispatchTarget { appModel.dispatchTask(d.taskID, to: d.agentID) }; dispatchTarget = nil }
            Button("取消", role: .cancel) { dispatchTarget = nil }
        } message: {
            if let d = dispatchTarget {
                Text("将向「\(store.agent(d.agentID)?.name ?? d.agentID)」的终端发送指令；若它正忙会排队，空闲后自动派发。任务：「\(store.task(d.taskID)?.title ?? "")」。")
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.md) {
            Picker("", selection: $groupBy) { ForEach(GroupMode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).fixedSize()
            Spacer()
        }
        .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
    }

    // MARK: lanes

    private func lanes() -> [Lane] {
        switch groupBy {
        case .status:
            return TaskStatus.allCases.map { s in
                Lane(id: "s:\(s.rawValue)", title: s.label, accent: accent(s), tasks: store.tasks(in: s),
                     onDrop: { id in animated { store.move(id, to: s) } },
                     onAdd: { title in store.addTask(title: title); if s != .todo, let id = newestID() { store.move(id, to: s) } })
            }
        case .agent:
            let tasks = store.board.tasks
            // One lane per agent that has tasks, ordered by name; plus an Unassigned lane.
            let usedAgentIDs = Set(tasks.compactMap(\.assignee))
            var lanes = store.board.agents.filter { usedAgentIDs.contains($0.id) }
                .sorted { $0.name < $1.name }
                .map { a in
                    Lane(id: "a:\(a.id)", title: a.name, accent: Theme.brand,
                         tasks: tasks.filter { $0.assignee == a.id }.sorted(by: Self.byStatusThenOrder),
                         onDrop: { id in animated { store.setAssignee(id, to: a.id) } },
                         onAdd: { title in store.addTask(title: title); if let id = newestID() { store.setAssignee(id, to: a.id) } })
                }
            // Assignees whose agent row is GONE (closed terminal / legacy ext:) still get a lane —
            // otherwise their tasks fall into no lane at all and silently vanish from this view.
            let knownIDs = Set(store.board.agents.map(\.id))
            for id in usedAgentIDs.subtracting(knownIDs).sorted() {
                lanes.append(Lane(id: "a:\(id)", title: appModel.assigneeLabel(id), accent: .secondary,
                                  tasks: tasks.filter { $0.assignee == id }.sorted(by: Self.byStatusThenOrder),
                                  onDrop: { tid in animated { store.setAssignee(tid, to: id) } },
                                  onAdd: { title in store.addTask(title: title); if let nid = newestID() { store.setAssignee(nid, to: id) } }))
            }
            lanes.append(Lane(id: "a:none", title: "未指派", accent: .secondary,
                              tasks: tasks.filter { $0.assignee == nil }.sorted(by: Self.byStatusThenOrder),
                              onDrop: { id in animated { store.setAssignee(id, to: nil) } },
                              onAdd: { title in store.addTask(title: title) }))
            return lanes
        }
    }

    private static func byStatusThenOrder(_ a: BoardTask, _ b: BoardTask) -> Bool {
        func rank(_ s: TaskStatus) -> Int { [.blocked, .doing, .todo, .done].firstIndex(of: s) ?? 9 }
        return rank(a.status) != rank(b.status) ? rank(a.status) < rank(b.status) : a.order < b.order
    }
    private func newestID() -> UUID? { store.board.tasks.max(by: { $0.createdAt < $1.createdAt })?.id }
    private func animated(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) { change() }
    }

    // MARK: a lane

    private func laneView(_ lane: Lane, width: CGFloat) -> some View {
        let targeted = dropTarget == lane.id
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.xs) {
                Circle().fill(lane.accent).frame(width: 8, height: 8)
                Text(lane.title).font(Theme.Font.headerTitle).lineLimit(1)
                Text("\(lane.tasks.count)").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.surface2, in: Capsule())
                Spacer()
            }
            ScrollView {
                VStack(spacing: Theme.Space.sm) {
                    ForEach(lane.tasks) { task in
                        TaskCard(task: task, appModel: appModel, reduceMotion: reduceMotion, showStatus: groupBy == .agent,
                                 onOpen: { editing = task },
                                 onMove: { to in animated { store.move(task.id, to: to) } },
                                 onDispatch: { a in dispatchTarget = (task.id, a) })
                            .transition(.scale(scale: 0.94).combined(with: .opacity))
                            .draggable(task.id.uuidString) { TaskCard.preview(task) }
                    }
                    inlineAdd(lane)
                }
                .padding(2)
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: lane.tasks)
            }
        }
        .padding(Theme.Space.sm)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(targeted ? lane.accent.opacity(0.07) : Theme.surface2)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(targeted ? lane.accent : .clear, lineWidth: 1.5))
        )
        .scaleEffect(targeted ? 1.012 : 1)
        .animation(.easeOut(duration: 0.18), value: targeted)
        .dropDestination(for: String.self) { ids, _ in
            for s in ids { if let id = UUID(uuidString: s) { lane.onDrop(id) } }
            dropTarget = nil
            return true
        } isTargeted: { hovering in
            withAnimation(.easeOut(duration: 0.15)) { dropTarget = hovering ? lane.id : (dropTarget == lane.id ? nil : dropTarget) }
        }
    }

    @ViewBuilder private func inlineAdd(_ lane: Lane) -> some View {
        if composingLane == lane.id {
            TextField("任务标题…", text: $draft)
                .textFieldStyle(.roundedBorder).font(.callout)
                .focused($draftFocused)
                .onSubmit {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { lane.onAdd(t) }
                    draft = "" // keep composing for rapid entry
                }
                .onExitCommand { composingLane = nil; draft = "" }
                .onAppear { draftFocused = true }
        } else {
            Button { draft = ""; composingLane = lane.id; draftFocused = true } label: {
                Label("加任务", systemImage: "plus").font(.caption).frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xs)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(Theme.surface2))
        }
    }

    private func accent(_ s: TaskStatus) -> Color {
        switch s {
        case .todo: return Theme.Status.neutral
        case .doing: return Theme.Status.active
        case .done: return Theme.Status.positive
        case .blocked: return Theme.Status.error
        }
    }
}

// MARK: - Card

private struct TaskCard: View {
    let task: BoardTask
    let appModel: AppModel
    let reduceMotion: Bool
    var showStatus: Bool = false
    let onOpen: () -> Void
    let onMove: (TaskStatus) -> Void
    let onDispatch: (String) -> Void

    @State private var hovering = false

    private var blocked: Bool { task.status == .blocked }
    private var assignedConn: ConnectionSession? {
        // Resolve via the agents table, falling back to the id itself ("tfa:<stableID>") — the
        // table is rebuilt from live terminals, so a stale row must not hide a live terminal.
        let s = appModel.taskBoard.agent(task.assignee)?.session
            ?? task.assignee.flatMap { $0.hasPrefix("tfa:") ? String($0.dropFirst(4)) : nil }
        guard let s else { return nil }
        return appModel.connections.first { $0.stableID == s }
    }
    private var working: Bool { assignedConn.map { appModel.isWorking($0) } ?? false }
    /// Needs a human: the agent asked a question, or its terminal pinged for attention (bell / OSC).
    private var needsTakeover: Bool {
        !blocked && (task.comments.last?.kind == "question" || (assignedConn?.needsAttention == true && !working))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .top, spacing: 4) {
                Text(task.title).font(Theme.Font.rowTitle).foregroundStyle(.primary).lineLimit(2)
                Spacer(minLength: 0)
                if blocked { badge("受阻", "exclamationmark.octagon.fill", Theme.Status.error) }
                else if needsTakeover { badge("待接管", "hand.raised.fill", amber) }
            }
            if showStatus { statusChip }
            if !task.body.isEmpty {
                Text(task.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let agent = appModel.taskBoard.agent(task.assignee) {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill").font(.system(size: 8))
                    Text(agent.name).font(.caption2).lineLimit(1)
                    if working { workingTag }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            } else if let a = task.assignee {
                // The assignee's agent row is gone (terminal closed, or a legacy ext: registration)
                // — keep showing WHO it was assigned to instead of dropping the line.
                HStack(spacing: 4) {
                    Image(systemName: "person.fill.questionmark").font(.system(size: 8))
                    Text(appModel.assigneeLabel(a)).font(.caption2).lineLimit(1)
                    if working { workingTag }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
            if let last = task.comments.last { latestRecord(last) }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(cardFill))
        .overlay(alignment: .leading) { accentBar }
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor, lineWidth: 1))
        .overlay(alignment: .topTrailing) { quickActions }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { inside in withAnimation(.easeInOut(duration: 0.12)) { hovering = inside } }
        .onTapGesture { onOpen() }
    }

    private var statusChip: some View {
        Text(task.status.label).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(statusTint.opacity(0.15), in: Capsule()).foregroundStyle(statusTint)
    }
    private var statusTint: Color {
        switch task.status {
        case .todo: return Theme.Status.neutral
        case .doing: return Theme.Status.active
        case .done: return Theme.Status.positive
        case .blocked: return Theme.Status.error
        }
    }

    // Static "运行中" — the brand-colored waveform reads as active without a per-0.6s blink that
    // forced every working card to re-render its body on a timer.
    private var workingTag: some View {
        Label("运行中", systemImage: "waveform").foregroundStyle(Theme.brand).font(.caption2)
    }

    private func latestRecord(_ c: TaskComment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: c.symbol).font(.system(size: 8)).foregroundStyle(recordTint(c.kind))
            Text(c.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            let steps = task.comments.filter { $0.kind == "step" }.count
            if steps > 0 { Text("\(steps)步").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.surface2.opacity(0.4)))
    }

    @ViewBuilder private var quickActions: some View {
        if hovering {
            HStack(spacing: 2) {
                iconButton("square.and.pencil", "打开") { onOpen() }
                if let next = nextStatus(task.status) { iconButton("arrow.right", "移到\(next.label)") { onMove(next) } }
                if task.status != .done { iconButton("checkmark", "标记完成") { onMove(.done) } }
                if let a = task.assignee { iconButton("paperplane.fill", "派发到终端") { onDispatch(a) } }
                if let conn = assignedConn { iconButton("terminal", "前往终端") { appModel.goToTerminal(conn.id) } }
            }
            .padding(3).background(.ultraThinMaterial, in: Capsule()).padding(4)
            .transition(.opacity)
        }
    }
    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 10, weight: .medium)).frame(width: 18, height: 18) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(help)
    }
    private func badge(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2).background(tint.opacity(0.15), in: Capsule())
    }

    private var cardFill: Color {
        if blocked { return Theme.Status.error.opacity(0.06) }
        if needsTakeover { return amber.opacity(0.10) }
        return Theme.surface
    }
    private var borderColor: Color {
        if blocked { return Theme.Status.error.opacity(0.35) }
        if needsTakeover { return amber.opacity(0.4) }
        return Theme.border
    }
    @ViewBuilder private var accentBar: some View {
        let c: Color? = blocked ? Theme.Status.error : (needsTakeover ? amber : (working ? Theme.brand : nil))
        if let c { RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 3).padding(.vertical, 4) }
    }
    private func recordTint(_ kind: String) -> Color {
        switch kind {
        case "step": return Theme.brand
        case "blocked": return Theme.Status.error
        case "question": return amber
        default: return .secondary
        }
    }
    private func nextStatus(_ s: TaskStatus) -> TaskStatus? {
        switch s {
        case .todo: return .doing
        case .doing: return .done
        case .done: return nil
        case .blocked: return .doing
        }
    }

    static func preview(_ task: BoardTask) -> some View {
        Text(task.title).font(Theme.Font.rowTitle).lineLimit(1)
            .padding(Theme.Space.sm).frame(width: 220, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.brand, lineWidth: 1.5))
    }
}

// MARK: - Editor sheet (live execution log)

/// Reads the task LIVE from the store by id, so the agent's reported steps appear in real time while
/// it's open. Title/body edit locally and save on demand. Status/assignee write through immediately.
/// A reply is pushed into the assigned terminal (via AppModel.pushReply) so the agent actually sees it.
private struct TaskEditor: View {
    @Environment(AppModel.self) private var appModel
    let taskID: UUID
    let agents: [BoardAgent]
    let onDispatch: (UUID, String) -> Void
    let onClose: () -> Void

    @State private var title = ""
    @State private var bodyText = ""
    @State private var reply = ""
    @State private var seeded = false
    @FocusState private var replyFocused: Bool

    private var store: TaskBoardStore { appModel.taskBoard }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let t = store.task(taskID) {
                TextField("标题", text: $title).textFieldStyle(.roundedBorder).font(.title3.weight(.semibold))
                TextEditor(text: $bodyText)
                    .font(.body).frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.surface2))
                HStack {
                    Picker("状态", selection: Binding(get: { t.status }, set: { store.move(taskID, to: $0) })) {
                        ForEach(TaskStatus.allCases) { Text($0.label).tag($0) }
                    }.fixedSize()
                    Picker("指派给", selection: Binding(get: { t.assignee ?? "" }, set: { store.setAssignee(taskID, to: $0.isEmpty ? nil : $0) })) {
                        Text("未指派").tag("")
                        // A dangling assignee (closed terminal / legacy ext: agent) gets its own
                        // entry so the picker still SHOWS who the task is assigned to — without
                        // this the selection silently renders empty.
                        if let a = t.assignee, !a.isEmpty, !agents.contains(where: { $0.id == a }) {
                            Text(appModel.assigneeLabel(a)).tag(a)
                        }
                        ForEach(agents.sorted { agentLabel($0) < agentLabel($1) }) { Text(agentLabel($0)).tag($0.id) }
                    }
                    Spacer()
                }
                executionLog(t)
                replyBar(t)
                Divider()
                footer(t)
            } else {
                Text("任务已删除").foregroundStyle(.secondary)
                HStack { Spacer(); Button("关闭") { onClose() } }
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 520)
        .onAppear { if !seeded, let t = store.task(taskID) { title = t.title; bodyText = t.body; seeded = true } }
    }

    @ViewBuilder private func executionLog(_ t: BoardTask) -> some View {
        Divider()
        HStack {
            Text("执行记录").font(.subheadline.weight(.semibold))
            Spacer()
            if !t.comments.isEmpty { Text("\(t.comments.count) 条 · 最新在上").font(.caption).foregroundStyle(.tertiary) }
        }
        if t.comments.isEmpty {
            Text("还没有记录。派发后 agent 会用 tfa-task step 边做边回报。").font(.callout).foregroundStyle(.tertiary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(t.comments.reversed()) { c in
                        HStack(alignment: .top, spacing: Theme.Space.sm) {
                            Image(systemName: c.symbol).font(.system(size: 13)).foregroundStyle(tint(c.kind)).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.text).font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                Text("\(c.by) · \(Self.timeAgo(c.at))").font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6).padding(.horizontal, Theme.Space.sm)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface2.opacity(0.25)))
                    }
                }.padding(.vertical, 2)
            }
            .frame(maxHeight: 240)
        }
    }

    private func replyBar(_ t: BoardTask) -> some View {
        HStack(spacing: Theme.Space.sm) {
            TextField("回复 / 补充信息（会推送到终端）…", text: $reply).textFieldStyle(.roundedBorder).focused($replyFocused).onSubmit(send)
            Button("发送", action: send)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
            if t.status == .blocked {
                Button("解除受阻") { store.move(taskID, to: .doing) }.buttonStyle(.borderedProminent).tint(Theme.brand)
            }
        }
    }
    private func send() {
        let r = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return }
        appModel.pushReply(taskID, text: r)   // record on board AND push into the assigned terminal
        reply = ""
        replyFocused = true
    }

    @ViewBuilder private func footer(_ t: BoardTask) -> some View {
        HStack {
            Button("删除", role: .destructive) { store.delete(taskID); onClose() }
            Spacer()
            if let conn = assignedConn(t) {
                Button("前往终端") { saveTitleBody(); onClose(); appModel.goToTerminal(conn.id) }
            }
            if let a = t.assignee {
                Button("派发到终端") { saveTitleBody(); onDispatch(taskID, a) }.buttonStyle(.borderedProminent)
            }
            Button("完成") { saveTitleBody(); onClose() }.keyboardShortcut(.defaultAction)
        }
    }
    /// The live connection behind this task's assigned agent, if it's a TFA-managed terminal.
    /// Falls back to parsing the "tfa:<stableID>" id so a stale agents table can't hide it.
    private func assignedConn(_ t: BoardTask) -> ConnectionSession? {
        let s = store.agent(t.assignee)?.session
            ?? t.assignee.flatMap { $0.hasPrefix("tfa:") ? String($0.dropFirst(4)) : nil }
        guard let s else { return nil }
        return appModel.connections.first { $0.stableID == s }
    }
    private func saveTitleBody() {
        let t0 = store.task(taskID)
        if t0?.title != title || t0?.body != bodyText { store.updateTitleBody(taskID, title: title, body: bodyText) }
    }
    private func agentLabel(_ a: BoardAgent) -> String {
        guard let s = a.session, let conn = appModel.connections.first(where: { $0.stableID == s }),
              let g = appModel.group(for: conn)?.name else { return a.name }
        return "[\(g)] \(a.name)"
    }
    private func tint(_ kind: String) -> Color {
        switch kind {
        case "step": return Theme.brand
        case "blocked": return Theme.Status.error
        case "question": return amber
        default: return .secondary
        }
    }
    private static func timeAgo(_ at: Double) -> String {
        let s = max(0, Int(Date().timeIntervalSince1970 - at))
        if s < 60 { return "\(s)秒前" }
        if s < 3600 { return "\(s/60)分前" }
        if s < 86400 { return "\(s/3600)小时前" }
        return "\(s/86400)天前"
    }
}
