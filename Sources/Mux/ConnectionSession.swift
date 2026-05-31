import Foundation
import Observation
import TmuxKit

/// Wraps ONE `TmuxController` plus its OWN pane registry, and keeps that terminal alive across
/// transient connection drops by transparently reconnecting (the whole point of tmux: detach-safe).
///
/// Pane ids (`%2`) are only unique per tmux server, so the registry MUST be per-connection;
/// it is never shared across connections.
@MainActor
@Observable
final class ConnectionSession: Identifiable {
    let id = UUID()

    /// The live controller. Swapped for a fresh one on reconnect, so it is a `var` (observed) —
    /// the rest of the app reads `state`/`primaryPane`/`title` through it and re-renders on swap.
    private(set) var controller: TmuxController

    /// The connection we were originally asked to open. Reconnects derive an attach-only variant
    /// of this (same endpoint/socket, current — possibly renamed — session name).
    private let baseConnection: TmuxConnection

    /// Per-connection terminal registry, keyed by pane id.
    @ObservationIgnored private var terminals: [TmuxPaneID: PaneTerminal] = [:]

    /// Non-nil if this connection failed to connect / has been given up on (e.g. tmux not found,
    /// ssh refused, session gone). Drives the failure banner + Retry button.
    var connectError: String?

    /// Set when the underlying connection closes for good (server died, session killed, gave up).
    var isClosed = false

    /// True while a reconnect loop is actively retrying after an unexpected drop. Drives the
    /// "Reconnecting…" UI.
    var isReconnecting = false
    /// 1-based attempt number currently being tried (for the "Reconnecting… (attempt N)" label).
    var reconnectAttempt = 0

    /// Bumped on every successful (re)connect so the terminal view is rebuilt and re-hydrated from
    /// the freshly-attached pane (pane ids survive on the server, but the engine must re-snapshot).
    private(set) var generation = 0

    /// LAZY ATTACH: true until this terminal is first asked to connect. A discovered session shows as
    /// a sidebar placeholder (status = Idle) and only spawns its `tmux -CC` when the user selects it —
    /// so launching / switching host with many sessions stays instant and cheap.
    private(set) var isDormant = true

    /// True when a NON-foreground terminal has produced output the user hasn't seen yet — drives the
    /// sidebar activity dot. Cleared when the terminal becomes the one being viewed.
    var hasUnseenOutput = false
    /// Set by AppModel for the currently-shown terminal: its output is "seen", so don't flag it.
    @ObservationIgnored private var isViewing = false

    /// Output activity phase driving the sidebar effect: idle → streaming (output flowing) →
    /// justFinished (a burst just ended) → idle. A burst is "finished" after `outputIdleGap` seconds
    /// with no new %output, so a continuous stream (`tail -f`) never false-finishes.
    enum OutputPhase: Equatable { case idle, streaming, justFinished }
    private(set) var outputPhase: OutputPhase = .idle
    /// Invoked on the main actor when an output burst finishes, with whether the terminal was being
    /// VIEWED at the time (so AppModel can post a system notification only for background terminals).
    @ObservationIgnored var onOutputFinished: ((_ wasViewing: Bool) -> Void)?
    @ObservationIgnored private var outputIdleTask: Task<Void, Never>?
    @ObservationIgnored private var finishedResetTask: Task<Void, Never>?
    /// Seconds of no %output after which an output burst counts as finished.
    static let outputIdleGap: Double = 1.2

    /// Invoked on the main actor ONLY when the connection is finalized as gone (set by AppModel) —
    /// i.e. after reconnect was either impossible or exhausted. Drives sidebar removal + the toast.
    @ObservationIgnored var onClosed: (() -> Void)?

    /// Interactive terminal for the ssh login phase (nil for local). Persists across reconnects.
    @ObservationIgnored private(set) var loginTerminal: LoginTerminal?

    /// True while waiting on the remote ssh login (password / host-key / 2FA) before tmux control mode.
    var isAuthenticating: Bool { controller.state.authenticating }

