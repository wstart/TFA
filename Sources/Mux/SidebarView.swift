import SwiftUI
import SuperagentCore
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

/// The left panel: one header row (host · project scope + filter field, 待处理, 「+」), and
/// the terminal list organized into collapsible groups (#6). Click to switch; right-click a row to
/// rename / move to a group / close / kill.
struct SidebarView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    @State private var filter: String = ""

    @State private var showHostSheet = false
    @State private var showServerSheet = false
    @State private var showProjects = false
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

    /// Top tab: live terminals vs ended (crashed / lost) records, plus the bulk-remove confirmation.
    @State private var showEnded = false
    @State private var confirmRemoveAllEnded = false
    /// Collapse state of the built-in「未分组」folder that holds ungrouped terminals.
    @AppStorage("defaultGroupCollapsed") private var defaultCollapsed = false
    /// The folder header under the pointer — its drag grip shows only then.
    @State private var hoveredGroup: UUID?

    /// A tool pane is showing: the List has no selection then, so the current terminal's row shows
    /// its own leading bar instead.
    private var toolPaneOpen: Bool {
        appModel.axisSelected || appModel.labSelected || appModel.skillsSelected
            || appModel.claudeMdSelected || appModel.tunnelsSelected || appModel.groupNoteSelected
            || appModel.superagentSelected || appModel.worklistSelected
    }

    var body: some View {
        @Bindable var model = appModel
        VStack(spacing: 0) {
            SidebarHeader(
                filter: $filter,
                onAddHost: { sshHost = ""; sshUser = ""; sshPassword = ""; sshArgs = ""; showHostSheet = true },
                onManageServers: { showServerSheet = true },
                onManageProjects: { showProjects = true },
                onNewGroup: { startNewGroup() }
            )
            let endedCount = appModel.visibleConnections.filter(\.isEnded).count
            if endedCount > 0 {
                SegmentedBar(selection: $showEnded, options: [
                    (false, "在线 \(appModel.visibleConnections.count - endedCount)"),
                    (true, "已断开 \(endedCount)"),
                ])
                .padding(.horizontal, Theme.Space.md)
                .padding(.bottom, Theme.Space.sm)
            }

            List(selection: Binding(
                // While a tool pane (Tasks / Lab / Skills / CLAUDE.md) is showing, no terminal is on
                // screen — so don't keep a terminal row highlighted (avoids a confusing double-selection).
                // selectedConnectionID is preserved underneath, so returning to a terminal restores it.
                get: { toolPaneOpen ? nil : model.selectedConnectionID },
                set: {
                    guard let id = $0 else { return }
                    if id == appModel.routerConnection?.id {
                        model.openRouter() // 主管终端若已退回 shell，点它时顺手按当前配置拉起 Agent
                    } else {
                        model.activateTerminal(id)
                    }
                }
            )) {
                // 已断开 tab: bulk actions first, where they're seen before scrolling the records.
                if showEnded && endedCount > 0 {
                    EndedActionsRow(count: endedCount,
                                    onRestoreAll: { appModel.restoreAllEnded() },
                                    onRemoveAll: { confirmRemoveAllEnded = true })
                }
                // 「我的清单」is the first screen: pinned above 主管 (注意事项 F-01). It stays while a project is
                // selected (the list filters by project itself); the terminal filter text hides it like 主管.
                if !showEnded && filter.isEmpty {
                    WorklistRow()
                }
                // The「主管」(router) row is pinned above everything (including while a project is selected):
                // `projectScoped` excludes the router from terminal lists so it only appears here.
                if !showEnded && filter.isEmpty {
                    routerRow
                }
                // Ungrouped terminals live in a built-in「未分组」folder pinned above the group folders
                // (not a real group: no note, no reorder, not deletable). Scoped to the current host.
                let ungrouped = filtered(showEnded ? appModel.visibleEndedUngroupedTerminals
                                                   : appModel.visibleUngroupedTerminals)
                // The folder also accepts drops: dropping a grouped terminal here pulls it back out of
                // its folder (#8, "drag out to ungrouped"); dropping a folder here moves it to the
                // front. Wrapped in a Section so the drop target spans the whole folder.
                Section {
                    if !ungrouped.isEmpty {
                        let hasGroups = !appModel.currentGroups.isEmpty
                        if hasGroups {
                            defaultHeaderRow(count: ungrouped.count)
                        }
                        if !hasGroups || !defaultCollapsed || !filter.trimmingCharacters(in: .whitespaces).isEmpty {
                            ForEach(ungrouped) { row($0) }
                        }
                    }
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
                            appModel.moveGroup(gid, before: appModel.currentGroups.first?.id) // → first folder
                        } else if let conn = appModel.connections.first(where: { $0.groupKey == key }) {
                            appModel.removeFromGroups(conn)
                        }
                    }
                    ungroupedDropTargeted = false; dropTargetGroup = nil
                    return true
                } isTargeted: { ungroupedDropTargeted = $0 }
                ForEach(appModel.currentGroups) { group in
                    groupTree(group)
                }
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

            // Bottom tool dock (DESIGN.md v2): Tasks + Tunnels + CLAUDE.md + Skills + Lab as an
            // equal-width icon+label row.
            ToolDock()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chrome)
        // Keep the selected row on screen: selecting (or ⌘-navigating to) an ended record shows the
        // 已断开 tab; restoring it, or the last record going away, brings back 在线.
        .onChange(of: appModel.selectedConnection?.isEnded) { _, ended in
            if let ended { showEnded = ended }
        }
        .onChange(of: appModel.visibleConnections.contains(where: \.isEnded)) { _, any in
            if !any { showEnded = false }
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
        .sheet(isPresented: $showProjects) { WorkspaceManager().environment(appModel) }
        .alert("移除全部已断开的终端?", isPresented: $confirmRemoveAllEnded) {
            Button("全部移除", role: .destructive) { appModel.removeAllEnded() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("从侧栏和恢复记录中删除，之后无法再恢复。不影响磁盘上的文件夹和文件。")
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
        let members = tabMembers(group)
        // The 已断开 tab lists only folders that hold ended records; 在线 keeps empty folders as drop targets.
        if (filter.isEmpty && WorkspaceStore.shared.selected == nil && !showEnded) || !members.isEmpty {
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
            if groupExpanded(group.id) && !members.isEmpty {
                ForEach(members) { row($0) }
                if members.isEmpty {
                    Text("暂无终端 · 右键终端可加入分组")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, Theme.Space.lg)
                }
            }
        }
    }

    /// A group's members on the current tab (live or ended), after the filter text.
    private func tabMembers(_ group: AppModel.TerminalGroup) -> [ConnectionSession] {
        filtered(appModel.visibleTerminals(in: group).filter { $0.isEnded == showEnded })
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

    /// The pinned「主管」row: the router terminal when it runs (selectable like any terminal), else a
    /// one-tap 启动. Its signal column carries the count of tickets that need you.
    @ViewBuilder
    private var routerRow: some View {
        if let conn = appModel.routerConnection {
            RouterRow(conn: conn, isSelected: conn.id == appModel.selectedConnectionID, toolPaneOpen: toolPaneOpen)
                .tag(conn.id)
                .contextMenu {
                    Button("重启主管") { appModel.restartRouter() }
                    Button("打开主管面板") { appModel.openSuperagent() }
                    Divider()
                    SessionMenuItems(conn: conn)
                }
        } else {
            RouterRow(conn: nil, isSelected: false, toolPaneOpen: toolPaneOpen)
                .contentShape(Rectangle())
                .onTapGesture { appModel.openRouter() }
                .contextMenu { Button("打开主管面板") { appModel.openSuperagent() } }
        }
    }

    @ViewBuilder
    private func row(_ conn: ConnectionSession) -> some View {
        TerminalRow(conn: conn, isSelected: conn.id == appModel.selectedConnectionID,
                    toolPaneOpen: toolPaneOpen)
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
        let count = appModel.visibleTerminals(in: group).filter { $0.isEnded == showEnded }.count
        let hovered = hoveredGroup == group.id
        return HStack(spacing: Theme.Space.md) {
            // Chevron = fold/unfold, as wide as a row's kind badge so the name lines up with titles.
            chevron(expanded)
                .contentShape(Rectangle())
                .onTapGesture { toggleGroup(group.id) }
            // Name = open this group's Markdown note in the detail area.
            sectionHeaderLabel(group.name)
                .contentShape(Rectangle())
                .onTapGesture { appModel.openGroupNote(group) }
            // The count and the drag grip share the rows' signal column; hovering swaps them. The grip
            // is the ONLY draggable bit, so tap-to-toggle never fights the drag recognizer.
            ZStack(alignment: .trailing) {
                countLabel(count).opacity(hovered ? 0 : 1)
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .opacity(hovered ? 1 : 0)
                    .contentShape(Rectangle())
                    .draggable(SidebarDrag.groupPayload(group.id)) {
                        Label(group.name, systemImage: "folder.fill")
                            .padding(Theme.Space.sm)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                    .help("拖动重新排序分组")
            }
            .frame(width: 14, alignment: .trailing)
                .accessibilityHidden(true) // reorder is exposed via the row's accessibilityActions
        }
        .padding(.top, isFirstSection(group.id) ? 0 : Theme.Space.lg)
        .onHover { hoveredGroup = $0 ? group.id : (hoveredGroup == group.id ? nil : hoveredGroup) }
        .background(
            // Highlight the folder while a terminal is dragged over it (#8 drop feedback).
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(dropTargetGroup == group.id ? Theme.brand.opacity(0.18) : .clear)
        )
        .contentShape(Rectangle())
        .help("点名字看分组说明 · 点箭头折叠/展开 · 拖右侧手柄重新排序")
        .animation(.easeInOut(duration: 0.15), value: expanded)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(group.name) group, \(expanded ? "expanded" : "collapsed")")
        .accessibilityHint(expanded ? "Collapse group" : "Expand group")
        .accessibilityAction { toggleGroup(group.id) } // VoiceOver activate → toggle
        .accessibilityAction(named: "查看分组说明") { appModel.openGroupNote(group) }
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

    /// Header of the built-in「未分组」folder: same chevron + label as a group folder, tap anywhere
    /// to fold. No note / drag handle — it isn't a real group.
    private func defaultHeaderRow(count: Int) -> some View {
        let expanded = !defaultCollapsed || !filter.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: Theme.Space.md) {
            chevron(expanded)
            sectionHeaderLabel("未分组")
            countLabel(count).frame(width: 14, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { defaultCollapsed.toggle() }
        .help("未分组的终端 · 点击折叠/展开")
        .animation(.easeInOut(duration: 0.15), value: expanded)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("未分组, \(expanded ? "expanded" : "collapsed")")
        .accessibilityAction { defaultCollapsed.toggle() }
    }

    /// Shared folder header label: a small, tracked, muted caps title (so the terminal names stay the
    /// loudest text in the list) and a plain count. Used by groups and「未分组」.
    private func sectionHeaderLabel(_ name: String) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.xs)
        }
    }

    @ViewBuilder private func countLabel(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.Colors.pewter)
        }
    }

    /// Fold chevron, as wide as a row's kind badge (22pt) so folder names align with row titles.
    private func chevron(_ expanded: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Theme.textTertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: 22, height: 14)
    }

    /// The first folder header in the list sits flush with the top; later ones get breathing room.
    private func isFirstSection(_ groupID: UUID) -> Bool {
        let ungrouped = filtered(showEnded ? appModel.visibleEndedUngroupedTerminals : appModel.visibleUngroupedTerminals)
        return ungrouped.isEmpty && appModel.currentGroups.first?.id == groupID
    }

    // MARK: - Helpers

    private func filtered(_ list: [ConnectionSession]) -> [ConnectionSession] {
        let router = appModel.routerConnection?.id
        let list = list.filter { WorkspaceStore.shared.includes($0) && $0.id != router }
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

/// Top of the left panel: clean scope selector on the left, contextual attention pill + search toggle +
/// primary「+」menu on the right; filter text field expands smoothly on demand underneath.
private struct SidebarHeader: View {
    @Environment(AppModel.self) private var appModel
    @Binding var filter: String
    let onAddHost: () -> Void
    let onManageServers: () -> Void
    let onManageProjects: () -> Void
    let onNewGroup: () -> Void

    @State private var scopeHovered = false
    @State private var showFilter = false

    private var hasServers: Bool {
        appModel.knownHosts.contains { if case .ssh = $0 { return true }; return false }
    }

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                scopeMenu

                Spacer(minLength: Theme.Space.xs)

                AttentionButton()

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showFilter.toggle()
                        if !showFilter { filter = "" }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(showFilter || !filter.isEmpty ? Theme.textPrimary : Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(
                            showFilter || !filter.isEmpty ? Theme.surface : Color.clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        )
                        .overlay {
                            if showFilter || !filter.isEmpty {
                                RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.border, lineWidth: 1)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
                .buttonStyle(.plain)
                .help(showFilter ? "收起筛选" : "筛选终端")
                .accessibilityLabel("筛选终端")

                Menu {
                    Button { appModel.newTerminal() } label: { Label("启动终端", systemImage: "terminal") }
                    Button { appModel.newTerminal(launch: .antigravity) } label: { Label("启动 Antigravity (agy)", systemImage: "sparkles") }
                        .disabled(appModel.currentHost != .local)
                    Button { appModel.newTerminal(launch: .axisClaude) } label: { Label("启动 axis-claude", systemImage: "cpu") }
                        .disabled(appModel.currentHost != .local)
                    Divider()
                    Button { onNewGroup() } label: { Label("新建分组…", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.onBrand)
                        .frame(width: 28, height: 28)
                        .background(Theme.brand, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("新建终端 (⌘T) · 新建分组")
                .accessibilityLabel("新建终端或分组")
            }

            if showFilter || !filter.isEmpty {
                FilterField(text: $filter, onCancel: {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        filter = ""
                        showFilter = false
                    }
                })
                .frame(height: 28)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.border, lineWidth: 1))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)
    }

    private var scopeMenu: some View {
        @Bindable var store = WorkspaceStore.shared
        return Menu {
            Section("主机") {
                ForEach(Array(appModel.knownHosts.enumerated()), id: \.offset) { _, host in
                    Button {
                        appModel.selectHost(host)
                    } label: {
                        Label(hostName(host), systemImage: appModel.currentHost == host ? "checkmark" : host.icon)
                    }
                }
                Button { onAddHost() } label: { Label("添加远程主机…", systemImage: "plus") }
                if hasServers {
                    Button { onManageServers() } label: { Label("管理服务器…", systemImage: "server.rack") }
                }
            }
            Section("项目") {
                Picker("项目", selection: $store.selectedID) {
                    Text("全部项目").tag(nil as UUID?)
                    ForEach(store.projects) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Button { onManageProjects() } label: { Label("管理项目…", systemImage: "folder.badge.gearshape") }
            }
        } label: {
            let host = hostName(appModel.currentHost)
            let project = store.selected?.name
            ViewThatFits(in: .horizontal) {
                scopeLabel(host, detail: project)
                scopeLabel(project ?? host)
                scopeLabel(project ?? host, truncates: true)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.Space.sm)
            .frame(height: 28)
            .background(scopeHovered ? Theme.surface : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay {
                if scopeHovered || store.selected != nil {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.border, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { scopeHovered = $0 }
        .help(store.selected.map { "\(hostName(appModel.currentHost)) · \($0.name) — 切换主机与项目" } ?? "切换主机与项目")
    }

    /// One wording of the scope label: host glyph with a status dot, then (if any) the title, an
    /// optional muted detail and the menu chevron. Whole words unless `truncates`, which may cut the
    /// title down to about two characters.
    private func scopeLabel(_ title: String?, detail: String? = nil, truncates: Bool = false) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: appModel.currentHost.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(hostDot)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Theme.surface, lineWidth: 1.5))
                        .offset(x: 3, y: 2)
                }
                .padding(.trailing, Theme.Space.xxs) // room for the dot before the name
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: !truncates, vertical: false)
                    .frame(idealWidth: truncates ? 28 : nil, alignment: .leading)
                if let detail {
                    Text("· \(detail)")
                        .font(Theme.Font.rowSubtitle)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func hostName(_ host: AppModel.HostTarget) -> String {
        if case .local = host { return "本机" }
        return host.label
    }

    /// The scope's host status dot — sage for the always-available local host, neutral for a remote
    /// host (its live state is shown per-terminal in the list).
    private var hostDot: Color {
        if case .local = appModel.currentHost { return Theme.Status.positive }
        return Theme.Status.neutral
    }
}

/// Streamlined sidebar footer: removes the cramped 6-cell 10pt grid and duplicate「主管」entry.
/// Exposes 3 clear items (Skills, 指令, 工具 menu) + a Settings gear button.
private struct ToolDock: View {
    @Environment(AppModel.self) private var appModel

    private var moreToolSelected: Bool {
        appModel.tunnelsSelected || appModel.axisSelected || appModel.labSelected
    }

    private var moreToolTitle: String {
        if appModel.tunnelsSelected { return "隧道" }
        if appModel.axisSelected { return "模型" }
        if appModel.labSelected { return "监控" }
        return "工具"
    }

    private var anyTunnelRunning: Bool {
        appModel.tunnelRunner.states.values.contains { $0 == .running }
            || appModel.cloudflaredRunner.states.values.contains {
                if case .running = $0 { return true }
                return false
            }
    }

    var body: some View {
        let settingsBadge = appModel.superagent.needsYouOutsideTasks.count
        HStack(spacing: Theme.Space.xs) {
            dockButton(title: "Skills", icon: "wand.and.stars", selected: appModel.skillsSelected) {
                appModel.openSkills()
            }
            dockButton(title: "指令", icon: "doc.text", selected: appModel.claudeMdSelected) {
                appModel.openClaudeMd()
            }
            Menu {
                Button { appModel.openTunnels() } label: {
                    Label("隧道与端口转发", systemImage: appModel.tunnelsSelected ? "checkmark" : "network.badge.shield.half.filled")
                }
                Button { appModel.openAxis() } label: {
                    Label("本地模型 (axis-model)", systemImage: appModel.axisSelected ? "checkmark" : "cpu")
                }
                Button { appModel.openLab() } label: {
                    Label("系统与用量监控", systemImage: appModel.labSelected ? "checkmark" : "waveform.path.ecg")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11, weight: .medium))
                    Text(moreToolTitle)
                        .font(.system(size: 11, weight: moreToolSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if anyTunnelRunning && !moreToolSelected {
                        Circle().fill(Theme.Status.positive).frame(width: 5, height: 5)
                    }
                }
                .foregroundStyle(moreToolSelected ? Theme.onBrand : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(moreToolSelected ? Theme.brand : Color.clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("更多工具：隧道、本地模型、系统监控")

            Button {
                appModel.openWorklistSettings(.router)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(appModel.superagentToolSelected ? Theme.onBrand : Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(appModel.superagentToolSelected ? Theme.brand : Color.clear,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(alignment: .topTrailing) {
                        if settingsBadge > 0 {
                            Circle().fill(Theme.Status.attention).frame(width: 6, height: 6)
                                .offset(x: -3, y: 3)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            .buttonStyle(.plain)
            .help("编排与全局设置")
            .accessibilityLabel("编排与全局设置")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func dockButton(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Theme.onBrand : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(selected ? Theme.brand : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A full-width two-way switch in the system segmented look.
private struct SegmentedBar<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Theme.textPrimary : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Theme.surface)
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.border, lineWidth: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The 已断开 tab's bulk actions: restore every record (the common case after a tmux server loss)
/// as the primary action, and a quiet remove-all.
private struct EndedActionsRow: View {
    let count: Int
    let onRestoreAll: () -> Void
    let onRemoveAll: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Button(action: onRestoreAll) {
                Label("全部恢复 \(count)", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("在原文件夹重建这些会话；仍在运行的会话直接重新连接")
            Spacer(minLength: Theme.Space.xs)
            Button("全部移除…", role: .destructive, action: onRemoveAll)
                .buttonStyle(.plain)
                .font(Theme.Font.rowSubtitle)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, Theme.Space.xs)
    }
}

/// The filter half of the header's scope field: live-filters the terminal list (distinct from ⌘F,
/// which searches the text inside every pane). The surrounding field draws the surface and border.
private struct FilterField: View {
    @Binding var text: String
    var onCancel: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField("筛选终端…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onExitCommand { onCancel?() }
            Button {
                if let onCancel { onCancel() } else { text = "" }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Clear filter")
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onAppear { focused = true }
        .onTapGesture { focused = true }
        .accessibilityLabel("Filter terminals")
    }
}

private struct TerminalRow: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `.increased` while the system draws the (accent-filled) selection behind this row — anything
    /// drawn in charcoal would vanish into it, so those glyphs switch to light.
    @Environment(\.backgroundProminence) private var prominence
    let conn: ConnectionSession
    let isSelected: Bool
    let toolPaneOpen: Bool

    /// "Working" = producing output right now (shared logic on AppModel — fuses the live tmux
    /// `window_activity` poll with the attached controller's streaming phase).
    private var working: Bool { appModel.isWorking(conn) }
    /// The latest output line for a working local session — "what it's doing right now".
    private var liveLine: String? { conn.host == nil ? appModel.activity.line(conn.groupKey) : nil }

    /// The ticket this terminal executes (nil for ordinary terminals).
    private var ticket: TicketView? { appModel.ticket(for: conn) }

    /// An agent in the background is waiting for you (bell / OSC notification), or this terminal's
    /// ticket needs you (review / answer / blocked …). Top-priority cue.
    private var attention: Bool { (conn.needsAttention || ticket?.stage.needsPerson != nil) && !isSelected }
    private static let amber = Theme.Status.attention

    var body: some View {
        let status = TerminalStatus.of(conn)
        let showDot = conn.hasUnseenOutput && !isSelected
        let prominent = prominence == .increased
        let ink = prominent ? Color.white : Theme.brand
        HStack(spacing: Theme.Space.md) {
            // ONE primary signal per row (dsh discipline): the icon tint + the single right-side
            // glyph carry the state; no left rail, no colored subtitles duplicating them.
            KindBadge(kind: TerminalKind.of(conn), dimmed: status == .ended || status == .dormant, prominent: prominent)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(conn.title)
                    .font(Theme.Font.rowTitle)
                    .foregroundStyle(status == .ended ? .secondary : .primary)
                    .lineLimit(1)
                subtitle(status)
            }
            Spacer(minLength: Theme.Space.xs)
            // ONE signal column (14pt, shared with the folder counts), in priority order.
            ZStack {
                if attention {
                    // Highest priority: an amber bell = this terminal explicitly wants you.
                    AttentionBell(animated: !reduceMotion, tint: Self.amber)
                } else if status != .connected {
                    // Only surface a connection glyph when it needs attention — a healthy row stays quiet.
                    StatusIndicator(status: status)
                } else if working {
                    // Lively "equalizer" bars = this terminal is actively producing output.
                    EqualizerBars(animated: !reduceMotion, tint: ink)
                } else {
                    // Idle: a checkmark flash when a burst just finished, else the unseen-output dot.
                    OutputActivityIndicator(phase: conn.outputPhase, showUnseen: showDot, tint: ink)
                }
            }
            .frame(width: 14)
        }
        .padding(.vertical, Theme.Space.xxs)
        // The amber "needs you" wash spans the same rounded area as the system selection highlight.
        .background {
            if attention {
                RoundedRectangle(cornerRadius: 6).fill(Self.amber.opacity(0.10))
                    .padding(.horizontal, -6).padding(.vertical, -3)
            }
        }
        // While a tool pane is open the List shows no selection — the current terminal keeps a bar.
        .overlay(alignment: .leading) {
            if isSelected && toolPaneOpen {
                Capsule().fill(Theme.brand).frame(width: 3, height: 16).offset(x: -11)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showDot)
        .animation(.easeInOut(duration: 0.28), value: working)
        .animation(.easeInOut(duration: 0.2), value: attention)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(status, showDot: showDot))
    }

    /// Subtitle: attention message (the agent's ping) > live output line while working > running
    /// command > dormant hint.
    @ViewBuilder private func subtitle(_ status: TerminalStatus) -> some View {
        if let t = ticket, t.stage.needsPerson != nil || !(working && liveLine?.isEmpty == false) {
            // A ticket terminal says where its ticket stands; the live line still wins while it works.
            HStack(spacing: 0) {
                Text("#\(t.id) ").foregroundStyle(.tertiary)
                Text(t.stage.label).foregroundStyle(t.stage.needsPerson != nil ? t.stage.tint : .secondary)
                if t.stage.needsPerson == nil, !t.ticket.ack.isEmpty {
                    Text(" · \(t.ticket.ack)").foregroundStyle(.tertiary)
                }
            }
            .font(Theme.Font.rowSubtitle)
            .lineLimit(1)
            .truncationMode(.tail)
        } else if attention, let msg = conn.attentionMessage, !msg.isEmpty {
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
            // Content changes, color stays quiet — the icon/equalizer already say "working".
            Text(line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if status == .ended {
            // Ended record: say so, and WHERE it lived — the folder is how you recognise it.
            HStack(spacing: 0) {
                Text("已断开 · ").fixedSize()
                Text(folderLabel ?? "可恢复").truncationMode(.head)
            }
            .font(Theme.Font.rowSubtitle)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        } else if status == .dormant {
            Text("未连接 · 点击打开")
                .font(Theme.Font.rowSubtitle)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if let folder = folderLabel {
            // Idle connected: just show WHERE this terminal is — the working directory, home as ~.
            // Head truncation keeps the folder's own name (the end of the path) visible.
            Text(folder)
                .font(Theme.Font.rowSubtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    /// The terminal's current working directory with home abbreviated to `~` (nil until known).
    private var fullFolder: String? {
        guard let p = conn.currentPath else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p == home ? "~" : p.replacingOccurrences(of: home, with: "~")
    }

    /// The folder as a row shows it: deep paths keep only their last two parts (`…/proj/sub`) —
    /// the part that identifies it; the full path is in the tooltip and VoiceOver.
    private var folderLabel: String? {
        guard let full = fullFolder else { return nil }
        let parts = full.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count > 3 ? "…/" + parts.suffix(2).joined(separator: "/") : full
    }

    private func accessibilityText(_ status: TerminalStatus, showDot: Bool) -> String {
        var parts = [conn.title, working ? "活动中" : status.label]
        if let folder = fullFolder { parts.append("目录 \(folder)") }
        if showDot { parts.append("new output") }
        return parts.joined(separator: ", ")
    }
}

/// The pinned「主管」row: a charcoal badge (the router is an agent), the title, and one line saying
/// where the tickets stand; the signal column shows how many need you.
private struct RouterRow: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conn: ConnectionSession?
    let isSelected: Bool
    let toolPaneOpen: Bool

    var body: some View {
        let sa = appModel.superagent
        let needs = sa.needsYouOutsideTasks.count
        let prominent = prominence == .increased
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Theme.onBrand)
                .frame(width: 22, height: 22)
                .background(prominent ? Color.white.opacity(0.22) : Theme.brand, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("主管").font(Theme.Font.rowTitle).foregroundStyle(prominent ? Color.white : Theme.textPrimary).lineLimit(1)
                Group {
                    if needs > 0 {
                        Text("\(needs) 个工单需要你").foregroundStyle(prominent ? Color.white : Theme.Status.attention)
                    } else if conn == nil {
                        Text("未启动 · 点击启动").foregroundStyle(.tertiary)
                    } else {
                        Text("运行中 · \(sa.settings.codingAgent.label)").foregroundStyle(.secondary)
                    }
                }
                .font(Theme.Font.rowSubtitle)
                .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.xs)
            ZStack {
                if needs > 0 {
                    Text("\(needs)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.white)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Theme.Status.attention, in: Capsule())
                } else if let conn, appModel.isWorking(conn) {
                    EqualizerBars(animated: !reduceMotion, tint: prominent ? Color.white : Theme.brand)
                }
            }
            .frame(minWidth: 14)
        }
        .padding(.vertical, Theme.Space.xxs)
        .padding(.bottom, Theme.Space.xs)
        .overlay(alignment: .leading) {
            if isSelected && toolPaneOpen {
                Capsule().fill(Theme.brand).frame(width: 3, height: 16).offset(x: -11)
            }
        }
        .help(conn == nil ? "启动主管终端：对它说一句，它把任务加进你的清单并建议谁来做" : "主管终端（右键可重启主管）")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(needs > 0 ? "主管，\(needs) 个工单需要你" : "主管")
    }
}

private struct WorklistRow: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let sa = appModel.superagent
        let needs = sa.tasksNeedingYou.count
        let subtitle = WorklistSidebarText.subtitle(needs: needs, unassigned: sa.unassignedTasks.count, open: sa.openTasks.count,
                                                    available: appModel.worklistAvailable)
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.onBrand)
                .frame(width: 22, height: 22)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("我的清单").font(Theme.Font.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Group {
                    if subtitle.attention {
                        Text(subtitle.text).foregroundStyle(Theme.Status.attention)
                    } else if sa.openTasks.isEmpty {
                        Text(subtitle.text).foregroundStyle(.tertiary)
                    } else {
                        Text(subtitle.text).foregroundStyle(.secondary)
                    }
                }
                .font(Theme.Font.rowSubtitle)
                .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.xs)
            ZStack {
                if needs > 0 {
                    Text("\(needs)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.white)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Theme.Status.attention, in: Capsule())
                }
            }
            .frame(minWidth: 14)
        }
        .padding(.vertical, Theme.Space.xxs)
        .overlay(alignment: .leading) {
            if appModel.worklistSelected {
                Capsule().fill(Theme.brand).frame(width: 3, height: 16).offset(x: -11)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { appModel.openWorklist() }
        .help("我的清单：先定谁来做，需要你的事在最上面")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("我的清单，\(subtitle.text)")
        .accessibilityAction { appModel.openWorklist() }
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
    var tint: Color = Theme.brand
    /// Only bounce while TFA is the active app: a `repeatForever` animation keeps the whole window
    /// re-rendering at display rate, which is wasted (and was most of TFA's idle CPU) when TFA is in
    /// the background. Inactive → static bars; reactivation remounts the animated variant.
    @State private var appActive = NSApp.isActive

    var body: some View {
        Bars(animated: animated && appActive, tint: tint)
            .id(animated && appActive)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
    }
}

private struct Bars: View {
    let animated: Bool
    let tint: Color
    @State private var up = false

    var body: some View {
        // Slim and slightly translucent: the activity cue must not outweigh the terminal names.
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(tint.opacity(0.85)).frame(width: 2, height: height(i))
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
        guard animated else { return [5, 9, 7][i] } // uneven at rest: reads as "activity", not "pause"
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
    var tint: Color = Theme.brand

    var body: some View {
        Group {
            switch phase {
            case .streaming:
                // Static brand dot — no perpetual pulse loop. (Working terminals show the equalizer
                // upstream; this path is the quieter fallback.)
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
            case .justFinished:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Status.positive)
                    .transition(.scale.combined(with: .opacity))
            case .idle:
                if showUnseen {
                    Circle()
                        .fill(tint)
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
            Text("Servers").font(Theme.Font.headerTitle)
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
            Text("环境变量 · \(sessionName)").font(Theme.Font.headerTitle)
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
            Text("Add SSH Host").font(Theme.Font.headerTitle)
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
