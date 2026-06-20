import SwiftUI
import TmuxKit

/// Shows the selected terminal's single pane (or its login / reconnecting / error state).
struct TerminalAreaView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if let conn = appModel.selectedConnection {
                TerminalContent(conn: conn)
            } else {
                EmptyTerminalView { appModel.newTerminal() }
            }
        }
    }
}

/// The terminal (or its login / reconnecting / error state) for one connection.
private struct TerminalContent: View {
    @Environment(AppModel.self) private var appModel
    let conn: ConnectionSession

    var body: some View {
        if conn.isAuthenticating, let login = conn.loginTerminal {
            // ssh login phase — an interactive terminal so you can type the password / answer prompts.
            LoginView(connection: conn, login: login)
        } else if let pane = conn.primaryPane, !conn.isReconnecting {
            SinglePaneView(connection: conn, pane: pane, combo: appModel.typingCombo)
                // Fresh view identity per (terminal, generation, pane) so resize/focus re-runs on
                // switch AND after a reconnect (generation bumps → re-hydrate); the underlying
                // SwiftTerm view is still reused from the registry.
                .id("\(conn.id)-\(conn.generation)-\(pane.id)")
        } else if conn.isReconnecting {
            ReconnectingView(connection: conn)
        } else if let error = conn.connectError {
            ConnectionFailureView(connection: conn, error: error)
        } else {
            ContentUnavailableView(
                "正在启动终端…",
                systemImage: "terminal",
                description: Text("正在连接 tmux 会话。")
            )
        }
    }
}

