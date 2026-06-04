import Foundation
import Observation
import AppKit
import TmuxKit

/// Top-level app state.
///
/// Model: **one terminal = one tmux session**, each backed by its own `tmux -CC` connection
/// (so every terminal streams live and independently — switching just changes which one is
/// shown, no `switch-client` needed). The sidebar is a flat list of these terminals.
@MainActor
@Observable
final class AppModel {
    /// Each connection is one terminal (one session, one window/pane).
    var connections: [ConnectionSession] = []

    /// The on-screen terminal. Single choke point for "which terminal is being viewed" — the
    /// sidebar `List` binding, ⌘1–9, ⌘K, and next/prev all funnel through here, so updating the
    /// per-terminal viewing/activity state in `didSet` covers every selection path.
    /// True when the Lab (experiments) pane is shown in the detail area instead of a terminal.
    var labSelected = false
    /// True when the Skills manager is shown in the detail area instead of a terminal.
    var skillsSelected = false
    /// True when the global CLAUDE.md rules editor is shown in the detail area instead of a terminal.
    var claudeMdSelected = false

    var selectedConnectionID: UUID? {
        didSet {
            guard oldValue != selectedConnectionID else { return }
            labSelected = false; skillsSelected = false; claudeMdSelected = false // a terminal leaves the tool panes
            for c in connections {
                if c.id == selectedConnectionID { c.markViewed() } else { c.resignViewing() }
            }
            if let id = selectedConnectionID { ensureConnected(id) } // lazy attach on first view
        }
    }

    /// Last surfaced error (e.g. tmux not found, ssh failed). Shown as a banner in the UI.
    var lastError: String?

    /// Live per-session output activity (working? + latest line), polled from the tmux server even for
    /// sessions this app hasn't attached. Drives the sidebar's real-time activity effects.
    let activity = TerminalActivityMonitor()

    // Search state lives here so the sheet and results survive view churn.
    var searchQuery: String = ""
    var searchResults: [SearchResult] = []
    var isSearching: Bool = false

    /// Drives the search sheet from AppModel so a menu command (⌘F) can open it.
    var isShowingSearch: Bool = false

    /// Drives the ⌘K quick-switch palette.
    var isShowingQuickSwitch: Bool = false

