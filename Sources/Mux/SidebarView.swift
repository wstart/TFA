import SwiftUI
import TmuxKit

/// The left panel: a host switcher + action buttons up top (rebuild.md #1/#2), a filter field, and
/// the terminal list organized into collapsible groups (#6). Click to switch; right-click a row to
/// rename / move to a group / close / kill.
struct SidebarView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    @State private var filter: String = ""
    @State private var renameTarget: ConnectionSession?
    @State private var renameText: String = ""
    @State private var killTarget: ConnectionSession?
    @State private var restartTarget: ConnectionSession?
    @State private var envTarget: ConnectionSession?
    @State private var pasteResultConn: ConnectionSession?
    @State private var pasteResultCount = 0

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
                get: { model.selectedConnectionID },
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
                        if let conn = appModel.connections.first(where: { $0.groupKey == key }) {
                            appModel.removeFromGroups(conn)
                        }
                    }
                    ungroupedDropTargeted = false
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

            // Bottom-left entries: CLAUDE.md rules + Skills + Lab.
            ClaudeMdEntry(selected: appModel.claudeMdSelected) { appModel.openClaudeMd() }
            SkillsEntry(selected: appModel.skillsSelected) { appModel.openSkills() }
            LabEntry(selected: appModel.labSelected) { appModel.openLab() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Rename Terminal", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let conn = renameTarget { appModel.renameTerminal(conn, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Kill Session?", isPresented: Binding(
            get: { killTarget != nil },
            set: { if !$0 { killTarget = nil } })
        ) {
            Button("Kill Session", role: .destructive) {
                if let conn = killTarget { appModel.closeTerminal(conn) }
                killTarget = nil
            }
            Button("Cancel", role: .cancel) { killTarget = nil }
        } message: {
            Text("This permanently ends the tmux session and it will not resume on next launch.")
        }
        .alert("重启 session?", isPresented: Binding(
            get: { restartTarget != nil },
            set: { if !$0 { restartTarget = nil } })
        ) {
            Button("重启", role: .destructive) {
                if let conn = restartTarget { appModel.restartSession(conn) }
                restartTarget = nil
            }
            Button("取消", role: .cancel) { restartTarget = nil }
        } message: {
            Text("重启该会话的 shell 以重新加载环境变量。会话本身保留，但当前窗格里正在运行的程序会被中断。")
        }
        .alert(pasteResultCount > 0 ? "已粘贴环境变量" : "没有可粘贴的内容", isPresented: Binding(
            get: { pasteResultConn != nil },
            set: { if !$0 { pasteResultConn = nil } })
        ) {
            if pasteResultCount > 0 {
                Button("重启 session 生效") {
                    if let conn = pasteResultConn { appModel.restartSession(conn) }
                    pasteResultConn = nil
                }
                Button("稍后", role: .cancel) { pasteResultConn = nil }
            } else {
                Button("好", role: .cancel) { pasteResultConn = nil }
            }
        } message: {
            if pasteResultCount > 0 {
                Text("已合并 \(pasteResultCount) 个环境变量到「\(pasteResultConn?.title ?? "")」。新窗口或重启 session 后生效。")
            } else {
                Text("剪贴板里没有可识别的 KEY=VALUE 环境变量。先在另一个会话「拷贝环境变量」，或复制 .env 格式的文本。")
            }
        }
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
        .sheet(item: $envTarget) { conn in
            EnvironmentSheet(initial: appModel.environment(for: conn), sessionName: conn.title) { env in
                appModel.setEnvironment(env, for: conn)
                envTarget = nil
            } onSaveAndRestart: { env in
                appModel.setEnvironment(env, for: conn)
                conn.restartShell()   // respawn the shell so the current pane gets the new env now
                envTarget = nil
            } onCancel: { envTarget = nil }
        }
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
                // Drop a terminal onto the folder header to file it into this group (#8).
                .dropDestination(for: String.self) { keys, _ in
                    for key in keys {
                        if let conn = appModel.connections.first(where: { $0.groupKey == key }) {
                            appModel.assign(conn, toGroup: group.id)
                        }
                    }
                    dropTargetGroup = nil
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
            .contextMenu { rowMenu(conn) }
    }

    /// A tappable folder header with a self-drawn chevron (rotates 90° on expand). Tapping anywhere on
    /// the row toggles collapse — no reliance on the system DisclosureGroup triangle (see groupTree).
    private func groupHeaderRow(_ group: AppModel.TerminalGroup) -> some View {
        let expanded = groupExpanded(group.id)
        return Button {
            toggleGroup(group.id)
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                sectionHeaderLabel(group.name, icon: "folder.fill",
                                   count: appModel.visibleTerminals(in: group).count)
            }
            .padding(.vertical, 2)
            .background(
                // Highlight the folder while a terminal is dragged over it (#8 drop feedback).
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(dropTargetGroup == group.id ? Theme.brand.opacity(0.18) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: expanded)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name) group, \(expanded ? "expanded" : "collapsed")")
        .accessibilityHint(expanded ? "Collapse group" : "Expand group")
        .contextMenu {
            Button("Rename Group…") { startRenameGroup(group) }
            Button("Delete Group", role: .destructive) { appModel.deleteGroup(group.id) }
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

    @ViewBuilder
    private func rowMenu(_ conn: ConnectionSession) -> some View {
        Button("Rename…") {
            renameTarget = conn
            renameText = conn.title
        }
        Menu("Move to Group") {
            ForEach(appModel.currentGroups) { g in
                Button {
                    appModel.assign(conn, toGroup: g.id)
                } label: {
                    if appModel.group(for: conn)?.id == g.id {
                        Label(g.name, systemImage: "checkmark")
                    } else {
                        Text(g.name)
                    }
                }
            }
            if !appModel.currentGroups.isEmpty { Divider() }
            Button("New Group…") { startNewGroup(assigning: conn) }
            if appModel.group(for: conn) != nil {
                Divider()
                Button("Remove from Group") { appModel.removeFromGroups(conn) }
            }
        }
        Button("环境变量…") { envTarget = conn }
        Button("拷贝环境变量") { appModel.copyEnvironment(conn) }
        Button("粘贴环境变量") {
            pasteResultCount = appModel.pasteEnvironment(into: conn)
            pasteResultConn = conn
        }
        Button("文件管理器…") {
            if let p = conn.currentPath { openWindow(value: URL(fileURLWithPath: p)) }
        }
        .disabled(conn.host != nil || conn.currentPath == nil)
        .help(conn.host != nil ? "暂不支持远程会话" : "")
        Button("重启 session（重载环境变量）") { restartTarget = conn }
        Button("克隆 session") { appModel.cloneTerminal(conn) }
        Divider()
        // Non-destructive: detach (session survives, resumes next launch).
        Button("Close") { appModel.detachTerminal(conn) }
        // Destructive: confirm, then kill-session.
        Button("Kill Session…", role: .destructive) { killTarget = conn }
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

    /// "Working" = producing output right now. For local sessions this fuses the live tmux poll
    /// (`window_activity`, which catches activity even on sessions this app hasn't attached) with the
    /// attached controller's streaming phase. Remote sessions fall back to the streaming phase only.
    private var working: Bool {
        if conn.host == nil { return appModel.activity.isWorking(name: conn.groupKey) || conn.outputPhase == .streaming }
        return conn.outputPhase == .streaming
    }
    /// The latest output line for a working local session — "what it's doing right now".
    private var liveLine: String? { conn.host == nil ? appModel.activity.line(conn.groupKey) : nil }

    var body: some View {
        let status = TerminalStatus.of(conn)
        let showDot = conn.hasUnseenOutput && !isSelected
        HStack(spacing: Theme.Space.md) {
            // Reserve a thin left "rail" on every row (clear when idle) so the brand accent on a
            // working row appears without shifting the layout.
            Capsule().fill(working ? Theme.brand : Color.clear)
                .frame(width: 2.5)
                .frame(maxHeight: .infinity)

            Image(systemName: "terminal.fill")
                .foregroundStyle(working || status == .connected ? Theme.brand : Color.secondary)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(conn.title)
                    .font(Theme.Font.rowTitle)
                    .lineLimit(1)
                subtitle(status)
            }
            Spacer(minLength: Theme.Space.xs)
            if working {
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
        .background(working && !isSelected ? Theme.brand.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.15), value: showDot)
        .animation(.easeInOut(duration: 0.28), value: working)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(status, showDot: showDot))
    }

    /// Subtitle: while working, show the live latest output line (mono, brand-tinted) — otherwise the
    /// running command, or the dormant hint.
    @ViewBuilder private func subtitle(_ status: TerminalStatus) -> some View {
        if working, let line = liveLine, !line.isEmpty {
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
        } else if !conn.subtitle.isEmpty {
            Text(conn.subtitle)
                .font(Theme.Font.rowSubtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func accessibilityText(_ status: TerminalStatus, showDot: Bool) -> String {
        var parts = [conn.title, working ? "活动中" : status.label]
        if !conn.subtitle.isEmpty { parts.append("running \(conn.subtitle)") }
        if showDot { parts.append("new output") }
        return parts.joined(separator: ", ")
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
    @State private var pulse = false

    var body: some View {
        Group {
            switch phase {
            case .streaming:
                Circle()
                    .fill(Theme.brand)
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulse ? 1.0 : 0.55)
                    .opacity(pulse ? 1 : 0.4)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
                    .onDisappear { pulse = false }
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