/// Warm first-run / empty state: a branded mark, a clear next action, and the shortcuts that get
/// you there — instead of a cold "No terminal".
private struct EmptyTerminalView: View {
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 46))
                .foregroundStyle(Theme.brand)
            Text("还没有打开终端")
                .font(Theme.Font.emptyTitle)
            Text("新建本地终端，或通过 ssh 连接远程主机。\n每个终端都是一个真实的 tmux 会话——关掉 App 也不丢；\n在里面跑 AI agent，再用任务看板（⌘⇧T）派活、盯进度。")
                .font(Theme.Font.emptyBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(action: onNew) {
                Label("新建终端", systemImage: "plus")
            }
            .controlSize(.large)
            .keyboardShortcut("t", modifiers: .command)
            ShortcutHints(pairs: [("⌘T", "新建"), ("⌘K", "切换"), ("⌘⇧T", "任务看板"), ("⌘]", "有动静的终端")])
                .padding(.top, Theme.Space.xs)
        }
        .padding(Theme.Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// A quiet row of keyboard hints (e.g. ⌘T · New).
private struct ShortcutHints: View {
    let pairs: [(key: String, label: String)]

    var body: some View {
        HStack(spacing: Theme.Space.lg) {
            ForEach(pairs, id: \.key) { pair in
                HStack(spacing: Theme.Space.xs) {
                    Text(pair.key)
                        .font(.caption.monospaced())
                        .padding(.horizontal, Theme.Space.sm)
                        .padding(.vertical, Theme.Space.xxs)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    Text(pair.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Shown while a dropped connection is being retried (the whole point of tmux: don't lose the
/// terminal on a transient drop).
private struct ReconnectingView: View {
    let connection: ConnectionSession

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            ProgressView()
                .controlSize(.large)
            Text("正在重连…")
                .font(Theme.Font.emptyTitle)
            Text(connection.reconnectAttempt > 0
                 ? "第 \(connection.reconnectAttempt) 次尝试（共 \(ConnectionSession.maxReconnectAttempts) 次）"
                 : "连接断开了——正在恢复你的会话。")
                .font(Theme.Font.emptyBody)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Replaces the previously-permanent "Starting terminal…" spinner when a connection genuinely
/// failed: shows the real error and a Retry button instead of spinning forever.
private struct ConnectionFailureView: View {
    let connection: ConnectionSession
    let error: String

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.Status.failed)
            Text("Couldn't connect")
                .font(Theme.Font.emptyTitle)
            Text(error)
                .font(Theme.Font.emptyBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .textSelection(.enabled)
            Button {
                connection.retry()
            } label: {
                Label("Retry Connection", systemImage: "arrow.clockwise")
            }
            .controlSize(.large)
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(Theme.Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The ssh LOGIN phase: a hint bar + an interactive terminal where you type the password / answer
/// host-key & 2FA prompts. Once tmux enters control mode this is replaced by the real pane.
private struct LoginView: View {
    let connection: ConnectionSession
    let login: LoginTerminal

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.brand)
                Text(hint)
                    .font(Theme.Font.headerMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                ProgressView().controlSize(.small)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.sm)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            LoginTerminalView(login: login)
                .background(Theme.terminalBackground)
        }
    }

    private var hint: String {
        let host = connection.host ?? "host"
        return "Signing in to \(host) — type your password / answer prompts, then press Return."
    }
}

/// A large, light, non-interactive watermark of the terminal's session name, scaled to fill the
/// pane — an at-a-glance identity cue when juggling many terminals (see DESIGN.md). Drawn faintly
/// on top of the opaque terminal so live text stays legible; never intercepts input.
private struct SessionWatermark: View {
    let name: String

    var body: some View {
        GeometryReader { geo in
            Text(name)
                .font(.system(size: max(geo.size.height * 0.46, 64), weight: .bold, design: .rounded))
                .foregroundStyle(Theme.brand.opacity(0.09))
                .lineLimit(1)
                .minimumScaleFactor(0.04) // shrink long names to one line
                .frame(width: geo.size.width * 0.9)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SinglePaneView: View {
    // Injected by TerminalAreaView's environment (AppModel is @Observable). Drives whether the
    // typing-combo effect is wired/shown — see requirement 10.
    @Environment(AppModel.self) private var appModel

    let connection: ConnectionSession
    let pane: TmuxPane
    let combo: TypingCombo

    @State private var refreshTask: Task<Void, Never>?
    @State private var sizeSyncTask: Task<Void, Never>?

    // Scroll state pushed up from PaneTerminal (which isn't @Observable) via its `onScrollState`
    // callback. When the user scrolls up off the live tail we surface a "jump to latest" pill;
    // `unseenLines` is an advisory count of output that streamed in while scrolled away.
    @State private var atBottom = true
    @State private var unseenLines = 0

    var body: some View {
        GeometryReader { geo in
            // Sizing: the terminal's own frame-driven `sizeChanged` (PaneTerminal) handles the common
            // case, but on first show it can be dropped (view not yet on a window) and then never
            // re-fires (grid already correct), leaving the pane stuck small. So we ALSO drive an
            // explicit, geometry-anchored push whenever the on-screen area changes — on first layout
            // and on every window/app resize — debounced and de-duped in PaneTerminal so it's
            // loop-free and preserves THE CURSOR INVARIANT (engine still follows tmux's paneSize).
            TerminalPaneView(connection: connection, paneID: pane.id)
                .onChange(of: geo.size) { scheduleSizeSync() }
                // SAME fixed color as the terminal itself, so an uncovered strip during the
                // first-layout/resize can never show as a mismatched (white/black) band.
                .background(Theme.terminalBackground)
                // A big, faint session-name watermark fills the terminal — at a glance you know
                // WHICH terminal you're looking at among many. Non-interactive, so it never eats
                // a keystroke or click; faint enough that live text stays readable on top.
                .overlay { SessionWatermark(name: connection.title) }
                // Typing-combo: a spark burst at the cursor on each keystroke + a top-right counter.
                // Gated on the user setting (requirement 10) — when off, neither overlay is mounted
                // and `wireCombo()` leaves the input hook nil.
                .overlay {
                    if appModel.typingEffectsEnabled {
                        ComboBurst(trigger: combo.burst, point: combo.burstPoint)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if appModel.typingEffectsEnabled, combo.count > 1 {
                        ComboCounter(count: combo.count).padding(Theme.Space.lg)
                    }
                }
                // Jump-to-latest: while the user is scrolled up into history, a pill in the
                // bottom-right snaps back to the live tail (and shows the unseen-line count).
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        JumpToLatestPill(unseenLines: unseenLines) {
                            connection.terminal(for: pane.id).scrollToBottom()
                        }
                        .padding(Theme.Space.lg)
                    }
                }
                .onAppear { scheduleRefresh(); wireCombo(); wireScrollState() }
                .onChange(of: appModel.typingEffectsEnabled) { wireCombo() }
                .onDisappear { refreshTask?.cancel(); sizeSyncTask?.cancel() }
        }
    }

    /// Route this terminal's keystrokes into the combo (fresh combo per switch). Honors the user
    /// setting: when typing effects are off we detach the input hook and reset the streak, so no
    /// burst/counter ever fires. Re-run on `typingEffectsEnabled` change for instant toggling.
    private func wireCombo() {
        combo.reset()
        let term = connection.terminal(for: pane.id)
        if appModel.typingEffectsEnabled {
            term.onUserInput = { [weak term] in
                combo.bump(at: term?.caretFraction())
            }
        } else {
            term.onUserInput = nil
        }
    }

    /// Subscribe to PaneTerminal's scroll-state callback (it isn't @Observable) so the jump pill
    /// appears/updates as the user scrolls into history and as output streams in.
    private func wireScrollState() {
        let term = connection.terminal(for: pane.id)
        // Seed from the current state, then keep it in sync.
        atBottom = true
        unseenLines = 0
        term.onScrollState = { atBottom, unseen in
            self.atBottom = atBottom
            self.unseenLines = unseen
        }
    }

    /// On switch-to, force a repaint of the live buffer (immediately, and again once any resize
    /// has settled) so the displayed content + cursor match tmux exactly without re-capturing.
    private func scheduleRefresh() {
        let paneID = pane.id
        connection.terminal(for: paneID).refreshDisplay()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            // FIRST: push the view's full grid to tmux so the pane/window grows to fill the area —
            // BEFORE hydration pins the engine to tmux's paneSize. Without this, a freshly-shown
            // terminal that never got a frame-driven `sizeChanged` (view not on a window yet) would
            // pin the engine to tmux's default 24 rows and stay small forever.
            connection.terminal(for: paneID).applyViewSizeToTmux()
            try? await Task.sleep(nanoseconds: 200_000_000) // let tmux reconcile + layout/resize settle
            guard !Task.isCancelled else { return }
            let term = connection.terminal(for: paneID)
            // Push once more in case the grid only finished settling during the wait (idempotent).
            term.applyViewSizeToTmux()
            term.hydrateIfNeeded() // first show: capture NOW that tmux height == this view's height
            term.refreshDisplay()
            term.syncCursor()      // re-assert cursor for already-hydrated terminals
        }
    }

    /// Window/app resized → re-fit the terminal. Debounced so a drag-resize coalesces into a single
    /// tmux `resize-window`; de-duped inside `applyViewSizeToTmux` so it's loop-free. After tmux
    /// reconciles the new `paneSize`, `syncCursor()` re-pins the engine to it (THE CURSOR INVARIANT).
    private func scheduleSizeSync() {
        let paneID = pane.id
        sizeSyncTask?.cancel()
        sizeSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000) // debounce a live drag-resize
            guard !Task.isCancelled else { return }
            let term = connection.terminal(for: paneID)
            term.applyViewSizeToTmux()                       // grow/shrink tmux to the new view grid
            try? await Task.sleep(nanoseconds: 120_000_000)  // let tmux reconcile paneSize
            guard !Task.isCancelled else { return }
            term.refreshDisplay()
            term.syncCursor()                                // engine follows tmux's new paneSize
        }
    }
}

// MARK: - Typing combo (rebuild.md #5)

/// A one-shot particle "explosion" fired at `point` (normalized 0…1) whenever `trigger` changes —
/// i.e. on every keystroke. Non-interactive so it never steals input/focus.
private struct ComboBurst: View {
    let trigger: Int
    let point: CGPoint

    var body: some View {
        GeometryReader { geo in
            BurstInstance()
                .position(x: point.x * geo.size.width, y: point.y * geo.size.height)
                .id(trigger) // a new instance per keystroke replays the one-shot animation
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One spark burst: a handful of brand-colored dots flying outward and fading, played once on
/// appear. Lightweight — nothing animates while idle (the parent only mounts it per keystroke).
private struct BurstInstance: View {
    @State private var expanded = false

    private struct Spark { let angle: Double; let distance: CGFloat; let size: CGFloat; let opacity: Double }
    private let sparks: [Spark] = (0..<9).map { i in
        Spark(angle: Double(i) / 9 * 2 * .pi + Double.random(in: -0.35...0.35),
              distance: CGFloat.random(in: 16...32),
              size: CGFloat.random(in: 3...6),
              opacity: Double.random(in: 0.7...1.0))
    }

    var body: some View {
        ZStack {
            ForEach(sparks.indices, id: \.self) { i in
                let s = sparks[i]
                Circle()
                    .fill(Theme.brand)
                    .frame(width: s.size, height: s.size)
                    .offset(x: expanded ? cos(s.angle) * s.distance : 0,
                            y: expanded ? sin(s.angle) * s.distance : 0)
                    .opacity(expanded ? 0 : s.opacity)
                    .scaleEffect(expanded ? 0.3 : 1)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.45)) { expanded = true } }
    }
}

/// The top-right "×N COMBO" counter. Grows and glows with the streak; pops on each increment.
private struct ComboCounter: View {
    let count: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: -2) {
            Text("×\(count)")
                .font(.system(size: 26 + min(CGFloat(count) * 0.8, 28), weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.brand)
                .shadow(color: Theme.brand.opacity(0.55), radius: min(CGFloat(count), 14))
                .contentTransition(.numericText())
            Text("COMBO")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(Theme.brand.opacity(0.8))
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.55), value: count)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Jump to latest (rebuild.md #5)

/// A small floating pill that appears in the terminal's bottom-right while the user is scrolled up
/// into history, snapping the viewport back to the live tail when tapped. Shows the count of lines
/// that streamed in while away (when known) so the user can tell there's new output below.
private struct JumpToLatestPill: View {
    let unseenLines: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.semibold))
                if unseenLines > 0 {
                    Text("\(unseenLines)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(Theme.brand)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, Theme.Space.xs)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.brand.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: unseenLines)
        .accessibilityLabel("Jump to latest output")
    }
}
