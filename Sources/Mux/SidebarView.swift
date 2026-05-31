import SwiftUI
import TmuxKit

/// The left panel: a host switcher + action buttons up top (rebuild.md #1/#2), a filter field, and
/// the terminal list organized into collapsible groups (#6). Click to switch; right-click a row to
/// rename / move to a group / close / kill.
struct SidebarView: View {
    @Environment(AppModel.self) private var appModel

    @State private var filter: String = ""
    @State private var renameTarget: ConnectionSession?
    @State private var renameText: String = ""
    @State private var killTarget: ConnectionSession?

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
                }
                .dropDestination(for: String.self) { keys, _ in
                    for key in keys {
                        if let conn = appModel.connections.first(where: { $0.groupKey == key }) {
                            appModel.removeFromGroups(conn)
                        }
                    }
                    return true
                }
                if ungrouped.isEmpty && appModel.currentGroups.isEmpty {
                    Text(filter.isEmpty
                         ? "No terminals on \(appModel.currentHost.label) yet — press +"
                         : "No terminals match “\(filter)”")
                        .font(Theme.Font.rowSubtitle)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
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
    @ViewBuilder
    private func groupTree(_ group: AppModel.TerminalGroup) -> some View {
        let members = filtered(appModel.visibleTerminals(in: group))
        if filter.isEmpty || !members.isEmpty {
            DisclosureGroup(isExpanded: groupExpanded(group.id)) {
                ForEach(members) { row($0) }
                if members.isEmpty {
                    Text("Empty — right-click a terminal to add")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } label: { groupHeader(group) }
            // Drop terminals onto the whole folder to file them into this group (#8). Attached to the
            // entire DisclosureGroup (not just the label) so the larger target also catches drops over
            // the folder's expanded children area.
            .dropDestination(for: String.self) { keys, _ in
                for key in keys {
                    if let conn = appModel.connections.first(where: { $0.groupKey == key }) {
                        appModel.assign(conn, toGroup: group.id)
                    }
                }
                return true
            }
        }
    }

    /// Two-way binding for a group's expanded state, backed by the persisted `collapsedRaw` set.
    private func groupExpanded(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                if !filter.trimmingCharacters(in: .whitespaces).isEmpty { return true }
                return !collapsedRaw.split(separator: ",").contains(Substring(id.uuidString))
            },
            set: { expanded in
                var ids = Set(collapsedRaw.split(separator: ",").map(String.init))
                if expanded { ids.remove(id.uuidString) } else { ids.insert(id.uuidString) }
                collapsedRaw = ids.sorted().joined(separator: ",")
            }
        )
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

    private func groupHeader(_ group: AppModel.TerminalGroup) -> some View {
        sectionHeaderLabel(group.name, icon: "folder.fill",
                           count: appModel.visibleTerminals(in: group).count)
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

            HeaderButton(system: "plus", help: "New terminal on \(appModel.currentHost.label) (⌘T)") {
                appModel.newTerminal()
            }
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
    let conn: ConnectionSession
    let isSelected: Bool

    var body: some View {
        let status = TerminalStatus.of(conn)
        let showDot = conn.hasUnseenOutput && !isSelected
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(status == .connected ? Theme.brand : Color.secondary)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(conn.title)
                    .font(Theme.Font.rowTitle)
                    .lineLimit(1)
                if !conn.subtitle.isEmpty {
                    Text(conn.subtitle)
                        .font(Theme.Font.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.xs)
            if showDot {
                Circle()
                    .fill(Theme.brand)
                    .frame(width: 7, height: 7)
                    .transition(.scale.combined(with: .opacity))
            }
            // Only surface a status glyph when it needs attention — a healthy connected row stays
            // quiet (its brand-tinted icon is signal enough), keeping a long list calm.
            if status != .connected {
                StatusIndicator(status: status)
            }
        }
        .padding(.vertical, Theme.Space.xxs)
        .animation(.easeInOut(duration: 0.15), value: showDot)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(status, showDot: showDot))
    }

    private func accessibilityText(_ status: TerminalStatus, showDot: Bool) -> String {
        var parts = [conn.title, status.label]
        if !conn.subtitle.isEmpty { parts.append("running \(conn.subtitle)") }
        if showDot { parts.append("new output") }
        return parts.joined(separator: ", ")
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