    /// True once the user asked us to go away (Close/Kill) — suppresses any reconnect.
    @ObservationIgnored private var intentionalClose = false
    /// True once we have connected at least once — distinguishes "first connect failed" (retry the
    /// create-or-attach as given) from "dropped after attaching" (reconnect attach-only).
    @ObservationIgnored private var hasEverConnected = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    /// Up to ~23s of backoff (0.5, 1, 2, 4, 8, 8s) before declaring the terminal gone.
    static let maxReconnectAttempts = 6

    var state: TmuxState { controller.state }
    var displayName: String { controller.connection.displayName }

    /// The single pane shown for this terminal (one session = one terminal).
    var primaryPane: TmuxPane? { controller.primaryPane }

    /// Friendly title for the sidebar: the session name, plus host for ssh terminals.
    var title: String {
        let name = controller.attachedSession?.name ?? controller.connection.sessionName
        switch controller.connection.endpoint {
        case .local: return name
        case .ssh(let host, _): return "\(name) @ \(host)"
        }
    }

    /// The current command running in the terminal's pane (for a subtitle).
    var subtitle: String { controller.primaryPane?.currentCommand ?? "" }

    /// The active pane's current working directory (nil until known) — shown in the header.
    var currentPath: String? {
        let p = controller.primaryPane?.currentPath ?? ""
        return p.isEmpty ? nil : p
    }

    /// The ssh host for remote terminals (nil for local) — header context.
    var host: String? {
        if case .ssh(let h, _) = controller.connection.endpoint { return h }
        return nil
    }

    /// Launch-stable key for persisting group membership across relaunch (session name, plus host
    /// for ssh). Used by `AppModel`'s session groups.
    var groupKey: String {
        let name = controller.connection.sessionName
        switch controller.connection.endpoint {
        case .local: return name
        case .ssh(let h, _): return "\(name)@\(h)"
        }
    }

    /// The pane's current grid size in cells (nil until known) — header context.
    var grid: (cols: Int, rows: Int)? {
        guard let p = controller.primaryPane, p.width > 0, p.height > 0 else { return nil }
        return (p.width, p.height)
    }

    init(connection: TmuxConnection) throws {
        self.baseConnection = connection
        self.controller = try TmuxController(connection: connection)
        if connection.isRemote {
            // The login terminal persists across reconnects; its input always targets the CURRENT
            // controller (swapped on reconnect), so re-auth after a drop works too.
            self.loginTerminal = LoginTerminal(onInput: { [weak self] data in
                self?.controller.sendLoginInput(data)
            })
        }
        wire(controller)
    }

    /// Wire output/removal/close callbacks for a (possibly freshly created) controller.
    private func wire(_ controller: TmuxController) {
        controller.onPaneOutput = { [weak self] paneID, data in
            // Already on the main actor (TmuxController is @MainActor).
            guard let self else { return }
            self.terminals[paneID]?.feed(data)
            // Flag background activity (idempotent — only mutate on a real change to avoid churn).
            if !self.isViewing, !self.hasUnseenOutput { self.hasUnseenOutput = true }
            self.noteOutputActivity()
        }
        controller.onPaneRemoved = { [weak self] paneID in
            self?.terminals.removeValue(forKey: paneID)
        }
        controller.onConnectionClosed = { [weak self] in
            self?.handleUnderlyingClose()
        }
        controller.onLoginData = { [weak self] data in
            self?.loginTerminal?.feed(data)
        }
    }

    // MARK: - Activity / viewing state

    /// Mark this terminal as the one on screen: its output is "seen" and the activity dot clears.
    func markViewed() {
        isViewing = true
        if hasUnseenOutput { hasUnseenOutput = false }
    }

    /// This terminal is no longer on screen — future output flags activity.
    func resignViewing() { isViewing = false }

