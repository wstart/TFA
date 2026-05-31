import Foundation

// MARK: - Events

/// A single decoded event from the tmux control-mode byte stream.
public enum TmuxEvent: Sendable {
    /// Raw (already octal-decoded) terminal output for a pane — feed straight into the emulator.
    case output(pane: TmuxPaneID, data: Data)
    /// Pause-mode buffered output (3.6 flow control). `ageMs` = ms tmux buffered it.
    case extendedOutput(pane: TmuxPaneID, ageMs: Int, data: Data)
    /// An asynchronous `%`-notification.
    case notification(TmuxNotification)
    /// The reply block for a command (`%begin`…`%end`/`%error`).
    case reply(TmuxReply)
}

/// Reply to a command, framed by `%begin`/`%end` (success) or `%begin`/`%error` (failure).
public struct TmuxReply: Sendable, Equatable {
    public let number: Int
    public let timestamp: Int
    /// 1 = client-issued command, 0 = internal/handshake command.
    public let flags: Int
    public let isError: Bool
    /// Body lines between `%begin` and `%end`/`%error`, UTF-8 decoded.
    public let lines: [String]
    public var success: Bool { !isError }
}

/// Parsed `%`-notifications (see docs/tmux-control-protocol.md §3).
public enum TmuxNotification: Sendable, Equatable {
    case sessionChanged(session: TmuxSessionID, name: String)
    case sessionsChanged
    case sessionRenamed(session: TmuxSessionID, name: String)
    case sessionWindowChanged(session: TmuxSessionID, window: TmuxWindowID)
    case windowAdd(window: TmuxWindowID)
    case windowClose(window: TmuxWindowID)
    case windowRenamed(window: TmuxWindowID, name: String)
    case windowPaneChanged(window: TmuxWindowID, pane: TmuxPaneID)
    case unlinkedWindowAdd(window: TmuxWindowID)
    case unlinkedWindowClose(window: TmuxWindowID)
    case unlinkedWindowRenamed(window: TmuxWindowID, name: String)
    case layoutChange(window: TmuxWindowID, layout: String, visibleLayout: String, flags: String)
    case paneModeChanged(pane: TmuxPaneID)
    case clientSessionChanged(client: String, session: TmuxSessionID, name: String)
    case clientDetached(client: String)
    case continued(pane: TmuxPaneID)
    case paused(pane: TmuxPaneID)
    case subscriptionChanged(name: String, raw: String)
    case exit(reason: String?)
    case configError(String)
    case message(String)
    case pasteBufferChanged(name: String)
    case pasteBufferDeleted(name: String)
    case unknown(String)
}

// MARK: - Parser

/// Incremental, byte-level parser for the tmux control-mode protocol.
///
/// Feed raw bytes from the tmux pipe via `feed(_:)`; it returns the events found so far.
/// Line framing is `\r\n`; the leading DCS opener `\033P1000p` is stripped once. `%output`
/// payloads are kept at the byte level (never round-tripped through `String`) so multibyte
/// UTF-8 split across chunks is never corrupted.
public final class TmuxProtocolParser {
    private enum State {
        case normal
        case block(number: Int, ts: Int, flags: Int)
    }

    private var buffer: [UInt8] = []
    private var strippedOpener = false
    private var state: State = .normal
    private var blockLines: [String] = []

    public init() {}

    /// Feed a chunk of bytes; returns all complete events decoded so far.
    public func feed(_ data: Data) -> [TmuxEvent] {
        buffer.append(contentsOf: data)
        var events: [TmuxEvent] = []
        var start = 0
        var i = 0
        let n = buffer.count
        while i < n {
            if buffer[i] == 0x0A { // \n
                var end = i
                if end > start && buffer[end - 1] == 0x0D { end -= 1 } // strip \r
                processLine(Array(buffer[start..<end]), into: &events)
                start = i + 1
            }
            i += 1
        }
        if start > 0 { buffer.removeFirst(start) }
        return events
    }

    // MARK: line processing