    /// Whether the playful per-keystroke typing-combo effect is shown. Persisted; toggled in Settings.
    var typingEffectsEnabled: Bool = (UserDefaults.standard.object(forKey: "typingEffectsEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(typingEffectsEnabled, forKey: "typingEffectsEnabled") }
    }

    /// Whether the left sidebar is collapsed (hidden). Toggled by the header button / ⌘\, persisted.
    var sidebarCollapsed: Bool = UserDefaults.standard.bool(forKey: "sidebarCollapsed") {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed") }
    }
    func toggleSidebar() { sidebarCollapsed.toggle() }

    /// Playful per-keystroke combo effect for the active terminal (rebuild.md #5).
    let typingCombo = TypingCombo()

    // MARK: - Terminal font size

    static let defaultFontSize: Double = 13
    static let minFontSize: Double = 9
    static let maxFontSize: Double = 28
    static let fontSizeKey = "terminalFontSize"

    /// Plain observed property mirrored to UserDefaults in didSet (NOT @AppStorage, which is a
    /// View/App property wrapper unsuitable for an @Observable model).
    var fontSize: Double = {
        let s = UserDefaults.standard.double(forKey: AppModel.fontSizeKey)
        return s == 0 ? AppModel.defaultFontSize : s
    }() {
        didSet { UserDefaults.standard.set(fontSize, forKey: AppModel.fontSizeKey) }
    }

    func connection(_ id: UUID) -> ConnectionSession? {
        connections.first { $0.id == id }
    }

    var selectedConnection: ConnectionSession? {
        selectedConnectionID.flatMap(connection)
    }

    // MARK: - Launch

    /// On launch, DISCOVER existing local tmux sessions and open one terminal per session
    /// (attaching, so they resume live). If the server has none, create one default session.
    func start() {
        loadGroups()
        loadHosts()
        loadEnvironments()
        activity.start() // begin polling per-session output activity for the sidebar effects
        guard connections.isEmpty else { return }
        let existing = TmuxServer.listLocalSessions()
        if existing.isEmpty {
            openLocal(sessionName: "main")              // create-or-attach a fresh default (connects)
        } else {
            for name in existing {
                // Register a dormant placeholder; the actual attach happens when it's selected (lazy).
                openLocal(sessionName: name, attachOnly: true, connect: false)
            }
            selectedConnectionID = connections.first?.id // selecting the first triggers its attach
        }
    }

    // MARK: - Creating terminals

    /// In-memory password per ssh host (`user@host`), so "+ new terminal" and reconnects on a remote
    /// host don't re-prompt. Combined with ssh ControlMaster, only the FIRST connection authenticates.
    @ObservationIgnored private var hostPasswords: [String: String] = [:]

    /// New terminal on the CURRENTLY-SELECTED host (rebuild.md #2): local → a fresh local session;
    /// ssh → a fresh session on that host (reusing the host's authenticated ssh master).
    func newTerminal(startDirectory: String? = nil) {
        switch currentHost {
        case .local:
            openLocal(sessionName: nextLocalSessionName(), startDirectory: startDirectory)
        case .ssh(let host, let args):
            // startDirectory is a LOCAL path → meaningless on a remote host, so it's ignored for ssh.
            open(TmuxConnection(endpoint: .ssh(host: host, sshArgs: args),
                                sessionName: nextSSHName(host: host),
                                password: hostPasswords[host]))
        }
    }

    /// New local terminal whose shell starts in a folder the user picks (`new-session -c <dir>`).
    /// Local hosts only — for a remote host the panel would pick a path that doesn't exist there.
    func newTerminalPickingFolder() {
        guard case .local = currentHost else { newTerminal(); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "在此新建"
        panel.message = "选择新终端的起始目录"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            newTerminal(startDirectory: url.path)
        }
    }

    /// Lowest unused "mux-N" given current terminals and live server sessions.
    private func nextLocalSessionName() -> String {
        var taken = Set(connections.map { $0.controller.connection.sessionName })
        taken.formUnion(TmuxServer.listLocalSessions())
        return Self.lowestUnusedName(taken: taken)
    }

    /// Lowest unused "`prefix`N" (N ≥ 1) not present in `taken`. Pure → unit-tested.
    static func lowestUnusedName(prefix: String = "mux-", taken: Set<String>) -> String {
        var n = 1
        while taken.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    /// New terminal on a remote host — kept for compatibility; routes through `addHost`.
    func addSSH(host: String, args: [String]) {
        addHost(host: host, args: args)
    }

    /// Clone a terminal's CONFIG into a brand-new tmux session: same endpoint (local / ssh host +
    /// args), socket, tmux path, password, and saved per-session environment — only the session name
    /// is fresh. Always created (never attach-only), so it behaves identically from the first shell.
    func cloneTerminal(_ conn: ConnectionSession) {
        var clone = conn.controller.connection
        clone.attachOnly = false
        switch clone.endpoint {
        case .local:           clone.sessionName = nextLocalSessionName()
        case .ssh(let host, _): clone.sessionName = nextSSHName(host: host)
        }
        // Carry the source's saved environment over to the clone's (new) key before opening, so
        // `open` injects it just like the original.
        if let srcEnv = sessionEnvironments[conn.groupKey], !srcEnv.isEmpty {
            sessionEnvironments[envLookupKey(clone)] = srcEnv
            persistEnvironments()
        }
        open(clone)
    }

    /// A session name unused among this host's live connections (we can't list remote sessions, so
    /// this is best-effort: "main", then "mux-N").
    private func nextSSHName(host: String) -> String {
        let taken = Set(connections.compactMap { conn -> String? in
            if case .ssh(let h, _) = conn.controller.connection.endpoint, h == host {
                return conn.controller.connection.sessionName
            }
            return nil
        })
        return taken.contains("main") ? Self.lowestUnusedName(taken: taken) : "main"
    }

    private func openLocal(sessionName: String, attachOnly: Bool = false, connect: Bool = true,
                           startDirectory: String? = nil) {
        open(TmuxConnection(endpoint: .local, sessionName: sessionName, attachOnly: attachOnly,
                            startDirectory: startDirectory),
             connect: connect)
    }

    /// Register a terminal. When `connect` is true (new terminal / explicit open) it is selected,
    /// which lazily triggers its attach via `selectedConnectionID`'s didSet → `ensureConnected`.
    /// When false (a session discovered at launch / host-switch) it stays a dormant placeholder
    /// until the user selects it — so no `tmux -CC` is spawned for sessions you never open.
    @discardableResult
    private func open(_ connection: TmuxConnection, connect: Bool = true) -> ConnectionSession? {
        var connection = connection
        connection.environment = sessionEnvironments[envLookupKey(connection)] ?? [:] // inject saved env
        do {
            let conn = try ConnectionSession(connection: connection)
            conn.onClosed = { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.handleConnectionClosed(conn)
            }
            // Output-finished system notification — BACKGROUND terminals only (if you're viewing it,
            // you're already watching, so we don't interrupt). The in-app row effect fires for all.
            conn.onOutputFinished = { [weak conn] wasViewing in
                guard let conn, !wasViewing else { return }
                NotificationManager.outputFinished(terminal: conn.title)
            }
            connections.append(conn)
            if connect { selectedConnectionID = conn.id } // didSet → ensureConnected spawns it
            return conn
        } catch {
            lastError = ConnectionSession.describe(error)
            return nil
        }
    }

    /// LAZY ATTACH: if the given terminal is still a dormant placeholder, spawn its connection now.
    /// Called whenever a terminal becomes selected (sidebar / ⌘K / ⌘1–9 / reveal all funnel through
    /// `selectedConnectionID`). Idempotent — already connecting/connected terminals are skipped.
    func ensureConnected(_ id: UUID) {
        guard let conn = connection(id), conn.isDormant else { return }
        conn.beginConnecting() // synchronous → the UI shows a connecting state immediately
        Task { @MainActor in
            await conn.connect()
            if let err = conn.connectError { self.lastError = "\(conn.title): \(err)" }
        }
    }

    // MARK: - Selecting / renaming / closing

    func select(_ conn: ConnectionSession) {
        selectedConnectionID = conn.id
    }

    /// Show the Lab (experiments) pane in the detail area. Keeps `selectedConnectionID` so returning
    /// to a terminal restores the last one — this just flips the detail area over to the Lab.
    func openLab() {
        labSelected = true; skillsSelected = false; claudeMdSelected = false
        leaveTerminals() // no terminal is on screen while the Lab shows
    }

    /// Show the Skills manager in the detail area. Mutually exclusive with the other tool panes / a terminal.
    func openSkills() {
        skillsSelected = true; labSelected = false; claudeMdSelected = false
        leaveTerminals()
    }

    /// Show the global CLAUDE.md rules editor. Mutually exclusive with the other tool panes / a terminal.
    func openClaudeMd() {
        claudeMdSelected = true; labSelected = false; skillsSelected = false
        leaveTerminals()
    }

    /// Switching to a tool pane (Lab / Skills / CLAUDE.md): no terminal is on screen, so stop flagging
    /// their output as "seen" AND surrender the keyboard focus the SwiftTerm view grabbed — otherwise
    /// the hidden session keeps a focused (blinking) cursor and could still swallow keystrokes.
    private func leaveTerminals() {
        for c in connections { c.resignViewing() }
        DispatchQueue.main.async {
            if let window = NSApp.keyWindow ?? NSApp.mainWindow { window.makeFirstResponder(nil) }
        }
    }

    /// The terminals the sidebar actually shows for the current host, in sidebar order (each group in
    /// order, then ungrouped). Keyboard navigation (⌘1–9, ⌘⌥←→, ⌘]) walks THIS — never the global
    /// `connections` — so the keys always match what the eye sees and never jump to a terminal hidden
    /// on another host. (Live filter text lives in the sidebar view, so it's not reflected here.)
    var visibleConnections: [ConnectionSession] {
        var out: [ConnectionSession] = []
        for g in currentGroups { out.append(contentsOf: visibleTerminals(in: g)) }
        out.append(contentsOf: visibleUngroupedTerminals)
        return out
    }

    /// The host a terminal lives on (for `reveal` and host-scoped grouping).
    func hostTarget(of conn: ConnectionSession) -> HostTarget {
        switch conn.controller.connection.endpoint {
        case .local: return .local
        case .ssh(let h, let args): return .ssh(host: h, args: args)
        }
    }

    /// Reveal a terminal in the sidebar — switching the active host if it lives on another one — and
    /// select it. ⌘K quick-switch and global search jump through here so a jump can never land on a
    /// terminal the host-scoped sidebar is currently hiding (you'd see the detail change but lose
    /// track of where you are in the list).
    func reveal(_ id: UUID) {
        guard let conn = connection(id) else { return }
        let target = hostTarget(of: conn)
        if currentHost != target { currentHost = target }
        selectedConnectionID = id
    }

    /// Select the Nth terminal (1-based, for ⌘1…⌘9) among the CURRENTLY VISIBLE ones.
    func selectIndex(_ i1: Int) {
        let i = i1 - 1
        let vis = visibleConnections
        guard vis.indices.contains(i) else { return }
        selectedConnectionID = vis[i].id
    }

    /// Select the next visible terminal, wrapping around (⌘⌥→).
    func selectNext() { step(by: +1) }
    /// Select the previous visible terminal, wrapping around (⌘⌥←).
    func selectPrev() { step(by: -1) }

    private func step(by delta: Int) {
        let vis = visibleConnections
        guard !vis.isEmpty else { return }
        guard let id = selectedConnectionID,
              let cur = vis.firstIndex(where: { $0.id == id }) else {
            selectedConnectionID = (delta > 0 ? vis.first : vis.last)?.id
            return
        }
        let n = vis.count
        selectedConnectionID = vis[((cur + delta) % n + n) % n].id
    }

    /// Jump to the next visible terminal with unseen background output (⌘]), wrapping around — so you
    /// can "patrol" busy terminals instead of hunting for lit activity dots. No-op if none have output.
    func selectNextUnseen() {
        let vis = visibleConnections
        guard !vis.isEmpty else { return }
        let start = vis.firstIndex { $0.id == selectedConnectionID } ?? -1
        for off in 1...vis.count where vis[(start + off) % vis.count].hasUnseenOutput {
            selectedConnectionID = vis[(start + off) % vis.count].id
            return
        }
    }

    /// Restart a session's shell so it reloads the latest saved environment. Re-pushes the stored
    /// per-session env via `set-environment`, then respawns the primary pane (the new shell inherits
    /// it). DESTRUCTIVE to whatever is running in that pane — invoked only on explicit user request.
    func restartSession(_ conn: ConnectionSession) {
        let env = sessionEnvironments[conn.groupKey] ?? [:]
        if !env.isEmpty { conn.controller.applySessionEnvironment(env) }
        conn.restartShell()
    }

    func renameTerminal(_ conn: ConnectionSession, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let oldKey = conn.groupKey
        conn.controller.renameAttachedSession(to: trimmed) // updates connection.sessionName synchronously
        migrateSessionKey(from: oldKey, to: conn.groupKey)  // so env + groups survive the rename / restart
    }

    /// Re-key a session's persisted state (per-session env, group membership) when its name changes.
    /// Without this, renaming a session orphans its env/group under the old name — invisible after the
    /// next launch, which restores the session under its NEW name.
    private func migrateSessionKey(from old: String, to new: String) {
        guard old != new else { return }
        if let env = sessionEnvironments.removeValue(forKey: old) {
            sessionEnvironments[new] = env
            persistEnvironments()
        }
        for i in groups.indices where groups[i].memberKeys.contains(old) {
            groups[i].memberKeys.remove(old)
            groups[i].memberKeys.insert(new) // groups' didSet persists
        }
    }

    /// Non-destructive close: detach from the tmux session (it SURVIVES and resumes on next
    /// launch) and remove the terminal from the app. This is what ⌘W and the row's primary
    /// "Close" do. Surfaces a toast (with Undo) so detach reads differently from Kill (destroy).
    func detachTerminal(_ conn: ConnectionSession) {
        // Remember how to re-attach (the session is still alive) so the toast can offer Undo.
        var reattach = conn.controller.connection
        reattach.attachOnly = true
        reattach.sessionName = conn.controller.attachedSession?.name ?? reattach.sessionName
        lastDetached = reattach
        detachedNotice = "已分离「\(conn.title)」— 会话保活,可恢复"
        conn.disconnect()
        removeConnection(conn)
    }

    /// Re-attach config + human notice for the most recently detached terminal, driving a
    /// non-blocking toast with an Undo affordance. detach (unlike Kill) leaves the tmux session
    /// alive, so re-attaching fully restores it.
    @ObservationIgnored private var lastDetached: TmuxConnection?
    var detachedNotice: String?

    /// Re-open the most recently detached terminal (the toast's Undo).
    func undoDetach() {
        guard let c = lastDetached else { return }
        lastDetached = nil
        detachedNotice = nil
        open(c)
    }
    /// Dismiss the detach toast without undoing.
    func dismissDetachNotice() { detachedNotice = nil; lastDetached = nil }

    /// Destructive: kill the terminal's tmux session and remove it from the app.
    func closeTerminal(_ conn: ConnectionSession) {
        if conn.isDormant {
            // A never-connected placeholder has no live -CC client to send `kill-session` on, so
            // briefly connect, then kill. The sidebar row is removed immediately regardless.
            conn.beginConnecting()
            Task { @MainActor in
                await conn.connect()
                conn.close()
            }
        } else {
            conn.close()
        }
        removeConnection(conn)
    }

    /// A connection finalized as gone (reconnect was impossible or exhausted): surface a
    /// non-blocking toast with the reason, then drop it from the sidebar.
    func handleConnectionClosed(_ conn: ConnectionSession) {
        if let err = conn.connectError { lastError = "\(conn.title): \(err)" }
        removeConnection(conn)
    }

    /// Remove a terminal and reselect the first remaining one if it was selected. Idempotent:
    /// removing an already-absent connection is a no-op.
    private func removeConnection(_ conn: ConnectionSession) {
        connections.removeAll { $0.id == conn.id }
        if selectedConnectionID == conn.id {
            selectedConnectionID = connections.first?.id
        }
    }

    // MARK: - Hosts (rebuild.md #2)

    /// A target a new terminal can open on: this machine, or an ssh host.
    enum HostTarget: Hashable, Codable {
        case local
        case ssh(host: String, args: [String])

        var label: String {
            switch self { case .local: return "Local"; case .ssh(let h, _): return h }
        }
        var icon: String {
            switch self { case .local: return "desktopcomputer"; case .ssh: return "network" }
        }
        /// Stable key that ties groups (and other per-host state) to this host.
        var persistKey: String {
            switch self { case .local: return "local"; case .ssh(let h, _): return "ssh:\(h)" }
        }
    }

    /// Hosts the user can switch between (Local always present). The ssh hosts are persisted across
    /// launches (UserDefaults; passwords live in the Keychain) so you never re-enter a server.
    private(set) var knownHosts: [HostTarget] = [.local] {
        didSet { persistHosts() }
    }
    /// The active host. The sidebar shows ONLY this host's terminals, and `newTerminal()` opens here.
    var currentHost: HostTarget = .local

    /// True while `selectHost` is discovering a host's sessions in the background — drives a brief
    /// "finding sessions…" hint so switching to a remote host doesn't look like an empty void.
    private(set) var isDiscoveringSessions = false

    private static let knownHostsKey = "knownHosts.v1"

    /// Restore persisted ssh hosts + their Keychain passwords (called at launch).
    func loadHosts() {
        guard let data = UserDefaults.standard.data(forKey: Self.knownHostsKey),
              let ssh = try? JSONDecoder().decode([HostTarget].self, from: data) else { return }
        knownHosts = [.local] + ssh
        // Load ALL ssh passwords from one Keychain item (A). If the Keychain read FAILS (e.g. the app
        // was re-signed / reinstalled and the OS prompt was denied) and an encrypted local backup (C)
        // exists, offer to restore from it instead of silently losing the saved passwords.
        let kc = SSHPasswordStore.loadKeychain()
        if let map = kc, !map.isEmpty {
            hostPasswords = map
        } else if kc != nil {
            // Keychain readable but empty → maybe first run after upgrading from the old per-host
            // layout: pull any legacy entries into the new combined item (+ backup).
            let hosts = ssh.compactMap { (t: HostTarget) -> String? in
                if case .ssh(let h, _) = t { return h }; return nil
            }
            let legacy = SSHPasswordStore.migrateLegacy(hosts: hosts)
            if !legacy.isEmpty { hostPasswords = legacy; SSHPasswordStore.persist(legacy) }
        } else if let backup = SSHPasswordStore.loadBackup(), !backup.isEmpty {
            // Keychain read FAILED (e.g. re-signed/reinstalled, prompt denied) → offer the backup.
            pendingBackup = backup
            keychainRecoveryNeeded = true
        }
    }

    /// Set when the Keychain read failed but an encrypted local backup is available — drives a
    /// one-shot recovery prompt (RootView) offering to restore saved ssh passwords from the backup.
    var keychainRecoveryNeeded = false
    @ObservationIgnored private var pendingBackup: [String: String]?

    /// Number of passwords the backup would restore (for the prompt message).
    var backupPasswordCount: Int { pendingBackup?.count ?? 0 }

    /// Restore ssh passwords from the encrypted backup and write them back to BOTH stores (so the
    /// Keychain item is re-created under the current signature and next launch reads cleanly).
    func recoverPasswordsFromBackup() {
        if let b = pendingBackup { hostPasswords = b; SSHPasswordStore.persist(hostPasswords) }
        pendingBackup = nil
        keychainRecoveryNeeded = false
    }

    func dismissKeychainRecovery() {
        pendingBackup = nil
        keychainRecoveryNeeded = false
    }
    private func persistHosts() {
        let ssh = knownHosts.filter { if case .ssh = $0 { return true }; return false }
        if let data = try? JSONEncoder().encode(ssh) {
            UserDefaults.standard.set(data, forKey: Self.knownHostsKey)
        }
    }

    /// Forget a saved ssh host: drop it from the menu, its cached password, and its Keychain entry.
    /// Does NOT close its live terminals. Falls back to Local if it was current.
    func forgetHost(_ host: HostTarget) {
        guard case .ssh(let h, _) = host else { return }
        knownHosts.removeAll { $0 == host }
        hostPasswords[h] = nil
        SSHPasswordStore.persist(hostPasswords) // keep A + C in sync
        if currentHost == host { selectHost(.local) }
    }

    /// Whether a connection belongs to the currently-selected host (drives the host-scoped sidebar).
    func matchesCurrentHost(_ conn: ConnectionSession) -> Bool {
        switch (currentHost, conn.controller.connection.endpoint) {
        case (.local, .local): return true
        case let (.ssh(h, _), .ssh(ch, _)): return h == ch
        default: return false
        }
    }

    /// Switch the active host: SHOW that host's terminals (the sidebar is host-scoped) and discover
    /// any of its sessions not yet open, attaching them. Selection moves to one of the host's terminals.
    func selectHost(_ host: HostTarget) {
        currentHost = host
        // Immediately show an already-open terminal of this host (or clear until discovery loads one).
        selectedConnectionID = connections.first { matchesCurrentHost($0) }?.id
        Task { @MainActor in
            isDiscoveringSessions = true
            await loadSessions(for: host)
            isDiscoveringSessions = false
            if selectedConnection == nil || !matchesCurrentHost(selectedConnection!) {
                selectedConnectionID = connections.first { matchesCurrentHost($0) }?.id
            }
        }
    }

    /// Discover the sessions on `host` and open an attach-only terminal for each one not already
    /// shown for that host. Compares by (host, session name) so re-switching never duplicates rows.
    func loadSessions(for host: HostTarget) async {
        let names: [String]
        switch host {
        case .local:
            names = TmuxServer.listLocalSessions()
        case .ssh(let h, let args):
            names = await TmuxServer.listRemoteSessions(host: h, args: args, password: hostPasswords[h])
        }
        guard !names.isEmpty else { return }

        let existing = openSessionNames(on: host)
        for name in names where !existing.contains(name) {
            switch host {
            case .local:
                openLocal(sessionName: name, attachOnly: true, connect: false) // dormant placeholder
            case .ssh(let h, let args):
                open(TmuxConnection(endpoint: .ssh(host: h, sshArgs: args),
                                    sessionName: name,
                                    attachOnly: true,
                                    password: hostPasswords[h]),
                     connect: false) // dormant placeholder — attaches when selected
            }
        }
    }

    /// The session names currently open (as terminals) for a given host. Used to avoid re-opening a
    /// session that's already on screen. ssh hosts match on `host` so two hosts can share names.
    /// Internal (not private) so the dedup contract can be unit-tested.
    func openSessionNames(on host: HostTarget) -> Set<String> {
        Set(connections.compactMap { conn -> String? in
            let endpoint = conn.controller.connection.endpoint
            switch (host, endpoint) {
            case (.local, .local):
                // Match the live (possibly renamed) name as well as the originally-opened one.
                return conn.controller.attachedSession?.name ?? conn.controller.connection.sessionName
            case let (.ssh(h, _), .ssh(connHost, _)) where h == connHost:
                return conn.controller.attachedSession?.name ?? conn.controller.connection.sessionName
            default:
                return nil
            }
        })
    }

    /// Add (or re-select) an ssh host from the Add-Host form, make it current, and open a terminal on
    /// it. `username` is folded into `user@host`; `password` (if given) is auto-supplied at the ssh
    /// password prompt — otherwise you type it in the login terminal.
    func addHost(host: String, username: String = "", password: String = "", args: [String] = []) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        let user = username.trimmingCharacters(in: .whitespaces)
        let dest = (user.isEmpty || h.contains("@")) ? h : "\(user)@\(h)"

        let target = HostTarget.ssh(host: dest, args: args)
        if !knownHosts.contains(target) { knownHosts.append(target) } // persisted via didSet
        currentHost = target
        if !password.isEmpty {
            hostPasswords[dest] = password            // remembered for "+" / reconnect
            SSHPasswordStore.persist(hostPasswords)   // persisted to Keychain (A) + encrypted backup (C)
        }
        open(TmuxConnection(endpoint: .ssh(host: dest, sshArgs: args),
                            sessionName: nextSSHName(host: dest),
                            password: hostPasswords[dest]))
    }

    // MARK: - Session groups (rebuild.md #6)

    /// A named folder of terminals. Membership is stored by a launch-stable key (session name, plus
    /// host for ssh) so it survives relaunch and reattach. Deleting a group only RELEASES its
    /// members back to "Ungrouped" — it never kills a session.
    struct TerminalGroup: Identifiable, Codable, Hashable {
        var id = UUID()
        var name: String
        /// Which host this group belongs to (`HostTarget.persistKey`). Groups are per-server, so
        /// switching the active host shows that host's groups.
        var hostKey: String = HostTarget.local.persistKey
        var memberKeys: Set<String> = []

        init(id: UUID = UUID(), name: String, hostKey: String, memberKeys: Set<String> = []) {
            self.id = id; self.name = name; self.hostKey = hostKey; self.memberKeys = memberKeys
        }
        // Tolerant decode so groups saved before host-binding still load (default to the local host).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try c.decode(String.self, forKey: .name)
            hostKey = try c.decodeIfPresent(String.self, forKey: .hostKey) ?? HostTarget.local.persistKey
            memberKeys = try c.decodeIfPresent(Set<String>.self, forKey: .memberKeys) ?? []
        }
    }

