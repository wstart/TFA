import Foundation

/// Drives a single tmux connection: issues the initial state queries, applies the live event
/// stream to an observable `TmuxState` tree, routes pane output to the UI, and exposes
/// high-level actions (new window, kill pane, send keys, …).
///
/// All mutation happens on the main actor so SwiftUI can observe `state` directly.
@MainActor
public final class TmuxController {
    public let state: TmuxState
    public let connection: TmuxConnection
    private let client: TmuxControlClient

    /// The session this control client is currently attached to (tracked from `%session-changed`).
    /// In this app each connection owns exactly one session, so this is "our terminal".
    public private(set) var attachedSessionID: TmuxSessionID?

    /// Raw, already-decoded output bytes for a pane → route to that pane's terminal view.
    public var onPaneOutput: ((TmuxPaneID, Data) -> Void)?
    /// A pane disappeared → drop its terminal view.
    public var onPaneRemoved: ((TmuxPaneID) -> Void)?
    /// The connection closed (tmux exited / detached / server died).
    public var onConnectionClosed: (() -> Void)?
    /// Raw login bytes (ssh password prompt / host-key / 2FA) seen BEFORE tmux control mode starts —
    /// the UI renders these in an interactive login terminal. Only fires for remote connections.
    public var onLoginData: ((Data) -> Void)?

    private var eventLoop: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var didClose = false

    /// Panes tmux has paused for flow control. Cleared on `%continue`; a per-pause fallback continue
    /// is scheduled so a missed `%continue` can't freeze a pane's output forever.
    private var pausedPanes: Set<TmuxPaneID> = []
    private var pauseFallbackTasks: [TmuxPaneID: Task<Void, Never>] = [:]

    public init(connection: TmuxConnection) throws {
        self.connection = connection
        self.state = TmuxState(connectionName: connection.displayName)
        self.client = TmuxControlClient(transport: try connection.makeTransport())
    }

    // MARK: - lifecycle

    public func connect() async throws {
        client.onClose = { [weak self] in
            Task { @MainActor in self?.handleClosed() }
        }
        client.onLoginData = { [weak self] data in
            Task { @MainActor in self?.onLoginData?(data) }
        }
        let interactive = connection.isRemote
        if interactive { state.authenticating = true }
        try client.start(interactiveLogin: interactive, password: connection.password)
        startEventLoop()
        // For ssh: blocks through the interactive login (password / host-key / 2FA) until tmux
        // enters control mode. For local: returns immediately.
        await client.waitForControlMode()
        state.authenticating = false
        try await refreshAll()
        // Enable flow control so a flooding pane (e.g. `yes`) can't grow an unbounded backlog or
        // swamp the main actor — tmux pauses + buffers instead. Best-effort: old tmux ignores it.
        client.setFlowControl(pauseAfter: 1)
        state.connected = true
    }

    /// Forward the user's keystrokes to the process during the interactive ssh login.
    public func sendLoginInput(_ data: Data) { client.writeRaw(data) }

    public func disconnect() {
        cancelPauseTasks()
        eventLoop?.cancel(); eventLoop = nil
        refreshTask?.cancel(); refreshTask = nil
        // Release our manual size hold so a concurrently-attached terminal regains its own size.
        if let sid = attachedSessionID ?? attachedSession?.id {
            client.sendFireAndForget("set-option -t \(sid) window-size latest")
        }
        // A blank line / detach-client cleanly leaves the server running.
        client.sendFireAndForget("detach-client")
        client.terminate()
    }

    private func startEventLoop() {
        eventLoop = Task { [weak self] in
            guard let self else { return }
            for await event in self.client.events {
                self.handle(event)
            }
        }
    }

    private func handleClosed() {
        guard !didClose else { return }
        didClose = true
        state.connected = false
        cancelPauseTasks()
        eventLoop?.cancel(); eventLoop = nil
        refreshTask?.cancel(); refreshTask = nil
        onConnectionClosed?()
    }

