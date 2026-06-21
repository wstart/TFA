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
    /// True when the task board (Kanban) is shown in the detail area instead of a terminal.
    var tasksSelected = false
    /// True when the SSH reverse-tunnel manager is shown in the detail area instead of a terminal.
    var tunnelsSelected = false

    var selectedConnectionID: UUID? {
        didSet {
            guard oldValue != selectedConnectionID else { return }
            labSelected = false; skillsSelected = false; claudeMdSelected = false; tasksSelected = false; tunnelsSelected = false // a terminal leaves the tool panes
            // Single-terminal view: the selected one is "viewed" (its output is seen); everything else
            // resigns viewing so the sidebar can keep flagging its activity.
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

    /// The shared task board (~/.tfa/board.db) — Kanban of tasks dispatched to terminal "agents".
    let taskBoard = TaskBoardStore()

    /// Session persistence (~/.tfa/sessions.db) — a disk snapshot of each local terminal so sessions
    /// (and AI conversations) survive a reboot / `tmux kill-server`, which wipe the in-memory server.
    let sessionStore = SessionStore()

    /// Per-session right-click menu state — shared by the sidebar row and the terminal area so both
    /// surfaces offer the same actions; its sheets/alerts are hosted once at the root.
    let sessionMenu = SessionMenu()

    /// True when no `tmux` binary was found — drives a friendly "install tmux" banner instead of
    /// letting the user hit a connection-failure page on their first New Terminal. Checked async.
    var tmuxMissing = false

    // Search state lives here so the sheet and results survive view churn.
    var searchQuery: String = ""
    var searchResults: [SearchResult] = []
    var isSearching: Bool = false

    /// Drives the search sheet from AppModel so a menu command (⌘F) can open it.
    var isShowingSearch: Bool = false

    /// Drives the ⌘K quick-switch palette.
    var isShowingQuickSwitch: Bool = false

    /// Whether the playful per-keystroke typing-combo effect is shown. Persisted; toggled in Settings.
    var typingEffectsEnabled: Bool = (UserDefaults.standard.object(forKey: "typingEffectsEnabled") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(typingEffectsEnabled, forKey: "typingEffectsEnabled") }
    }

    /// Whether the left sidebar is collapsed (hidden). Toggled by the header button / ⌘\, persisted.
    var sidebarCollapsed: Bool = UserDefaults.standard.bool(forKey: "sidebarCollapsed") {
        didSet {
            UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed")
            // Sidebar hidden → its live activity isn't shown, so skip the per-session capture-pane forks
            // (the cheap window_activity poll still runs, keeping `isWorking` correct for dispatch).
            activity.captureEnabled = !sidebarCollapsed
        }
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
        loadIdentities()
        loadGroups()
        loadTunnels()
        tunnelRunner.passwordFor = { [weak self] (id: UUID) in self?.hostPasswords["tunnel:\(id.uuidString)"] }
        loadHosts()
        loadEnvironments()
        migrateLegacyKeysIfNeeded() // one-time: name-keyed env/groups/assignees → UUID keys
        startScheduler() // ONE heartbeat: activity sampling + board watch + dispatch/attention
        activity.captureEnabled = !sidebarCollapsed
        Task { @MainActor in self.tmuxMissing = await Task.detached(priority: .utility) { TmuxLocator.find() == nil }.value }
        // Discover existing local tmux sessions OFF the main thread: `tmux list-sessions` is a
        // synchronous subprocess (fork/exec + waitUntilExit) that would otherwise block the first
        // frame. The window shows instantly; dormant placeholder rows appear a beat later (they don't
        // spawn `-CC` until selected, so there's no functional cost to populating them async).
        guard connections.isEmpty else { syncBoardAgents(); return }
        Task { @MainActor in
            let existing = await Task.detached(priority: .userInitiated) { TmuxServer.listLocalSessions() }.value
            guard self.connections.isEmpty else { return } // user may have created one while we waited
            for name in existing {
                self.openLocal(sessionName: name, attachOnly: true, connect: false)
            }
            // Recreate sessions the live server lost to a reboot / kill-server (dormant placeholders).
            self.restoreMissingSessions(liveLocalNames: Set(existing))
            if self.connections.isEmpty {
                self.openLocal(sessionName: "main")          // nothing live, nothing to restore → fresh default
            }
            self.selectedConnectionID = self.connections.first?.id // selecting triggers its attach
            // Register the discovered terminals as assignable agents only NOW — syncing before
            // discovery would wipe the agents table with an empty list, leaving every task's
            // assignee dangling (the board showed cards with no 指派 until it was reopened).
            self.syncBoardAgents()
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
        // Carry the source's saved environment over to the clone's (new) identity before opening,
        // so `open` injects it just like the original.
        if let srcEnv = sessionEnvironments[conn.stableID], !srcEnv.isEmpty {
            sessionEnvironments[identity(for: envLookupKey(clone))] = srcEnv
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
        let stableID = identity(for: envLookupKey(connection)) // permanent UUID (created on first sight)
        connection.environment = sessionEnvironments[stableID] ?? [:] // inject saved env
        do {
            let conn = try ConnectionSession(connection: connection)
            conn.stableID = stableID
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
            // An agent explicitly pinged (bell / OSC notification) while in the background → a stronger,
            // separate system notification carrying the message, so "it needs you" stands out from the
            // routine "output finished".
            conn.onNeedsAttention = { [weak conn] message in
                guard let conn else { return }
                NotificationManager.needsAttention(terminal: conn.title, message: message)
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
            await self.reconcileIdentity(conn) // adopt/stamp @tfa_id in the session env
        }
    }

    // MARK: - Selecting / renaming / closing

    func select(_ conn: ConnectionSession) {
        activateTerminal(conn.id)
    }

    /// Show a terminal in the detail area (sidebar click / ⌘K / ⌘1–9). Robust to the "same id" case:
    /// while a tool pane (任务/隧道/Lab/…) is open, `selectedConnectionID` is preserved underneath, so
    /// re-selecting the SAME terminal wouldn't trip `selectedConnectionID.didSet` (its `guard oldValue
    /// != …` short-circuits) — and we'd stay stuck on the tool pane. Detect that and leave the tool
    /// pane + re-show the terminal explicitly.
    func activateTerminal(_ id: UUID) {
        if selectedConnectionID == id {
            let onTool = tasksSelected || labSelected || skillsSelected || claudeMdSelected || tunnelsSelected
            tasksSelected = false; labSelected = false; skillsSelected = false; claudeMdSelected = false; tunnelsSelected = false
            if onTool, let c = connection(id) { c.markViewed() } // returning to it counts as viewed again
            ensureConnected(id)
        } else {
            selectedConnectionID = id // didSet clears tool flags + markViewed/resign + ensureConnected
        }
    }

    /// Show the Lab (experiments) pane in the detail area. Keeps `selectedConnectionID` so returning
    /// to a terminal restores the last one — this just flips the detail area over to the Lab.
    func openLab() {
        labSelected = true; skillsSelected = false; claudeMdSelected = false; tasksSelected = false; tunnelsSelected = false
        leaveTerminals() // no terminal is on screen while the Lab shows
    }

    /// Show the Skills manager in the detail area. Mutually exclusive with the other tool panes / a terminal.
    func openSkills() {
        skillsSelected = true; labSelected = false; claudeMdSelected = false; tasksSelected = false; tunnelsSelected = false
        leaveTerminals()
    }

    /// Show the global CLAUDE.md rules editor. Mutually exclusive with the other tool panes / a terminal.
    func openClaudeMd() {
        claudeMdSelected = true; labSelected = false; skillsSelected = false; tasksSelected = false; tunnelsSelected = false
        leaveTerminals()
    }

    /// Show the task board (Kanban). Mutually exclusive with the other tool panes / a terminal.
    func openTasks() {
        tasksSelected = true; labSelected = false; skillsSelected = false; claudeMdSelected = false; tunnelsSelected = false
        syncBoardAgents()
        leaveTerminals()
    }

    /// Show the SSH reverse-tunnel manager. Mutually exclusive with the other tool panes / a terminal.
    func openTunnels() {
        tunnelsSelected = true; tasksSelected = false; labSelected = false; skillsSelected = false; claudeMdSelected = false
        leaveTerminals()
    }

    /// ⌘⇧T: flip between the task board and the terminal you were on — the board/terminal round-trip
    /// is the heart of the dispatch loop, so it gets a single dedicated key.
    func toggleTasks() {
        if tasksSelected { backToTerminal() } else { openTasks() }
    }

    /// Leave whatever tool pane is open and land on a terminal (the selected one, or the first).
    /// Selection may be UNCHANGED, so the didSet that normally clears the tool flags won't fire —
    /// clear them explicitly and re-mark the terminal as viewed.
    private func backToTerminal() {
        tasksSelected = false; labSelected = false; skillsSelected = false; claudeMdSelected = false; tunnelsSelected = false
        if selectedConnectionID == nil { selectedConnectionID = connections.first?.id }
        if let id = selectedConnectionID, let c = connection(id) {
            c.markViewed()
            ensureConnected(id)
        }
    }

    /// Jump from a board card straight into its agent's terminal (the other half of the dispatch
    /// loop: dispatch on the board, watch in the terminal).
    func goToTerminal(_ id: UUID) {
        tasksSelected = false; labSelected = false; skillsSelected = false; claudeMdSelected = false; tunnelsSelected = false
        reveal(id) // switches host if needed; the didSet marks viewed when the id changes
        if let c = connection(id) { c.markViewed() } // and when it doesn't, mark it here
        ensureConnected(id)
    }

    /// Register every LOCAL terminal as an assignable board agent (id `tfa:<stableID>`). Remote (ssh)
    /// terminals are excluded by design — their agents can't reach the local board.db, so the
    /// dispatch→report loop would silently break (决议 #2). Cheap; called when the board is opened
    /// or terminals change.
    func syncBoardAgents() {
        let managed = connections.filter { $0.host == nil }.map { c in
            BoardAgent(id: "tfa:" + c.stableID, name: c.title,
                       kind: c.subtitle.isEmpty ? "shell" : c.subtitle,
                       session: c.stableID, cwd: c.currentPath ?? "")
        }
        taskBoard.syncManagedAgents(managed)
    }

    /// The dispatch domain (queueing, retries, attention reconcile) — extracted so it's unit-testable
    /// against fake terminals/boards (决议 #4). Wired with live adapters in `start()`.
    @ObservationIgnored private(set) lazy var dispatch = DispatchCenter(board: taskBoard)

    func dispatchTask(_ taskID: UUID, to agentID: String) { dispatch.dispatchTask(taskID, to: agentID) }
    func pushReply(_ taskID: UUID, text: String) { dispatch.pushReply(taskID, text: text) }

    /// True while a (local) terminal is actively producing output — sending keystrokes then would be
    /// swallowed; idle (sitting at a prompt / agent awaiting input) is safe to dispatch into. Single
    /// source of truth shared by the sidebar effects, the board cards, and dispatch.
    func isWorking(_ conn: ConnectionSession) -> Bool {
        if conn.host == nil { return activity.isWorking(name: conn.groupKey) || conn.outputPhase == .streaming }
        return conn.outputPhase == .streaming
    }

    /// THE app heartbeat (决议 #5): one loop drives all periodic work in a guaranteed order —
    /// ① sample activity (tmux poll, skipped while occluded) → ② board change-check (fast while the
    /// board is shown, every 3rd tick otherwise) → ③ dispatch queue + attention reconcile. One timer
    /// instead of three: fewer wakeups, and "dispatch sees fresh activity" by construction.
    private func startScheduler() {
        dispatch.terminals = { [weak self] in
            guard let self else { return [] }
            return self.connections.map { TerminalAgentAdapter($0, model: self) }
        }
        Task { @MainActor in
            var n = 0
            while !Task.isCancelled {
                await activity.tick()
                if taskBoard.watchFast || n % 3 == 0 { taskBoard.tickIfChanged() }
                dispatch.tick()
                if n == 40 || (n > 0 && n % 2400 == 0) { await snapshotSessions() } // baseline ~1 min, then hourly
                n &+= 1
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    // MARK: - Session persistence (恢复对话 across reboot)

    /// Full snapshot of every CONNECTED local terminal — metadata + scrollback — to `sessions.db`.
    /// Async (it runs `capture-pane` per terminal); driven by the heartbeat every ~10 min. Upsert-only,
    /// so dormant/restored rows we haven't reconnected to are preserved.
    private func snapshotSessions() async {
        for conn in connections where conn.host == nil && conn.state.connected {
            guard let pane = conn.primaryPane?.id else { continue }
            let name = conn.controller.connection.sessionName
            let cwd = conn.currentPath ?? ""
            let ai = isAITerminal(command: conn.subtitle, cwd: conn.currentPath)
            let text = await conn.controller.capturePaneText(pane, historyLines: 3000)
            if text.isEmpty {
                // Transient capture failure → keep the previously saved scrollback, refresh metadata.
                sessionStore.upsertMeta(tfaID: conn.stableID, name: name, cwd: cwd, command: conn.subtitle, isAI: ai)
            } else {
                sessionStore.upsert(SessionRecord(
                    tfaID: conn.stableID, name: name, cwd: cwd, command: conn.subtitle,
                    isAI: ai, scrollback: text, updatedAt: 0))
            }
        }
    }

    /// Full snapshot on graceful quit (scrollback included), bounded by a ~2.5s deadline so quitting
    /// never hangs on a stuck `capture-pane`. Falls back to synchronous metadata if it times out.
    func snapshotSessionsOnQuit() async {
        let full = Task { @MainActor in await self.snapshotSessions() }
        let timeout = Task { try? await Task.sleep(nanoseconds: 2_500_000_000) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await full.value }
            group.addTask { await timeout.value }
            await group.next()       // whichever finishes first
            group.cancelAll()
        }
        snapshotMetadataNow()        // guarantee at least fresh metadata even if capture was slow
    }

    /// Best-effort SYNCHRONOUS metadata snapshot for clean quit (⌘Q / SIGTERM) — no async capture
    /// (the exit path can't await), but it freshens cwd/command and keeps the last scrollback row.
    private func snapshotMetadataNow() {
        for conn in connections where conn.host == nil && conn.state.connected {
            sessionStore.upsertMeta(
                tfaID: conn.stableID, name: conn.controller.connection.sessionName,
                cwd: conn.currentPath ?? "", command: conn.subtitle,
                isAI: isAITerminal(command: conn.subtitle, cwd: conn.currentPath))
        }
    }

    /// On launch, recreate local sessions the live tmux server no longer has (lost to a reboot /
    /// `tmux kill-server`). Each is recreated as a DORMANT placeholder under its saved name → same
    /// `@tfa_id` → its env / group / board assignments reconnect automatically. Opening it connects
    /// a fresh session in the saved cwd, then replays history (or resumes the AI conversation).
    private func restoreMissingSessions(liveLocalNames: Set<String>) {
        let existing = Set(connections.compactMap { $0.host == nil ? $0.controller.connection.sessionName : nil })
        let cutoff = Date().timeIntervalSince1970 - 14 * 86_400 // don't resurrect sessions idle > 14 days
        for r in sessionStore.roster()
        where !liveLocalNames.contains(r.name) && !existing.contains(r.name) && r.updatedAt >= cutoff {
            seedIdentity(name: r.name, id: r.tfaID) // ensure the restored placeholder keeps its UUID
            let conn = TmuxConnection(endpoint: .local, sessionName: r.name,
                                      attachOnly: false,            // create-or-attach on first open
                                      startDirectory: r.cwd.isEmpty ? nil : r.cwd)
            guard let session = open(conn, connect: false) else { continue }
            if r.isAI {
                session.restoreCommand = r.command.contains("codex") ? "codex resume" : "claude --continue --dangerously-skip-permissions"
            } else if !r.scrollback.isEmpty {
                session.restorePreamble = Data(r.scrollback.utf8)
            }
        }
    }

    /// A terminal is an AI agent session if it's (was) running claude/codex, or its directory has a
    /// Claude Code transcript — meaning `claude --continue` there would actually resume a conversation.
    private func isAITerminal(command: String, cwd: String?) -> Bool {
        let c = command.lowercased()
        if c.contains("claude") || c.contains("codex") { return true }
        guard let cwd, !cwd.isEmpty else { return false }
        return claudeProjectExists(cwd: cwd)
    }
    /// Cache of cwd → "has a Claude project dir", so the hourly snapshot doesn't re-stat ~/.claude
    /// every time (reads there also raise the macOS "access other apps' data" prompt).
    @ObservationIgnored private var claudeProjectCache: [String: Bool] = [:]
    /// Claude Code encodes a project's cwd by replacing `/` and `.` with `-` under ~/.claude/projects.
    private func claudeProjectExists(cwd: String) -> Bool {
        if let cached = claudeProjectCache[cwd] { return cached }
        let encoded = cwd.map { ($0 == "/" || $0 == ".") ? "-" : $0 }.reduce("") { $0 + String($1) }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: dir.path)
        claudeProjectCache[cwd] = exists
        return exists
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
        activateTerminal(id)
    }

    /// Select the Nth terminal (1-based, for ⌘1…⌘9) among the CURRENTLY VISIBLE ones.
    func selectIndex(_ i1: Int) {
        let i = i1 - 1
        let vis = visibleConnections
        guard vis.indices.contains(i) else { return }
        activateTerminal(vis[i].id)
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
            if let to = (delta > 0 ? vis.first : vis.last)?.id { activateTerminal(to) }
            return
        }
        let n = vis.count
        activateTerminal(vis[((cur + delta) % n + n) % n].id)
    }

    /// Jump to the next terminal that needs eyes (⌘]), wrapping around. Priority: a terminal that's
    /// explicitly WAITING for you (bell / agent ask) beats one that merely has unseen output — one
    /// key patrols everything, most urgent first. No-op when nothing is pending.
    func selectNextUnseen() {
        let vis = visibleConnections
        guard !vis.isEmpty else { return }
        let start = vis.firstIndex { $0.id == selectedConnectionID } ?? -1
        for off in 1...vis.count where vis[(start + off) % vis.count].needsAttention {
            activateTerminal(vis[(start + off) % vis.count].id)
            return
        }
        for off in 1...vis.count where vis[(start + off) % vis.count].hasUnseenOutput {
            activateTerminal(vis[(start + off) % vis.count].id)
            return
        }
    }

    /// Number of terminals currently waiting for the user (agent pinged in the background).
    var attentionCount: Int { connections.filter { $0.needsAttention }.count }

    /// Jump to the next terminal that's explicitly waiting for you (bell / OSC notification). Cycles
    /// through them; selecting clears that one's flag (markViewed).
    func selectNextAttention() {
        let vis = visibleConnections
        guard !vis.isEmpty else { return }
        let start = vis.firstIndex { $0.id == selectedConnectionID } ?? -1
        for off in 1...vis.count where vis[(start + off) % vis.count].needsAttention {
            activateTerminal(vis[(start + off) % vis.count].id)
            return
        }
    }

    /// Restart a session's shell so it reloads the latest saved environment. Re-pushes the stored
    /// per-session env via `set-environment`, then respawns the primary pane (the new shell inherits
    /// it). DESTRUCTIVE to whatever is running in that pane — invoked only on explicit user request.
    func restartSession(_ conn: ConnectionSession) {
        let env = sessionEnvironments[conn.stableID] ?? [:]
        if !env.isEmpty { conn.controller.applySessionEnvironment(env) }
        conn.restartShell()
    }

    func renameTerminal(_ conn: ConnectionSession, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let oldKey = conn.groupKey
        conn.controller.renameAttachedSession(to: trimmed) // updates connection.sessionName synchronously
        // Data is keyed by the permanent @tfa_id, so NOTHING migrates — only the name→UUID
        // bootstrap entry moves, and the board shows the new title.
        renameIdentity(from: oldKey, to: conn.groupKey)
        syncBoardAgents()
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
        sessionStore.remove(tfaID: conn.stableID) // user explicitly destroyed it → don't ever restore it
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
        if tasksSelected { syncBoardAgents() } // keep the board's agent list current while it's shown
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
        knownHosts = [.local] + ssh // host menu is ready immediately (UserDefaults only)
        // Keychain read is OFF the main thread: on a re-signed / reinstalled app `SecItemCopyMatching`
        // can pop a modal ACL prompt that would FREEZE the first frame. Passwords aren't needed until
        // you actually connect to an ssh host, so load them in the background and assign back on main.
        let sshHosts = ssh
        Task { @MainActor in
            let kc = await Task.detached(priority: .utility) { SSHPasswordStore.loadKeychain() }.value
            if let map = kc, !map.isEmpty {
                self.hostPasswords = map
            } else if kc != nil {
                let hosts = sshHosts.compactMap { (t: HostTarget) -> String? in if case .ssh(let h, _) = t { return h }; return nil }
                let legacy = await Task.detached(priority: .utility) { SSHPasswordStore.migrateLegacy(hosts: hosts) }.value
                if !legacy.isEmpty { self.hostPasswords = legacy; SSHPasswordStore.persist(legacy) }
            } else {
                let backup = await Task.detached(priority: .utility) { SSHPasswordStore.loadBackup() }.value
                if let backup, !backup.isEmpty { self.pendingBackup = backup; self.keychainRecoveryNeeded = true }
            }
            self.autoStartTunnels() // passwords are loaded now → bring up enabled tunnels
        }
    }

    // MARK: - SSH reverse tunnels (ssh -R)

    /// Reverse tunnels (`ssh -N -R`). Config persisted in UserDefaults; passwords in the Keychain
    /// (same aggregated item as host passwords, under a `tunnel:<id>` key). The runner owns the
    /// processes + auto-reconnect; the UI observes `sshTunnels` + `tunnelRunner.states`.
    let tunnelRunner = TunnelRunner()
    private static let tunnelsKey = "sshTunnels.v1"
    private(set) var sshTunnels: [SSHTunnel] = [] {
        didSet { persistTunnels() }
    }

    private func loadTunnels() {
        guard let data = UserDefaults.standard.data(forKey: Self.tunnelsKey),
              let decoded = try? JSONDecoder().decode([SSHTunnel].self, from: data) else { return }
        sshTunnels = decoded
    }
    private func persistTunnels() {
        if let data = try? JSONEncoder().encode(sshTunnels) {
            UserDefaults.standard.set(data, forKey: Self.tunnelsKey)
        }
    }

    private func tunnelPasswordKey(_ id: UUID) -> String { "tunnel:\(id.uuidString)" }
    /// The saved password for a tunnel (for the editor's initial value).
    func tunnelPassword(_ t: SSHTunnel) -> String { hostPasswords[tunnelPasswordKey(t.id)] ?? "" }

    private func setTunnelPassword(_ id: UUID, _ password: String) {
        if password.isEmpty { hostPasswords[tunnelPasswordKey(id)] = nil }
        else { hostPasswords[tunnelPasswordKey(id)] = password }
        SSHPasswordStore.persist(hostPasswords) // whole aggregated map (hosts + tunnels)
    }

    /// Create + (since new tunnels default enabled) immediately start a tunnel.
    func addTunnel(name: String, serverIP: String, account: String, password: String,
                   loginPort: Int, remotePort: Int, localPort: Int, gatewayPorts: Bool) {
        let t = SSHTunnel(name: name, serverIP: serverIP, account: account,
                          loginPort: loginPort, remotePort: remotePort, localPort: localPort,
                          enabled: true, gatewayPorts: gatewayPorts)
        setTunnelPassword(t.id, password)
        sshTunnels.append(t)
        if t.enabled { tunnelRunner.start(t) }
    }

    /// Apply edits to an existing tunnel; `password == nil` keeps the saved one. Restarts if enabled.
    func updateTunnel(_ t: SSHTunnel, password: String?) {
        guard let i = sshTunnels.firstIndex(where: { $0.id == t.id }) else { return }
        sshTunnels[i] = t
        if let pw = password { setTunnelPassword(t.id, pw) }
        if t.enabled { tunnelRunner.restart(t) } else { tunnelRunner.stop(t.id) }
    }

    func removeTunnel(_ t: SSHTunnel) {
        tunnelRunner.stop(t.id)
        sshTunnels.removeAll { $0.id == t.id }
        setTunnelPassword(t.id, "") // clears the key + persists
    }

    /// Flip a tunnel's remembered on/off switch and start/stop it accordingly.
    func setTunnelEnabled(_ t: SSHTunnel, _ on: Bool) {
        guard let i = sshTunnels.firstIndex(where: { $0.id == t.id }) else { return }
        sshTunnels[i].enabled = on
        if on { tunnelRunner.start(sshTunnels[i]) } else { tunnelRunner.stop(t.id) }
    }

    /// Launch-time: bring up every tunnel whose switch was left on. Called after Keychain passwords
    /// have loaded (askpass needs them).
    private func autoStartTunnels() {
        for t in sshTunnels where t.enabled { tunnelRunner.start(t) }
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
        autoStartTunnels() // passwords just recovered → enabled tunnels can connect now
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

    // MARK: - Terminal identity (@tfa_id)

    /// groupKey (name-based, host-scoped) → permanent UUID. The name side exists ONLY to bootstrap:
    /// at discovery (and after a reboot wiped the tmux env) a session is recognised by name once and
    /// handed its UUID back. All persisted data is keyed by the UUID, so renames never migrate data.
    private static let identityStoreKey = "terminalIdentities.v1"
    @ObservationIgnored private var identityMap: [String: String] = [:]

    private func loadIdentities() {
        guard let data = UserDefaults.standard.data(forKey: Self.identityStoreKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        identityMap = decoded
    }
    private func persistIdentities() {
        if let data = try? JSONEncoder().encode(identityMap) {
            UserDefaults.standard.set(data, forKey: Self.identityStoreKey)
        }
    }

    /// The permanent UUID for a (possibly not-yet-opened) terminal, creating one on first sight.
    private func identity(for groupKey: String) -> String {
        if let id = identityMap[groupKey] { return id }
        let id = UUID().uuidString.lowercased()
        identityMap[groupKey] = id
        persistIdentities()
        return id
    }

    /// Force a name→UUID mapping (session restore: the roster row carries the permanent id, so the
    /// recreated placeholder must adopt it rather than mint a new one).
    private func seedIdentity(name: String, id: String) {
        guard identityMap[name] != id else { return }
        identityMap[name] = id
        persistIdentities()
    }

    /// Rename: the UUID (and all data) stays put — only the name→UUID bootstrap entry moves.
    private func renameIdentity(from old: String, to new: String) {
        guard old != new, let id = identityMap.removeValue(forKey: old) else { return }
        identityMap[new] = id // a stale entry under the new name is overwritten — the live session wins
        persistIdentities()
    }

    /// Last-known display name for a terminal UUID (reverse bootstrap lookup) — used to label board
    /// assignees whose terminal is gone.
    func displayName(forIdentity id: String) -> String? {
        identityMap.first { $0.value == id }?.key
    }

    /// A human-readable label for a board agent id ("tfa:<uuid>"), degrading gracefully:
    /// live terminal title → last-known name (+ 终端已关闭) → legacy ext: → raw id.
    func assigneeLabel(_ agentID: String) -> String {
        if agentID.hasPrefix("tfa:") {
            let key = String(agentID.dropFirst(4))
            if let conn = connections.first(where: { $0.stableID == key }) { return conn.title }
            if let name = displayName(forIdentity: key) { return "\(name)（终端已关闭）" }
            return "\(String(key.prefix(8)))（终端已关闭）"
        }
        if agentID.hasPrefix("ext:") { return "\(String(agentID.dropFirst(4)))（外部 agent，已失联）" }
        return agentID
    }

    /// ONE-TIME migration of name-keyed data (pre-@tfa_id) to UUID keys: env store, group members,
    /// and board assignees. Idempotent (guarded by a defaults flag; non-UUID keys simply disappear
    /// after conversion).
    private func migrateLegacyKeysIfNeeded() {
        let flag = "identityMigration.v1.done"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }
        for (key, env) in sessionEnvironments where !isUUID(key) {
            sessionEnvironments[identity(for: key)] = env
            sessionEnvironments[key] = nil
        }
        persistEnvironments()
        for i in groups.indices {
            groups[i].memberKeys = Set(groups[i].memberKeys.map { isUUID($0) ? $0 : identity(for: $0) })
        }
        for t in taskBoard.board.tasks {
            if let a = t.assignee, a.hasPrefix("tfa:") {
                let suffix = String(a.dropFirst(4))
                if !isUUID(suffix) { taskBoard.migrateAssignee(from: a, to: "tfa:" + identity(for: suffix)) }
            }
        }
        UserDefaults.standard.set(true, forKey: flag)
    }

    /// After a terminal connects: reconcile its identity with the `@tfa_id` stored in the tmux
    /// session env. tmux WINS when it has a valid id (it survives TFA reinstalls and out-of-band
    /// renames); otherwise we stamp ours in. Cheap, runs once per connect.
    private func reconcileIdentity(_ conn: ConnectionSession) async {
        guard conn.state.connected else { return }
        if let tmuxID = await conn.controller.sessionVariable("@tfa_id"),
           UUID(uuidString: tmuxID) != nil {
            if tmuxID.lowercased() != conn.stableID {
                identityMap[conn.groupKey] = tmuxID.lowercased()
                persistIdentities()
                conn.stableID = tmuxID.lowercased()
            }
        } else {
            conn.controller.setSessionVariable("@tfa_id", conn.stableID)
        }
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
    /// Reorder folders: move group `id` to sit just before `targetID` among the CURRENT host's groups
    /// (or to the end when `targetID` is nil). Only the active host's slots are reordered — other
    /// hosts' groups keep their positions in the backing array. Persisted via `groups`' didSet.
    func moveGroup(_ id: UUID, before targetID: UUID?) {
        guard id != targetID else { return }
        var order = currentGroups.map(\.id)
        guard let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        if let t = targetID, let to = order.firstIndex(of: t) { order.insert(id, at: to) }
        else { order.append(id) } // dropped past the last folder → move to the end
        let hostKey = currentHost.persistKey
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var next = order.compactMap { byID[$0] }.makeIterator()
        groups = groups.map { $0.hostKey == hostKey ? (next.next() ?? $0) : $0 }
    }
    /// Move a terminal into a group (a terminal belongs to at most one group). Membership is keyed
    /// by the permanent @tfa_id, so renames never strand it.
    func assign(_ conn: ConnectionSession, toGroup id: UUID) {
        let key = conn.stableID
        for i in groups.indices { groups[i].memberKeys.remove(key) }
        if let i = groups.firstIndex(where: { $0.id == id }) { groups[i].memberKeys.insert(key) }
    }
    func removeFromGroups(_ conn: ConnectionSession) {
        let key = conn.stableID
        for i in groups.indices { groups[i].memberKeys.remove(key) }
    }
    func group(for conn: ConnectionSession) -> TerminalGroup? {
        groups.first { $0.memberKeys.contains(conn.stableID) }
    }
    /// Live terminals in a group, in sidebar order.
    func terminals(in group: TerminalGroup) -> [ConnectionSession] {
        connections.filter { group.memberKeys.contains($0.stableID) }
    }
    /// Terminals not in any group.
    var ungroupedTerminals: [ConnectionSession] {
        let grouped = Set(groups.flatMap { $0.memberKeys })
        return connections.filter { !grouped.contains($0.stableID) }
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
        sessionEnvironments[conn.stableID] ?? [:]
    }

    /// Persist a terminal's per-session environment and apply it live to the running session. Note:
    /// already-running shells keep their old environment until a new window opens (or the shell is
    /// respawned); new windows pick it up immediately.
    func setEnvironment(_ env: [String: String], for conn: ConnectionSession) {
        let key = conn.stableID
        if env.isEmpty { sessionEnvironments.removeValue(forKey: key) } else { sessionEnvironments[key] = env }
        persistEnvironments()
        conn.controller.applySessionEnvironment(env)
    }

    /// Copy a session's saved environment to the system clipboard as `KEY=VALUE` lines (sorted),
    /// so it can be pasted into another session — or anywhere (a `.env` file, the shell, etc.).
    func copyEnvironment(_ conn: ConnectionSession) {
        let env = sessionEnvironments[conn.stableID] ?? [:]
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
        var env = sessionEnvironments[conn.stableID] ?? [:]
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
        snapshotMetadataNow() // freshen the roster (cwd/command) so a clean quit restores accurately
        tunnelRunner.stopAll() // terminate ssh -R children so they don't orphan
        for conn in connections { conn.disconnect() }
        connections.removeAll()
    }
}
