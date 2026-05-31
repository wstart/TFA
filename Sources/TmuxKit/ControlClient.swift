import Foundation

/// Owns a `TmuxTransport`, parses its bytes, and exposes:
///  - an `AsyncStream<TmuxEvent>` of output + notifications, and
///  - `send(_:)` / `sendFireAndForget(_:)` to issue tmux commands with FIFO reply matching.
///
/// Replies are matched to issued commands by FIFO order among `flags == 1` blocks (client
/// commands); internal `flags == 0` blocks from the handshake are ignored. See
/// docs/tmux-control-protocol.md §5.
public final class TmuxControlClient: @unchecked Sendable {
    private let transport: TmuxTransport
    private let parser = TmuxProtocolParser()
    private let queue = DispatchQueue(label: "tmux.control.client")

    /// FIFO of awaiters for the commands we've sent. `nil` entries are fire-and-forget
    /// placeholders that keep the FIFO aligned with tmux's reply order.
    private var pending: [CheckedContinuation<TmuxReply, Error>?] = []
    private var eventContinuation: AsyncStream<TmuxEvent>.Continuation?
    private var closed = false

    /// True until the tmux control-mode opener (`ESC P 1000 p`) appears. During this window raw bytes
    /// are surfaced via `onLoginData` (ssh password / host-key / 2FA) and `writeRaw` forwards
    /// keystrokes. Local connections never enter it — `tmux -CC`'s first bytes ARE the opener.
    private var awaitingControlMode = false
    private var loginScan: [UInt8] = []
    private var controlModeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Auto-login state: the password to inject at the prompt, and one-shot guards so we answer each
    /// prompt exactly once (a wrong password re-prompts, and we then leave it to the manual login
    /// terminal). `promptTail` is a bounded rolling copy of recent login text for prompt matching.
    private var loginPassword: String?
    private var injectedPassword = false
    private var answeredHostKey = false
    private var promptTail = ""

    /// Invoked on the main queue with raw login bytes seen before control mode (ssh prompts / MOTD).
    public var onLoginData: ((Data) -> Void)?

    /// Most recent error text seen on the stream (%error body or %exit reason), used to enrich
    /// the close path so callers see WHY the connection ended instead of a generic message.
    private(set) var lastErrorText: String?

    /// Stream of output + notification events (replies are delivered via `send` instead).
    public let events: AsyncStream<TmuxEvent>

    /// Invoked on the main queue when the connection closes.
    public var onClose: (() -> Void)?

    public init(transport: TmuxTransport) {
        self.transport = transport
        var continuation: AsyncStream<TmuxEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventContinuation = continuation

        transport.onData = { [weak self] data in self?.handleData(data) }
        transport.onClose = { [weak self] in self?.handleClose() }
    }

    public func start(interactiveLogin: Bool = false, password: String? = nil) throws {
        queue.sync {
            self.awaitingControlMode = interactiveLogin
            self.loginPassword = password
        }
        try transport.start()
    }