    private static let groupsKey = "terminalGroups"

    var groups: [TerminalGroup] = [] {
        didSet { persistGroups() }
    }

    private func loadGroups() {
        guard let data = UserDefaults.standard.data(forKey: Self.groupsKey),
              let decoded = try? JSONDecoder().decode([TerminalGroup].self, from: data) else { return }
        groups = decoded
    }
    private func persistGroups() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: Self.groupsKey)
        }
    }

    /// Groups belonging to the currently-active host (the only ones the sidebar shows).
    var currentGroups: [TerminalGroup] {
        groups.filter { $0.hostKey == currentHost.persistKey }
    }

    func newGroup(name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        groups.append(TerminalGroup(name: n, hostKey: currentHost.persistKey)) // bound to the active host
    }
    func renameGroup(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = n
    }
    /// Delete a group, releasing its terminals back to Ungrouped (sessions are NOT killed).
    func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
    }
    /// Move a terminal into a group (a terminal belongs to at most one group).
    func assign(_ conn: ConnectionSession, toGroup id: UUID) {
        let key = conn.groupKey
        for i in groups.indices { groups[i].memberKeys.remove(key) }
        if let i = groups.firstIndex(where: { $0.id == id }) { groups[i].memberKeys.insert(key) }
    }
    func removeFromGroups(_ conn: ConnectionSession) {
        let key = conn.groupKey
        for i in groups.indices { groups[i].memberKeys.remove(key) }
    }
    func group(for conn: ConnectionSession) -> TerminalGroup? {
        groups.first { $0.memberKeys.contains(conn.groupKey) }
    }
    /// Live terminals in a group, in sidebar order.
    func terminals(in group: TerminalGroup) -> [ConnectionSession] {
        connections.filter { group.memberKeys.contains($0.groupKey) }
    }
    /// Terminals not in any group.
    var ungroupedTerminals: [ConnectionSession] {
        let grouped = Set(groups.flatMap { $0.memberKeys })
        return connections.filter { !grouped.contains($0.groupKey) }
    }

    // Host-scoped variants: the sidebar shows only the CURRENT host's terminals.
    func visibleTerminals(in group: TerminalGroup) -> [ConnectionSession] {
        terminals(in: group).filter { matchesCurrentHost($0) }
    }
    var visibleUngroupedTerminals: [ConnectionSession] {
        ungroupedTerminals.filter { matchesCurrentHost($0) }
    }

    // MARK: - Per-session environment variables (方案 A: tmux set-environment)

    private static let envStoreKey = "sessionEnvironments.v1"
    /// Per-session env vars keyed by launch-stable groupKey (sessionName, or sessionName@host).
    /// Persisted; injected on (re)connect via `set-environment`.
    private(set) var sessionEnvironments: [String: [String: String]] = [:]

    private func loadEnvironments() {
        guard let data = UserDefaults.standard.data(forKey: Self.envStoreKey),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return }
        sessionEnvironments = decoded
    }
    private func persistEnvironments() {
        if let data = try? JSONEncoder().encode(sessionEnvironments) {
            UserDefaults.standard.set(data, forKey: Self.envStoreKey)
        }
    }

    /// The groupKey a (not-yet-opened) connection will have — for looking up its saved environment.
    private func envLookupKey(_ c: TmuxConnection) -> String {
        switch c.endpoint {
        case .local: return c.sessionName
        case .ssh(let h, _): return "\(c.sessionName)@\(h)"
        }
    }

    /// The saved environment for a terminal (for the editor's initial values).
    func environment(for conn: ConnectionSession) -> [String: String] {
        sessionEnvironments[conn.groupKey] ?? [:]
    }

    /// Persist a terminal's per-session environment and apply it live to the running session. Note:
    /// already-running shells keep their old environment until a new window opens (or the shell is
    /// respawned); new windows pick it up immediately.
    func setEnvironment(_ env: [String: String], for conn: ConnectionSession) {
        let key = conn.groupKey
        if env.isEmpty { sessionEnvironments.removeValue(forKey: key) } else { sessionEnvironments[key] = env }
        persistEnvironments()
        conn.controller.applySessionEnvironment(env)
    }

    /// Copy a session's saved environment to the system clipboard as `KEY=VALUE` lines (sorted),
    /// so it can be pasted into another session — or anywhere (a `.env` file, the shell, etc.).
    func copyEnvironment(_ conn: ConnectionSession) {
        let env = sessionEnvironments[conn.groupKey] ?? [:]
        let text = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Merge `KEY=VALUE` lines from the system clipboard into a session's env (same-named keys are
    /// overwritten, others kept), persist, and apply. Returns how many vars were merged (0 if the
    /// clipboard had nothing parseable). The new env takes effect in new shells / after restart.
    @discardableResult
    func pasteEnvironment(into conn: ConnectionSession) -> Int {
        guard let text = NSPasteboard.general.string(forType: .string) else { return 0 }
        let parsed = Self.parseEnvLines(text)
        guard !parsed.isEmpty else { return 0 }
        var env = sessionEnvironments[conn.groupKey] ?? [:]
        for (k, v) in parsed { env[k] = v }
        setEnvironment(env, for: conn) // persists + applies
        return parsed.count
    }

    /// Parse `KEY=VALUE` lines (one per line) into an env dict. Tolerates `export ` prefixes, blank
    /// lines, `#` comments, surrounding single/double quotes, and `=` in the value. Pure → testable.
    static func parseEnvLines(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2,
               (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            // Valid POSIX-ish env name: starts with a letter/underscore, then letters/digits/underscores.
            let valid = !key.isEmpty && (key.first!.isLetter || key.first! == "_")
                && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            if valid { out[key] = val }
        }
        return out
    }

    // MARK: - Font size

    func incFont() { setFont(fontSize + 1) }
    func decFont() { setFont(fontSize - 1) }
    func resetFont() { setFont(Self.defaultFontSize) }

    /// Bumped on every applied font-size keystroke so the UI can flash a brief "13 pt" HUD — even at
    /// the 9–28 clamp boundary (so ⌘+ held at the max still gives "you're at 28" feedback).
    private(set) var fontPulse = 0

    /// Clamp, persist, and broadcast the new font size to every live pane. Each pane re-pins its
    /// engine to tmux's paneSize and re-syncs the cursor (see the cursor-fix invariant).
    private func setFont(_ n: Double) {
        let c = min(max(n, Self.minFontSize), Self.maxFontSize)
        fontPulse &+= 1 // flash the HUD on every press, including a no-op at the clamp boundary
        guard c != fontSize else { return }
        fontSize = c
        for conn in connections { conn.applyFont(size: c) }
    }

    /// Cleanly tear down every live connection on app quit.
    /// Detach only — never kill sessions here, so they can be resumed on next launch.
    func shutdown() {
        for conn in connections { conn.disconnect() }
        connections.removeAll()
    }
}