    /// Called for every %output batch: enter the streaming phase and (re)arm the idle timer. When the
    /// timer fires (no output for `outputIdleGap`), the burst is finished → effect + notification hook.
    private func noteOutputActivity() {
        if outputPhase != .streaming { outputPhase = .streaming }
        finishedResetTask?.cancel(); finishedResetTask = nil
        outputIdleTask?.cancel()
        outputIdleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.outputIdleGap * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.outputFinished()
        }
    }

    private func outputFinished() {
        guard outputPhase == .streaming, !intentionalClose else { return }
        outputPhase = .justFinished
        onOutputFinished?(isViewing)              // AppModel decides whether to post a system notification
        finishedResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000) // let the finish effect play, then settle
            guard !Task.isCancelled else { return }
            if self.outputPhase == .justFinished { self.outputPhase = .idle }
        }
    }

    /// Flip out of the dormant (placeholder) state — synchronous, so the sidebar/header switch to a
    /// "connecting" state the instant the user selects the terminal, before the async `connect` runs.
    func beginConnecting() { isDormant = false }

    func connect() async {
        isDormant = false
        let freshCreate = !hasEverConnected && !baseConnection.attachOnly
        do {
            try await controller.connect()
            connectError = nil
            isClosed = false
            applyEnvironment(freshCreate: freshCreate)
            hasEverConnected = true
        } catch {
            connectError = Self.describe(error)
        }
    }

    /// Inject this connection's per-session environment after attach. On a fresh create (first
    /// connect of a non-attach-only session) also respawn the initial shell so it picks them up; on
    /// reconnect / launch-resume we never respawn — that would kill whatever the user is running.
    private func applyEnvironment(freshCreate: Bool) {
        let env = baseConnection.environment
        guard !env.isEmpty else { return }
        controller.applySessionEnvironment(env)
        if freshCreate { controller.respawnPrimaryPane() }
    }

    // MARK: - Reconnection

    /// The underlying control connection dropped. Either the user asked for it (quiet teardown),
    /// or it's an unexpected drop → try to reconnect, and only give up (toast + sidebar removal)
    /// once the session is provably gone or retries are exhausted.
    private func handleUnderlyingClose() {
        terminals.removeAll() // every PaneTerminal referenced the now-dead controller

        if intentionalClose {
            isClosed = true
            isReconnecting = false
            return // AppModel already removed us on the user's action — no toast, no onClosed.
        }
        guard reconnectTask == nil else { return } // a reconnect loop is already running

        if canAttemptReconnect() {
            startReconnectLoop()
        } else {
            finalizeClosed()
        }
    }

    /// Reconnect is worth attempting only if the session might still be there. For local we can
    /// cheaply check the server; for ssh we can't, so we attempt (bounded) — ssh jitter is exactly
    /// the case reconnect exists for.
    private func canAttemptReconnect() -> Bool {
        switch baseConnection.endpoint {
        case .local:
            let names = TmuxServer.listLocalSessions(tmuxPath: baseConnection.tmuxPath,
                                                     socketName: baseConnection.socketName)
            return names.contains(currentSessionName)
        case .ssh:
            return true
        }
    }

    private func startReconnectLoop() {
        isReconnecting = true
        connectError = nil
        reconnectTask = Task { @MainActor in
            defer { self.reconnectTask = nil }
            var attempt = 0
            while attempt < Self.maxReconnectAttempts {
                if self.intentionalClose || Task.isCancelled { return }
                guard self.canAttemptReconnect() else { break } // session disappeared mid-backoff
                self.reconnectAttempt = attempt + 1
                let delay = Self.backoffDelay(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if self.intentionalClose || Task.isCancelled { return }
                if await self.tryReconnectOnce() {
                    self.applyReconnectSuccess()
                    return
                }
                attempt += 1
            }
            self.finalizeClosed()
        }
    }

    /// One reconnect attempt: build a fresh controller attached to the (possibly renamed) session,
    /// wire it, and connect. Returns whether it succeeded.
    private func tryReconnectOnce() async -> Bool {
        do {
            let fresh = try TmuxController(connection: reconnectConnection())
            wire(fresh)
            controller = fresh
            try await fresh.connect()
            hasEverConnected = true
            return true
        } catch {
            connectError = Self.describe(error)
            return false
        }
    }

    /// Shared success-path bookkeeping after a (re)connect lands: clear the reconnecting/failure UI
    /// and bump `generation` so the terminal view rebuilds and re-hydrates from the freshly-attached
    /// pane. Used by BOTH the automatic backoff loop and the manual Retry button so they can't drift.
    private func applyReconnectSuccess() {
        isReconnecting = false
        reconnectAttempt = 0
        connectError = nil
        isClosed = false
        generation &+= 1
    }

    /// Finalize as gone: surface a reason and ask AppModel to remove + toast.
    private func finalizeClosed() {
        isReconnecting = false
        reconnectAttempt = 0
        isClosed = true
        if connectError == nil {
            connectError = "Disconnected — the tmux session ended or is unreachable."
        }
        onClosed?()
    }

    /// An attach-only variant of the original connection, targeting the live session name. Before
    /// we have ever connected, reuse the original create-or-attach semantics (the session may not
    /// exist yet, so attach-session would fail).
    private func reconnectConnection() -> TmuxConnection {
        var c = baseConnection
        if hasEverConnected {
            c.attachOnly = true
            c.sessionName = currentSessionName
        }
        return c
    }

    /// The session's current (possibly renamed) name, falling back to the requested name.
    private var currentSessionName: String {
        controller.attachedSession?.name ?? baseConnection.sessionName
    }

    /// Backoff before the Nth (0-based) reconnect attempt: 0.5, 1, 2, 4, 8, then capped at 8s.
    static func backoffDelay(attempt: Int) -> Double {
        let capped = min(max(attempt, 0), 4)
        return min(0.5 * Double(1 << capped), 8.0)
    }

    /// User-initiated retry from the failure banner: reset and try once immediately (no backoff).
    func retry() {
        guard reconnectTask == nil else { return }
        intentionalClose = false
        isClosed = false
        connectError = nil
        terminals.removeAll()
        isReconnecting = true
        reconnectAttempt = 1
        reconnectTask = Task { @MainActor in
            defer { self.reconnectTask = nil }
            if await self.tryReconnectOnce() {
                self.applyReconnectSuccess()
            } else if self.connectError == nil {
                self.connectError = "Reconnect failed."
            }
            self.isReconnecting = false
            self.reconnectAttempt = 0
        }
    }

    // MARK: - Lifecycle (user-initiated)

    func disconnect() {
        intentionalClose = true
        reconnectTask?.cancel(); reconnectTask = nil
        outputIdleTask?.cancel(); finishedResetTask?.cancel()
        outputPhase = .idle
        isReconnecting = false
        controller.disconnect()
        terminals.removeAll()
    }

    /// Kill this terminal's tmux session and tear down the connection.
    func close() {
        intentionalClose = true
        reconnectTask?.cancel(); reconnectTask = nil
        isReconnecting = false
        controller.killAttachedSession()
        controller.disconnect()
        terminals.removeAll()
    }

    /// Respawn the primary pane's shell so it picks up updated session environment immediately.
    /// Destructive to whatever runs in that pane — invoked only on explicit user request (the env
    /// editor's "保存并重启 shell").
    func restartShell() { controller.respawnPrimaryPane() }

    // MARK: - Terminals

    /// Lazily create (and hydrate) the SwiftTerm-backed terminal for a pane. Identity is stable:
    /// repeated calls return the same `PaneTerminal`.
    func terminal(for paneID: TmuxPaneID) -> PaneTerminal {
        if let existing = terminals[paneID] {
            return existing
        }
        let term = PaneTerminal(paneID: paneID, controller: controller)
        terminals[paneID] = term
        return term
    }

    /// Apply a new font size to every live pane in this connection's registry. Each `setFont`
    /// re-pins the engine to tmux's paneSize and re-syncs the cursor (preserves the invariant).
    func applyFont(size: Double) {
        for term in terminals.values { term.setFont(size: size) }
    }

    static func describe(_ error: Error) -> String {
        if let tmuxError = error as? TmuxError {
            switch tmuxError {
            case .tmuxNotFound:
                return "tmux executable not found. Install tmux (e.g. `brew install tmux`)."
            default:
                return String(describing: tmuxError)
            }
        }
        return error.localizedDescription
    }
}
