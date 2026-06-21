import SwiftUI
import TmuxKit

/// Sidebar drag payloads share one `String` channel. A TERMINAL-assign drag carries a row's
/// `groupKey` (a tmux session name / `name@host` — never contains a control char). A FOLDER-reorder
/// drag carries a control-char-sentinel'd group id, so a single `dropDestination(for: String.self)`
/// can tell the two apart with zero collision risk.
private enum SidebarDrag {
    private static let groupPrefix = "\u{1}tfa-group:"
    static func groupPayload(_ id: UUID) -> String { groupPrefix + id.uuidString }
    static func groupID(from payload: String) -> UUID? {
        guard payload.hasPrefix(groupPrefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(groupPrefix.count)))
    }
}

/// The left panel: a host switcher + action buttons up top (rebuild.md #1/#2), a filter field, and
/// the terminal list organized into collapsible groups (#6). Click to switch; right-click a row to
/// rename / move to a group / close / kill.
struct SidebarView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    @State private var filter: String = ""

    @State private var showHostSheet = false
    @State private var showServerSheet = false
    @State private var sshHost: String = ""
    @State private var sshUser: String = ""
    @State private var sshPassword: String = ""
    @State private var sshArgs: String = ""

    // Group-name alert (create or rename).
    @State private var groupAlertShown = false
    @State private var groupAlertName = ""
    @State private var groupRenameID: UUID?
    @State private var groupAssignConn: ConnectionSession?

    /// Persisted set of collapsed group ids (comma-joined uuid strings). Groups default to expanded.
    @AppStorage("collapsedGroups") private var collapsedRaw: String = ""

    /// Drag-and-drop hover targets — drive a highlight so you can SEE where a dragged terminal will
    /// land. `dropTargetGroup` = the group folder currently hovered; `ungroupedDropTargeted` = the
    /// loose (ungrouped) drop area.
    @State private var dropTargetGroup: UUID?
    @State private var ungroupedDropTargeted = false

    var body: some View {
        @Bindable var model = appModel
        VStack(spacing: 0) {
            SidebarHeader(
                onSearch: { appModel.isShowingSearch = true },
                onAddHost: { sshHost = ""; sshUser = ""; sshPassword = ""; sshArgs = ""; showHostSheet = true },
                onManageServers: { showServerSheet = true },
                onNewGroup: { startNewGroup() }
            )

            FilterField(text: $filter)

            List(selection: Binding(
                // While a tool pane (Tasks / Lab / Skills / CLAUDE.md) is showing, no terminal is on
                // screen — so don't keep a terminal row highlighted (avoids a confusing double-selection).
                // selectedConnectionID is preserved underneath, so returning to a terminal restores it.
                get: { (model.tasksSelected || model.labSelected || model.skillsSelected || model.claudeMdSelected || model.tunnelsSelected) ? nil : model.selectedConnectionID },
                set: { if let id = $0 { model.selectedConnectionID = id } }
            )) {
                // Tree: group folders (expandable) with their sessions indented underneath, then
                // loose (ungrouped) sessions at the top level. Scoped to the current host.
                ForEach(appModel.currentGroups) { group in
                    groupTree(group)
                }
                let ungrouped = filtered(appModel.visibleUngroupedTerminals)
                // The top-level (ungrouped) area also accepts drops: dropping a grouped terminal here
                // pulls it back out of its folder (#8, "drag out to ungrouped"). Wrapped in a Section
                // so the drop target spans the loose rows rather than a single row.
                Section {
                    ForEach(ungrouped) { row($0) }
                } header: {
                    if ungroupedDropTargeted {
                        Text("松手 → 移出分组")
                            .font(.caption2)
                            .foregroundStyle(Theme.brand)
                    }
                }
                .dropDestination(for: String.self) { keys, _ in
                    for key in keys {
                        if let gid = SidebarDrag.groupID(from: key) {
                            appModel.moveGroup(gid, before: nil) // folder dropped below all → move to end
                        } else if let conn = appModel.connections.first(where: { $0.groupKey == key }) {
                            appModel.removeFromGroups(conn)
                        }
                    }
                    ungroupedDropTargeted = false; dropTargetGroup = nil
                    return true
                } isTargeted: { ungroupedDropTargeted = $0 }
                if appModel.isDiscoveringSessions {
                    HStack(spacing: Theme.Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("正在发现 \(appModel.currentHost.label) 的会话…")
                            .font(Theme.Font.rowSubtitle)
                            .foregroundStyle(.secondary)
                    }
                } else if ungrouped.isEmpty && appModel.currentGroups.isEmpty {
                    Text(filter.isEmpty
                         ? "No terminals on \(appModel.currentHost.label) yet — press +"
                         : "No terminals match “\(filter)”")
                        .font(Theme.Font.rowSubtitle)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            // Bottom-left entries: Tasks + Tunnels + CLAUDE.md rules + Skills + Lab.
            ToolEntry(title: "任务", icon: "checklist", selected: appModel.tasksSelected) { appModel.openTasks() }
            ToolEntry(title: "隧道", icon: "network.badge.shield.half.filled", selected: appModel.tunnelsSelected) { appModel.openTunnels() }
            ClaudeMdEntry(selected: appModel.claudeMdSelected) { appModel.openClaudeMd() }
            SkillsEntry(selected: appModel.skillsSelected) { appModel.openSkills() }
            LabEntry(selected: appModel.labSelected) { appModel.openLab() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(groupRenameID == nil ? "New Group" : "Rename Group", isPresented: $groupAlertShown) {
            TextField("Group name", text: $groupAlertName)
            Button(groupRenameID == nil ? "Create" : "Rename") { confirmGroupAlert() }
            Button("Cancel", role: .cancel) { groupAlertShown = false }
        }
        .sheet(isPresented: $showHostSheet) {
            SSHSheet(host: $sshHost, username: $sshUser, password: $sshPassword, args: $sshArgs) {
                let extra = sshArgs.split(whereSeparator: { $0 == " " }).map(String.init).filter { !$0.isEmpty }
                appModel.addHost(host: sshHost, username: sshUser, password: sshPassword, args: extra)
                showHostSheet = false
            } onCancel: {
                showHostSheet = false
            }
        }
        .sheet(isPresented: $showServerSheet) { ServerListView() }
    }

    // MARK: - Sections

    /// A group folder in the tree: an expandable DisclosureGroup whose children are its sessions
    /// (indented). Kept visible as a drop target even when empty (unless filtering). Collapse state
    /// persists; filtering force-expands so matches are never hidden inside a folded group.
    /// A group folder rendered WITHOUT the system `DisclosureGroup`: a tappable header row with a
    /// SELF-DRAWN chevron, then (when expanded) its indented session rows. We draw our own chevron
    /// because the system DisclosureGroup triangle in a `List(.sidebar)` mixed with `Section` rendered
    /// inconsistently across macOS versions — the first group's triangle could go missing. Self-drawn
    /// is identical on every version and fully styleable. Collapse state persists; filtering
    /// force-expands so matches are never hidden inside a folded group.
    @ViewBuilder
    private func groupTree(_ group: AppModel.TerminalGroup) -> some View {
        let members = filtered(appModel.visibleTerminals(in: group))
        if filter.isEmpty || !members.isEmpty {
            groupHeaderRow(group)
                // One drop target, two payloads: a folder token → reorder before this folder; a
                // terminal's groupKey → file that terminal into this group (#8). (The folder's OWN
                // drag lives on its grip handle inside groupHeaderRow, not here.)
                .dropDestination(for: String.self) { keys, _ in
                    for key in keys {
                        if let gid = SidebarDrag.groupID(from: key) {
                            appModel.moveGroup(gid, before: group.id)
                        } else if let conn = appModel.connections.first(where: { $0.groupKey == key }) {
                            appModel.assign(conn, toGroup: group.id)
                        }
                    }
                    dropTargetGroup = nil; ungroupedDropTargeted = false
                    return true
                } isTargeted: { hovering in
                    dropTargetGroup = hovering ? group.id
                        : (dropTargetGroup == group.id ? nil : dropTargetGroup)
                }
            if groupExpanded(group.id) {
                ForEach(members) { row($0).padding(.leading, Theme.Space.lg) } // indent under the folder
                if members.isEmpty {
                    Text("Empty — right-click a terminal to add")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, Theme.Space.lg)
                }
            }
        }
    }

    /// Whether a group is expanded, backed by the persisted `collapsedRaw` set. Filtering
    /// force-expands so matches are never hidden inside a folded group.
    private func groupExpanded(_ id: UUID) -> Bool {
        if !filter.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return !collapsedRaw.split(separator: ",").contains(Substring(id.uuidString))
    }

    /// Toggle (and persist) a group's collapsed state — driven by tapping the folder header.
    private func toggleGroup(_ id: UUID) {
        var ids = Set(collapsedRaw.split(separator: ",").map(String.init))
        if ids.contains(id.uuidString) { ids.remove(id.uuidString) } else { ids.insert(id.uuidString) }
        collapsedRaw = ids.sorted().joined(separator: ",")
    }

    // MARK: - Rows / headers

    @ViewBuilder
    private func row(_ conn: ConnectionSession) -> some View {
        TerminalRow(conn: conn, isSelected: conn.id == appModel.selectedConnectionID)
            .tag(conn.id)
            // Drag a row onto a group folder to file it there (#8). We carry the stable String
            // groupKey (Transferable) rather than the id so the drop side can re-resolve the session.
            .draggable(conn.groupKey)
            .contextMenu { SessionMenuItems(conn: conn) }
    }

    /// A tappable folder header with a self-drawn chevron (rotates 90° on expand). Tapping anywhere on
    /// the row toggles collapse — no reliance on the system DisclosureGroup triangle (see groupTree).
    private func groupHeaderRow(_ group: AppModel.TerminalGroup) -> some View {
        let expanded = groupExpanded(group.id)
        // NOT a Button: a Button's tap recognizer competes with `.draggable` (added in groupTree), making
        // the folder hard to pick up. A plain tappable row lets tap and drag coexist cleanly — quick
        // click toggles, press-and-move reorders. `.isButton` keeps the VoiceOver semantics.
        return HStack(spacing: Theme.Space.xs) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            sectionHeaderLabel(group.name, icon: "folder.fill",
                               count: appModel.visibleTerminals(in: group).count)
            // Dedicated drag handle: the ONLY draggable bit, so the tap-to-toggle area never fights the
            // drag recognizer (that conflict is why dragging the whole header didn't start a drag).
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, Theme.Space.xs)
                .contentShape(Rectangle())
                .draggable(SidebarDrag.groupPayload(group.id)) {
                    Label(group.name, systemImage: "folder.fill")
                        .padding(Theme.Space.sm)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
                .help("拖动重新排序分组")
                .accessibilityHidden(true) // reorder is exposed via the row's accessibilityActions
        }
        .padding(.vertical, 2)
        .background(
            // Highlight the folder while a terminal is dragged over it (#8 drop feedback).
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(dropTargetGroup == group.id ? Theme.brand.opacity(0.18) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { toggleGroup(group.id) }
        .help("点击折叠/展开 · 拖右侧手柄重新排序")
        .animation(.easeInOut(duration: 0.15), value: expanded)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(group.name) group, \(expanded ? "expanded" : "collapsed")")
        .accessibilityHint(expanded ? "Collapse group" : "Expand group")
        .accessibilityAction { toggleGroup(group.id) } // VoiceOver activate → toggle
        // Keyboard / VoiceOver alternative to drag-reorder.
        .accessibilityAction(named: "上移分组") { moveGroupBy(group.id, -1) }
        .accessibilityAction(named: "下移分组") { moveGroupBy(group.id, 1) }
        .contextMenu {
            let ids = appModel.currentGroups.map(\.id)
            let i = ids.firstIndex(of: group.id)
            Button("上移分组") { moveGroupBy(group.id, -1) }.disabled(i == nil || i == 0)
            Button("下移分组") { moveGroupBy(group.id, 1) }.disabled(i == nil || i == ids.count - 1)
            Divider()
            Button("Rename Group…") { startRenameGroup(group) }
            Button("Delete Group", role: .destructive) { appModel.deleteGroup(group.id) }
        }
    }

    /// Nudge a folder one slot up (`delta -1`) or down (`+1`) among the current host's folders.
    private func moveGroupBy(_ id: UUID, _ delta: Int) {
        let ids = appModel.currentGroups.map(\.id)
        guard let i = ids.firstIndex(of: id) else { return }
        let j = i + delta
        guard j >= 0, j <= ids.count else { return }
        if delta < 0 {
            appModel.moveGroup(id, before: ids[max(0, j)])      // before the previous folder
        } else {
            // down: insert before the folder AFTER the next one (or end if next is last)
            let beforeID = j + 1 < ids.count ? ids[j + 1] : nil
            appModel.moveGroup(id, before: beforeID)
        }
    }

    /// Shared prominent section header: a brand-tinted icon, a LARGE full-strength title (so a group
    /// reads as a header, not a dimmer sub-item), and a count pill. Used by groups and "Default".
    private func sectionHeaderLabel(_ name: String, icon: String, count: Int) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(Theme.brand)
            Text(name)
                .font(Theme.Font.groupHeader)
                .foregroundStyle(.primary)
                .textCase(nil)        // don't let the sidebar uppercase/dim the title
                .lineLimit(1)
            Spacer(minLength: Theme.Space.xs)
            if count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, Theme.Space.xxs)
    }

    // MARK: - Helpers

    private func filtered(_ list: [ConnectionSession]) -> [ConnectionSession] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { ($0.title + " " + $0.subtitle).lowercased().contains(q) }
    }

    private func startNewGroup(assigning conn: ConnectionSession? = nil) {
        groupRenameID = nil; groupAssignConn = conn; groupAlertName = ""; groupAlertShown = true
    }
    private func startRenameGroup(_ g: AppModel.TerminalGroup) {
        groupRenameID = g.id; groupAssignConn = nil; groupAlertName = g.name; groupAlertShown = true
    }
    private func confirmGroupAlert() {
        if let id = groupRenameID {
            appModel.renameGroup(id, to: groupAlertName)
        } else {
            appModel.newGroup(name: groupAlertName)
            if let conn = groupAssignConn, let g = appModel.groups.last {
                appModel.assign(conn, toGroup: g.id)
            }
        }
        groupAlertShown = false
    }
}

