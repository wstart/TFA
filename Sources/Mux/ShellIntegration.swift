import Foundation

/// Streaming byte-level parser for shell-integration OSC sequences in raw pane output:
/// `ESC ] <code> ; <payload> (BEL | ESC \)`.
///
/// Recognized codes (emitted by `~/.tfa/shell-integration.sh`):
///   `133;A`        — shell is showing a prompt (idle)           (FinalTerm / iTerm2 convention)
///   `133;C`        — a command starts executing (busy)
///   `133;D;<exit>` — the command finished with that exit code
///   `7770;<text>`  — TFA-private: the command line about to run (zsh preexec passes it)
///
/// A per-byte state machine, so sequences split across `%output` chunks parse correctly with no
/// lookback buffer. Any other OSC code is consumed to its terminator and ignored — matching the
/// introducer generically also means a title sequence can never alias into our marks.
struct ShellIntegrationScanner {
    enum Event: Equatable {
        case prompt                // 133;A — at prompt
        case commandStart          // 133;C — command began
        case commandEnd(Int?)      // 133;D — command finished (exit code when parseable)
        case commandText(String)   // 7770  — the command line (trimmed, capped)
    }

    private enum State { case idle, esc, code, payload }
    private var state: State = .idle
    private var code = 0
    private var codeDigits = 0
    private var payload: [UInt8] = []
    private var sawESC = false // inside payload: saw ESC (possible ST `ESC \`)

    /// Payload cap — command lines are capped shell-side too; this is the hard parser bound.
    private static let maxPayload = 256

    mutating func scan(_ data: Data) -> [Event] {
        var out: [Event] = []
        for b in data {
            switch state {
            case .idle:
                if b == 0x1B { state = .esc }
            case .esc:
                if b == 0x5D { state = .code; code = 0; codeDigits = 0 }        // ESC ]
                else { state = (b == 0x1B) ? .esc : .idle }
            case .code:
                if b >= 0x30, b <= 0x39, codeDigits < 6 {
                    code = code * 10 + Int(b - 0x30); codeDigits += 1
                } else if b == 0x3B, codeDigits > 0 {                            // `;` → payload
                    state = .payload; payload = []; sawESC = false
                } else {
                    state = (b == 0x1B) ? .esc : .idle                            // not `code;` — bail
                }
            case .payload:
                if sawESC {
                    if b == 0x5C, let e = Self.event(code, payload) { out.append(e) } // ESC \ = ST
                    reset(); if b == 0x1B { state = .esc }
                    continue
                }
                if b == 0x07 {                                                   // BEL terminator
                    if let e = Self.event(code, payload) { out.append(e) }
                    reset()
                    continue
                }
                if b == 0x1B { sawESC = true; continue }
                if payload.count < Self.maxPayload { payload.append(b) }         // cap; still scans on
            }
        }
        return out
    }

    private mutating func reset() {
        state = .idle; payload = []; sawESC = false; code = 0; codeDigits = 0
    }

    private static func event(_ code: Int, _ payload: [UInt8]) -> Event? {
        switch code {
        case 133:
            let s = String(decoding: payload, as: UTF8.self)
            let segs = s.split(separator: ";", omittingEmptySubsequences: false)
            switch segs.first.map(String.init) {
            case "A": return .prompt
            case "C": return .commandStart
            case "D": return .commandEnd(segs.count > 1 ? Int(segs[1]) : nil)
            default:  return nil // B (prompt end) and unknown marks are irrelevant to TFA
            }
        case 7770:
            let text = String(decoding: payload, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .commandText(text)
        default:
            return nil // some other OSC (title, hyperlink, …) — consumed, ignored
        }
    }
}

/// A shell's integration-reported phase. `.unknown` = the shell has no integration installed (or
/// hasn't emitted a mark yet) — consumers must fall back to the activity heuristic.
enum ShellPhase: Equatable {
    case unknown
    case atPrompt
    case running(since: Date)
}