    /// Suspends until tmux control mode begins. Resolves immediately for non-login connections, and
    /// also resolves if the process dies during login (so the caller proceeds and surfaces the error).
    public func waitForControlMode() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if !self.awaitingControlMode { cont.resume(); return }
                self.controlModeWaiters.append(cont)
            }
        }
    }

    /// Forward raw keystrokes to the process during the login phase (password, host-key y/n, 2FA).
    public func writeRaw(_ data: Data) { transport.write(data) }

    /// Issue a command and await its reply block.
    @discardableResult
    public func send(_ command: String) async throws -> TmuxReply {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TmuxReply, Error>) in
            queue.async {
                if self.closed { cont.resume(throwing: TmuxError.connectionClosed); return }
                self.pending.append(cont)
                self.transport.write(Data((command + "\n").utf8))
            }
        }
    }

    /// Issue a command without awaiting its reply (e.g. `send-keys`). Still keeps the FIFO aligned.
    public func sendFireAndForget(_ command: String) {
        queue.async {
            if self.closed { return }
            self.pending.append(nil)
            self.transport.write(Data((command + "\n").utf8))
        }
    }

    public func resize(cols: Int, rows: Int) {
        transport.resize(cols: cols, rows: rows)
    }

    /// Enable tmux flow control: when the client falls behind, tmux buffers a flooding pane and emits
    /// `%pause` instead of flooding us with `%output`, delivering the backlog as `%extended-output`.
    /// Fire-and-forget; on a tmux too old for the flag the `%error` is ignored silently (see dispatch).
    public func setFlowControl(pauseAfter seconds: Int) {
        sendFireAndForget("refresh-client -f pause-after=\(seconds)")
    }

    /// Tell tmux we've caught up on a paused pane's backlog so it resumes live `%output` (`%continue`).
    public func continuePane(_ pane: String) {
        sendFireAndForget("refresh-client -A '\(pane):continue'")
    }

    public func terminate() {
        transport.terminate()
    }

    /// The DCS sequence tmux emits to enter control mode (`ESC P 1000 p`) — the login→control handoff.
    private static let controlModeOpener: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]

    private static func firstIndex(of seq: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !seq.isEmpty, bytes.count >= seq.count else { return nil }
        let last = bytes.count - seq.count
        var i = 0
        while i <= last {
            var match = true
            for j in 0..<seq.count where bytes[i + j] != seq[j] { match = false; break }
            if match { return i }
            i += 1
        }
        return nil
    }

    // MARK: - internals

    private func handleData(_ data: Data) {
        queue.async {
            if self.awaitingControlMode {
                self.scanLogin(Array(data))
            } else {
                for event in self.parser.feed(data) {
                    self.dispatch(event)
                }
            }
        }
    }

    /// Runs on `queue`. Buffers login bytes, emitting them via `onLoginData`, until the control-mode
    /// opener appears; from the opener onward the stream is handed to the protocol parser as usual.
    private func scanLogin(_ chunk: [UInt8]) {
        loginScan.append(contentsOf: chunk)
        // Maintain a bounded rolling text tail and auto-answer host-key / password prompts.
        promptTail += String(decoding: chunk, as: UTF8.self)
        if promptTail.count > 600 { promptTail = String(promptTail.suffix(600)) }
        autoAnswerLogin()

        if let idx = Self.firstIndex(of: Self.controlModeOpener, in: loginScan) {
            emitLogin(Array(loginScan[..<idx]))                 // everything before = login dialogue
            let rest = Data(loginScan[idx...])                  // opener onward = control mode
            loginScan.removeAll(keepingCapacity: false)
            awaitingControlMode = false
            let waiters = controlModeWaiters; controlModeWaiters.removeAll()
            for w in waiters { w.resume() }
            for event in parser.feed(rest) { dispatch(event) }
        } else {
            // No opener yet — emit all but a tail that could be a split opener prefix.
            let keep = Self.controlModeOpener.count - 1
            if loginScan.count > keep {
                let cut = loginScan.count - keep
                emitLogin(Array(loginScan[..<cut]))
                loginScan.removeFirst(cut)
            }
        }
    }

    private func emitLogin(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, let cb = onLoginData else { return }
        let d = Data(bytes)
        DispatchQueue.main.async { cb(d) }
    }

    /// Runs on `queue`. Auto-answer the host-key confirmation ("yes") and the password prompt with
    /// the form-supplied password — each exactly once. Anything else (2FA, a wrong-password retry)
    /// falls through to the manual login terminal.
    private func autoAnswerLogin() {
        let lower = promptTail.lowercased()
        if !answeredHostKey, lower.contains("(yes/no") {
            answeredHostKey = true
            scheduleLoginWrite("yes\n", after: 0.2)
            return
        }
        if !injectedPassword, let pw = loginPassword, !pw.isEmpty, Self.isPasswordPrompt(lower) {
            injectedPassword = true
            // CRITICAL: delay the write. ssh's `readpassphrase` sets the tty with `tcsetattr(TCSAFLUSH)`
            // which DISCARDS pending input — a password written the instant the prompt appears races
            // that flush and gets thrown away (→ "Permission denied"). A short delay lets ssh finish
            // setting up and actually start reading. (Proven against a real docker sshd.)
            scheduleLoginWrite(pw + "\n", after: 0.4)
        }
    }

    /// Write a login response on `queue` after a short delay (see `autoAnswerLogin`).
    private func scheduleLoginWrite(_ s: String, after delay: TimeInterval) {
        let payload = Data(s.utf8)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.transport.write(payload) }
    }

    private static func isPasswordPrompt(_ lower: String) -> Bool {
        let tail = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.hasSuffix("password:") || tail.hasSuffix("passphrase:") || lower.contains("password for ")
    }

    /// Runs on `queue`.
    private func dispatch(_ event: TmuxEvent) {
        switch event {
        case .reply(let reply):
            if reply.flags == 1, !pending.isEmpty {
                let awaiter = pending.removeFirst()
                if reply.isError {
                    let msg = reply.lines.joined(separator: "\n")
                    if let awaiter {
                        // A real awaited command failed → record the reason and propagate it.
                        lastErrorText = msg.isEmpty ? nil : msg
                        awaiter.resume(throwing: TmuxError.commandFailed(msg.isEmpty ? "unknown tmux error" : msg))
                    }
                    // else: a fire-and-forget command errored (e.g. `refresh-client -f pause-after`
                    // on a tmux too old for flow control) — ignore SILENTLY and do NOT poison
                    // lastErrorText, or an optional command's failure would mislabel the close reason.
                } else {
                    awaiter?.resume(returning: reply)
                }
            }
            // flags == 0 → internal/handshake block, ignore.
        case .notification(.exit(let reason)):
            if let reason, !reason.isEmpty { lastErrorText = reason }
            eventContinuation?.yield(event)
            close()
        default:
            eventContinuation?.yield(event)
        }
    }

    private func handleClose() {
        queue.async { self.close() }
    }

    /// Runs on `queue`.
    private func close() {
        guard !closed else { return }
        closed = true
        let closeError = TmuxError.commandFailed(lastErrorText ?? TmuxError.connectionClosed.description)
        for awaiter in pending { awaiter?.resume(throwing: closeError) }
        pending.removeAll()
        // Unblock anyone awaiting control mode (e.g. an ssh login that died before tmux started).
        awaitingControlMode = false
        let waiters = controlModeWaiters; controlModeWaiters.removeAll()
        for w in waiters { w.resume() }
        eventContinuation?.finish()
        eventContinuation = nil
        let cb = onClose
        if let cb { DispatchQueue.main.async { cb() } }
    }
}
