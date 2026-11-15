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

    /// Runs (on the signal queue) before exiting on SIGTERM / SIGHUP — e.g. to save the session.
    var beforeExit: (() -> Void)?

    func install() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in
                if sig == SIGINT {
                    self?.fire()
                } else {
                    TerminalModeGuard.restoreAll()
                    Shell.killAll()
                    self?.beforeExit?()
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

/// Remembers active raw/cbreak terminal states so SIGTERM / SIGHUP can restore termios before exit.
enum TerminalModeGuard {
    private static let lock = NSLock()
    private static var saved: [Int32: termios] = [:]

    static func push(fd: Int32, original: termios) {
        lock.withLock { saved[fd] = original }
    }

    static func pop(fd: Int32) {
        if var orig = lock.withLock({ saved.removeValue(forKey: fd) }) {
            _ = tcsetattr(fd, TCSANOW, &orig)
        }
    }

    static func restoreAll() {
        let all = lock.withLock { defer { saved.removeAll() }; return saved }
        for (fd, var orig) in all { _ = tcsetattr(fd, TCSANOW, &orig) }
    }
}

// MARK: - Line input

enum LineInput: Equatable {
    case line(String)
    case eof
    case interrupted
}

/// Reads lines from stdin with `poll`, so a blocked read can be abandoned on Ctrl-C or when the
/// surrounding task is cancelled. On a TTY, temporarily disables `ICANON` so pasted/injected lines
/// longer than macOS `MAX_CANON` (1024 bytes — e.g. Superagent relay/deliver messages) never truncate
/// or hang waiting for an `Enter` that the kernel TTY queue dropped.
final class LineReader {
    private let inputFD: Int32
    private let outputFD: Int32
    private var buffer: [UInt8] = []
    private var pendingUTF8: [UInt8] = []
    private var atEOF = false

    init(inputFD: Int32 = 0, outputFD: Int32 = 1) {
        self.inputFD = inputFD
        self.outputFD = outputFD
    }

    func readLine() -> LineInput {
        if isatty(inputFD) != 0 { return readInteractiveLine(initialTimeoutMS: nil) ?? .eof }
        let start = Interrupts.shared.count
        while true {
            if let i = buffer.firstIndex(of: 10) {
                var slice = Array(buffer[..<i])
                if slice.last == 13 { slice.removeLast() }
                let line = String(decoding: slice, as: UTF8.self)
                buffer.removeFirst(i + 1)
                return .line(line)
            }
            if atEOF {
                if buffer.isEmpty { return .eof }
                defer { buffer.removeAll() }
                return .line(String(decoding: buffer, as: UTF8.self))
            }
            if Interrupts.shared.count != start || Task.isCancelled { return .interrupted }
            if let more = fill(timeoutMS: 100) { if !more { atEOF = true } }
        }
    }

    /// The next line IF more input is already pending (it arrived in the same burst as the previous
    /// line, i.e. a paste); nil once input pauses. Typing never arrives this fast.
    func readPasteContinuation() -> LineInput? {
        if isatty(inputFD) != 0 { return readInteractiveLine(initialTimeoutMS: 15) }
        if buffer.isEmpty, fill(timeoutMS: 15) == nil { return nil }
        if buffer.isEmpty { return nil }
        if let i = buffer.firstIndex(of: 10) {
            var slice = Array(buffer[..<i])
            if slice.last == 13 { slice.removeLast() }
            let line = String(decoding: slice, as: UTF8.self)
            buffer.removeFirst(i + 1)
            return .line(line)
        }
        // A trailing partial line: wait briefly for its newline, else take it as is.
        _ = fill(timeoutMS: 15)
        if let i = buffer.firstIndex(of: 10) {
            var slice = Array(buffer[..<i])
            if slice.last == 13 { slice.removeLast() }
            let line = String(decoding: slice, as: UTF8.self)
            buffer.removeFirst(i + 1)
            return .line(line)
        }
        defer { buffer.removeAll() }
        return .line(String(decoding: buffer, as: UTF8.self))
    }

    /// Non-canonical TTY line reader: unlimited line length, UTF-8-aware backspace, ISIG preserved.
    /// When `initialTimeoutMS` is non-nil, returns `nil` if no byte arrives within that window.
    private func readInteractiveLine(initialTimeoutMS: Int32?) -> LineInput? {
        var orig = termios()
        let hasTermios = tcgetattr(inputFD, &orig) == 0
        if hasTermios {
            var raw = orig
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
            raw.c_iflag |= tcflag_t(ICRNL)
            withUnsafeMutableBytes(of: &raw.c_cc) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
            TerminalModeGuard.push(fd: inputFD, original: orig)
            _ = tcsetattr(inputFD, TCSANOW, &raw)
        }
        defer { if hasTermios { TerminalModeGuard.pop(fd: inputFD) } }

        if let wait = initialTimeoutMS, buffer.isEmpty {
            guard let more = fill(timeoutMS: wait) else { return nil }
            if !more { atEOF = true; return nil }
        }

        let start = Interrupts.shared.count
        var chars: [Character] = []

        while true {
            while let b = popByte() {
                switch b {
                case 10, 13: // \n or \r
                    pendingUTF8.removeAll()
                    // Swallow LF immediately following CR in CRLF paste bursts.
                    if b == 13, buffer.first == 10 { buffer.removeFirst() }
                    writeOut("\n")
                    return .line(String(chars))
                case 4: // Ctrl-D
                    if chars.isEmpty && pendingUTF8.isEmpty { return .eof }
                case 127, 8: // Backspace / Ctrl-H
                    pendingUTF8.removeAll()
                    if let last = chars.popLast() {
                        eraseColumns(Self.displayWidth(of: last))
                    }
                case 21: // Ctrl-U: clear current line
                    pendingUTF8.removeAll()
                    let total = chars.reduce(0) { $0 + Self.displayWidth(of: $1) }
                    chars.removeAll()
                    eraseColumns(total)
                case 27: // ESC: skip CSI / SS3 sequences (arrow keys, Home/End, bracketed paste markers)
                    pendingUTF8.removeAll()
                    consumeEscapeSequence()
                case 9: // Tab
                    chars.append("\t")
                    writeOut("\t")
                case 0..<32:
                    break
                default:
                    pendingUTF8.append(b)
                    if let expected = Self.utf8SequenceLength(firstByte: pendingUTF8[0]) {
                        if pendingUTF8.count >= expected {
                            let decoded = String(decoding: pendingUTF8, as: UTF8.self)
                            pendingUTF8.removeAll()
                            for ch in decoded {
                                chars.append(ch)
                            }
                            writeOut(decoded)
                        }
                    } else {
                        pendingUTF8.removeAll()
                    }
                }
            }
            if atEOF {
                if chars.isEmpty { return .eof }
                writeOut("\n")
                return .line(String(chars))
            }
            if Interrupts.shared.count != start || Task.isCancelled { return .interrupted }
            let timeout: Int32 = initialTimeoutMS != nil && !chars.isEmpty ? 15 : 100
            if let more = fill(timeoutMS: timeout) {
                if !more { atEOF = true }
            } else if initialTimeoutMS != nil && !chars.isEmpty {
                writeOut("\n")
                return .line(String(chars))
            }
        }
    }

    private func popByte() -> UInt8? {
        guard !buffer.isEmpty else { return nil }
        return buffer.removeFirst()
    }

    private func consumeEscapeSequence() {
        if buffer.isEmpty { _ = fill(timeoutMS: 15) }
        guard let next = buffer.first else { return }
        if next == 91 { // '[' CSI
            _ = buffer.removeFirst()
            while true {
                if buffer.isEmpty { if fill(timeoutMS: 15) == nil { return } }
                guard let c = popByte() else { return }
                if (0x40...0x7E).contains(c) { return }
            }
        } else if next == 79 { // 'O' SS3
            _ = buffer.removeFirst()
            if buffer.isEmpty { _ = fill(timeoutMS: 15) }
            _ = popByte()
        }
    }

    private func writeOut(_ s: String) {
        guard outputFD >= 0, !s.isEmpty else { return }
        var copy = s
        copy.withUTF8 { ptr in
            guard let base = ptr.baseAddress else { return }
            var written = 0
            while written < ptr.count {
                let n = Darwin.write(outputFD, base.advanced(by: written), ptr.count - written)
                if n > 0 { written += n }
                else if n < 0 && errno == EINTR { continue }
                else { break }
            }
        }
    }

    private func eraseColumns(_ cols: Int) {
        guard cols > 0 else { return }
        writeOut(String(repeating: "\u{08} \u{08}", count: cols))
    }

    private static func utf8SequenceLength(firstByte b: UInt8) -> Int? {
        if b < 0x80 { return 1 }
        if (0xC2...0xDF).contains(b) { return 2 }
        if (0xE0...0xEF).contains(b) { return 3 }
        if (0xF0...0xF4).contains(b) { return 4 }
        return nil
    }

    private static func displayWidth(of ch: Character) -> Int {
        let w = ch.unicodeScalars.reduce(0) { acc, scalar in
            let cw = wcwidth(wchar_t(scalar.value))
            return acc + max(0, Int(cw))
        }
        return max(1, w)
    }

    /// Reads whatever stdin has within `timeoutMS`: nil = nothing arrived, true = bytes appended,
    /// false = end of input.
    private func fill(timeoutMS: Int32) -> Bool? {
        var pfd = pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, timeoutMS) > 0 else { return nil }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(inputFD, &chunk, chunk.count)
        if n > 0 { buffer += chunk[0..<n]; return true }
        if n == 0 || errno != EINTR { return false }
        return nil
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

    private var toolStartedAt = Date()

    func toolStarted(_ summary: String) {
        newline()
        toolStartedAt = Date()
        emit(Style.green("●") + " " + Style.bold(summary) + "\n")
    }

    func toolFinished(_ result: ToolResult) {
        var lines = result.content.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 { lines.removeLast() }
        var preview = lines.prefix(4).map { l -> String in
            l.count > 160 ? String(l.prefix(160)) + "…" : String(l)
        }
        if lines.count > 4 { preview.append("… (+\(lines.count - 4) 行)") }
        let body = preview.enumerated().map { i, l in
            (i == 0 ? (result.isError ? "  ⎿ ✗ " : "  ⎿ ") : "    ") + l
        }.joined(separator: "\n")
        // Slow tools say how long they took (a quick read/edit doesn't need it).
        let elapsed = Date().timeIntervalSince(toolStartedAt)
        let timing = elapsed >= 1 ? Style.dim(String(format: "  (%.1fs)", elapsed)) : ""
        emit((result.isError ? Style.red(body) : Style.dim(body)) + timing + "\n")
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