    /// Flow-control safety net: if `%continue` never arrives for a paused pane, force a continue after
    /// a short delay so its output can't freeze. Cancelled on `%continue` / teardown.
    private func scheduleContinueFallback(_ pane: TmuxPaneID) {
        pauseFallbackTasks[pane]?.cancel()
        pauseFallbackTasks[pane] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, self.pausedPanes.contains(pane) else { return }
            self.client.continuePane(pane)
        }
    }

    private func cancelPauseTasks() {
        for t in pauseFallbackTasks.values { t.cancel() }
        pauseFallbackTasks.removeAll()
        pausedPanes.removeAll()
    }

    // MARK: - event application

    private func handle(_ event: TmuxEvent) {
        switch event {
        case .output(let pane, let data):
            onPaneOutput?(pane, data)
        case .extendedOutput(let pane, _, let data):
            onPaneOutput?(pane, data)
            // Rendered this buffered (paused) batch → ack so tmux resumes live %output for the pane.
            if pausedPanes.contains(pane) { client.continuePane(pane) }

        case .reply:
            break // replies are awaited via send(_:)

        case .notification(let note):
            apply(note)
        }
    }

    private func apply(_ note: TmuxNotification) {
        switch note {
        case .layoutChange(let wid, let layout, _, _):
            if let w = state.window(wid) {
                applyLayout(layout, to: w)
            } else {
                scheduleRefresh()
            }
        case .windowRenamed(let wid, let name), .unlinkedWindowRenamed(let wid, let name):
            state.window(wid)?.name = name
        case .windowPaneChanged(let wid, let pid):
            if let w = state.window(wid) {
                w.activePaneID = pid
                for p in w.panes { p.active = (p.id == pid) }
            }
        case .sessionRenamed(let sid, let name):
            state.session(sid)?.name = name
        case .sessionChanged(let sid, _):
            attachedSessionID = sid // our client switched/attached to this session
            scheduleRefresh()
        case .windowAdd, .unlinkedWindowAdd,
             .windowClose, .unlinkedWindowClose,
             .sessionsChanged, .sessionWindowChanged:
            scheduleRefresh()
        case .exit:
            handleClosed()
        case .paused(let pane):
            pausedPanes.insert(pane)
            scheduleContinueFallback(pane)
        case .continued(let pane):
            pausedPanes.remove(pane)
            pauseFallbackTasks[pane]?.cancel()
            pauseFallbackTasks.removeValue(forKey: pane)
        case .paneModeChanged, .clientSessionChanged, .clientDetached,
             .subscriptionChanged,
             .configError, .message, .pasteBufferChanged, .pasteBufferDeleted, .unknown:
            break
        }
    }

    /// Update pane geometry from a layout string; reconcile the pane set (handles split/kill).
    private func applyLayout(_ layout: String, to window: TmuxWindow) {
        window.layout = layout
        let geoms = LayoutParser.parse(layout)
        guard !geoms.isEmpty else { return }
        let newIDs = geoms.map(\.id)
        let oldIDs = window.panes.map(\.id)

        for gone in Set(oldIDs).subtracting(newIDs) {
            window.panes.removeAll { $0.id == gone }
            onPaneRemoved?(gone)
        }
        window.panes = geoms.map { g in
            let p = window.pane(g.id) ?? TmuxPane(id: g.id)
            p.left = g.left; p.top = g.top; p.width = g.width; p.height = g.height
            return p
        }
        // New panes appeared (split) → refresh to fill title/command/active metadata.
        if Set(newIDs) != Set(oldIDs) { scheduleRefresh() }
    }

    private func scheduleRefresh() {
        guard !didClose else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000) // coalesce bursts
            guard let self, !Task.isCancelled else { return }
            try? await self.refreshAll()
        }
    }

    // MARK: - full state query

    private static let fmtSession = "#{session_id}|#{session_attached}|#{session_name}"
    private static let fmtWindow = "#{session_id}|#{window_id}|#{window_active}|#{window_layout}|#{window_name}"
    private static let fmtPane = "#{session_id}|#{window_id}|#{pane_id}|#{pane_active}|#{pane_width}|#{pane_height}|#{pane_left}|#{pane_top}|#{pane_current_command}|#{pane_title}"

    /// Re-query THIS connection's session and reconcile it into `state`, preserving existing objects
    /// by id.
    ///
    /// Scoped to our own session (one-terminal-per-session model), NOT the whole server: tmux
    /// broadcasts `%sessions-changed` to EVERY client of a server, so a server-wide `-a` query here
    /// would make N terminals each re-fetch all N sessions' panes on every change — O(N²) round-trips.
    /// Targeting our session keeps it O(N). The target is our session id once known (robust to
    /// rename), else the requested name on the very first refresh (before `%session-changed` lands).
    public func refreshAll() async throws {
        let target = Self.quote(attachedSessionID ?? connection.sessionName)
        let sessionsReply = try await client.send("display-message -p -t \(target) '\(Self.fmtSession)'")
        let windowsReply = try await client.send("list-windows -t \(target) -F '\(Self.fmtWindow)'")
        let panesReply = try await client.send("list-panes -s -t \(target) -F '\(Self.fmtPane)'")

        // Group windows & panes by their parent id.
        var windowsBySession: [TmuxSessionID: [(id: TmuxWindowID, active: Bool, layout: String, name: String)]] = [:]
        for line in windowsReply.lines {
            let f = splitFields(line, 4)
            guard f.count == 5 else { continue }
            windowsBySession[f[0], default: []].append((f[1], f[2] == "1", f[3], f[4]))
        }
        var panesByWindow: [TmuxWindowID: [(id: TmuxPaneID, active: Bool, w: Int, h: Int, x: Int, y: Int, cmd: String, title: String)]] = [:]
        for line in panesReply.lines {
            let f = splitFields(line, 9)
            guard f.count == 10 else { continue }
            panesByWindow[f[1], default: []].append((
                f[2], f[3] == "1",
                Int(f[4]) ?? 0, Int(f[5]) ?? 0, Int(f[6]) ?? 0, Int(f[7]) ?? 0,
                f[8], f[9]))
        }

        let oldPaneIDs = Set(allPaneIDs())
        var newSessions: [TmuxSession] = []
        for sline in sessionsReply.lines {
            let f = splitFields(sline, 2)
            guard f.count == 3 else { continue }
            let sid = f[0]
            let session = state.session(sid) ?? TmuxSession(id: sid)
            session.attached = f[1] == "1"
            session.name = f[2]

            var newWindows: [TmuxWindow] = []
            for wmeta in windowsBySession[sid] ?? [] {
                let window = session.window(wmeta.id) ?? state.window(wmeta.id) ?? TmuxWindow(id: wmeta.id)
                window.active = wmeta.active
                window.layout = wmeta.layout
                window.name = wmeta.name
                if wmeta.active { session.activeWindowID = wmeta.id }

                var newPanes: [TmuxPane] = []
                for pmeta in panesByWindow[wmeta.id] ?? [] {
                    let pane = window.pane(pmeta.id) ?? state.pane(pmeta.id) ?? TmuxPane(id: pmeta.id)
                    pane.active = pmeta.active
                    pane.width = pmeta.w; pane.height = pmeta.h
                    pane.left = pmeta.x; pane.top = pmeta.y
                    pane.currentCommand = pmeta.cmd
                    pane.title = pmeta.title
                    if pmeta.active { window.activePaneID = pmeta.id }
                    newPanes.append(pane)
                }
                window.panes = newPanes
                newWindows.append(window)
            }
            session.windows = newWindows
            newSessions.append(session)
        }
        state.sessions = newSessions

        if attachedSessionID == nil {
            attachedSessionID = state.sessions.first { $0.name == connection.sessionName }?.id
        }

        for gone in oldPaneIDs.subtracting(Set(allPaneIDs())) { onPaneRemoved?(gone) }
    }

    // MARK: - attached session (one-terminal-per-session model)

    /// The session our control client is attached to (by id, falling back to name match).
    public var attachedSession: TmuxSession? {
        if let id = attachedSessionID, let session = state.session(id) { return session }
        return state.sessions.first { $0.name == connection.sessionName } ?? state.sessions.first
    }

    /// The single pane to show for this terminal: the attached session's active window's active pane.
    public var primaryPane: TmuxPane? {
        guard let session = attachedSession else { return nil }
        let window = (session.activeWindowID.flatMap { session.window($0) }) ?? session.windows.first
        guard let window else { return nil }
        return (window.activePaneID.flatMap { window.pane($0) }) ?? window.panes.first
    }

    public func renameAttachedSession(to name: String) {
        guard let sid = attachedSessionID ?? attachedSession?.id else { return }
        client.sendFireAndForget("rename-session -t \(sid) \(Self.quote(name))")
    }

    public func killAttachedSession() {
        guard let sid = attachedSessionID ?? attachedSession?.id else { return }
        client.sendFireAndForget("kill-session -t \(sid)")
    }

    private func allPaneIDs() -> [TmuxPaneID] {
        state.sessions.flatMap { $0.windows.flatMap { $0.panes.map(\.id) } }
    }

    // MARK: - scrollback / search

    /// Capture a pane's content (with ANSI escapes) for hydrating a freshly-attached terminal.
    public func capturePaneANSI(_ pane: TmuxPaneID, historyLines: Int = 2000) async -> Data {
        guard let reply = try? await client.send("capture-pane -p -e -J -t \(pane) -S -\(historyLines) -E -")
        else { return Data() }
        return Data(reply.lines.joined(separator: "\r\n").utf8)
    }

    /// The pane's current cursor position (0-based col/row, relative to the visible screen).
    /// `capture-pane` does NOT restore the cursor, so hydration uses this to place it correctly.
    public func cursorPosition(_ pane: TmuxPaneID) async -> (x: Int, y: Int)? {
        guard let reply = try? await client.send("display-message -p -t \(pane) '#{cursor_x},#{cursor_y}'"),
              let line = reply.lines.first(where: { !$0.isEmpty }) else { return nil }
        let parts = line.split(separator: ",")
        guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else { return nil }
        return (x, y)
    }

    /// The pane's current REAL size in cells, AFTER multi-client window-size reconciliation.
    /// Hydration resizes the SwiftTerm engine to this so engineRows == captureRows == the screen
    /// tmux measured cursor_y against — making the hydration CUP land on the correct row regardless
    /// of which other clients are attached or how the window-size option arbitrated the pane.
    public func paneSize(_ pane: TmuxPaneID) async -> (cols: Int, rows: Int)? {
        guard let reply = try? await client.send("display-message -p -t \(pane) '#{pane_width},#{pane_height}'"),
              let line = reply.lines.first(where: { !$0.isEmpty }) else { return nil }
        let parts = line.split(separator: ",")
        guard parts.count == 2, let c = Int(parts[0]), let r = Int(parts[1]) else { return nil }
        return (c, r)
    }

    /// Capture a pane's plain text (no escapes) for indexing / cross-terminal search.
    public func capturePaneText(_ pane: TmuxPaneID, historyLines: Int = 5000) async -> String {
        guard let reply = try? await client.send("capture-pane -p -J -t \(pane) -S -\(historyLines) -E -")
        else { return "" }
        return reply.lines.joined(separator: "\n")
    }

    // MARK: - actions

    /// Forward user keystrokes (raw terminal bytes) to a pane, binary-safe via `send-keys -H`.
    public func sendKeys(to pane: TmuxPaneID, bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        client.sendFireAndForget("send-keys -t \(pane) -H \(hex)")
    }

    public func sendKeys(to pane: TmuxPaneID, text: String) {
        sendKeys(to: pane, bytes: ArraySlice(Array(text.utf8)))
    }

    public func selectWindow(_ window: TmuxWindowID) { client.sendFireAndForget("select-window -t \(window)") }
    public func selectPane(_ pane: TmuxPaneID) { client.sendFireAndForget("select-pane -t \(pane)") }
    public func newWindow(in session: TmuxSessionID? = nil) {
        client.sendFireAndForget("new-window" + (session.map { " -t \($0)" } ?? ""))
    }
    public func killWindow(_ window: TmuxWindowID) { client.sendFireAndForget("kill-window -t \(window)") }
    public func renameWindow(_ window: TmuxWindowID, to name: String) {
        client.sendFireAndForget("rename-window -t \(window) \(Self.quote(name))")
    }
    public func splitPane(_ pane: TmuxPaneID, horizontal: Bool) {
        client.sendFireAndForget("split-window \(horizontal ? "-h" : "-v") -t \(pane)")
    }
    public func killPane(_ pane: TmuxPaneID) { client.sendFireAndForget("kill-pane -t \(pane)") }
    public func zoomPane(_ pane: TmuxPaneID) { client.sendFireAndForget("resize-pane -Z -t \(pane)") }
    public func newSession(name: String) { client.sendFireAndForget("new-session -d -s \(Self.quote(name))") }
    public func killSession(_ session: TmuxSessionID) { client.sendFireAndForget("kill-session -t \(session)") }

    /// Tell tmux this GUI client's grid size and try to OWN it (so the pane fills our view). Pins
    /// this session to manual window sizing and resizes its active window to our grid; if another
    /// client/option defeats this, hydration still pins the engine to tmux's actual pane size, so
    /// the cursor stays correct (the view just letterboxes). Debounce in the caller.
    public func setClientSize(cols: Int, rows: Int) {
        if let sid = attachedSessionID ?? attachedSession?.id {
            client.sendFireAndForget("set-option -t \(sid) window-size manual")
            if let win = attachedSession?.activeWindowID {
                client.sendFireAndForget("resize-window -t \(win) -x \(cols) -y \(rows)")
            }
        }
        client.sendFireAndForget("refresh-client -C \(cols)x\(rows)")
        client.resize(cols: cols, rows: rows)
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Split on `|`, keeping the final free-form field intact (so a `|` in a title/name doesn't shift columns).
private func splitFields(_ line: String, _ maxSplits: Int) -> [String] {
    line.split(separator: "|", maxSplits: maxSplits, omittingEmptySubsequences: false).map(String.init)
}