/// Top of the left panel: a host switcher (Local / ssh hosts / Add Host…) plus the primary actions,
/// so the functions live on the LEFT and the title stays on the right (rebuild.md #1/#2).
private struct SidebarHeader: View {
    @Environment(AppModel.self) private var appModel
    let onSearch: () -> Void
    let onAddHost: () -> Void
    let onManageServers: () -> Void
    let onNewGroup: () -> Void

    private var hasServers: Bool {
        appModel.knownHosts.contains { if case .ssh = $0 { return true }; return false }
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Menu {
                ForEach(Array(appModel.knownHosts.enumerated()), id: \.offset) { _, host in
                    Button {
                        appModel.selectHost(host)
                    } label: {
                        if appModel.currentHost == host {
                            Label(host.label, systemImage: "checkmark")
                        } else {
                            Label(host.label, systemImage: host.icon)
                        }
                    }
                }
                Divider()
                Button { onAddHost() } label: { Label("Add Host…", systemImage: "plus") }
                if hasServers {
                    Button { onManageServers() } label: { Label("Manage Servers…", systemImage: "server.rack") }
                }
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: appModel.currentHost.icon).font(.caption)
                    Text(appModel.currentHost.label).font(Theme.Font.rowTitle).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch host for new terminals")

            Spacer(minLength: Theme.Space.xs)

            // Click = new terminal (⌘T). Click-and-hold = pick a start folder (local).
            Menu {
                Button { appModel.newTerminal() } label: { Label("新建终端", systemImage: "plus") }
                Button { appModel.newTerminalPickingFolder() } label: { Label("选择文件夹新建…", systemImage: "folder.badge.plus") }
            } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
            } primaryAction: {
                appModel.newTerminal()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New terminal on \(appModel.currentHost.label) (⌘T) · 长按可选起始文件夹")
            HeaderButton(system: "magnifyingglass", help: "Search across all panes (⌘F)", action: onSearch)
            HeaderButton(system: "folder.badge.plus", help: "New group", action: onNewGroup)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.md)
        .padding(.bottom, Theme.Space.xs)
    }
}