    private func processLine(_ original: [UInt8], into events: inout [TmuxEvent]) {
        var line = original
        if !strippedOpener {
            strippedOpener = true
            if bytesHavePrefix(line, Self.dcsOpener) {
                line.removeFirst(Self.dcsOpener.count)
            }
        }

        switch state {
        case .block(let number, let ts0, let flags0):
            if bytesHavePrefix(line, Self.pEnd) || bytesHavePrefix(line, Self.pError) {
                let isErr = bytesHavePrefix(line, Self.pError)
                let parts = String(decoding: line, as: UTF8.self).split(separator: " ")
                if parts.count >= 3, let num = Int(parts[2]), num == number {
                    let ts = Int(parts[1]) ?? ts0
                    let flags = parts.count >= 4 ? (Int(parts[3]) ?? flags0) : flags0
                    events.append(.reply(TmuxReply(number: num, timestamp: ts, flags: flags,
                                                   isError: isErr, lines: blockLines)))
                    blockLines.removeAll(keepingCapacity: true)
                    state = .normal
                    return
                }
                // cmdnum mismatch → not our terminator; fall through and treat as body.
            }
            blockLines.append(String(decoding: line, as: UTF8.self))

        case .normal:
            if bytesHavePrefix(line, Self.pOutput) {
                handleOutput(line, into: &events)
            } else if bytesHavePrefix(line, Self.pExtOutput) {
                handleExtendedOutput(line, into: &events)
            } else if bytesHavePrefix(line, Self.pBegin) {
                let parts = String(decoding: line, as: UTF8.self).split(separator: " ")
                let num = parts.count >= 3 ? (Int(parts[2]) ?? -1) : -1
                let ts = parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
                let flags = parts.count >= 4 ? (Int(parts[3]) ?? 0) : 0
                state = .block(number: num, ts: ts, flags: flags)
                blockLines.removeAll(keepingCapacity: true)
            } else if line.first == 0x25 { // '%'
                events.append(.notification(parseNotification(String(decoding: line, as: UTF8.self))))
            }
            // else: stray bytes (e.g. trailing ST terminator) → ignore.
        }
    }

    private func handleOutput(_ line: [UInt8], into events: inout [TmuxEvent]) {
        let rest = Array(line[Self.pOutput.count...])
        guard let sp = rest.firstIndex(of: 0x20) else { return }
        let pane = String(decoding: rest[0..<sp], as: UTF8.self)
        let payload = sp + 1 <= rest.count ? Array(rest[(sp + 1)...]) : []
        events.append(.output(pane: pane, data: Self.octalDecode(payload)))
    }

    private func handleExtendedOutput(_ line: [UInt8], into events: inout [TmuxEvent]) {
        let rest = Array(line[Self.pExtOutput.count...])
        guard let r = indexOfSeq(rest, [0x20, 0x3A, 0x20]) else { return } // " : "
        let header = String(decoding: rest[0..<r], as: UTF8.self).split(separator: " ")
        let pane = header.first.map(String.init) ?? ""
        let age = header.count >= 2 ? (Int(header[1]) ?? 0) : 0
        let payload = Array(rest[(r + 3)...])
        events.append(.extendedOutput(pane: pane, ageMs: age, data: Self.octalDecode(payload)))
    }

    // MARK: notification parsing

