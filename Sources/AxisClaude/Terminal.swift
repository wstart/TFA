import Foundation

// MARK: - Signals

/// Routes SIGINT to the current turn (cancel) instead of killing the program, and reclaims child
/// process groups on SIGTERM/SIGHUP.
final class Interrupts: @unchecked Sendable {
    static let shared = Interrupts()

    private let lock = NSLock()
    private var _count = 0
    private var handler: (() -> Void)?
    private var sources: [DispatchSourceSignal] = []

    /// Incremented on every SIGINT; readers compare snapshots to detect Ctrl-C.
    var count: Int { lock.withLock { _count } }

    func setHandler(_ h: (() -> Void)?) { lock.withLock { handler = h } }

    func install() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in
                if sig == SIGINT {
                    self?.fire()
                } else {
                    Shell.killAll()
                    exit(128 + sig)
                }
            }
            src.resume()
            sources.append(src)
        }
    }

    private func fire() {
        let h: (() -> Void)? = lock.withLock { _count += 1; return handler }
        h?()
    }
}

// MARK: - Line input

enum LineInput: Equatable {
    case line(String)
    case eof
    case interrupted
}

/// Reads lines from stdin with `poll`, so a blocked read can be abandoned on Ctrl-C or when the
/// surrounding task is cancelled.
final class LineReader {
    private var buffer: [UInt8] = []
    private var atEOF = false

    func readLine() -> LineInput {
        let start = Interrupts.shared.count
        while true {
            if let i = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<i], as: UTF8.self)
                buffer.removeFirst(i + 1)
                return .line(line)
            }
            if atEOF {
                if buffer.isEmpty { return .eof }
                defer { buffer.removeAll() }
                return .line(String(decoding: buffer, as: UTF8.self))
            }
            if Interrupts.shared.count != start || Task.isCancelled { return .interrupted }
            var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 100) > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(0, &chunk, chunk.count)
            if n > 0 { buffer += chunk[0..<n] } else if n == 0 || errno != EINTR { atEOF = true }
        }
    }
}

// MARK: - Output

enum Style {
    static let enabled = isatty(1) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    static func wrap(_ s: String, _ code: String) -> String { enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func red(_ s: String) -> String { wrap(s, "31") }
    static func green(_ s: String) -> String { wrap(s, "32") }
}

func out(_ s: String) {
    fputs(s, stdout)
    fflush(stdout)
}

func err(_ s: String) {
    fputs(s, stderr)
    fflush(stderr)
}

/// Renders the agent loop. In print mode (`-p`) only tool activity goes to stderr; the final text
/// is printed by the caller.
final class ConsoleUI: AgentUI {
    let printMode: Bool
    private var waiting = false
    private var thinking = false
    private var atLineStart = true

    init(printMode: Bool) { self.printMode = printMode }

    private func emit(_ s: String) {
        guard !s.isEmpty else { return }
        clearWaiting()
        if printMode { err(s) } else { out(s) }
        atLineStart = s.hasSuffix("\n")
    }

    private func newline() {
        if !atLineStart { emit("\n") }
    }

    private func clearWaiting() {
        guard waiting else { return }
        waiting = false
        out("\r\u{1B}[K")
    }

    func requestStarted() {
        guard !printMode, Style.enabled else { return }
        newline()
        out(Style.dim("思考中…"))
        waiting = true
    }

    func streamEvent(_ event: StreamEvent) {
        guard !printMode else { return }
        switch event {
        case .text(let t):
            if thinking { thinking = false; newline() }
            emit(t)
        case .thinking(let t):
            if !thinking { thinking = true; newline() }
            emit(Style.dim(t))
        case .toolUseStart:
            break
        }
    }

    func responseFinished(_ message: AssistantMessage) {
        clearWaiting()
        thinking = false
        newline()
    }

    func toolStarted(_ summary: String) {
        newline()
        emit(Style.green("●") + " " + Style.bold(summary) + "\n")
    }

    func toolFinished(_ result: ToolResult) {
        let lines = result.content.split(separator: "\n", omittingEmptySubsequences: false)
        var preview = lines.prefix(4).map { l -> String in
            l.count > 160 ? String(l.prefix(160)) + "…" : String(l)
        }
        if lines.count > 4 { preview.append("… (+\(lines.count - 4) 行)") }
        let body = preview.enumerated().map { i, l in (i == 0 ? "  ⎿ " : "    ") + l }.joined(separator: "\n")
        emit((result.isError ? Style.red(body) : Style.dim(body)) + "\n")
    }

    /// Interactive permission prompt for mutating tools; `a` remembers the tool for this session.
    func permissionChecker(reader: LineReader) -> PermissionCheck {
        var always: Set<String> = []
        return { [weak self] tool, _ in
            if always.contains(tool.name) { return .allow }
            while true {
                self?.emit("  允许? [y]是 / [a]本会话总是允许 / [n]否 ")
                self?.atLineStart = true
                switch reader.readLine() {
                case .line(let s):
                    switch s.trimmingCharacters(in: .whitespaces).lowercased() {
                    case "y", "yes": return .allow
                    case "a", "always": always.insert(tool.name); return .allow
                    case "n", "no": return .deny(reason: "用户拒绝")
                    default: continue
                    }
                case .eof, .interrupted:
                    out("\n")
                    return .deny(reason: "用户拒绝")
                }
            }
        }
    }
}