private struct HeaderButton: View {
    let system: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Bottom-of-sidebar entry into the global CLAUDE.md rules editor.
private struct ClaudeMdEntry: View {
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "text.book.closed")
                    .foregroundStyle(selected ? Theme.brand : Color.secondary)
                Text("CLAUDE.md").font(Theme.Font.rowTitle)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.brand.opacity(0.12) : Color.clear)
        .overlay(alignment: .top) { Divider() }
        .accessibilityLabel("CLAUDE.md 规则")
    }
}

/// Generic bottom-of-sidebar tool entry (used by the Tasks board).
private struct ToolEntry: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: icon)
                    .foregroundStyle(selected ? Theme.brand : Color.secondary)
                Text(title).font(Theme.Font.rowTitle)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.brand.opacity(0.12) : Color.clear)
        .overlay(alignment: .top) { Divider() }
        .accessibilityLabel(title)
    }
}

/// Bottom-of-sidebar entry into the Skills manager. Selected → the detail area shows Skills.
private struct SkillsEntry: View {
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(selected ? Theme.brand : Color.secondary)
                Text("Skills").font(Theme.Font.rowTitle)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.brand.opacity(0.12) : Color.clear)
        .overlay(alignment: .top) { Divider() }
        .accessibilityLabel("Skills 管理")
    }
}