    private func parseNotification(_ line: String) -> TmuxNotification {
        let keyword: Substring
        if let sp = line.firstIndex(of: " ") {
            keyword = line[line.startIndex..<sp]
        } else {
            keyword = Substring(line)
        }
        switch keyword {
        case "%sessions-changed": return .sessionsChanged
        case "%session-changed":
            let f = splitKeepingTail(line, 2); return .sessionChanged(session: f.at(1), name: f.at(2))
        case "%session-renamed":
            let f = splitKeepingTail(line, 2); return .sessionRenamed(session: f.at(1), name: f.at(2))
        case "%session-window-changed":
            let f = splitKeepingTail(line, 2); return .sessionWindowChanged(session: f.at(1), window: f.at(2))
        case "%window-add":
            let f = splitKeepingTail(line, 1); return .windowAdd(window: f.at(1))
        case "%window-close":
            let f = splitKeepingTail(line, 1); return .windowClose(window: f.at(1))
        case "%window-renamed":
            let f = splitKeepingTail(line, 2); return .windowRenamed(window: f.at(1), name: f.at(2))
        case "%window-pane-changed":
            let f = splitKeepingTail(line, 2); return .windowPaneChanged(window: f.at(1), pane: f.at(2))
        case "%unlinked-window-add":
            let f = splitKeepingTail(line, 1); return .unlinkedWindowAdd(window: f.at(1))
        case "%unlinked-window-close":
            let f = splitKeepingTail(line, 1); return .unlinkedWindowClose(window: f.at(1))
        case "%unlinked-window-renamed":
            let f = splitKeepingTail(line, 2); return .unlinkedWindowRenamed(window: f.at(1), name: f.at(2))
        case "%layout-change":
            let f = splitKeepingTail(line, 4)
            return .layoutChange(window: f.at(1), layout: f.at(2), visibleLayout: f.at(3), flags: f.at(4))
        case "%pane-mode-changed":
            let f = splitKeepingTail(line, 1); return .paneModeChanged(pane: f.at(1))
        case "%client-session-changed":
            let f = splitKeepingTail(line, 3); return .clientSessionChanged(client: f.at(1), session: f.at(2), name: f.at(3))
        case "%client-detached":
            let f = splitKeepingTail(line, 1); return .clientDetached(client: f.at(1))
        case "%continue":
            let f = splitKeepingTail(line, 1); return .continued(pane: f.at(1))
        case "%pause":
            let f = splitKeepingTail(line, 1); return .paused(pane: f.at(1))
        case "%subscription-changed":
            let f = splitKeepingTail(line, 1); return .subscriptionChanged(name: f.at(1), raw: line)
        case "%exit":
            return line == "%exit" ? .exit(reason: nil) : .exit(reason: String(line.dropFirst("%exit ".count)))
        case "%config-error":
            return .configError(String(line.dropFirst("%config-error ".count)))
        case "%message":
            return .message(String(line.dropFirst("%message ".count)))
        case "%paste-buffer-changed":
            let f = splitKeepingTail(line, 1); return .pasteBufferChanged(name: f.at(1))
        case "%paste-buffer-deleted":
            let f = splitKeepingTail(line, 1); return .pasteBufferDeleted(name: f.at(1))
        default:
            return .unknown(line)
        }
    }

    // MARK: octal decode

    /// Decode a `%output` payload: `\NNN` (3 octal digits) → byte; everything else verbatim.
    static func octalDecode(_ bytes: [UInt8]) -> Data {
        var out = Data()
        out.reserveCapacity(bytes.count)
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if b == 0x5C, i + 3 < n,
               isOctalDigit(bytes[i + 1]), isOctalDigit(bytes[i + 2]), isOctalDigit(bytes[i + 3]) {
                let v = (Int(bytes[i + 1] - 0x30) << 6) | (Int(bytes[i + 2] - 0x30) << 3) | Int(bytes[i + 3] - 0x30)
                out.append(UInt8(v & 0xFF))
                i += 4
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    // MARK: static prefixes

    private static let pOutput = Array("%output ".utf8)
    private static let pExtOutput = Array("%extended-output ".utf8)
    private static let pBegin = Array("%begin ".utf8)
    private static let pEnd = Array("%end ".utf8)
    private static let pError = Array("%error ".utf8)
    private static let dcsOpener: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70] // ESC P 1 0 0 0 p
}

// MARK: - byte helpers

@inline(__always)
private func bytesHavePrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
    guard bytes.count >= prefix.count else { return false }
    for i in 0..<prefix.count where bytes[i] != prefix[i] { return false }
    return true
}

@inline(__always)
private func isOctalDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x37 }

/// Index of the first occurrence of `seq` in `bytes`, or nil.
private func indexOfSeq(_ bytes: [UInt8], _ seq: [UInt8]) -> Int? {
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

private func splitKeepingTail(_ s: String, _ maxSplits: Int) -> [String] {
    s.split(separator: " ", maxSplits: maxSplits, omittingEmptySubsequences: false).map(String.init)
}

private extension Array where Element == String {
    func at(_ i: Int) -> String { indices.contains(i) ? self[i] : "" }
}