/// Bottom-of-sidebar entry into the Lab (experiments). Selected → the detail area shows the Lab.
private struct LabEntry: View {
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "flask")
                    .foregroundStyle(selected ? Theme.brand : Color.secondary)
                Text("实验室").font(Theme.Font.rowTitle)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.brand.opacity(0.12) : Color.clear)
        .overlay(alignment: .top) { Divider() }
        .accessibilityLabel("实验室")
    }
}

/// A native-feeling search field that live-filters the terminal list.
private struct FilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            // A filter-semantics glyph (not a magnifier) so it reads as "narrow this list", visually
            // distinct from the header's magnifyingglass which triggers full-text search across panes.
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .medium))
            TextField("Filter terminals", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Font.rowSubtitle)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)
        .accessibilityLabel("Filter terminals")
    }
}

private struct TerminalRow: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conn: ConnectionSession
    let isSelected: Bool

    /// "Working" = producing output right now (shared logic on AppModel — fuses the live tmux
    /// `window_activity` poll with the attached controller's streaming phase).
    private var working: Bool { appModel.isWorking(conn) }
    /// The latest output line for a working local session — "what it's doing right now".
    private var liveLine: String? { conn.host == nil ? appModel.activity.line(conn.groupKey) : nil }

    /// An agent in the background is waiting for you (bell / OSC notification). Top-priority cue.
    private var attention: Bool { conn.needsAttention && !isSelected }
    private static let amber = Color(red: 0.95, green: 0.62, blue: 0.16)

    var body: some View {
        let status = TerminalStatus.of(conn)
        let showDot = conn.hasUnseenOutput && !isSelected
        HStack(spacing: Theme.Space.md) {
            // Reserve a thin left "rail" on every row (clear when idle) so an accent appears without
            // shifting the layout: amber = needs you, brand = actively working.
            Capsule().fill(attention ? Self.amber : (working ? Theme.brand : Color.clear))
                .frame(width: 2.5)
                .frame(maxHeight: .infinity)

            Image(systemName: "terminal.fill")
                .foregroundStyle(attention ? Self.amber : (working || status == .connected ? Theme.brand : Color.secondary))
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(conn.title)
                    .font(Theme.Font.rowTitle)
                    .lineLimit(1)
                subtitle(status)
            }
            Spacer(minLength: Theme.Space.xs)
            if attention {
                // Highest priority: an amber bell = this terminal explicitly wants you.
                AttentionBell(animated: !reduceMotion, tint: Self.amber)
            } else if working {
                // Lively "equalizer" bars = this terminal is actively producing output.
                EqualizerBars(animated: !reduceMotion)
            } else {
                // Idle: a checkmark flash when a burst just finished, else the unseen-output dot.
                OutputActivityIndicator(phase: conn.outputPhase, showUnseen: showDot)
            }
            // Only surface a status glyph when it needs attention — a healthy connected row stays
            // quiet (its brand-tinted icon is signal enough), keeping a long list calm.
            if status != .connected {
                StatusIndicator(status: status)
            }
        }
        .padding(.vertical, Theme.Space.xxs)
        .background(rowTint, in: RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.15), value: showDot)
        .animation(.easeInOut(duration: 0.28), value: working)
        .animation(.easeInOut(duration: 0.2), value: attention)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(status, showDot: showDot))
    }

    private var rowTint: Color {
        if attention { return Self.amber.opacity(0.12) }
        if working && !isSelected { return Theme.brand.opacity(0.06) }
        return .clear
    }

    /// Subtitle: attention message (the agent's ping) > live output line while working > running
    /// command > dormant hint.
    @ViewBuilder private func subtitle(_ status: TerminalStatus) -> some View {
        if attention, let msg = conn.attentionMessage, !msg.isEmpty {
            Text(msg)
                .font(.system(size: 11))
                .foregroundStyle(Self.amber)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if attention {
            Text("等待你的操作")
                .font(Theme.Font.rowSubtitle)
                .foregroundStyle(Self.amber)
                .lineLimit(1)
        } else if working, let line = liveLine, !line.isEmpty {
            Text(line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.brand.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        } else if status == .dormant {
            Text("未连接 · 点击打开")
                .font(Theme.Font.rowSubtitle)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if let folder = folderLabel {
            // Idle connected: just show WHERE this terminal is — the working directory, home as ~.
            Text(folder)
                .font(Theme.Font.rowSubtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// The terminal's current working directory with home abbreviated to `~` (nil until known).
    private var folderLabel: String? {
        guard let p = conn.currentPath else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p == home ? "~" : p.replacingOccurrences(of: home, with: "~")
    }

    private func accessibilityText(_ status: TerminalStatus, showDot: Bool) -> String {
        var parts = [conn.title, working ? "活动中" : status.label]
        if let folder = folderLabel { parts.append("目录 \(folder)") }
        if showDot { parts.append("new output") }
        return parts.joined(separator: ", ")
    }
}

/// A static amber bell — a terminal is explicitly waiting for you. The amber tint + bell glyph are
/// signal enough; an endless wobble loop (one per waiting terminal) was needless continuous motion.
private struct AttentionBell: View {
    let animated: Bool // kept for call-site compatibility; the bell no longer animates
    let tint: Color

    var body: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: 12))
            .foregroundStyle(tint)
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}

/// Three little bars that bounce while a terminal is actively producing output — an "equalizer"
/// activity effect. Honors Reduce Motion (static bars). Pure visual, no layout impact.
private struct EqualizerBars: View {
    let animated: Bool
    @State private var up = false

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(Theme.brand).frame(width: 2.5, height: height(i))
            }
        }
        .frame(width: 12, height: 12, alignment: .center)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) { up = true }
        }
        .accessibilityHidden(true)
    }

    /// Each bar swings between two heights; staggering the pairs makes them bounce out of phase.
    private func height(_ i: Int) -> CGFloat {
        guard animated else { return [8, 8, 8][i] }
        let low: [CGFloat] = [4, 10, 6]
        let high: [CGFloat] = [10, 5, 11]
        return up ? high[i] : low[i]
    }
}

/// Sidebar output-activity effect: a brand dot that PULSES while output streams, a green checkmark
/// FLASH when a burst finishes, otherwise the static unseen-output dot (or nothing).
private struct OutputActivityIndicator: View {
    let phase: ConnectionSession.OutputPhase
    let showUnseen: Bool

    var body: some View {
        Group {
            switch phase {
            case .streaming:
                // Static brand dot — no perpetual pulse loop. (Working terminals show the equalizer
                // upstream; this path is the quieter fallback.)
                Circle()
                    .fill(Theme.brand)
                    .frame(width: 7, height: 7)
            case .justFinished:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Status.connected)
                    .transition(.scale.combined(with: .opacity))
            case .idle:
                if showUnseen {
                    Circle()
                        .fill(Theme.brand)
                        .frame(width: 7, height: 7)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phase)
        .accessibilityHidden(true)
    }
}

/// Manage saved ssh servers: open one (switch to it) or delete it (drops it from the menu + its
/// Keychain password). Live terminals are not closed by deleting a server.
struct ServerListView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private var servers: [AppModel.HostTarget] {
        appModel.knownHosts.filter { if case .ssh = $0 { return true }; return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("Servers").font(.headline)
            if servers.isEmpty {
                Text("No saved servers. Use “Add Host…” to add one.")
                    .font(Theme.Font.emptyBody)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(servers, id: \.self) { host in
                        HStack(spacing: Theme.Space.md) {
                            Image(systemName: "network").foregroundStyle(Theme.brand)
                            Text(host.label).lineLimit(1)
                            if appModel.currentHost == host {
                                Text("current").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Theme.Space.sm)
                            Button("Open") { appModel.selectHost(host); dismiss() }
                                .buttonStyle(.borderless)
                            Button(role: .destructive) { appModel.forgetHost(host) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Forget this server (also removes its saved password)")
                        }
                        .padding(.vertical, Theme.Space.xxs)
                    }
                }
                .frame(height: 220)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 400)
    }
}

/// Editor for a session's per-session environment variables (tmux `set-environment`). A key/value
/// list with add/remove. Saving applies them live (new windows pick them up immediately; existing
/// shells keep their old environment until reopened/respawned).
struct EnvironmentSheet: View {
    let initial: [String: String]
    let sessionName: String
    let onSave: ([String: String]) -> Void
    let onSaveAndRestart: ([String: String]) -> Void
    let onCancel: () -> Void

    private struct EnvRow: Identifiable { let id = UUID(); var key: String; var value: String }
    @State private var rows: [EnvRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("环境变量 · \(sessionName)").font(.headline)
            Text("保存后对该会话**新开的窗口 / 重启的 shell**生效；已经在跑的 shell 不变。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: Theme.Space.sm) {
                    ForEach($rows) { $row in
                        HStack(spacing: Theme.Space.sm) {
                            TextField("KEY", text: $row.key)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                                .autocorrectionDisabled()
                            Text("=").foregroundStyle(.secondary)
                            TextField("value", text: $row.value)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            Button { rows.removeAll { $0.id == row.id } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("删除变量")
                        }
                    }
                    if rows.isEmpty {
                        Text("暂无变量").font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.vertical, Theme.Space.xs)
            }
            .frame(height: 200)

            Button { rows.append(EnvRow(key: "", value: "")) } label: {
                Label("添加变量", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                Button("保存并重启 shell") { onSaveAndRestart(collected()) }
                    .help("重启该会话的 shell 让变量立即生效（会结束当前 shell 正在跑的东西）")
                Button("保存") { onSave(collected()) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 480)
        .onAppear {
            rows = initial.sorted { $0.key < $1.key }.map { EnvRow(key: $0.key, value: $0.value) }
        }
    }

    /// Collapse the rows into a dict, dropping blank keys; later rows win on duplicate keys.
    private func collected() -> [String: String] {
        var out: [String: String] = [:]
        for r in rows {
            let k = r.key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = r.value }
        }
        return out
    }
}

/// Sheet for adding an ssh host: host + username + password (auto-supplied at the ssh prompt) +
/// optional extra ssh args. Password is optional — leave it blank to type it in the login terminal.
struct SSHSheet: View {
    @Binding var host: String
    @Binding var username: String
    @Binding var password: String
    @Binding var args: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("Add SSH Host").font(.headline)
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                TextField("Host (host or ssh alias)", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onSubmit)
                TextField("Username (optional)", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onSubmit)
                SecureField("Password (optional — else typed in the terminal)", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onSubmit)
                TextField("Extra ssh args (optional, space-separated)", text: $args)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(width: 360)
            Text("Connects over ssh, then launches tmux. Password is saved securely to your macOS Keychain so this server doesn't re-prompt — remove it any time via Manage Servers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 360, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Connect", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.xl + Theme.Space.xs)
    }
}
